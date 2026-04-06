// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {TreasuryDAO} from "../src/TreasuryDAO.sol";

/// @title Deploy
/// @notice Deploys StakingVault and TreasuryDAO to PulseChain, then wires them together.
///
/// Environment variables:
///   STAKE_TOKEN  — the ERC-20 token users stake
///   REWARD_TOKEN — the yield/reward asset (eHEX, pHEX, etc.)
///
/// Usage:
///   source .env
///   forge script script/Deploy.s.sol:Deploy --rpc-url http://localhost:8545 --broadcast
contract Deploy is Script {
    // PulseChain constants
    address constant WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant PULSEX_V1_ROUTER = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;

    // Top-staker list size
    uint256 constant TOP_STAKER_COUNT = 100;

    function run() external {
        address stakeToken = vm.envAddress("STAKE_TOKEN");
        address rewardToken = vm.envAddress("REWARD_TOKEN");

        vm.startBroadcast();

        // 1. Deploy StakingVault
        StakingVault vault = new StakingVault(
            stakeToken,
            rewardToken,
            msg.sender,  // deployer is initial owner
            TOP_STAKER_COUNT
        );

        // 2. Deploy TreasuryDAO (uses the vault address)
        TreasuryDAO dao = new TreasuryDAO(
            address(vault),
            stakeToken,
            WPLS,
            PULSEX_V1_ROUTER
        );

        // 3. Wire: point the vault's DAO address to the TreasuryDAO
        vault.setDaoAddress(address(dao));

        vm.stopBroadcast();

        // Log deployed addresses
        console.log("=== Deployment Complete ===");
        console.log("StakingVault :", address(vault));
        console.log("TreasuryDAO  :", address(dao));
        console.log("Stake Token  :", stakeToken);
        console.log("Reward Token :", rewardToken);
        console.log("WPLS         :", WPLS);
        console.log("PulseX Router:", PULSEX_V1_ROUTER);
    }
}
