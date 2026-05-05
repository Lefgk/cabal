// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IChef {
    function poolLength() external view returns (uint256);
    function poolInfo(uint256) external view returns (
        IERC20 token,
        uint256 allocPoint,
        uint256 lastRewardTime,
        uint16 depositFeeBP,
        uint16 withdrawFeeBP,
        uint256 accTokensPerShare,
        bool isStarted,
        uint8 externalProtocol,
        uint256 externalPid,
        uint256 lpBalance
    );
    function deposit(uint256 pid, uint256 amount, address referrer) external;
}

/// @notice Approves and deposits caller's full LP balance into every pool on the new chef.
contract RestakeAll is Script {
    address constant DEFAULT_CHEF = 0x1062282a3e25F2f797b0Da5cBeE2a38829b6f7c2;
    address constant ZERO = address(0);

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
            (IERC20 token,,,,,,,,,) = c.poolInfo(i);
            uint256 bal = token.balanceOf(user);
            if (bal == 0) {
                console.log("pid", i, "skip (no LP)");
                continue;
            }
            uint256 allowance = token.allowance(user, chef);
            if (allowance < bal) {
                token.approve(chef, type(uint256).max);
                console.log("pid", i, "approved");
            }
            console.log("pid", i, "deposit:", bal);
            c.deposit(i, bal, ZERO);
        }
        vm.stopBroadcast();
    }

    function _envOr(string memory k, address fb) internal view returns (address) {
        try vm.envAddress(k) returns (address v) { return v; } catch { return fb; }
    }
}
