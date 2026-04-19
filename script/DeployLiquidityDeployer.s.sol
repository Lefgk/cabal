// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {LiquidityDeployer} from "../src/LiquidityDeployer.sol";

contract DeployLiquidityDeployerScript is Script {
    address constant PULSEX_ROUTER = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant WPLS          = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant BROADCASTER   = 0xa0419404eF7b81d9Ec64367eb68e5f425EACE618;

    function run() external {
        uint256 pk = vm.envUint("pk_618_sai");
        address bcast = vm.addr(pk);
        require(bcast == BROADCASTER, "Broadcaster != expected wallet");

        console.log("=== DEPLOY LiquidityDeployer ===");
        console.log("broadcaster:", bcast);

        vm.startBroadcast(pk);

        LiquidityDeployer deployer = new LiquidityDeployer(WPLS, PULSEX_ROUTER);
        console.log("LiquidityDeployer:", address(deployer));

        vm.stopBroadcast();

        console.log("");
        console.log("=== DONE ===");
        console.log("LiquidityDeployer:", address(deployer));
        console.log("Owner:", bcast);
        console.log("Router:", PULSEX_ROUTER);
        console.log("WPLS:", WPLS);
        console.log("");
        console.log("UPDATE cabal-dao-ui/src/lib/contracts.ts:");
        console.log("  liquidityDeployer:", address(deployer));
    }
}
