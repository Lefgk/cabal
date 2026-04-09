// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

/// @notice Re-creates the cabal stake token (`testt` / TSTT) on the upgraded
///         PulseFun v3 TokenFactoryTax, preserving ALL original parameters:
///         name, symbol, decimals (18 fixed), supply, and the full 5-tax set.
///
/// Resulting live TSTT:   0xAbEaBFE146F347537b82426B4c4d8F1E768721C7
/// (Historical parameter source was the pre-migration v2 clone; no longer relevant.)
///
///   name           testt
///   symbol         TSTT
///   initialSupply  1,000,000,000 * 1e18
///   tradingEnabled true
///   taxes:
///     0: Dev   (2)       3.25% → StakingVault, reward eHEX (was Yield(4) in prior
///                        clones; switched because v3 Yield is a holder-reflection
///                        pool that ignores tax.receiver — Dev type swaps WPLS→eHEX
///                        and transfers directly to receiver, which is what we want)
///     1: Dev   (2)       1.00% → dev wallet, reward PLS
///     2: Liquify (5)     0.25% auto-LP
///     3: ExternalBurn(1) 0.25% burn external token 0x90F0...a050 to dead
///     4: Burn  (0)       0.25% burn self to dead
///
/// Factory v3 is the SAME proxy as v2 (UUPS upgrade in place):
///   0x000b1ae112D59513618A04FD5E83Bd7eFbA05A3f
///
/// Broadcaster: pk_618_sai (matches the old token's owner wallet
///              0xa0419404eF7b81d9Ec64367eb68e5f425EACE618). msg.sender
///              becomes both mintTo and the new token's owner.
contract CreateStakeTokenScript is Script {
    // ── Factory (v3 impl behind the same proxy) ───────────────────────────
    address constant FACTORY = 0x000b1ae112D59513618A04FD5E83Bd7eFbA05A3f;

    // ── Per-token support contract (from PulseFun UI config) ──────────────
    address constant SMART_TRADER_V2 = 0xcaE394005c9C4C309621c53d53DB9cEB701fc8d8;

    // ── Tax receivers / token refs pulled from the live TSTT ──────────────
    address constant STAKING_VAULT       = 0xDb15ee3255E7158f1823220D73f1403c18b474E6;
    address constant eHEX                = 0x57fde0a71132198BBeC939B98976993d8D89D225;
    address constant DEV_WALLET          = 0xa0419404eF7b81d9Ec64367eb68e5f425EACE618;
    address constant EXT_BURN_TOKEN      = 0x90F055196778e541018482213Ca50648cEA1a050;
    address constant DEAD                = 0x000000000000000000000000000000000000dEaD;

    // ── Economics (unchanged from TSTT) ───────────────────────────────────
    uint256 constant INITIAL_SUPPLY = 1_000_000_000 ether; // 1e9 * 1e18

    // TaxType:   0=Burn, 1=ExternalBurn, 2=Dev, 3=Reflection, 4=Yield, 5=Liquify
    // TaxMoment: 0=Both, 1=Buy, 2=Sell

    struct Tax {
        uint256 id;
        uint8   taxType;
        uint8   taxMoment;
        uint256 percentage;
        address receiver;
        address tokenAddress;
        address burnAddress;
        bool    rewardInPls;
        uint256 amountAccumulated;
    }

    struct CreateTokenParams {
        string   name_;
        string   symbol_;
        uint256  initialSupply;
        Tax[]    taxes;
        bool     ownershipRenounced;
        address  smartTrader;
        uint256  burnOnDeployPct;
        uint256  vestingPct;
        uint64   cliffDuration;
        uint64   vestingDuration;
        bool     tradingEnabled;
        uint64   enableTradingAt;
        uint256  initialLiquidityPct;
        address  liquidityRouter;
        bool     lockLiquidity;
    }

    function run() external {
        uint256 pk = vm.envUint("pk_618_sai");
        address broadcaster = vm.addr(pk);
        require(broadcaster == DEV_WALLET, "Broadcaster != original TSTT owner");

        Tax[] memory taxes = new Tax[](5);

        // 0: Dev 3.25% reward in eHEX → DEV_WALLET (placeholder; will updateTaxReceiver
        //    to the fresh StakingVault immediately after token creation). Dev type is
        //    the only tax code path that actually honors tax.receiver for non-PLS rewards.
        taxes[0] = Tax({
            id: 0,
            taxType: 2,            // Dev
            taxMoment: 0,          // Both
            percentage: 325,
            receiver: DEV_WALLET,
            tokenAddress: eHEX,
            burnAddress: DEAD,
            rewardInPls: false,
            amountAccumulated: 0
        });

        // 1: Dev 1% → DEV_WALLET, reward paid in PLS
        taxes[1] = Tax({
            id: 1,
            taxType: 2,            // Dev
            taxMoment: 0,
            percentage: 100,
            receiver: DEV_WALLET,
            tokenAddress: address(0),
            burnAddress: address(0),
            rewardInPls: true,
            amountAccumulated: 0
        });

        // 2: Liquify 0.25% (auto-LP)
        taxes[2] = Tax({
            id: 2,
            taxType: 5,            // Liquify
            taxMoment: 0,
            percentage: 25,
            receiver: address(0),
            tokenAddress: address(0),
            burnAddress: address(0),
            rewardInPls: false,
            amountAccumulated: 0
        });

        // 3: ExternalBurn 0.25% (burn 0x90F0...a050 to dead)
        taxes[3] = Tax({
            id: 3,
            taxType: 1,            // ExternalBurn
            taxMoment: 0,
            percentage: 25,
            receiver: DEAD,
            tokenAddress: EXT_BURN_TOKEN,
            burnAddress: DEAD,
            rewardInPls: false,
            amountAccumulated: 0
        });

        // 4: Burn 0.25% (self-burn to dead)
        taxes[4] = Tax({
            id: 4,
            taxType: 0,            // Burn
            taxMoment: 0,
            percentage: 25,
            receiver: address(0),
            tokenAddress: address(0),
            burnAddress: DEAD,
            rewardInPls: false,
            amountAccumulated: 0
        });

        CreateTokenParams memory p = CreateTokenParams({
            name_:               "testt",
            symbol_:             "TSTT",
            initialSupply:       INITIAL_SUPPLY,
            taxes:               taxes,
            ownershipRenounced:  false,
            smartTrader:         SMART_TRADER_V2,
            burnOnDeployPct:     0,
            vestingPct:          0,
            cliffDuration:       0,
            vestingDuration:     0,
            tradingEnabled:      true,
            enableTradingAt:     0,
            initialLiquidityPct: 0,                // LP was seeded manually post-create on the original
            liquidityRouter:     address(0),
            lockLiquidity:       false
        });

        console.log("=== Creating TSTT clone on v3 factory ===");
        console.log("Factory:    ", FACTORY);
        console.log("Broadcaster:", broadcaster);

        vm.startBroadcast(pk);
        (bool ok, bytes memory ret) = FACTORY.call{value: 0}(
            abi.encodeWithSignature(
                "createToken((string,string,uint256,(uint256,uint8,uint8,uint256,address,address,address,bool,uint256)[],bool,address,uint256,uint256,uint64,uint64,bool,uint64,uint256,address,bool))",
                p
            )
        );
        vm.stopBroadcast();

        require(ok, _revertMsg(ret));
        address newToken = abi.decode(ret, (address));

        console.log("=== NEW TSTT DEPLOYED ===");
        console.log("New token address:", newToken);
        console.log("Otterscan: https://otter.pulsechain.com/address/");
        console.log(newToken);
    }

    function _revertMsg(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "createToken reverted with no reason";
        assembly { ret := add(ret, 0x04) }
        return abi.decode(ret, (string));
    }
}
