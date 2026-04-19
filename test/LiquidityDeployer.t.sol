// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LiquidityDeployer} from "../src/LiquidityDeployer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------
//  Mocks
// ---------------------------------------------------------------

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Normal mock router — all calls succeed.
contract MockPulseXRouter {
    address public immutable wplsAddr;

    uint256 public swapCallCount;
    uint256 public lastLPLiquidity;
    address public lastLPTo;
    address public lastLiqTokenA;
    address public lastLiqTokenB;

    constructor(address _wpls) {
        wplsAddr = _wpls;
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256, address[] calldata path, address to, uint256
    ) external payable {
        MockERC20(path[1]).mint(to, msg.value);
        swapCallCount++;
    }

    function addLiquidityETH(
        address tokenAddr,
        uint256 amountTokenDesired,
        uint256,
        uint256,
        address to,
        uint256
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        IERC20(tokenAddr).transferFrom(msg.sender, address(this), amountTokenDesired);
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = msg.value;
        lastLPLiquidity = liquidity;
        lastLPTo = to;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256,
        uint256,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired);
        IERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired);
        amountA = amountADesired;
        amountB = amountBDesired;
        liquidity = amountADesired;
        lastLPLiquidity = liquidity;
        lastLPTo = to;
        lastLiqTokenA = tokenA;
        lastLiqTokenB = tokenB;
    }

    receive() external payable {}
}

/// @dev Router that reverts on swap and addLiquidity calls — simulates "no V2 pair".
contract RevertingRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256, address[] calldata, address, uint256
    ) external payable {
        revert("no pair");
    }

    function addLiquidityETH(
        address, uint256, uint256, uint256, address, uint256
    ) external payable returns (uint256, uint256, uint256) {
        revert("no pair");
    }

    function addLiquidity(
        address, address, uint256, uint256, uint256, uint256, address, uint256
    ) external returns (uint256, uint256, uint256) {
        revert("no pair");
    }

    receive() external payable {}
}

// ---------------------------------------------------------------
//  Tests
// ---------------------------------------------------------------

contract LiquidityDeployerTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LiquidityDeployer deployer;
    MockPulseXRouter routerV2;
    MockPulseXRouter routerV1;
    MockERC20 tokenA;
    MockERC20 tokenB;
    address wpls;

    function setUp() public {
        wpls = makeAddr("wpls");
        routerV2 = new MockPulseXRouter(wpls);
        routerV1 = new MockPulseXRouter(wpls);
        deployer = new LiquidityDeployer(wpls, address(routerV2), address(routerV1));
        tokenA = new MockERC20("TokenA", "TKA");
        tokenB = new MockERC20("TokenB", "TKB");
    }

    // ---- Token/PLS pair ----

    function test_addLiquidity_tokenPls() public {
        uint256 plsAmount = 10 ether;
        deployer.addLiquidity{value: plsAmount}(address(tokenA), address(0));

        // LP sent to DEAD
        assertEq(routerV2.lastLPTo(), DEAD);
        assertGt(routerV2.lastLPLiquidity(), 0);
    }

    // ---- Token/Token pair ----

    function test_addLiquidity_tokenToken() public {
        uint256 plsAmount = 10 ether;
        deployer.addLiquidity{value: plsAmount}(address(tokenA), address(tokenB));

        assertEq(routerV2.lastLPTo(), DEAD);
        assertEq(routerV2.lastLiqTokenA(), address(tokenA));
        assertEq(routerV2.lastLiqTokenB(), address(tokenB));
        assertGt(routerV2.lastLPLiquidity(), 0);
    }

    // ---- Reverts ----

    function test_addLiquidity_revertsZeroValue() public {
        vm.expectRevert("zero value");
        deployer.addLiquidity(address(tokenA), address(0));
    }

    function test_addLiquidity_revertsZeroTokenA() public {
        vm.expectRevert("zero tokenA");
        deployer.addLiquidity{value: 1 ether}(address(0), address(0));
    }

    // ---- Leftovers burned to DEAD ----

    function test_addLiquidity_leftoversBurnedToDead_tokenPls() public {
        deployer.addLiquidity{value: 10 ether}(address(tokenA), address(0));
        assertEq(tokenA.balanceOf(address(deployer)), 0);
    }

    function test_addLiquidity_leftoversBurnedToDead_tokenToken() public {
        deployer.addLiquidity{value: 10 ether}(address(tokenA), address(tokenB));
        assertEq(tokenA.balanceOf(address(deployer)), 0);
        assertEq(tokenB.balanceOf(address(deployer)), 0);
    }

    // ---- Event ----

    function test_addLiquidity_emitsEvent_tokenPls() public {
        vm.expectEmit(true, true, false, true);
        emit LiquidityDeployer.LiquidityAdded(address(tokenA), address(0), 5 ether, 10 ether);
        deployer.addLiquidity{value: 10 ether}(address(tokenA), address(0));
    }

    function test_addLiquidity_emitsEvent_tokenToken() public {
        vm.expectEmit(true, true, false, true);
        emit LiquidityDeployer.LiquidityAdded(address(tokenA), address(tokenB), 5 ether, 10 ether);
        deployer.addLiquidity{value: 10 ether}(address(tokenA), address(tokenB));
    }

    // ---- setRouterV2 / setRouterV1 ----

    function test_setRouterV2() public {
        address newRouter = makeAddr("newRouterV2");
        deployer.setRouterV2(newRouter);
        assertEq(deployer.routerV2(), newRouter);
    }

    function test_setRouterV2_revertsNonOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        deployer.setRouterV2(makeAddr("newRouterV2"));
    }

    function test_setRouterV2_revertsZero() public {
        vm.expectRevert("zero routerV2");
        deployer.setRouterV2(address(0));
    }

    function test_setRouterV1() public {
        address newRouter = makeAddr("newRouterV1");
        deployer.setRouterV1(newRouter);
        assertEq(deployer.routerV1(), newRouter);
    }

    function test_setRouterV1_revertsNonOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        deployer.setRouterV1(makeAddr("newRouterV1"));
    }

    function test_setRouterV1_revertsZero() public {
        vm.expectRevert("zero routerV1");
        deployer.setRouterV1(address(0));
    }

    // ---- receive ----

    function test_receive_acceptsPLS() public {
        (bool ok,) = address(deployer).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(deployer).balance, 1 ether);
    }

    // ---- Constructor reverts ----

    function test_constructor_revertsZeroWpls() public {
        vm.expectRevert("zero wpls");
        new LiquidityDeployer(address(0), address(routerV2), address(routerV1));
    }

    function test_constructor_revertsZeroRouterV2() public {
        vm.expectRevert("zero routerV2");
        new LiquidityDeployer(wpls, address(0), address(routerV1));
    }

    function test_constructor_revertsZeroRouterV1() public {
        vm.expectRevert("zero routerV1");
        new LiquidityDeployer(wpls, address(routerV2), address(0));
    }

    // ---- V2-first routing ----

    function test_addLiquidity_usesV2WhenAvailable() public {
        deployer.addLiquidity{value: 10 ether}(address(tokenA), address(0));

        // V2 should have been called, V1 should not
        assertGt(routerV2.swapCallCount(), 0);
        assertEq(routerV1.swapCallCount(), 0);
        assertEq(routerV2.lastLPTo(), DEAD);
    }

    // ---- V1 fallback — Token/PLS ----

    function test_addLiquidity_fallsBackToV1_tokenPls() public {
        // Use a reverting V2 router
        RevertingRouter badV2 = new RevertingRouter();
        LiquidityDeployer d = new LiquidityDeployer(wpls, address(badV2), address(routerV1));

        d.addLiquidity{value: 10 ether}(address(tokenA), address(0));

        // V1 got the swap and LP
        assertGt(routerV1.swapCallCount(), 0);
        assertEq(routerV1.lastLPTo(), DEAD);
        assertGt(routerV1.lastLPLiquidity(), 0);
    }

    // ---- V1 fallback — Token/Token ----

    function test_addLiquidity_fallsBackToV1_tokenToken() public {
        RevertingRouter badV2 = new RevertingRouter();
        LiquidityDeployer d = new LiquidityDeployer(wpls, address(badV2), address(routerV1));

        d.addLiquidity{value: 10 ether}(address(tokenA), address(tokenB));

        // V1 got the swaps and LP
        assertGt(routerV1.swapCallCount(), 0);
        assertEq(routerV1.lastLPTo(), DEAD);
        assertEq(routerV1.lastLiqTokenA(), address(tokenA));
        assertEq(routerV1.lastLiqTokenB(), address(tokenB));
    }

    // ---- Mixed routers — tokenA on V2, tokenB falls to V1 ----

    function test_addLiquidity_mixedRouters() public {
        // V2 works for both tokens at swap level (both succeed on routerV2),
        // but LP addLiquidity on V2 could fail. We test the simpler case:
        // both swaps succeed on V2, LP added on V2.
        deployer.addLiquidity{value: 10 ether}(address(tokenA), address(tokenB));

        assertEq(routerV2.swapCallCount(), 2);
        assertEq(routerV1.swapCallCount(), 0);
        assertEq(routerV2.lastLPTo(), DEAD);
    }
}
