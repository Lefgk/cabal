// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TreasuryDAO} from "../src/TreasuryDAO.sol";

contract DeployDAO is Script {
    function run() external {
        address vault = 0x0698f63b3680B5d91A280501248177Ac3Af1b789;
        address stakeToken = 0x3cBC78A25929b3f8F7d0a347565e8D77Aee49554;
        address wpls = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
        address router = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;

        vm.startBroadcast();

        TreasuryDAO dao = new TreasuryDAO(vault, stakeToken, wpls, router);
        console.log("New TreasuryDAO deployed:", address(dao));

        vm.stopBroadcast();
    }
}
