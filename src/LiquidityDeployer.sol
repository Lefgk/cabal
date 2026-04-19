// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IPulseXRouter.sol";

/// @title LiquidityDeployer
/// @notice Standalone contract for DAO-governed LP creation on PulseX.
///         The DAO sends PLS via a Custom proposal; this contract swaps for
///         tokens and adds liquidity. LP tokens are burned to DEAD.
contract LiquidityDeployer is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable wpls;
    address public router;

    event LiquidityAdded(
        address indexed tokenA,
        address indexed tokenB,
        uint256 liquidity,
        uint256 plsSpent
    );
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);

    constructor(address _wpls, address _router) Ownable(msg.sender) {
        require(_wpls != address(0), "zero wpls");
        require(_router != address(0), "zero router");
        wpls = _wpls;
        router = _router;
    }

    /// @notice Swap PLS for token(s) and add liquidity on PulseX. LP burned to DEAD.
    /// @param tokenA First token (required).
    /// @param tokenB Second token, or address(0) for a tokenA/PLS pair.
    function addLiquidity(address tokenA, address tokenB) external payable nonReentrant {
        require(msg.value > 0, "zero value");
        require(tokenA != address(0), "zero tokenA");

        uint256 half = msg.value / 2;
        uint256 otherHalf = msg.value - half;

        if (tokenB == address(0)) {
            _addLiquidityTokenPls(tokenA, half, otherHalf);
        } else {
            _addLiquidityTokenToken(tokenA, tokenB, half, otherHalf);
        }
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "zero router");
        emit RouterUpdated(router, _router);
        router = _router;
    }

    receive() external payable {}

    // ---------------------------------------------------------------
    //  Internal
    // ---------------------------------------------------------------

    function _addLiquidityTokenPls(address tokenA, uint256 half, uint256 otherHalf) internal {
        address _router = router;

        // Swap half PLS -> tokenA
        address[] memory path = new address[](2);
        path[0] = wpls;
        path[1] = tokenA;
        IPulseXRouter(_router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: half}(
            0, path, address(this), block.timestamp
        );

        uint256 tokenBal = IERC20(tokenA).balanceOf(address(this));
        IERC20(tokenA).approve(_router, tokenBal);

        // Add liquidity — LP tokens to DEAD
        (,, uint256 liquidity) = IPulseXRouter(_router).addLiquidityETH{value: otherHalf}(
            tokenA, tokenBal, 0, 0, DEAD, block.timestamp
        );

        // Burn leftover tokens
        uint256 leftover = IERC20(tokenA).balanceOf(address(this));
        if (leftover > 0) {
            IERC20(tokenA).safeTransfer(DEAD, leftover);
        }

        // Revoke approval
        IERC20(tokenA).approve(_router, 0);

        emit LiquidityAdded(tokenA, address(0), liquidity, half + otherHalf);
    }

    function _addLiquidityTokenToken(
        address tokenA,
        address tokenB,
        uint256 half,
        uint256 otherHalf
    ) internal {
        address _router = router;

        // Swap half PLS -> tokenA
        address[] memory pathA = new address[](2);
        pathA[0] = wpls;
        pathA[1] = tokenA;
        IPulseXRouter(_router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: half}(
            0, pathA, address(this), block.timestamp
        );

        // Swap other half PLS -> tokenB
        address[] memory pathB = new address[](2);
        pathB[0] = wpls;
        pathB[1] = tokenB;
        IPulseXRouter(_router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: otherHalf}(
            0, pathB, address(this), block.timestamp
        );

        uint256 balA = IERC20(tokenA).balanceOf(address(this));
        uint256 balB = IERC20(tokenB).balanceOf(address(this));
        IERC20(tokenA).approve(_router, balA);
        IERC20(tokenB).approve(_router, balB);

        // Add liquidity — LP tokens to DEAD
        (,, uint256 liquidity) = IPulseXRouter(_router).addLiquidity(
            tokenA, tokenB, balA, balB, 0, 0, DEAD, block.timestamp
        );

        // Burn leftovers
        uint256 leftA = IERC20(tokenA).balanceOf(address(this));
        if (leftA > 0) IERC20(tokenA).safeTransfer(DEAD, leftA);
        uint256 leftB = IERC20(tokenB).balanceOf(address(this));
        if (leftB > 0) IERC20(tokenB).safeTransfer(DEAD, leftB);

        // Revoke approvals
        IERC20(tokenA).approve(_router, 0);
        IERC20(tokenB).approve(_router, 0);

        emit LiquidityAdded(tokenA, tokenB, liquidity, half + otherHalf);
    }
}
