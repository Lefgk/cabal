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
///         Uses PulseX V2 as primary router with V1 fallback (e.g. for OMEGA).
contract LiquidityDeployer is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable wpls;
    address public routerV2; // primary — PulseX V2
    address public routerV1; // fallback — PulseX V1

    /// @notice Max slippage in basis points (e.g. 500 = 5%). Applied to swaps.
    uint256 public maxSlippageBps = 2000;

    event LiquidityAdded(
        address indexed tokenA,
        address indexed tokenB,
        uint256 liquidity,
        uint256 plsSpent
    );
    event RouterV2Updated(address indexed oldRouter, address indexed newRouter);
    event RouterV1Updated(address indexed oldRouter, address indexed newRouter);
    event MaxSlippageUpdated(uint256 oldBps, uint256 newBps);

    constructor(address _wpls, address _routerV2, address _routerV1) Ownable(msg.sender) {
        require(_wpls != address(0), "zero wpls");
        require(_routerV2 != address(0), "zero routerV2");
        require(_routerV1 != address(0), "zero routerV1");
        wpls = _wpls;
        routerV2 = _routerV2;
        routerV1 = _routerV1;
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

    function setRouterV2(address _router) external onlyOwner {
        require(_router != address(0), "zero routerV2");
        emit RouterV2Updated(routerV2, _router);
        routerV2 = _router;
    }

    function setRouterV1(address _router) external onlyOwner {
        require(_router != address(0), "zero routerV1");
        emit RouterV1Updated(routerV1, _router);
        routerV1 = _router;
    }

    function setMaxSlippageBps(uint256 _bps) external onlyOwner {
        require(_bps <= 5000, "slippage > 50%");
        emit MaxSlippageUpdated(maxSlippageBps, _bps);
        maxSlippageBps = _bps;
    }

    receive() external payable {}

    // ---------------------------------------------------------------
    //  Internal
    // ---------------------------------------------------------------

    /// @dev Get the minimum output for a swap after slippage.
    ///      Tries V2 quote first, falls back to V1 quote.
    function _getMinOut(address[] memory path, uint256 amountIn) internal view returns (uint256) {
        uint256 _slippage = maxSlippageBps;
        // Try V2 quote
        try IPulseXRouter(routerV2).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            return amounts[amounts.length - 1] * (10000 - _slippage) / 10000;
        } catch {}
        // Try V1 quote
        try IPulseXRouter(routerV1).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            return amounts[amounts.length - 1] * (10000 - _slippage) / 10000;
        } catch {}
        // Both quotes failed — use 0 (swap itself will revert if no pair)
        return 0;
    }

    /// @dev Swap PLS for a token. Tries V2 first; falls back to V1 on revert.
    function _swapPLSForToken(address token, uint256 amount) internal {
        address[] memory path = new address[](2);
        path[0] = wpls;
        path[1] = token;

        uint256 minOut = _getMinOut(path, amount);

        try IPulseXRouter(routerV2).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            minOut, path, address(this), block.timestamp
        ) {
            // V2 succeeded
        } catch {
            // V2 failed — use V1
            IPulseXRouter(routerV1).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
                minOut, path, address(this), block.timestamp
            );
        }
    }

    /// @dev Add tokenA/ETH liquidity. Tries V2 first; falls back to V1 on revert.
    function _addLiquidityETHTryBoth(
        address token,
        uint256 tokenBal,
        uint256 ethVal
    ) internal returns (uint256 liquidity) {
        // Try V2 first
        IERC20(token).approve(routerV2, tokenBal);
        try IPulseXRouter(routerV2).addLiquidityETH{value: ethVal}(
            token, tokenBal, 0, 0, DEAD, block.timestamp
        ) returns (uint256, uint256, uint256 liq) {
            liquidity = liq;
            IERC20(token).approve(routerV2, 0);
        } catch {
            // Revoke V2 approval, approve V1
            IERC20(token).approve(routerV2, 0);
            IERC20(token).approve(routerV1, tokenBal);
            (,, liquidity) = IPulseXRouter(routerV1).addLiquidityETH{value: ethVal}(
                token, tokenBal, 0, 0, DEAD, block.timestamp
            );
            IERC20(token).approve(routerV1, 0);
        }
    }

    /// @dev Add tokenA/tokenB liquidity. Tries V2 first; falls back to V1 on revert.
    function _addLiquidityTryBoth(
        address tokenA,
        address tokenB,
        uint256 balA,
        uint256 balB
    ) internal returns (uint256 liquidity) {
        // Try V2 first
        IERC20(tokenA).approve(routerV2, balA);
        IERC20(tokenB).approve(routerV2, balB);
        try IPulseXRouter(routerV2).addLiquidity(
            tokenA, tokenB, balA, balB, 0, 0, DEAD, block.timestamp
        ) returns (uint256, uint256, uint256 liq) {
            liquidity = liq;
            IERC20(tokenA).approve(routerV2, 0);
            IERC20(tokenB).approve(routerV2, 0);
        } catch {
            // Revoke V2, approve V1
            IERC20(tokenA).approve(routerV2, 0);
            IERC20(tokenB).approve(routerV2, 0);
            IERC20(tokenA).approve(routerV1, balA);
            IERC20(tokenB).approve(routerV1, balB);
            (,, liquidity) = IPulseXRouter(routerV1).addLiquidity(
                tokenA, tokenB, balA, balB, 0, 0, DEAD, block.timestamp
            );
            IERC20(tokenA).approve(routerV1, 0);
            IERC20(tokenB).approve(routerV1, 0);
        }
    }

    function _addLiquidityTokenPls(address tokenA, uint256 half, uint256 otherHalf) internal {
        _swapPLSForToken(tokenA, half);

        uint256 tokenBal = IERC20(tokenA).balanceOf(address(this));
        uint256 liquidity = _addLiquidityETHTryBoth(tokenA, tokenBal, otherHalf);

        // Burn leftover tokens
        uint256 leftover = IERC20(tokenA).balanceOf(address(this));
        if (leftover > 0) {
            IERC20(tokenA).safeTransfer(DEAD, leftover);
        }

        emit LiquidityAdded(tokenA, address(0), liquidity, half + otherHalf);
    }

    function _addLiquidityTokenToken(
        address tokenA,
        address tokenB,
        uint256 half,
        uint256 otherHalf
    ) internal {
        _swapPLSForToken(tokenA, half);
        _swapPLSForToken(tokenB, otherHalf);

        uint256 balA = IERC20(tokenA).balanceOf(address(this));
        uint256 balB = IERC20(tokenB).balanceOf(address(this));
        uint256 liquidity = _addLiquidityTryBoth(tokenA, tokenB, balA, balB);

        // Burn leftovers
        uint256 leftA = IERC20(tokenA).balanceOf(address(this));
        if (leftA > 0) IERC20(tokenA).safeTransfer(DEAD, leftA);
        uint256 leftB = IERC20(tokenB).balanceOf(address(this));
        if (leftB > 0) IERC20(tokenB).safeTransfer(DEAD, leftB);

        emit LiquidityAdded(tokenA, tokenB, liquidity, half + otherHalf);
    }
}
