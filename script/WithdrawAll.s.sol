// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IChef {
    function poolLength() external view returns (uint256);
    function getUserView(uint256, address) external view returns (
        uint256 pid, uint256 stakedAmount, uint256 unclaimedRewards, uint256 lpBalance, uint256 allowance
    );
    function withdraw(uint256, uint256) external;
}

/// @notice Pulls the caller's full LP stake out of every pool on the chef.
contract WithdrawAll is Script {
    address constant DEFAULT_CHEF = 0x66b368a328D06c1D358e8c9d2DD3927CBC326ca4;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address chef = _envOr("CABAL_EMISSIONS", DEFAULT_CHEF);
        address user = vm.addr(pk);

        IChef c = IChef(chef);
        uint256 n = c.poolLength();
        console.log("Chef:", chef);
        console.log("User:", user);
        console.log("Pools:", n);

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < n; i++) {
            (, uint256 staked, , , ) = c.getUserView(i, user);
            if (staked == 0) {
                console.log("pid", i, "skip (no stake)");
                continue;
            }
            console.log("pid", i, "withdraw amount:", staked);
            c.withdraw(i, staked);
        }
        vm.stopBroadcast();
    }

    function _envOr(string memory k, address fb) internal view returns (address) {
        try vm.envAddress(k) returns (address v) { return v; } catch { return fb; }
    }
}
