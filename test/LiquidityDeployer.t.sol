// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LiquidityDeployer} from "../src/LiquidityDeployer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------
//  Mocks (mirrored from TreasuryDAO.t.sol)
// ---------------------------------------------------------------

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPulseXRouter {
    address public immutable wplsAddr;

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

// ---------------------------------------------------------------
//  Tests
// ---------------------------------------------------------------

contract LiquidityDeployerTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LiquidityDeployer deployer;
    MockPulseXRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    address wpls;

    function setUp() public {
        wpls = makeAddr("wpls");
        router = new MockPulseXRouter(wpls);
        deployer = new LiquidityDeployer(wpls, address(router));
        tokenA = new MockERC20("TokenA", "TKA");
        tokenB = new MockERC20("TokenB", "TKB");
    }

    // ---- Token/PLS pair ----

    function test_addLiquidity_tokenPls() public {
        uint256 plsAmount = 10 ether;
        deployer.addLiquidity{value: plsAmount}(address(tokenA), address(0));

        // LP sent to DEAD
        assertEq(router.lastLPTo(), DEAD);
        assertGt(router.lastLPLiquidity(), 0);
    }

    // ---- Token/Token pair ----

    function test_addLiquidity_tokenToken() public {
        uint256 plsAmount = 10 ether;
        deployer.addLiquidity{value: plsAmount}(address(tokenA), address(tokenB));

        assertEq(router.lastLPTo(), DEAD);
        assertEq(router.lastLiqTokenA(), address(tokenA));
        assertEq(router.lastLiqTokenB(), address(tokenB));
        assertGt(router.lastLPLiquidity(), 0);
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

        // Contract should hold zero tokenA
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

    // ---- setRouter ----

    function test_setRouter() public {
        address newRouter = makeAddr("newRouter");
        deployer.setRouter(newRouter);
        assertEq(deployer.router(), newRouter);
    }

    function test_setRouter_revertsNonOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        deployer.setRouter(makeAddr("newRouter"));
    }

    function test_setRouter_revertsZero() public {
        vm.expectRevert("zero router");
        deployer.setRouter(address(0));
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
        new LiquidityDeployer(address(0), address(router));
    }

    function test_constructor_revertsZeroRouter() public {
        vm.expectRevert("zero router");
        new LiquidityDeployer(wpls, address(0));
    }
}
