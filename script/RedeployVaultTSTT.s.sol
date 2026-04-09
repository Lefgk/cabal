// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StakingVault} from "../src/StakingVault.sol";

/// @notice Redeploys StakingVault as TSTT/TSTT (single-token staking) wired to
///         the existing TSTT and TreasuryDAO. Required because the v3 factory's
///         Dev tax with rewardInPls=false transfers raw TSTT to the receiver
///         (tax.tokenAddress is dead storage). Vault REWARDS_TOKEN is immutable
///         so this requires a fresh deploy.
contract RedeployVaultTSTTScript is Script {
    address constant TSTT          = 0xAbEaBFE146F347537b82426B4c4d8F1E768721C7;
    address constant DAO           = 0x40E5B727227d45eCe9be9c48d40430A67A15b60C;
    address constant PULSEX_ROUTER = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant DEV_WALLET    = 0xa0419404eF7b81d9Ec64367eb68e5f425EACE618;

    function run() external {
        uint256 pk = vm.envUint("pk_618_sai");
        address bcast = vm.addr(pk);
        require(bcast == DEV_WALLET, "wrong broadcaster");

        vm.startBroadcast(pk);
        StakingVault vault = new StakingVault(TSTT, TSTT, bcast, 100);
        vault.setDexRouter(PULSEX_ROUTER);
        vault.setDaoAddress(DAO);
        vm.stopBroadcast();

        console.log("New TSTT/TSTT vault:", address(vault));
        require(address(vault.STAKING_TOKEN()) == TSTT, "stake!=TSTT");
        require(address(vault.REWARDS_TOKEN()) == TSTT, "reward!=TSTT");
    }
}
