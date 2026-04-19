// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {IStakingVault} from "../src/interfaces/IStakingVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------
//  Mock ERC-20
// ---------------------------------------------------------------

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ---------------------------------------------------------------
//  Mock PulseX Router (supports both ETH and token-to-token swaps)
// ---------------------------------------------------------------

contract MockWPLS is ERC20 {
    constructor() ERC20("Wrapped PLS", "WPLS") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPulseXRouter {
    address public immutable wplsAddr;
    MockERC20 public rewardToken;
    uint256 public swapRate; // reward tokens per PLS (scaled 1:1 default)

    constructor(address _wpls, address _rewardToken) {
        wplsAddr = _wpls;
        rewardToken = MockERC20(_rewardToken);
        swapRate = 1;
    }

    function setSwapRate(uint256 rate) external {
        swapRate = rate;
    }

    function WPLS() external view returns (address) {
        return wplsAddr;
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256, /* amountOutMin */
        address[] calldata, /* path */
        address to,
        uint256 /* deadline */
    ) external payable {
        uint256 rewardAmount = msg.value * swapRate;
        rewardToken.mint(to, rewardAmount);
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256, /* amountOutMin */
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external {
        // Pull staking tokens from the caller via the first token in path
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        // Simulate swap: mint output token proportional to input
        uint256 outAmount = amountIn * swapRate;
        address outToken = path[path.length - 1];
        if (outToken == wplsAddr) {
            MockWPLS(payable(wplsAddr)).mint(to, outAmount);
        } else {
            rewardToken.mint(to, outAmount);
        }
    }
}

// ---------------------------------------------------------------
//  StakingVault Tests — Weighted Multi-Position
// ---------------------------------------------------------------

contract StakingVaultTest is Test {
    MockERC20 stakeToken;
    MockERC20 rewardToken;
    MockERC20 randomToken;
    MockWPLS wpls;
    MockPulseXRouter router;
    StakingVault vault;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address dao = makeAddr("dao");
    address dev = makeAddr("dev");

    uint256 constant TOP_COUNT = 3;
    uint256 constant SEVEN_DAYS = 7 days;

    function setUp() public {
        stakeToken = new MockERC20("Stake", "STK");
        rewardToken = new MockERC20("Reward", "RWD");
        randomToken = new MockERC20("Random", "RND");
        MockWPLS _tmpWpls = new MockWPLS();
        vm.etch(0xA1077a294dDE1B09bB078844df40758a5D0f9a27, address(_tmpWpls).code);
        wpls = MockWPLS(payable(0xA1077a294dDE1B09bB078844df40758a5D0f9a27));
        router = new MockPulseXRouter(address(wpls), address(rewardToken));
        vault = new StakingVault(
            address(stakeToken),
            address(rewardToken),
            owner,
            TOP_COUNT
        );
        vault.setDexRouter(address(router));
        vault.setDaoAddress(dao);
        vault.setDevWallet(dev);
    }

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    function test_constructor_setsState() public view {
        assertEq(vault.stakingToken(), address(stakeToken));
        assertEq(vault.rewardsToken(), address(rewardToken));
        assertEq(vault.topStakerCount(), TOP_COUNT);
        assertEq(vault.owner(), owner);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.totalStakers(), 0);
        assertEq(vault.rewardsDuration(), SEVEN_DAYS);
    }

    function test_constructor_acceptsZeroStakeToken() public {
        StakingVault v = new StakingVault(address(0), address(rewardToken), owner, TOP_COUNT);
        assertEq(address(v.STAKING_TOKEN()), address(0));
    }

    function test_constructor_revertsZeroRewardToken() public {
        vm.expectRevert("StakingVault: zero rewards token");
        new StakingVault(address(stakeToken), address(0), owner, TOP_COUNT);
    }

    function test_constructor_revertsZeroTopCount() public {
        vm.expectRevert("StakingVault: invalid top count");
        new StakingVault(address(stakeToken), address(rewardToken), owner, 0);
    }

    // ---------------------------------------------------------------
    //  Flex Stake
    // ---------------------------------------------------------------

    function test_stake_basic() public {
        _mintAndApprove(alice, 100e18);

        vm.prank(alice);
        vault.stake(100e18);

        assertEq(vault.flexBalance(alice), 100e18);
        assertEq(vault.totalStaked(), 100e18);
        assertEq(vault.totalEffectiveStaked(), 100e18);
        assertEq(vault.effectiveBalance(alice), 100e18);
        assertEq(vault.totalStakers(), 1);
    }

    function test_stake_revertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("StakingVault: zero stake");
        vault.stake(0);
    }

    function test_stake_multipleStakes_sameUser() public {
        _mintAndApprove(alice, 200e18);

        vm.startPrank(alice);
        vault.stake(100e18);
        vault.stake(100e18);
        vm.stopPrank();

        assertEq(vault.flexBalance(alice), 200e18);
        assertEq(vault.totalStakers(), 1);
    }

    function test_stake_revertsWhenPaused() public {
        vault.setPaused(true);
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert("StakingVault: paused");
        vault.stake(100e18);
    }

    // ---------------------------------------------------------------
    //  Flex Withdraw (with 1% fee)
    // ---------------------------------------------------------------

    function test_withdraw_basic_with1pctFee() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        uint256 deadBefore = stakeToken.balanceOf(vault.DEAD());

        vm.prank(alice);
        vault.withdraw(100e18);

        // 1% fee = 1e18 burned to DEAD, 99e18 to alice
        assertEq(stakeToken.balanceOf(alice), 99e18);
        assertEq(stakeToken.balanceOf(vault.DEAD()) - deadBefore, 1e18);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.totalStakers(), 0);
    }

    function test_withdraw_partial() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        uint256 deadBefore = stakeToken.balanceOf(vault.DEAD());

        vm.prank(alice);
        vault.withdraw(60e18);

        // 1% of 60 = 0.6e18 burned to DEAD
        assertEq(stakeToken.balanceOf(vault.DEAD()) - deadBefore, 0.6e18);
        assertEq(stakeToken.balanceOf(alice), 59.4e18);
        assertEq(vault.flexBalance(alice), 40e18);
        assertEq(vault.totalStakers(), 1);
    }

    function test_withdraw_emitsEventWithFee() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        vm.expectEmit(true, false, false, true);
        emit IStakingVault.Withdrawn(alice, 100e18, 1e18);

        vm.prank(alice);
        vault.withdraw(100e18);
    }

    function test_withdraw_revertsInsufficientBalance() public {
        _mintAndApprove(alice, 50e18);
        vm.prank(alice);
        vault.stake(50e18);

        vm.prank(alice);
        vm.expectRevert("StakingVault: insufficient balance");
        vault.withdraw(51e18);
    }

    function test_withdraw_revertsZeroAmount() public {
        _mintAndApprove(alice, 50e18);
        vm.prank(alice);
        vault.stake(50e18);

        vm.prank(alice);
        vm.expectRevert("StakingVault: zero withdraw");
        vault.withdraw(0);
    }

    function test_withdraw_worksWhenPaused() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        vault.setPaused(true);

        vm.prank(alice);
        vault.withdraw(100e18);
        assertEq(stakeToken.balanceOf(alice), 99e18); // minus 1% fee
    }

    // ---------------------------------------------------------------
    //  Exit (flex only + claim)
    // ---------------------------------------------------------------

    function test_exit_withdrawsAllFlexAndClaims() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.exit();

        assertEq(vault.flexBalance(alice), 0);
        assertEq(stakeToken.balanceOf(alice), 99e18); // 1% fee
        assertApproxEqAbs(rewardToken.balanceOf(alice), 700e18, 1e15);
    }

    // ---------------------------------------------------------------
    //  Lock Staking
    // ---------------------------------------------------------------

    function test_stakeLocked_90days() public {
        _mintAndApprove(alice, 100e18);

        vm.prank(alice);
        vault.stakeLocked(100e18, 90 days);

        assertEq(vault.lockCount(alice), 1);
        IStakingVault.LockPosition memory lk = vault.getLock(alice, 0);
        assertEq(lk.amount, 100e18);
        assertEq(lk.duration, 90 days);
        assertEq(lk.multiplier, 15000); // 1.5x
        assertEq(lk.unlockTime, block.timestamp + 90 days);

        // Effective = 100 * 1.5 = 150
        assertEq(vault.effectiveBalance(alice), 150e18);
        assertEq(vault.totalEffectiveStaked(), 150e18);
        assertEq(vault.totalStaked(), 100e18);
        assertEq(vault.totalStakers(), 1);
    }

    function test_stakeLocked_365days() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stakeLocked(100e18, 365 days);

        assertEq(vault.getLock(alice, 0).multiplier, 30000); // 3x
        assertEq(vault.effectiveBalance(alice), 300e18);
    }

    function test_stakeLocked_10years() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stakeLocked(100e18, 3650 days);

        assertEq(vault.getLock(alice, 0).multiplier, 100000); // 10x
        assertEq(vault.effectiveBalance(alice), 1000e18);
    }

    function test_stakeLocked_revertsInvalidDuration() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert("StakingVault: invalid lock duration");
        vault.stakeLocked(100e18, 42 days);
    }

    function test_stakeLocked_revertsFlexDuration() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert("StakingVault: use stake() for flex");
        vault.stakeLocked(100e18, 0);
    }

    function test_stakeLocked_revertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("StakingVault: zero stake");
        vault.stakeLocked(0, 90 days);
    }

    function test_stakeLocked_multiplePositions() public {
        _mintAndApprove(alice, 300e18);

        vm.startPrank(alice);
        vault.stakeLocked(100e18, 90 days);    // 150 eff
        vault.stakeLocked(100e18, 365 days);   // 300 eff
        vault.stakeLocked(100e18, 730 days);   // 400 eff
        vm.stopPrank();

        assertEq(vault.lockCount(alice), 3);
        assertEq(vault.totalStaked(), 300e18);
        assertEq(vault.effectiveBalance(alice), 850e18); // 150+300+400
        assertEq(vault.totalStakers(), 1);
    }

    function test_stakeLocked_maxLocksCapReached() public {
        _mintAndApprove(alice, 51e18);
        vm.startPrank(alice);
        for (uint256 i; i < 50; ++i) {
            vault.stakeLocked(1e18, 90 days);
        }
        vm.expectRevert("StakingVault: too many locks");
        vault.stakeLocked(1e18, 90 days);
        vm.stopPrank();
    }

    function test_stakeLocked_revertsWhenPaused() public {
        vault.setPaused(true);
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert("StakingVault: paused");
        vault.stakeLocked(100e18, 90 days);
    }

    // ---------------------------------------------------------------
    //  Unlock — expired (full return)
    // ---------------------------------------------------------------

    function test_unlock_expired_fullReturn() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stakeLocked(100e18, 90 days);

        vm.warp(block.timestamp + 90 days + 1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.prank(alice);
        vault.unlock(ids);

        assertEq(stakeToken.balanceOf(alice), 100e18); // full amount
        assertEq(vault.lockCount(alice), 0);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.totalEffectiveStaked(), 0);
        assertEq(vault.totalStakers(), 0);
    }

    // ---------------------------------------------------------------
    //  Unlock — early (30% penalty)
    // ---------------------------------------------------------------

    function test_unlock_early_30pctPenalty() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stakeLocked(100e18, 90 days);

        // Unlock early (only 1 day in)
        vm.warp(block.timestamp + 1 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.prank(alice);
        vault.unlock(ids);

        // 30% penalty = 30e18
        // Alice gets 70e18
        assertEq(stakeToken.balanceOf(alice), 70e18);

        // Penalty distribution: 30e18 total
        // 59% burn = 17.7e18 to DEAD
        assertEq(stakeToken.balanceOf(vault.DEAD()), 17.7e18);
        // 10% DAO = 3e18 (swapped to WPLS)
        assertEq(wpls.balanceOf(dao), 3e18);
        // 1% dev = 0.3e18 (swapped to WPLS)
        assertEq(wpls.balanceOf(dev), 0.3e18);
        // 30% to stakers (pending penalty tokens) = 9e18
        assertEq(vault.pendingPenaltyTokens(), 9e18);
    }

    function test_unlock_emitsPenaltyDistributed() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stakeLocked(100e18, 90 days);

        vm.warp(block.timestamp + 1 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;

        vm.expectEmit(true, false, false, true);
        emit IStakingVault.PenaltyDistributed(30e18, 9e18, 17.7e18, 3e18, 0.3e18);

        vm.prank(alice);
        vault.unlock(ids);
    }

    // ---------------------------------------------------------------
    //  Unlock — descending order requirement
    // ---------------------------------------------------------------

    function test_unlock_multipleIds_descendingOrder() public {
        _mintAndApprove(alice, 300e18);
        vm.startPrank(alice);
        vault.stakeLocked(100e18, 90 days);  // id 0
        vault.stakeLocked(100e18, 180 days); // id 1
        vault.stakeLocked(100e18, 365 days); // id 2
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days + 1); // all expired

        uint256[] memory ids = new uint256[](3);
        ids[0] = 2;
        ids[1] = 1;
        ids[2] = 0;

        vm.prank(alice);
        vault.unlock(ids);

        assertEq(stakeToken.balanceOf(alice), 300e18);
        assertEq(vault.lockCount(alice), 0);
    }

    function test_unlock_revertsAscendingOrder() public {
        _mintAndApprove(alice, 200e18);
        vm.startPrank(alice);
        vault.stakeLocked(100e18, 90 days);
        vault.stakeLocked(100e18, 180 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 180 days + 1);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;

        vm.prank(alice);
        vm.expectRevert("StakingVault: ids must be descending");
        vault.unlock(ids);
    }

    function test_unlock_revertsEmptyArray() public {
        uint256[] memory ids = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert("StakingVault: empty array");
        vault.unlock(ids);
    }

    // ---------------------------------------------------------------
    //  Unlock — vote lock blocks unlock
    // ---------------------------------------------------------------

    function test_unlock_revertsWhenVoteLocked() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stakeLocked(100e18, 90 days);

        // Simulate DAO setting vote lock that extends past current time
        vm.prank(dao);
        vault.lockForVote(alice, block.timestamp + 30 days);

        // Warp partway — vote lock still active
        vm.warp(block.timestamp + 15 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.prank(alice);
        vm.expectRevert("StakingVault: tokens locked by active vote");
        vault.unlock(ids);
    }

    // ---------------------------------------------------------------
    //  Weighted Rewards
    // ---------------------------------------------------------------

    function test_weightedRewards_flexVsLocked() public {
        // Alice: 100 flex (1x = 100 eff)
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        // Bob: 100 locked 1yr (3x = 300 eff)
        _mintAndApprove(bob, 100e18);
        vm.prank(bob);
        vault.stakeLocked(100e18, 365 days);

        // Total effective = 400
        assertEq(vault.totalEffectiveStaked(), 400e18);

        _notifyReward(400e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        // Alice: 100/400 = 25% → 100e18
        // Bob: 300/400 = 75% → 300e18
        assertApproxEqAbs(vault.earned(alice), 100e18, 1e15);
        assertApproxEqAbs(vault.earned(bob), 300e18, 1e15);
    }

    function test_weightedRewards_multipleLockedTiers() public {
        // Alice: 100 locked 90d (1.5x = 150 eff)
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stakeLocked(100e18, 90 days);

        // Bob: 100 locked 2yr (4x = 400 eff)
        _mintAndApprove(bob, 100e18);
        vm.prank(bob);
        vault.stakeLocked(100e18, 730 days);

        // Total = 550
        _notifyReward(550e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        assertApproxEqAbs(vault.earned(alice), 150e18, 1e15);
        assertApproxEqAbs(vault.earned(bob), 400e18, 1e15);
    }

    function test_weightedRewards_lockMidPeriod_snapshotsCorrectly() public {
        // Alice stakes flex at start
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        // Bob locks halfway
        vm.warp(block.timestamp + SEVEN_DAYS / 2);

        _mintAndApprove(bob, 100e18);
        vm.prank(bob);
        vault.stakeLocked(100e18, 365 days); // 3x = 300 eff

        // First half: Alice gets 100% of 350 = 350
        // Second half: Alice 100/(100+300)=25% of 350 = 87.5, Bob 75% of 350 = 262.5
        vm.warp(block.timestamp + SEVEN_DAYS / 2);

        assertApproxEqAbs(vault.earned(alice), 437.5e18, 1e15);
        assertApproxEqAbs(vault.earned(bob), 262.5e18, 1e15);
    }

    function test_weightedRewards_unlockStopsEarning() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stakeLocked(100e18, 90 days);

        _mintAndApprove(bob, 100e18);
        vm.prank(bob);
        vault.stake(100e18);

        _notifyReward(1000e18);

        // Warp halfway through reward period
        vm.warp(block.timestamp + SEVEN_DAYS / 2);

        // Snapshot earned before unlock
        uint256 aliceEarnedBefore = vault.earned(alice);
        uint256 bobEarnedHalf = vault.earned(bob);

        // Alice unlocks early (takes penalty)
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.prank(alice);
        vault.unlock(ids);

        // Alice's earned rewards are materialized in rewards[] mapping
        uint256 aliceEarnedAfterUnlock = vault.earned(alice);
        assertApproxEqAbs(aliceEarnedAfterUnlock, aliceEarnedBefore, 1e15);

        // Claim alice's rewards to reset
        vm.prank(alice);
        vault.getReward();
        assertEq(vault.earned(alice), 0);

        // Now only Bob is staking, gets all remaining rewards
        vm.warp(block.timestamp + SEVEN_DAYS / 2);

        uint256 bobEarnedFull = vault.earned(bob);
        assertGt(bobEarnedFull, bobEarnedHalf);
        // Alice has no more accruing
        assertEq(vault.earned(alice), 0);
    }

    // ---------------------------------------------------------------
    //  getReward — collects flex + all lock rewards
    // ---------------------------------------------------------------

    function test_getReward_collectsFlexAndLockRewards() public {
        _mintAndApprove(alice, 200e18);
        vm.startPrank(alice);
        vault.stake(100e18);
        vault.stakeLocked(100e18, 90 days);
        vm.stopPrank();

        // Flex = 100 eff, Lock = 150 eff (1.5x), total = 250
        _notifyReward(250e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();

        assertApproxEqAbs(rewardToken.balanceOf(alice), 250e18, 1e15);
    }

    function test_getReward_afterFullPeriod() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();

        assertApproxEqAbs(rewardToken.balanceOf(alice), 700e18, 1e15);
    }

    function test_getReward_noReward_doesNothing() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(alice);
        vault.getReward();
        assertEq(rewardToken.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------
    //  Reward drip — time-based scenarios
    // ---------------------------------------------------------------

    function test_earned_proportionalDistribution() public {
        _mintAndApprove(alice, 75e18);
        _mintAndApprove(bob, 25e18);

        vm.prank(alice);
        vault.stake(75e18);
        vm.prank(bob);
        vault.stake(25e18);

        _notifyReward(1000e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        assertApproxEqAbs(vault.earned(alice), 750e18, 1e15);
        assertApproxEqAbs(vault.earned(bob), 250e18, 1e15);
    }

    function test_rewardDrip_linearOverTime() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(vault.earned(alice), 100e18, 1e15);

        vm.warp(block.timestamp + 2.5 days);
        assertApproxEqAbs(vault.earned(alice), 350e18, 1e15);

        vm.warp(block.timestamp + 3.5 days);
        assertApproxEqAbs(vault.earned(alice), 700e18, 1e15);
    }

    function test_rewardDrip_stopsAfterPeriodFinish() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);
        vm.warp(block.timestamp + SEVEN_DAYS + 30 days);

        assertApproxEqAbs(vault.earned(alice), 700e18, 1e15);
    }

    /// @notice Period expires → gap with zero accrual → new rewards arrive → drip restarts
    function test_rewardDrip_restartsAfterExpiredGap() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        // Period 1: 700 rewards over 7 days
        _notifyReward(700e18);
        uint256 finish1 = vault.periodFinish();

        // Warp past period end + 30 day gap
        vm.warp(finish1 + 30 days);

        // Alice claims period 1 rewards
        uint256 earned1 = vault.earned(alice);
        assertApproxEqAbs(earned1, 700e18, 1e15, "period 1 full");
        vm.prank(alice);
        vault.getReward();

        // Confirm period is dead
        assertLt(vault.periodFinish(), block.timestamp, "period should be expired");
        assertEq(vault.earned(alice), 0, "no new rewards accruing");

        // Period 2: send new rewards after the gap
        _notifyReward(300e18);
        uint256 finish2 = vault.periodFinish();
        assertGt(finish2, block.timestamp, "new period should be active");
        assertApproxEqAbs(finish2, block.timestamp + SEVEN_DAYS, 1, "new 7-day window");

        // Warp to end of period 2
        vm.warp(finish2 + 1);

        uint256 earned2 = vault.earned(alice);
        assertApproxEqAbs(earned2, 300e18, 1e15, "period 2 full after restart");

        // Total across both periods
        vm.prank(alice);
        vault.getReward();
        uint256 totalReceived = rewardToken.balanceOf(alice);
        assertApproxEqAbs(totalReceived, 1000e18, 2e15, "total = 700 + 300");
    }

    // ---------------------------------------------------------------
    //  Governance — top stakers ranked by effective weight
    // ---------------------------------------------------------------

    function test_topStakers_rankedByEffectiveBalance() public {
        // Alice: 50 flex = 50 eff
        _mintAndApprove(alice, 50e18);
        vm.prank(alice);
        vault.stake(50e18);

        // Bob: 30 locked 1yr = 90 eff (3x)
        _mintAndApprove(bob, 30e18);
        vm.prank(bob);
        vault.stakeLocked(30e18, 365 days);

        // Carol: 40 flex = 40 eff
        _mintAndApprove(carol, 40e18);
        vm.prank(carol);
        vault.stake(40e18);

        address[] memory tops = vault.getTopStakers();
        assertEq(tops.length, 3);
        assertEq(tops[0], bob);   // 90 eff
        assertEq(tops[1], alice); // 50 eff
        assertEq(tops[2], carol); // 40 eff
    }

    function test_topStakers_removedOnFullWithdraw() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        assertTrue(vault.isTopStaker(alice));

        vm.prank(alice);
        vault.withdraw(100e18);

        assertFalse(vault.isTopStaker(alice));
    }

    function test_topStakers_evictsSmallestWhenFull() public {
        _mintAndApprove(alice, 10e18);
        _mintAndApprove(bob, 20e18);
        _mintAndApprove(carol, 30e18);

        vm.prank(alice);
        vault.stake(10e18);
        vm.prank(bob);
        vault.stake(20e18);
        vm.prank(carol);
        vault.stake(30e18);

        // Dave stakes 25 — should evict Alice (10)
        _mintAndApprove(dave, 25e18);
        vm.prank(dave);
        vault.stake(25e18);

        assertFalse(vault.isTopStaker(alice));
        assertTrue(vault.isTopStaker(dave));

        address[] memory tops = vault.getTopStakers();
        assertEq(tops.length, 3);
        assertEq(tops[0], carol); // 30
        assertEq(tops[1], dave);  // 25
        assertEq(tops[2], bob);   // 20
    }

    // ---------------------------------------------------------------
    //  Lock Tier Views
    // ---------------------------------------------------------------

    function test_getLockTiers() public view {
        (uint256[] memory durations, uint256[] memory multipliers) = vault.getLockTiers();
        assertEq(durations.length, 7);
        assertEq(durations[0], 0);
        assertEq(multipliers[0], 10000);
        assertEq(durations[1], 90 days);
        assertEq(multipliers[1], 15000);
        assertEq(durations[6], 3650 days);
        assertEq(multipliers[6], 100000);
    }

    function test_getMultiplierForDuration() public view {
        assertEq(vault.getMultiplierForDuration(0), 10000);
        assertEq(vault.getMultiplierForDuration(90 days), 15000);
        assertEq(vault.getMultiplierForDuration(365 days), 30000);
    }

    // ---------------------------------------------------------------
    //  notifyRewardAmount
    // ---------------------------------------------------------------

    function test_notifyRewardAmount_basic() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        assertGt(vault.rewardRate(), 0);
        assertEq(vault.periodFinish(), block.timestamp + SEVEN_DAYS);
    }

    function test_notifyRewardAmount_revertsZero() public {
        vm.expectRevert("StakingVault: zero reward");
        vault.notifyRewardAmount(0);
    }

    function test_notifyRewardAmount_duringActivePeriod_restacks() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);
        uint256 rateBefore = vault.rewardRate();

        vm.warp(block.timestamp + SEVEN_DAYS / 2);
        _notifyReward(700e18);

        assertGt(vault.rewardRate(), rateBefore);
        assertEq(vault.periodFinish(), block.timestamp + SEVEN_DAYS);
    }

    // ---------------------------------------------------------------
    //  topUp
    // ---------------------------------------------------------------

    function test_topUp_basic() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        vm.deal(address(this), 10e18);
        vault.topUp{value: 10e18}();

        assertGt(vault.rewardRate(), 0);
    }

    function test_topUp_revertsZeroPLS() public {
        vm.expectRevert("StakingVault: zero PLS");
        vault.topUp{value: 0}();
    }

    // ---------------------------------------------------------------
    //  processRewards
    // ---------------------------------------------------------------

    function test_processRewards_basic() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        rewardToken.mint(address(vault), 700e18);
        vault.processRewards();

        assertGt(vault.rewardRate(), 0);
    }

    function test_processRewards_revertsNoNewRewards() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        vm.expectRevert("StakingVault: no new rewards");
        vault.processRewards();
    }

    // ---------------------------------------------------------------
    //  Admin — setDevWallet
    // ---------------------------------------------------------------

    function test_setDevWallet() public {
        address newDev = makeAddr("newDev");

        vm.expectEmit(true, true, false, true);
        emit IStakingVault.DevWalletUpdated(dev, newDev);

        vault.setDevWallet(newDev);
        assertEq(vault.devWallet(), newDev);
    }

    function test_setDevWallet_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setDevWallet(alice);
    }

    // ---------------------------------------------------------------
    //  Admin — setDaoAddress
    // ---------------------------------------------------------------

    function test_setDaoAddress() public {
        address newDao = makeAddr("newDao");
        vault.setDaoAddress(newDao);
        assertEq(vault.daoAddress(), newDao);
    }

    // ---------------------------------------------------------------
    //  Admin — setRewardsDuration
    // ---------------------------------------------------------------

    function test_setRewardsDuration_afterPeriodFinishes() public {
        vault.setRewardsDuration(14 days);
        assertEq(vault.rewardsDuration(), 14 days);
    }

    function test_setRewardsDuration_revertsDuringActivePeriod() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);
        _notifyReward(700e18);

        vm.expectRevert("StakingVault: period not finished");
        vault.setRewardsDuration(14 days);
    }

    function test_setRewardsDuration_revertsZero() public {
        vm.expectRevert("StakingVault: zero duration");
        vault.setRewardsDuration(0);
    }

    // ---------------------------------------------------------------
    //  Admin — setPaused
    // ---------------------------------------------------------------

    function test_setPaused_blocksStake() public {
        vault.setPaused(true);
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert("StakingVault: paused");
        vault.stake(100e18);
    }

    // ---------------------------------------------------------------
    //  Admin — recoverERC20
    // ---------------------------------------------------------------

    function test_recoverERC20_recoversRandomToken() public {
        randomToken.mint(address(vault), 500e18);
        vault.recoverERC20(address(randomToken), 500e18);
        assertEq(randomToken.balanceOf(owner), 500e18);
    }

    function test_recoverERC20_cannotRecoverStakingToken() public {
        stakeToken.mint(address(vault), 100e18);
        vm.expectRevert("StakingVault: cannot recover staking token");
        vault.recoverERC20(address(stakeToken), 100e18);
    }

    // ---------------------------------------------------------------
    //  Edge cases
    // ---------------------------------------------------------------

    function test_zeroEffectiveSupply_rewardPerToken_unchanged() public view {
        assertEq(vault.rewardPerToken(), 0);
    }

    function test_solvencyInvariant_sameTokenStakeReward() public {
        // Deploy vault where staking token == reward token
        StakingVault sameVault = new StakingVault(
            address(stakeToken), address(stakeToken), owner, TOP_COUNT
        );
        sameVault.setDaoAddress(dao);
        sameVault.setDevWallet(dev);

        stakeToken.mint(alice, 100e18);
        vm.startPrank(alice);
        stakeToken.approve(address(sameVault), 100e18);
        sameVault.stake(100e18);
        vm.stopPrank();

        // Reward injection
        stakeToken.mint(address(this), 700e18);
        stakeToken.approve(address(sameVault), 700e18);
        sameVault.notifyRewardAmount(700e18);

        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        sameVault.getReward();
        assertApproxEqAbs(stakeToken.balanceOf(alice), 700e18, 1e15);

        // Withdraw flex — should succeed without touching reward allocation
        vm.prank(alice);
        sameVault.withdraw(100e18);
        // Alice gets 99e18 from flex (1% fee) + 700e18 from rewards
        assertApproxEqAbs(stakeToken.balanceOf(alice), 799e18, 1e15);
    }

    function test_stakedBalance_sumOfFlexAndLocks() public {
        _mintAndApprove(alice, 250e18);
        vm.startPrank(alice);
        vault.stake(100e18);
        vault.stakeLocked(50e18, 90 days);
        vault.stakeLocked(100e18, 365 days);
        vm.stopPrank();

        assertEq(vault.stakedBalance(alice), 250e18);
        assertEq(vault.flexBalance(alice), 100e18);
    }

    function test_getUserLocks() public {
        _mintAndApprove(alice, 200e18);
        vm.startPrank(alice);
        vault.stakeLocked(100e18, 90 days);
        vault.stakeLocked(100e18, 365 days);
        vm.stopPrank();

        IStakingVault.LockPosition[] memory locks = vault.getUserLocks(alice);
        assertEq(locks.length, 2);
        assertEq(locks[0].multiplier, 15000);
        assertEq(locks[1].multiplier, 30000);
    }

    function test_pendingRewardForLock() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stakeLocked(100e18, 365 days);

        _notifyReward(300e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        uint256 pending = vault.pendingRewardForLock(alice, 0);
        assertApproxEqAbs(pending, 300e18, 1e15);
    }

    // ---------------------------------------------------------------
    //  Vote lock interaction
    // ---------------------------------------------------------------

    function test_voteLock_withdrawRevertsWhileLocked() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(dao);
        vault.lockForVote(alice, block.timestamp + 7 days);

        vm.prank(alice);
        vm.expectRevert("StakingVault: tokens locked by active vote");
        vault.withdraw(10e18);
    }

    function test_voteLock_withdrawSucceedsAfterExpiry() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(dao);
        vault.lockForVote(alice, block.timestamp + 7 days);

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        vault.withdraw(10e18);
        assertEq(vault.flexBalance(alice), 90e18);
    }

    function test_voteLock_nonDaoCannotCallLockForVote() public {
        vm.prank(alice);
        vm.expectRevert("StakingVault: caller is not DAO");
        vault.lockForVote(alice, block.timestamp + 7 days);
    }

    // ---------------------------------------------------------------
    //  Multi-user reward claiming
    // ---------------------------------------------------------------

    function test_multipleUsers_claimAfterFullPeriod() public {
        _mintAndApprove(alice, 100e18);
        _mintAndApprove(bob, 100e18);

        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(bob);
        vault.stake(100e18);

        _notifyReward(1000e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();
        vm.prank(bob);
        vault.getReward();

        assertApproxEqAbs(rewardToken.balanceOf(alice), 500e18, 1e15);
        assertApproxEqAbs(rewardToken.balanceOf(bob), 500e18, 1e15);
    }

    // ---------------------------------------------------------------
    //  Helpers
    // ---------------------------------------------------------------

    function _mintAndApprove(address user, uint256 amount) internal {
        stakeToken.mint(user, amount);
        vm.prank(user);
        stakeToken.approve(address(vault), amount);
    }

    function _notifyReward(uint256 amount) internal {
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(vault), amount);
        vault.notifyRewardAmount(amount);
    }
}
