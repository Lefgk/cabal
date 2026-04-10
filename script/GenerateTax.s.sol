// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

interface IRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external;
    function WPLS() external pure returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Buy then sell TSTT from a non-owner wallet to generate tax.
contract GenerateTaxScript is Script {
    address constant PULSEX_ROUTER = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant WPLS          = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant TSTT          = 0x1745A8154C134840e4D4F6A84dD109902d52A33b;
    address constant NEW_VAULT     = 0x7EB99faBE537dc4a2C8685291F72c7772FD1528C;
    address constant NEW_DAO       = 0xdFF5792C57Cd36D4705ed5c2c39823eE42FB5dEa;

    uint256 constant BUY_AMOUNT = 1000 ether; // 1000 PLS

    function run() external {
        uint256 pk = vm.envUint("pk");
        address bcast = vm.addr(pk);

        console.log("=== GENERATE TAX (non-owner) ===");
        console.log("broadcaster:", bcast);

        uint256 vaultPlsBefore = NEW_VAULT.balance;
        uint256 daoWplsBefore = IERC20(WPLS).balanceOf(NEW_DAO);

        vm.startBroadcast(pk);

        // 1. Buy TSTT with PLS (triggers buy tax)
        address[] memory buyPath = new address[](2);
        buyPath[0] = WPLS;
        buyPath[1] = TSTT;

        IRouter(PULSEX_ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: BUY_AMOUNT}(
            0, buyPath, bcast, block.timestamp + 300
        );
        uint256 tsttBal = IERC20(TSTT).balanceOf(bcast);
        console.log("TSTT balance after buy:", tsttBal);

        // 2. Sell same amount back (triggers sell tax)
        IERC20(TSTT).approve(PULSEX_ROUTER, tsttBal);

        address[] memory sellPath = new address[](2);
        sellPath[0] = TSTT;
        sellPath[1] = WPLS;

        IRouter(PULSEX_ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(
            tsttBal, 0, sellPath, bcast, block.timestamp + 300
        );
        console.log("Sold TSTT back");

        vm.stopBroadcast();

        uint256 vaultPlsAfter = NEW_VAULT.balance;
        uint256 daoWplsAfter = IERC20(WPLS).balanceOf(NEW_DAO);

        console.log("");
        console.log("=== TAX GENERATED ===");
        console.log("Vault PLS received:", vaultPlsAfter - vaultPlsBefore);
        console.log("DAO WPLS received: ", daoWplsAfter - daoWplsBefore);
    }
}
