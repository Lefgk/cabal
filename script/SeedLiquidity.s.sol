// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IPulseXRouter {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function factory() external pure returns (address);
}

interface IPulseXFactory {
    function getPair(address a, address b) external view returns (address);
}

/// @notice Seeds the initial PulseX V2 liquidity pool for the new TSTT:
///   100,000,000 TSTT + 10,000 PLS, LP receipt tokens sent to the dev
///   wallet (broadcaster). Initial ratio therefore = 0.0001 PLS per TSTT.
///
/// Prereqs verified on-chain:
///   - Dev wallet is isTaxExcluded on the new TSTT -> tax-free transfer in
///   - Dev wallet currently holds the full 1e27 TSTT mint
///   - tradingEnabled = true
contract SeedLiquidityScript is Script {
    address constant TSTT          = 0x584cb57d12dDea0c8A20299f1e972fFF6f581161;
    address constant PULSEX_ROUTER = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant DEV_WALLET    = 0xa0419404eF7b81d9Ec64367eb68e5f425EACE618;

    uint256 constant TSTT_AMOUNT = 100_000_000 ether;  // 1e8 * 1e18
    uint256 constant PLS_AMOUNT  = 10_000 ether;       // 1e4 * 1e18

    function run() external {
        uint256 pk = vm.envUint("pk_618_sai");
        address broadcaster = vm.addr(pk);
        require(broadcaster == DEV_WALLET, "Broadcaster != dev wallet");

        uint256 balBefore = IERC20(TSTT).balanceOf(broadcaster);
        require(balBefore >= TSTT_AMOUNT, "Insufficient TSTT in dev wallet");
        require(broadcaster.balance >= PLS_AMOUNT, "Insufficient PLS in dev wallet");

        console.log("=== SeedLiquidity ===");
        console.log("Token:       ", TSTT);
        console.log("Router:      ", PULSEX_ROUTER);
        console.log("LP recipient:", broadcaster);
        console.log("TSTT in:     ", TSTT_AMOUNT);
        console.log("PLS in:      ", PLS_AMOUNT);

        vm.startBroadcast(pk);

        // 1. Approve router to pull TSTT
        require(
            IERC20(TSTT).approve(PULSEX_ROUTER, TSTT_AMOUNT),
            "TSTT approve failed"
        );

        // 2. addLiquidityETH → pair will be auto-created.
        //    amountTokenMin/amountETHMin = full amount since the pool is
        //    brand-new (no other liquidity can front-run the ratio).
        (uint256 amtToken, uint256 amtETH, uint256 liquidity) = IPulseXRouter(PULSEX_ROUTER)
            .addLiquidityETH{value: PLS_AMOUNT}(
                TSTT,
                TSTT_AMOUNT,
                TSTT_AMOUNT,      // min token accepted
                PLS_AMOUNT,       // min PLS accepted
                broadcaster,      // LP tokens → dev wallet
                block.timestamp + 1200
            );

        vm.stopBroadcast();

        console.log("=== LP SEEDED ===");
        console.log("amountToken:", amtToken);
        console.log("amountETH:  ", amtETH);
        console.log("LP minted:  ", liquidity);

        address factory = IPulseXRouter(PULSEX_ROUTER).factory();
        address pair = IPulseXFactory(factory).getPair(
            TSTT,
            0xA1077a294dDE1B09bB078844df40758a5D0f9a27 // WPLS
        );
        console.log("Pair address:", pair);
    }
}
