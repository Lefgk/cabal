// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {TreasuryDAO}  from "../src/TreasuryDAO.sol";

interface IERC20 {
    function approve(address s, uint256 a) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 a) external returns (bool);
}

interface IPulseXRouter {
    function addLiquidityETH(
        address token, uint256 aDes, uint256 aMin, uint256 eMin,
        address to, uint256 dl
    ) external payable returns (uint256, uint256, uint256);
    function factory() external view returns (address);
}
interface IPulseXFactory { function getPair(address,address) external view returns (address); }

/// @notice Stage B v2 — corrected redeploy per client spec:
///
///   tax 0: Dev 3.25% rewardInPls=true → new StakingVault
///          Vault's autoProcess modifier converts accumulated PLS to pHEX on
///          every user action (swap via PulseX), and the Synthetix StakingRewards
///          drip releases pHEX linearly over 7 days (ZKP pattern).
///   tax 1: Dev 1.00% rewardInPls=true → new TreasuryDAO
///          DAO.receive() auto-wraps incoming PLS to WPLS for proposal spend.
///   tax 2: Liquify 0.25% (auto-LP)
///   tax 3: ExternalBurn 0.25% ZKP → dead
///   tax 4: Burn 0.25% self → dead
///
/// Vault is deployed as STAKING=newTSTT, REWARDS=pHEX (cross-token; staked
/// principal and rewards are fully separate — no single-token workaround).
/// pHEX = native PulseChain HEX (0x2b59...eb39). Per client update 2026-04-09.
///
/// This script does NOT touch the old TSTT / old vault / old DAO. It only
/// creates the new stack. Old contracts remain on-chain and can be paused
/// separately if desired.
///
/// Forge script semantics: running without `--broadcast` performs a pure
/// dry-run against the forked chain (no tx signed, no state committed).
contract StageB2Script is Script {
    // ── Live PulseChain infra ─────────────────────────────────────────────
    address constant FACTORY_PROXY   = 0x000b1ae112D59513618A04FD5E83Bd7eFbA05A3f;
    address constant SMART_TRADER_V2 = 0xcaE394005c9C4C309621c53d53DB9cEB701fc8d8;
    address constant PULSEX_ROUTER   = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant WPLS            = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant pHEX            = 0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39;
    address constant EXT_BURN_TOKEN  = 0x90F055196778e541018482213Ca50648cEA1a050; // ZKP
    address constant DEAD            = 0x000000000000000000000000000000000000dEaD;
    address constant DEV_WALLET      = 0xa0419404eF7b81d9Ec64367eb68e5f425EACE618;

    // ── Economics ─────────────────────────────────────────────────────────
    uint256 constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 constant CREATION_FEE   = 2_000_000 ether;
    uint256 constant LP_TSTT        = 100_000_000 ether;
    uint256 constant LP_PLS         = 10_000 ether;

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

    /// @dev Tax 0 and Tax 1 receivers are initially DEV_WALLET placeholders;
    ///      they are re-pointed to the real vault / DAO via updateTaxReceiver
    ///      after those contracts are deployed (chicken-and-egg: the token
    ///      must exist before the vault can be constructed around it).
    function _taxes() internal pure returns (Tax[] memory t) {
        t = new Tax[](5);
        t[0] = Tax(0, 2, 0, 325, DEV_WALLET, address(0),     address(0), true,  0);
        t[1] = Tax(1, 2, 0, 100, DEV_WALLET, address(0),     address(0), true,  0);
        t[2] = Tax(2, 5, 0,  25, address(0), address(0),     address(0), false, 0);
        t[3] = Tax(3, 1, 0,  25, DEAD,       EXT_BURN_TOKEN, DEAD,       false, 0);
        t[4] = Tax(4, 0, 0,  25, address(0), address(0),     DEAD,       false, 0);
    }

    function _revertMsg(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "reverted (no reason)";
        assembly { ret := add(ret, 0x04) }
        return abi.decode(ret, (string));
    }

    function _createNewTSTT() internal returns (address newTSTT) {
        CreateTokenParams memory p = CreateTokenParams({
            name_: "testt", symbol_: "TSTT", initialSupply: INITIAL_SUPPLY,
            taxes: _taxes(), ownershipRenounced: false, smartTrader: SMART_TRADER_V2,
            burnOnDeployPct: 0, vestingPct: 0, cliffDuration: 0, vestingDuration: 0,
            tradingEnabled: true, enableTradingAt: 0, initialLiquidityPct: 0,
            liquidityRouter: address(0), lockLiquidity: false
        });
        (bool ok, bytes memory ret) = FACTORY_PROXY.call{value: CREATION_FEE}(
            abi.encodeWithSignature(
                "createToken((string,string,uint256,(uint256,uint8,uint8,uint256,address,address,address,bool,uint256)[],bool,address,uint256,uint256,uint64,uint64,bool,uint64,uint256,address,bool))",
                p
            )
        );
        if (!ok) revert(_revertMsg(ret));
        newTSTT = abi.decode(ret, (address));
    }

    function _updateTaxReceiver(address token, uint256 id, address receiver) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSignature("updateTaxReceiver(uint256,address)", id, receiver)
        );
        if (!ok) revert(_revertMsg(ret));
    }

    function _seedNewLP(address newTSTT, address bcast) internal {
        require(IERC20(newTSTT).approve(PULSEX_ROUTER, LP_TSTT), "new TSTT approve");
        IPulseXRouter(PULSEX_ROUTER).addLiquidityETH{value: LP_PLS}(
            newTSTT, LP_TSTT, LP_TSTT, LP_PLS, bcast, block.timestamp + 1200
        );
    }

    function run() external {
        uint256 pk = vm.envUint("pk_618_sai");
        address bcast = vm.addr(pk);
        require(bcast == DEV_WALLET, "Broadcaster != dev wallet");

        console.log("=== STAGE B2 ===");
        console.log("broadcaster:", bcast);
        console.log("PLS balance:", bcast.balance);

        vm.startBroadcast(pk);

        // 1. Create new TSTT (tax 0/1 receivers are placeholders)
        address newTSTT = _createNewTSTT();
        console.log("new TSTT:", newTSTT);
        require(IERC20(newTSTT).balanceOf(bcast) == INITIAL_SUPPLY, "mint mismatch");

        // 2. Deploy vault: STAKING=newTSTT, REWARDS=pHEX
        StakingVault vault = new StakingVault(newTSTT, pHEX, bcast, 100);
        vault.setDexRouter(PULSEX_ROUTER);
        console.log("new vault:", address(vault));

        // 3. Deploy DAO wired to vault + new TSTT
        TreasuryDAO dao = new TreasuryDAO(address(vault), newTSTT, WPLS, PULSEX_ROUTER);
        console.log("new DAO:  ", address(dao));

        // 4. Wire vault → DAO
        vault.setDaoAddress(address(dao));

        // 5. Repoint taxes
        _updateTaxReceiver(newTSTT, 0, address(vault));
        console.log("tax[0] receiver -> vault OK");
        _updateTaxReceiver(newTSTT, 1, address(dao));
        console.log("tax[1] receiver -> DAO OK");

        // 6. Seed new LP
        _seedNewLP(newTSTT, bcast);

        address newPair = IPulseXFactory(IPulseXRouter(PULSEX_ROUTER).factory())
            .getPair(newTSTT, WPLS);

        vm.stopBroadcast();

        console.log("");
        console.log("=== STAGE B2 COMPLETE ===");
        console.log("NEW_TSTT ", newTSTT);
        console.log("NEW_VAULT", address(vault));
        console.log("NEW_DAO  ", address(dao));
        console.log("NEW_PAIR ", newPair);
    }
}
