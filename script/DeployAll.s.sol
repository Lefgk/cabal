// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {TreasuryDAO} from "../src/TreasuryDAO.sol";

contract DeployAll is Script {
    // PulseChain constants
    address constant WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant PULSEX_ROUTER = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant eHEX = 0x57fde0a71132198BBeC939B98976993d8D89D225;

    function run() external {
        address stakeToken = vm.envAddress("STAKE_TOKEN");

        vm.startBroadcast();

        // 1. Deploy StakingVault
        StakingVault vault = new StakingVault(
            stakeToken,   // token users stake
            eHEX,         // reward token (eHEX)
            msg.sender,   // owner
            100            // top 100 stakers
        );
        console.log("StakingVault deployed:", address(vault));

        // 2. Deploy TreasuryDAO
        TreasuryDAO dao = new TreasuryDAO(
            address(vault),
            stakeToken,
            WPLS,
            PULSEX_ROUTER
        );
        console.log("TreasuryDAO deployed:", address(dao));

        // 3. Wire them together
        vault.setDaoAddress(address(dao));
        console.log("Vault -> DAO wired");

        vm.stopBroadcast();
    }
}
