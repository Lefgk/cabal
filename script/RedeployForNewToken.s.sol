// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {TreasuryDAO} from "../src/TreasuryDAO.sol";

/// @notice Atomically:
///   1. Deploys a fresh StakingVault wired to the NEW TSTT
///   2. Deploys a fresh TreasuryDAO wired to the new vault + new TSTT
///   3. vault.setDexRouter(PULSEX_ROUTER)
///   4. vault.setDaoAddress(newDAO)
///   5. Calls newToken.updateTaxReceiver(0, newVault) so the 3.25% Yield→eHEX
///      tax routes to the NEW vault instead of the old one. Tax id 0 was
///      verified on-chain to be the Yield→eHEX→old vault entry.
///
/// Broadcaster MUST be 0xa041...E618 (the new TSTT owner) so that
/// updateTaxReceiver passes the onlyOwner check.
contract RedeployForNewTokenScript is Script {
    // ── New token deployed in CreateStakeTokenScript ──────────────────────
    address constant NEW_TSTT = 0x584cb57d12dDea0c8A20299f1e972fFF6f581161;

    // ── PulseChain constants (mirrors DeployAll.s.sol) ────────────────────
    address constant WPLS          = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant PULSEX_ROUTER = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant eHEX          = 0x57fde0a71132198BBeC939B98976993d8D89D225;

    // ── Existing dev / token-owner wallet ─────────────────────────────────
    address constant DEV_WALLET = 0xa0419404eF7b81d9Ec64367eb68e5f425EACE618;

    // Yield-tax slot id on the new TSTT (verified on-chain on the source token)
    uint256 constant YIELD_TAX_ID = 0;

    function run() external {
        uint256 pk = vm.envUint("pk_618_sai");
        address broadcaster = vm.addr(pk);
        require(broadcaster == DEV_WALLET, "Broadcaster != new TSTT owner");

        console.log("=== RedeployForNewToken ===");
        console.log("New TSTT:   ", NEW_TSTT);
        console.log("Broadcaster:", broadcaster);

        vm.startBroadcast(pk);

        // 1. Fresh StakingVault wired to the new TSTT
        StakingVault vault = new StakingVault(
            NEW_TSTT,    // staking token
            eHEX,        // reward token
            broadcaster, // owner
            100          // top 100 stakers
        );
        console.log("New StakingVault:", address(vault));

        // 2. Fresh TreasuryDAO wired to the new vault + new TSTT
        TreasuryDAO dao = new TreasuryDAO(
            address(vault),
            NEW_TSTT,
            WPLS,
            PULSEX_ROUTER
        );
        console.log("New TreasuryDAO: ", address(dao));

        // 3. Configure router (needed for vault.topUp swaps)
        vault.setDexRouter(PULSEX_ROUTER);
        console.log("Router set:      ", PULSEX_ROUTER);

        // 4. Wire vault → DAO
        vault.setDaoAddress(address(dao));
        console.log("DAO wired into vault");

        // 5. Re-point Yield tax #0 from old vault to new vault on the new token
        (bool ok, bytes memory ret) = NEW_TSTT.call(
            abi.encodeWithSignature(
                "updateTaxReceiver(uint256,address)",
                YIELD_TAX_ID,
                address(vault)
            )
        );
        require(ok, _revertMsg(ret));
        console.log("Yield tax receiver updated -> new vault");

        vm.stopBroadcast();

        // ── Post-flight verification ─────────────────────────────────────
        require(
            address(vault.STAKING_TOKEN()) == NEW_TSTT,
            "Vault stakingToken != new TSTT"
        );
        require(
            address(vault.REWARDS_TOKEN()) == eHEX,
            "Vault rewardsToken != eHEX"
        );
        require(vault.daoAddress() == address(dao), "DAO not wired");
        require(
            address(vault.dexRouter()) == PULSEX_ROUTER,
            "Router not set"
        );

        console.log("=== DEPLOY SUMMARY ===");
        console.log("stakeToken:   ", NEW_TSTT);
        console.log("stakingVault: ", address(vault));
        console.log("treasuryDAO:  ", address(dao));
    }

    function _revertMsg(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "call reverted with no reason";
        assembly { ret := add(ret, 0x04) }
        return abi.decode(ret, (string));
    }
}
