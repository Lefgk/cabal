// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TreasuryDAO} from "../src/TreasuryDAO.sol";

interface IVaultAdmin {
    function setDaoAddress(address dao) external;
}

contract DeployDAO is Script {
    address constant VAULT       = 0x1DdDfF8D36bb2561119868C2D5C2E99F50ED0843;
    address constant TOKEN       = 0xFbA28dA172e60E9CA50985C51E3772f715FAba20;
    address constant WPLS        = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant ROUTER      = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant BROADCASTER = 0xa0419404eF7b81d9Ec64367eb68e5f425EACE618;

    function run() external {
        uint256 pk = vm.envUint("pk_618_sai");
        require(vm.addr(pk) == BROADCASTER, "wrong wallet");

        vm.startBroadcast(pk);

        // 1. Deploy DAO
        TreasuryDAO dao = new TreasuryDAO(VAULT, TOKEN, WPLS, ROUTER);
        console.log("NEW DAO:", address(dao));

        // 2. Point vault at new DAO
        IVaultAdmin(VAULT).setDaoAddress(address(dao));
        console.log("vault.setDaoAddress -> new DAO");

        // 3. Redirect token tax[1] to new DAO
        (bool ok, bytes memory ret) = TOKEN.call(
            abi.encodeWithSignature("updateTaxReceiver(uint256,address)", 1, address(dao))
        );
        if (!ok) {
            if (ret.length >= 68) { assembly { ret := add(ret, 0x04) } }
            revert(ret.length >= 4 ? abi.decode(ret, (string)) : "updateTaxReceiver failed");
        }
        console.log("tax[1] receiver -> new DAO");

        // 4. Set voting period to 5 minutes (matches minVotingPeriod)
        dao.setVotingPeriod(5 minutes);
        console.log("votingPeriod set to 5 minutes");

        vm.stopBroadcast();

        console.log("");
        console.log("=== DONE ===");
        console.log("DAO:    ", address(dao));
        console.log("VAULT:  ", VAULT);
        console.log("TOKEN:  ", TOKEN);
        console.log("");
        console.log("UPDATE contracts.ts: dao =", address(dao));
    }
}
