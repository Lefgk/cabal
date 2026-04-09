// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TreasuryDAO} from "../src/TreasuryDAO.sol";

contract DeployDAO is Script {
    function run() external {
        address vault = 0xDb15ee3255E7158f1823220D73f1403c18b474E6;
        address stakeToken = 0xAbEaBFE146F347537b82426B4c4d8F1E768721C7;
        address wpls = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
        address router = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;

        vm.startBroadcast();

        TreasuryDAO dao = new TreasuryDAO(vault, stakeToken, wpls, router);
        console.log("New TreasuryDAO deployed:", address(dao));

        vm.stopBroadcast();
    }
}
