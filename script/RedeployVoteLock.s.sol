// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {TreasuryDAO}  from "../src/TreasuryDAO.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Redeploy StakingVault + TreasuryDAO with vote-lock feature.
///         Same wiring as StageB2 — just fresh vault & DAO, repoint tax receivers.
///         Token address stays the same.
///
///   1. Deploy new StakingVault (TSTT/pHEX, top 100)
///   2. Deploy new TreasuryDAO  (vault, TSTT, WPLS, router)
///   3. Wire vault → DAO
///   4. Repoint tax[0] → new vault, tax[1] → new DAO
///
/// After running, update ui/src/config/contracts.js with the new addresses.
contract RedeployVoteLockScript is Script {
    // ── Live PulseChain addresses (same as StageB2) ─────────────────────
    address constant PULSEX_ROUTER = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant WPLS          = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant pHEX          = 0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39;
    address constant DEV_WALLET    = 0xa0419404eF7b81d9Ec64367eb68e5f425EACE618;

    // ── Current token (does NOT change) ─────────────────────────────────
    address constant TSTT = 0x1745A8154C134840e4D4F6A84dD109902d52A33b;

    function _revertMsg(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "reverted (no reason)";
        assembly { ret := add(ret, 0x04) }
        return abi.decode(ret, (string));
    }

    function _updateTaxReceiver(address token, uint256 id, address receiver) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSignature("updateTaxReceiver(uint256,address)", id, receiver)
        );
        if (!ok) revert(_revertMsg(ret));
    }

    function run() external {
        uint256 pk = vm.envUint("pk_618_sai");
        address bcast = vm.addr(pk);
        require(bcast == DEV_WALLET, "Broadcaster != dev wallet");

        console.log("=== REDEPLOY VOTE-LOCK ===");
        console.log("broadcaster:", bcast);

        vm.startBroadcast(pk);

        // 1. Deploy new vault: STAKING=TSTT, REWARDS=pHEX, top 100
        StakingVault vault = new StakingVault(TSTT, pHEX, bcast, 100);
        vault.setDexRouter(PULSEX_ROUTER);
        console.log("new vault:", address(vault));

        // 2. Deploy new DAO wired to new vault
        TreasuryDAO dao = new TreasuryDAO(address(vault), TSTT, WPLS, PULSEX_ROUTER);
        console.log("new DAO:  ", address(dao));

        // 3. Wire vault -> DAO
        vault.setDaoAddress(address(dao));

        // 4. Repoint token tax receivers to new contracts
        _updateTaxReceiver(TSTT, 0, address(vault));
        console.log("tax[0] receiver -> vault OK");
        _updateTaxReceiver(TSTT, 1, address(dao));
        console.log("tax[1] receiver -> DAO OK");

        vm.stopBroadcast();

        console.log("");
        console.log("=== REDEPLOY COMPLETE ===");
        console.log("TSTT (unchanged):", TSTT);
        console.log("NEW_VAULT:       ", address(vault));
        console.log("NEW_DAO:         ", address(dao));
        console.log("");
        console.log("UPDATE ui/src/config/contracts.js:");
        console.log("  stakingVault:", address(vault));
        console.log("  treasuryDAO: ", address(dao));
    }
}
