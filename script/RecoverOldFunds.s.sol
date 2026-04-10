// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

interface IVault {
    function recoverERC20(address token, uint256 amount) external;
}

interface IDAO {
    function propose(uint256 amount, address target, string calldata description) external returns (uint256);
    function castVote(uint256 proposalId, bool support) external;
    function setQuorumBps(uint256 bps) external;
    function proposalCount() external view returns (uint256);
}

/// @notice Recover funds from old vault + old DAO after vote-lock redeploy.
///
///   1. recoverERC20(pHEX) from old vault  → dev wallet (instant)
///   2. Lower quorum on old DAO so dev wallet vote is sufficient
///   3. propose on old DAO to send WPLS    → dev wallet (needs 7-day vote)
///   4. castVote yes on that proposal      → from dev wallet (top staker)
///
///   After 7 days, anyone calls executeProposal() to release the WPLS.
contract RecoverOldFundsScript is Script {
    address constant OLD_VAULT  = 0x57124b4E6b44401D96D3b39b094923c5832dC769;
    address constant OLD_DAO    = 0xE27E3963cDF3B881a467f259318ca793076B42A1;
    address constant pHEX       = 0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39;
    address constant DEV_WALLET = 0xa0419404eF7b81d9Ec64367eb68e5f425EACE618;

    // Full pHEX balance on old vault
    uint256 constant PHEX_AMOUNT = 103279553952;
    // Available (unlocked) WPLS on old DAO
    uint256 constant WPLS_AMOUNT = 4655674857398791686844;

    function run() external {
        uint256 pk = vm.envUint("pk_618_sai");
        address bcast = vm.addr(pk);
        require(bcast == DEV_WALLET, "Broadcaster != dev wallet");

        console.log("=== RECOVER OLD FUNDS ===");

        vm.startBroadcast(pk);

        // 1. Recover pHEX from old vault (owner-only, instant)
        IVault(OLD_VAULT).recoverERC20(pHEX, PHEX_AMOUNT);
        console.log("Recovered pHEX from old vault:", PHEX_AMOUNT);

        // 2. Lower quorum so dev wallet's ~1M TSTT (of 12M total) is enough
        //    Dev has ~8.3% of total stake; set quorum to 1% to clear easily.
        IDAO(OLD_DAO).setQuorumBps(100);
        console.log("Lowered old DAO quorum to 1%");

        // 3. Propose WPLS transfer on old DAO
        uint256 proposalId = IDAO(OLD_DAO).propose(
            WPLS_AMOUNT,
            DEV_WALLET,
            "Recover WPLS to dev wallet - old DAO decommissioned after vote-lock redeploy"
        );
        console.log("Proposal created on old DAO, id:", proposalId);

        // 4. Vote yes (dev wallet is top staker on old vault)
        IDAO(OLD_DAO).castVote(proposalId, true);
        console.log("Voted YES on proposal", proposalId);

        vm.stopBroadcast();

        console.log("");
        console.log("=== RECOVERY STATUS ===");
        console.log("pHEX: DONE - sent to dev wallet");
        console.log("WPLS: PENDING - proposal %s needs 7 days, then call executeProposal(%s)", proposalId, proposalId);
    }
}
