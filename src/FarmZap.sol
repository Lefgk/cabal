// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IWPLS {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IUniV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
}

interface IRouter {
    function WPLS() external view returns (address);
    function factory() external view returns (address);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256, uint256, uint256);
}

/// @notice CabalEmissions has 4-arg depositOnBehalfOf(pid, amount, referrer, staker).
///         poolInfo's first field is the LP token; we don't need the rest.
interface ICabalEmissions {
    function poolInfo(uint256 pid) external view returns (
        address token,
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
    function depositOnBehalfOf(
        uint256 pid,
        uint256 amount,
        address referrer,
        address staker
    ) external;
}

/// @title FarmZap (CabalEmissions, V1+V2 dispatch)
/// @notice One-tx zap from PLS into a CabalEmissions LP pool. Reads the LP's
///         factory and dispatches to PulseX V1 or V2 router accordingly, so a
///         single zap covers both V1 LPs (legacy PulseX MasterChef pools) and
///         V2 LPs (TSTT/WPLS, etc.). Forwards referrer=0 → chef defaultReferrer.
contract FarmZap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IRouter         public immutable routerV1;
    IRouter         public immutable routerV2;
    address         public immutable factoryV1;
    address         public immutable factoryV2;
    address         public immutable wpls;
    ICabalEmissions public immutable masterchef;

    event Zapped(address indexed user, uint256 indexed pid, uint256 plsIn, uint256 lpStaked, uint8 routerVersion);

    error ZeroValue();
    error InsufficientLp(uint256 got, uint256 min);
    error DeadlinePassed();
    error UnknownFactory(address factory);
    error WplsMismatch();

    constructor(IRouter _routerV1, IRouter _routerV2, ICabalEmissions _masterchef) {
        routerV1   = _routerV1;
        routerV2   = _routerV2;
        factoryV1  = _routerV1.factory();
        factoryV2  = _routerV2.factory();
        address w1 = _routerV1.WPLS();
        address w2 = _routerV2.WPLS();
        if (w1 != w2) revert WplsMismatch();
        wpls       = w1;
        masterchef = _masterchef;
    }

    receive() external payable { require(msg.sender == wpls, "PLS rejected"); }

    function zapInPLS(
        uint256 pid,
        uint256 amountLpMin,
        uint256 swapSlipBps,
        uint256 deadline
    ) external payable nonReentrant {
        if (msg.value == 0) revert ZeroValue();
        if (block.timestamp > deadline) revert DeadlinePassed();

        (address lp,,,,,,,,, ) = masterchef.poolInfo(pid);
        IRouter router = _routerFor(lp);
        address t0 = IUniV2Pair(lp).token0();
        address t1 = IUniV2Pair(lp).token1();

        IWPLS(wpls).deposit{ value: msg.value }();
        (uint256 amt0, uint256 amt1) = _splitAndSwap(router, t0, t1, msg.value, swapSlipBps, deadline);

        uint256 lpReceived = _addAndStake(router, pid, lp, t0, t1, amt0, amt1, deadline);
        if (lpReceived < amountLpMin) revert InsufficientLp(lpReceived, amountLpMin);

        _sweep(t0, msg.sender);
        _sweep(t1, msg.sender);
        _sweepPls(msg.sender);

        emit Zapped(msg.sender, pid, msg.value, lpReceived, router == routerV2 ? 2 : 1);
    }

    function _routerFor(address lp) internal view returns (IRouter) {
        address f = IUniV2Pair(lp).factory();
        if (f == factoryV2) return routerV2;
        if (f == factoryV1) return routerV1;
        revert UnknownFactory(f);
    }

    function _splitAndSwap(
        IRouter router,
        address t0,
        address t1,
        uint256 wplsAmount,
        uint256 swapSlipBps,
        uint256 deadline
    ) internal returns (uint256 amt0, uint256 amt1) {
        uint256 half = wplsAmount / 2;
        uint256 rest = wplsAmount - half;
        if (t0 == wpls) {
            amt0 = half;
            amt1 = _swap(router, wpls, t1, rest, swapSlipBps, deadline);
        } else if (t1 == wpls) {
            amt1 = rest;
            amt0 = _swap(router, wpls, t0, half, swapSlipBps, deadline);
        } else {
            amt0 = _swap(router, wpls, t0, half, swapSlipBps, deadline);
            amt1 = _swap(router, wpls, t1, rest, swapSlipBps, deadline);
        }
    }

    function _addAndStake(
        IRouter router,
        uint256 pid,
        address lp,
        address t0,
        address t1,
        uint256 amt0,
        uint256 amt1,
        uint256 deadline
    ) internal returns (uint256 lpReceived) {
        _approveIfNeeded(t0, address(router), amt0);
        _approveIfNeeded(t1, address(router), amt1);
        (, , lpReceived) = router.addLiquidity(
            t0, t1, amt0, amt1, 1, 1, address(this), deadline
        );
        _approveIfNeeded(lp, address(masterchef), lpReceived);
        masterchef.depositOnBehalfOf(pid, lpReceived, address(0), msg.sender);
    }

    function _swap(
        IRouter router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slipBps,
        uint256 deadline
    ) internal returns (uint256 received) {
        _approveIfNeeded(tokenIn, address(router), amountIn);
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        slipBps;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, path, address(this), deadline
        );
        received = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
    }

    function _approveIfNeeded(address token, address spender, uint256 amount) internal {
        uint256 cur = IERC20(token).allowance(address(this), spender);
        if (cur < amount) IERC20(token).forceApprove(spender, type(uint256).max);
    }

    function _sweep(address token, address to) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(to, bal);
    }

    function _sweepPls(address to) internal {
        uint256 wbal = IERC20(wpls).balanceOf(address(this));
        if (wbal > 0) {
            IWPLS(wpls).withdraw(wbal);
            (bool ok, ) = to.call{ value: wbal }("");
            require(ok, "PLS refund failed");
        }
    }
}
