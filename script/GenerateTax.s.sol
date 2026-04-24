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
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Buy then sell TSTT from a NON-OWNER wallet to generate tax.
contract GenerateTaxScript is Script {
    address constant ROUTER = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant WPLS   = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant TOKEN  = 0xFbA28dA172e60E9CA50985C51E3772f715FAba20;
    address constant VAULT  = 0x1DdDfF8D36bb2561119868C2D5C2E99F50ED0843;
    address constant DAO    = 0xF34769d1Df2bd2F6738cE5CaeaCF09b565E36992;

    uint256 constant BUY_AMOUNT = 50_000 ether; // 50K PLS

    function run() external {
        uint256 pk = vm.envUint("pk"); // dev wallet — NOT tax excluded
        address bcast = vm.addr(pk);

        console.log("=== GENERATE TAX (non-owner) ===");
        console.log("wallet:", bcast);

        uint256 vaultPlsBefore = VAULT.balance;
        uint256 daoPlsBefore   = DAO.balance;

        vm.startBroadcast(pk);

        // 1. Buy TSTT
        address[] memory buyPath = new address[](2);
        buyPath[0] = WPLS;
        buyPath[1] = TOKEN;
        IRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: BUY_AMOUNT}(
            0, buyPath, bcast, block.timestamp + 300
        );
        uint256 tsttBal = IERC20(TOKEN).balanceOf(bcast);
        console.log("TSTT bought:", tsttBal);

        // 2. Sell all back
        IERC20(TOKEN).approve(ROUTER, tsttBal);
        address[] memory sellPath = new address[](2);
        sellPath[0] = TOKEN;
        sellPath[1] = WPLS;
        IRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(
            tsttBal, 0, sellPath, bcast, block.timestamp + 300
        );
        console.log("sold all back");

        vm.stopBroadcast();

        uint256 vaultPlsAfter = VAULT.balance;
        uint256 daoPlsAfter   = DAO.balance;

        console.log("");
        console.log("=== TAX RESULTS ===");
        console.log("vault PLS received:", vaultPlsAfter - vaultPlsBefore);
        console.log("DAO PLS received:  ", daoPlsAfter - daoPlsBefore);
    }
}
