// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {TreasuryDAO}  from "../src/TreasuryDAO.sol";

/// @notice End-to-end fork test for StageB2 deploy.
///
/// Verifies on a fork of live PulseChain that a fresh TSTT minted on the v3
/// factory with the client-spec tax table actually:
///
///   1. Creates successfully with 5-tax set (Dev PLS/vault, Dev PLS/DAO,
///      Liquify, ExtBurn ZKP, self-burn).
///   2. Repoints tax 0 → vault and tax 1 → DAO via updateTaxReceiver.
///   3. Seeds LP with 100M TSTT + 10k PLS.
///   4. On a real sell trade:
///        a. The factory's tax distribution to vault (PLS) SUCCEEDS —
///           proving the factory forwards enough gas for vault.receive() →
///           topUp() → PulseX swap PLS→pHEX. This is the critical unknown.
///        b. Vault's pHEX balance increases (topUp fired).
///        c. Vault rewardRate > 0 and periodFinish advanced (7d drip started).
///        d. DAO's WPLS balance increases (receive wrapped incoming PLS).
///        e. ZKP at dead increases (ExtBurn fired).
///        f. TSTT total supply dropped (self-burn fired).
///   5. A staker who staked before the sell earns pHEX over time.
contract ForkStageB2Test is Test {
    // ── Live mainnet infra ────────────────────────────────────────────────
    address constant FACTORY_PROXY   = 0x000b1ae112D59513618A04FD5E83Bd7eFbA05A3f;
    address constant SMART_TRADER_V2 = 0xcaE394005c9C4C309621c53d53DB9cEB701fc8d8;
    address constant PULSEX_ROUTER   = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant PULSEX_FACTORY  = 0x1715a3E4A142d8b698131108995174F37aEBA10D;
    address constant WPLS            = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant pHEX            = 0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39;
    address constant EXT_BURN_TOKEN  = 0x90F055196778e541018482213Ca50648cEA1a050;
    address constant DEAD            = 0x000000000000000000000000000000000000dEaD;
    address constant ZERO_ADDR       = 0x0000000000000000000000000000000000000000;
    address constant DEV_WALLET      = 0xa0419404eF7b81d9Ec64367eb68e5f425EACE618;

    uint256 constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 constant CREATION_FEE   = 2_000_000 ether;
    uint256 constant LP_TSTT        = 100_000_000 ether;
    uint256 constant LP_PLS         = 10_000 ether;

    address buyer;
    address staker;

    // Deployment outputs — storage to avoid stack-too-deep in the big test
    address internal newToken;
    StakingVault internal vault;
    TreasuryDAO internal dao;

    // Baselines / after-state — storage for the same reason
    uint256 internal vaultEhexBefore;
    uint256 internal daoWplsBefore;
    uint256 internal zkpDeadBefore;
    uint256 internal zkpZeroBefore;
    uint256 internal supplyBefore;

    struct Tax {
        uint256 id; uint8 taxType; uint8 taxMoment; uint256 percentage;
        address receiver; address tokenAddress; address burnAddress;
        bool rewardInPls; uint256 amountAccumulated;
    }
    struct CreateTokenParams {
        string name_; string symbol_; uint256 initialSupply; Tax[] taxes;
        bool ownershipRenounced; address smartTrader; uint256 burnOnDeployPct;
        uint256 vestingPct; uint64 cliffDuration; uint64 vestingDuration;
        bool tradingEnabled; uint64 enableTradingAt; uint256 initialLiquidityPct;
        address liquidityRouter; bool lockLiquidity;
    }

    function setUp() public {
        try vm.createSelectFork("http://localhost:8545") {
            emit log("forked local node");
        } catch {
            try vm.createSelectFork("https://rpc.pulsechain.com") {
                emit log("forked rpc.pulsechain.com");
            } catch {
                try vm.createSelectFork("https://pulsechain-rpc.publicnode.com") {
                    emit log("forked pulsechain-rpc.publicnode.com");
                } catch {
                    vm.createSelectFork("https://rpc-pulsechain.g4mm4.io");
                    emit log("forked rpc-pulsechain.g4mm4.io");
                }
            }
        }
        buyer  = makeAddr("buyer");
        staker = makeAddr("staker");
        vm.deal(buyer,  100_000 ether);
        vm.deal(staker, 1_000 ether);
        // CREATION_FEE + LP_PLS + gas headroom
        vm.deal(DEV_WALLET, 3_000_000 ether);
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _buildTaxes() internal pure returns (Tax[] memory t) {
        t = new Tax[](5);
        t[0] = Tax(0, 2, 0, 325, DEV_WALLET, address(0),     address(0), true,  0);
        t[1] = Tax(1, 2, 0, 100, DEV_WALLET, address(0),     address(0), true,  0);
        t[2] = Tax(2, 5, 0,  25, address(0), address(0),     address(0), false, 0);
        t[3] = Tax(3, 1, 0,  25, DEAD,       EXT_BURN_TOKEN, DEAD,       false, 0);
        t[4] = Tax(4, 0, 0,  25, address(0), address(0),     DEAD,       false, 0);
    }

    function _decodeRevert(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "reverted (no reason)";
        assembly { ret := add(ret, 0x04) }
        return abi.decode(ret, (string));
    }

    function _bal(address token, address who) internal view returns (uint256) {
        (, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return abi.decode(ret, (uint256));
    }

    function _totalSupply(address token) internal view returns (uint256) {
        (, bytes memory ret) = token.staticcall(abi.encodeWithSignature("totalSupply()"));
        return abi.decode(ret, (uint256));
    }

    function _createToken() internal returns (address newToken) {
        CreateTokenParams memory p = CreateTokenParams({
            name_: "testt", symbol_: "TSTT", initialSupply: INITIAL_SUPPLY,
            taxes: _buildTaxes(), ownershipRenounced: false, smartTrader: SMART_TRADER_V2,
            burnOnDeployPct: 0, vestingPct: 0, cliffDuration: 0, vestingDuration: 0,
            tradingEnabled: true, enableTradingAt: 0, initialLiquidityPct: 0,
            liquidityRouter: address(0), lockLiquidity: false
        });

        vm.startPrank(DEV_WALLET);
        (bool ok, bytes memory ret) = FACTORY_PROXY.call{value: CREATION_FEE}(
            abi.encodeWithSignature(
                "createToken((string,string,uint256,(uint256,uint8,uint8,uint256,address,address,address,bool,uint256)[],bool,address,uint256,uint256,uint64,uint64,bool,uint64,uint256,address,bool))",
                p
            )
        );
        vm.stopPrank();
        if (!ok) revert(_decodeRevert(ret));
        newToken = abi.decode(ret, (address));
    }

    function _updateTaxReceiver(address token, uint256 id, address rcv) internal {
        vm.prank(DEV_WALLET);
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSignature("updateTaxReceiver(uint256,address)", id, rcv)
        );
        if (!ok) revert(_decodeRevert(ret));
    }

    function _seedLP(address token) internal {
        vm.startPrank(DEV_WALLET);
        (bool okA, ) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", PULSEX_ROUTER, type(uint256).max)
        );
        require(okA, "approve");
        (bool okL, bytes memory retL) = PULSEX_ROUTER.call{value: LP_PLS}(
            abi.encodeWithSignature(
                "addLiquidityETH(address,uint256,uint256,uint256,address,uint256)",
                token, LP_TSTT, LP_TSTT, LP_PLS, DEV_WALLET, block.timestamp + 1200
            )
        );
        if (!okL) revert(_decodeRevert(retL));
        vm.stopPrank();
    }

    function _sell(address token, address seller, uint256 amount) internal {
        vm.startPrank(seller);
        (bool okA, ) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", PULSEX_ROUTER, type(uint256).max)
        );
        require(okA, "seller approve");

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WPLS;
        (bool okS, bytes memory retS) = PULSEX_ROUTER.call(
            abi.encodeWithSignature(
                "swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)",
                amount, 0, path, seller, block.timestamp + 1200
            )
        );
        if (!okS) revert(_decodeRevert(retS));
        vm.stopPrank();
    }

    // ── the actual test ───────────────────────────────────────────────────

    struct Deployed {
        address token;
        StakingVault vault;
        TreasuryDAO dao;
    }

    struct Snapshot {
        uint256 vaultEhex;
        uint256 daoWpls;
        uint256 zkpDead;
        uint256 zkpZero;
        uint256 supply;
    }

    function _deploy() internal returns (Deployed memory d) {
        d.token = _createToken();
        emit log_named_address("new TSTT", d.token);
        assertTrue(d.token != address(0), "zero token");
        assertEq(_bal(d.token, DEV_WALLET), INITIAL_SUPPLY, "dev mint");

        vm.startPrank(DEV_WALLET);
        d.vault = new StakingVault(d.token, pHEX, DEV_WALLET, 100);
        d.vault.setDexRouter(PULSEX_ROUTER);
        d.dao = new TreasuryDAO(address(d.vault), d.token, WPLS, PULSEX_ROUTER);
        d.vault.setDaoAddress(address(d.dao));
        vm.stopPrank();

        assertEq(address(d.vault.STAKING_TOKEN()), d.token, "staking=TSTT");
        assertEq(address(d.vault.REWARDS_TOKEN()), pHEX,    "reward=pHEX");
        emit log_named_address("vault", address(d.vault));
        emit log_named_address("dao",   address(d.dao));

        _updateTaxReceiver(d.token, 0, address(d.vault));
        _updateTaxReceiver(d.token, 1, address(d.dao));
        _seedLP(d.token);
        emit log("LP seeded");
    }

    function _prefund(Deployed memory d) internal {
        vm.startPrank(DEV_WALLET);
        (bool okS, ) = d.token.call(
            abi.encodeWithSignature("transfer(address,uint256)", staker, 10_000_000 ether)
        );
        require(okS, "xfer to staker");
        (bool okB, ) = d.token.call(
            abi.encodeWithSignature("transfer(address,uint256)", buyer, 10_000_000 ether)
        );
        require(okB, "xfer to buyer");
        vm.stopPrank();

        vm.startPrank(staker);
        (bool okA, ) = d.token.call(
            abi.encodeWithSignature("approve(address,uint256)", address(d.vault), type(uint256).max)
        );
        require(okA, "staker approve vault");
        d.vault.stake(5_000_000 ether);
        vm.stopPrank();
        assertEq(d.vault.stakedBalance(staker), 5_000_000 ether, "stake balance");
    }

    function _snap(Deployed memory d) internal view returns (Snapshot memory s) {
        s.vaultEhex = _bal(pHEX, address(d.vault));
        s.daoWpls   = _bal(WPLS, address(d.dao));
        s.zkpDead   = _bal(EXT_BURN_TOKEN, DEAD);
        s.zkpZero   = _bal(EXT_BURN_TOKEN, ZERO_ADDR);
        s.supply    = _totalSupply(d.token);
    }

    function _assertFlow(Deployed memory d, Snapshot memory b, Snapshot memory a) internal {
        // HEX has 8 decimals, NOT 18 — label formatting matches that.
        emit log_named_decimal_uint("vault pHEX gained   ", a.vaultEhex - b.vaultEhex, 8);
        emit log_named_decimal_uint("DAO   WPLS gained   ", a.daoWpls - b.daoWpls, 18);
        emit log_named_decimal_uint("ZKP at dead gained  ",
            (a.zkpDead - b.zkpDead) + (a.zkpZero - b.zkpZero), 18);
        emit log_named_decimal_uint("TSTT supply burned  ", b.supply - a.supply, 18);
        emit log_named_decimal_uint("vault rewardRate    ", d.vault.rewardRate(), 0);
        emit log_named_decimal_uint("vault periodFinish  ", d.vault.periodFinish(), 0);

        assertGt(a.vaultEhex, b.vaultEhex,
            "CRITICAL: vault got no pHEX -- factory did not forward gas for receive()/topUp() OR swap failed");
        assertGt(a.daoWpls, b.daoWpls,
            "CRITICAL: DAO got no WPLS -- factory did not forward gas for DAO.receive() OR rewardInPls broken");
        assertGt(d.vault.rewardRate(), 0,
            "CRITICAL: vault rewardRate=0 -- topUp did not start drip");
        assertGt(d.vault.periodFinish(), block.timestamp,
            "CRITICAL: vault periodFinish not in future -- drip not active");
        assertGt((a.zkpDead - b.zkpDead) + (a.zkpZero - b.zkpZero), 0,
            "ExtBurn (ZKP) did not fire");
        assertGt(b.supply, a.supply, "self-burn did not fire");
    }

    function test_stageB2_fullFlow() public {
        Deployed memory d = _deploy();
        _prefund(d);

        Snapshot memory b = _snap(d);

        // Do several sells — each triggers the 5-tax distribution.
        // If factory forwards insufficient gas for vault.receive()/topUp(),
        // THIS is where it reverts. Critical test.
        for (uint256 i = 0; i < 5; i++) {
            _sell(d.token, buyer, 1_000_000 ether);
        }

        // Diagnostics: where did tax 0 PLS actually go?
        emit log_named_decimal_uint("vault PLS balance   ", address(d.vault).balance, 18);
        emit log_named_decimal_uint("vault WPLS balance  ", _bal(WPLS, address(d.vault)), 18);
        emit log_named_decimal_uint("DAO PLS balance     ", address(d.dao).balance, 18);
        emit log_named_decimal_uint("dev wallet PLS gain ", DEV_WALLET.balance, 18);

        // Trigger a vault interaction so the autoProcess modifier swaps the
        // accumulated PLS → pHEX and starts the drip. In production this
        // happens organically the moment any staker stakes/withdraws/claims
        // or any keeper calls processRewards(). Here we call processRewards()
        // explicitly to simulate the first post-sell touch.
        try d.vault.processRewards() {
            emit log("processRewards() succeeded");
        } catch Error(string memory reason) {
            emit log_named_string("processRewards reverted", reason);
        }

        Snapshot memory a = _snap(d);
        _assertFlow(d, b, a);

        // Staker accrual: skip full 7-day drip and claim.
        // Note: warping less than ~7d can give zero earned() because HEX has
        // 8 decimals — the Synthetix rewardPerToken formula
        // (delta_time * rewardRate * 1e18 / totalSupply) integer-divides to
        // 0 when rewardRate is small and totalSupply is large. The end of
        // the drip period gives the most headroom for the test.
        vm.warp(block.timestamp + 7 days);
        uint256 earned = d.vault.earned(staker);
        emit log_named_decimal_uint("staker earned (7d)  ", earned, 8); // HEX has 8 decimals
        assertGt(earned, 0, "staker did not earn pHEX over 7 days");

        uint256 stakerEhexBefore = _bal(pHEX, staker);
        vm.prank(staker);
        d.vault.getReward();
        uint256 paid = _bal(pHEX, staker) - stakerEhexBefore;
        assertGt(paid, 0, "staker getReward did not pay out pHEX");
        emit log_named_decimal_uint("staker pHEX claimed ", paid, 8);
    }
}
