// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {TreasuryDAO}  from "../src/TreasuryDAO.sol";

/// @notice Step 1: Deploy StakingVault + TreasuryDAO.
///         Step 2: Create token in PulseFun UI using vault/DAO as tax receivers.
///         Step 3: Run ConnectToken.s.sol to wire the token in + enable trading.
contract DeployAllScript is Script {
    address constant PULSEX_V2       = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant WPLS            = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant pHEX            = 0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39;
    address constant DEV_WALLET      = 0xA04f1f7661fDa0C5872A41c77fCcDc335e248b2B;
    address constant MARKETING_WALLET = 0xC131726D091de327936c7E6Ed587771f7aaF5718;
    address constant BROADCASTER     = 0xa0419404eF7b81d9Ec64367eb68e5f425EACE618;

    function run() external {
        uint256 pk = vm.envUint("pk_618_sai");
        address bcast = vm.addr(pk);
        require(bcast == BROADCASTER, "Broadcaster != expected wallet");

        console.log("=== DEPLOY VAULT + DAO ===");
        console.log("broadcaster:", bcast);

        vm.startBroadcast(pk);

        // 1. Deploy StakingVault (stakingToken=0 until token is created)
        StakingVault vault = new StakingVault(address(0), pHEX, bcast, 100);
        console.log("VAULT:", address(vault));

        // 2. Deploy TreasuryDAO (token=0 until token is created)
        TreasuryDAO dao = new TreasuryDAO(address(vault), address(0), WPLS, PULSEX_V2);
        console.log("DAO:", address(dao));
        console.log("marketingWallet:", dao.marketingWallet());

        // 3. Wire vault
        vault.setDaoAddress(address(dao));
        vault.setDexRouter(PULSEX_V2);
        vault.setDevWallet(DEV_WALLET);
        console.log("vault wired: DAO + router + dev");

        // 4. Set marketing wallet on DAO
        dao.setMarketingWallet(MARKETING_WALLET);
        console.log("marketingWallet:", MARKETING_WALLET);

        vm.stopBroadcast();

        console.log("");
        console.log("=============================================");
        console.log("  STEP 1 DONE - NOW CREATE TOKEN IN PULSEFUN");
        console.log("=============================================");
        console.log("  VAULT:", address(vault));
        console.log("  DAO:  ", address(dao));
        console.log("");
        console.log("  Tax 0: Dev 3.25% receiver -> VAULT address above");
        console.log("  Tax 1: Dev 1.00% receiver -> DAO address above");
        console.log("  Tax 2: Liquify 0.25%");
        console.log("  Tax 3: ExternalBurn 0.25% -> ZKP burn");
        console.log("  Tax 4: Burn 0.25%");
        console.log("");
        console.log("  Then run: ConnectToken.s.sol with NEW_TOKEN=<address>");
    }
}
