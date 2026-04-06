// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StakingVault} from "../src/StakingVault.sol";

contract DeployVault is Script {
    address constant TSTT = 0x3cBC78A25929b3f8F7d0a347565e8D77Aee49554;
    address constant eHEX = 0x57fde0a71132198BBeC939B98976993d8D89D225;
    address constant PULSEX_ROUTER = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant TREASURY_DAO = 0x99Bf08d3A8cDC80ca1A9a823F8900A8E3DD3624C;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy new StakingVault with topUp support
        StakingVault vault = new StakingVault(
            TSTT,         // staking token
            eHEX,         // reward token
            msg.sender,   // owner
            100           // top 100 stakers
        );
        console.log("StakingVault deployed:", address(vault));

        // 2. Set PulseX router for topUp
        vault.setDexRouter(PULSEX_ROUTER);
        console.log("DexRouter set:", PULSEX_ROUTER);

        // 3. Wire to existing DAO
        vault.setDaoAddress(TREASURY_DAO);
        console.log("DAO wired:", TREASURY_DAO);

        vm.stopBroadcast();
    }
}
