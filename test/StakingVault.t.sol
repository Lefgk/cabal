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
//  Mock PulseX Router (for topUp tests)
// ---------------------------------------------------------------

contract MockWPLS is ERC20 {
    constructor() ERC20("Wrapped PLS", "WPLS") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
}

contract MockPulseXRouter {
    address public immutable wplsAddr;
    MockERC20 public rewardToken;
    uint256 public swapRate; // reward tokens per PLS (scaled 1:1 default)

    constructor(address _wpls, address _rewardToken) {
        wplsAddr = _wpls;
        rewardToken = MockERC20(_rewardToken);
        swapRate = 1; // 1 PLS = 1 reward token by default
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
        // Simulate swap: mint reward tokens proportional to PLS sent
        uint256 rewardAmount = msg.value * swapRate;
        rewardToken.mint(to, rewardAmount);
    }
}

// ---------------------------------------------------------------
//  StakingVault Tests (Synthetix StakingRewards style)
// ---------------------------------------------------------------

contract StakingVaultTest is Test {
    MockERC20 stakeToken;
    MockERC20 rewardToken;
    MockERC20 randomToken; // for recoverERC20 tests
    MockWPLS wpls;
    MockPulseXRouter router;
    StakingVault vault;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    uint256 constant TOP_COUNT = 3;
    uint256 constant SEVEN_DAYS = 7 days;

    function setUp() public {
        stakeToken = new MockERC20("Stake", "STK");
        rewardToken = new MockERC20("Reward", "RWD");
        randomToken = new MockERC20("Random", "RND");
        wpls = new MockWPLS();
        router = new MockPulseXRouter(address(wpls), address(rewardToken));
        vault = new StakingVault(
            address(stakeToken),
            address(rewardToken),
            owner,
            TOP_COUNT
        );
        // Set the DEX router for topUp tests
        vault.setDexRouter(address(router));
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

    function test_constructor_revertsZeroStakeToken() public {
        vm.expectRevert("StakingVault: zero staking token");
        new StakingVault(address(0), address(rewardToken), owner, TOP_COUNT);
    }

    function test_constructor_revertsZeroRewardToken() public {
        vm.expectRevert("StakingVault: zero rewards token");
        new StakingVault(address(stakeToken), address(0), owner, TOP_COUNT);
    }

    function test_constructor_revertsZeroTopCount() public {
        vm.expectRevert("StakingVault: zero top count");
        new StakingVault(address(stakeToken), address(rewardToken), owner, 0);
    }

    // ---------------------------------------------------------------
    //  Stake
    // ---------------------------------------------------------------

    function test_stake_basic() public {
        _mintAndApprove(alice, 100e18);

        vm.prank(alice);
        vault.stake(100e18);

        assertEq(vault.stakedBalance(alice), 100e18);
        assertEq(vault.totalStaked(), 100e18);
        assertEq(vault.totalStakers(), 1);
    }

    function test_stake_emitsEvent() public {
        _mintAndApprove(alice, 50e18);

        vm.expectEmit(true, false, false, true);
        emit IStakingVault.Staked(alice, 50e18);

        vm.prank(alice);
        vault.stake(50e18);
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

        assertEq(vault.stakedBalance(alice), 200e18);
        assertEq(vault.totalStakers(), 1); // still 1 unique staker
    }

    function test_stake_revertsWhenPaused() public {
        vault.setPaused(true);

        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert("StakingVault: paused");
        vault.stake(100e18);
    }

    // ---------------------------------------------------------------
    //  Withdraw
    // ---------------------------------------------------------------

    function test_withdraw_basic() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(alice);
        vault.withdraw(60e18);

        assertEq(vault.stakedBalance(alice), 40e18);
        assertEq(vault.totalStaked(), 40e18);
        assertEq(stakeToken.balanceOf(alice), 60e18);
    }

    function test_withdraw_full_decrementsStakers() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        assertEq(vault.totalStakers(), 1);

        vm.prank(alice);
        vault.withdraw(100e18);

        assertEq(vault.totalStakers(), 0);
        assertEq(vault.stakedBalance(alice), 0);
    }

    function test_withdraw_emitsEvent() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        vm.expectEmit(true, false, false, true);
        emit IStakingVault.Withdrawn(alice, 100e18);

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

        // withdraw should still work even when paused
        vm.prank(alice);
        vault.withdraw(100e18);
        assertEq(stakeToken.balanceOf(alice), 100e18);
    }

    function test_withdrawFromNonStaker_reverts() public {
        vm.prank(alice);
        vm.expectRevert("StakingVault: insufficient balance");
        vault.withdraw(1);
    }

    // ---------------------------------------------------------------
    //  getReward
    // ---------------------------------------------------------------

    function test_getReward_afterFullPeriod() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        // Warp full 7 days
        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();

        // Should get ~full reward (minus dust from integer division)
        uint256 bal = rewardToken.balanceOf(alice);
        assertApproxEqAbs(bal, 700e18, 1e15); // allow tiny dust
    }

    function test_getReward_afterHalfPeriod() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        // Warp 3.5 days (half)
        vm.warp(block.timestamp + SEVEN_DAYS / 2);

        vm.prank(alice);
        vault.getReward();

        uint256 bal = rewardToken.balanceOf(alice);
        assertApproxEqAbs(bal, 350e18, 1e15);
    }

    function test_getReward_emitsEvent() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        // Earned amount
        uint256 expectedReward = vault.earned(alice);

        vm.expectEmit(true, false, false, true);
        emit IStakingVault.RewardPaid(alice, expectedReward);

        vm.prank(alice);
        vault.getReward();
    }

    function test_getReward_noReward_doesNothing() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        // No rewards notified, getReward should not revert
        vm.prank(alice);
        vault.getReward();

        assertEq(rewardToken.balanceOf(alice), 0);
    }

    function test_getReward_worksWhenPaused() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        vault.setPaused(true);

        // getReward should still work when paused
        vm.prank(alice);
        vault.getReward();
        assertGt(rewardToken.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------
    //  exit
    // ---------------------------------------------------------------

    function test_exit_withdrawsAllAndClaims() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.exit();

        assertEq(vault.stakedBalance(alice), 0);
        assertEq(stakeToken.balanceOf(alice), 100e18);
        assertApproxEqAbs(rewardToken.balanceOf(alice), 700e18, 1e15);
    }

    // ---------------------------------------------------------------
    //  earned / rewardPerToken views
    // ---------------------------------------------------------------

    function test_earned_zeroForNoStake() public view {
        assertEq(vault.earned(alice), 0);
    }

    function test_earned_proportionalDistribution() public {
        // Alice stakes 75, Bob stakes 25 => 75% / 25%
        _mintAndApprove(alice, 75e18);
        _mintAndApprove(bob, 25e18);

        vm.prank(alice);
        vault.stake(75e18);
        vm.prank(bob);
        vault.stake(25e18);

        _notifyReward(1000e18);

        // Warp full period
        vm.warp(block.timestamp + SEVEN_DAYS);

        assertApproxEqAbs(vault.earned(alice), 750e18, 1e15);
        assertApproxEqAbs(vault.earned(bob), 250e18, 1e15);
    }

    function test_earned_twoEqualStakers_splitEvenly() public {
        _mintAndApprove(alice, 100e18);
        _mintAndApprove(bob, 100e18);

        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(bob);
        vault.stake(100e18);

        _notifyReward(1000e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        assertApproxEqAbs(vault.earned(alice), 500e18, 1e15);
        assertApproxEqAbs(vault.earned(bob), 500e18, 1e15);
    }

    function test_rewardPerToken_zeroWhenNoSupply() public view {
        assertEq(vault.rewardPerToken(), 0);
    }

    function test_getRewardForDuration() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        uint256 rfd = vault.getRewardForDuration();
        // rewardRate = 700e18 / 7 days, getRewardForDuration = rewardRate * 7 days
        assertApproxEqAbs(rfd, 700e18, 1e15);
    }

    function test_lastTimeRewardApplicable_beforePeriodFinish() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        // Before period finishes => returns block.timestamp
        assertEq(vault.lastTimeRewardApplicable(), block.timestamp);
    }

    function test_lastTimeRewardApplicable_afterPeriodFinish() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        uint256 finish = vault.periodFinish();
        vm.warp(finish + 1000);

        assertEq(vault.lastTimeRewardApplicable(), finish);
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

    function test_notifyRewardAmount_emitsEvent() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        rewardToken.mint(address(this), 100e18);
        rewardToken.approve(address(vault), 100e18);

        vm.expectEmit(false, false, false, true);
        emit IStakingVault.RewardAdded(100e18);

        vault.notifyRewardAmount(100e18);
    }

    function test_notifyRewardAmount_duringActivePeriod_restacks() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        uint256 rateBefore = vault.rewardRate();

        // Warp halfway
        vm.warp(block.timestamp + SEVEN_DAYS / 2);

        // Notify again with more reward
        _notifyReward(700e18);

        uint256 rateAfter = vault.rewardRate();

        // Rate should increase because leftover + new are combined
        assertGt(rateAfter, rateBefore);
        // Period finish should be reset to now + 7 days
        assertEq(vault.periodFinish(), block.timestamp + SEVEN_DAYS);
    }

    function test_notifyRewardAmount_multipleNotifies_accumulateCorrectly() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(350e18);

        // Warp to end of first period
        vm.warp(block.timestamp + SEVEN_DAYS);

        // Claim first batch
        vm.prank(alice);
        vault.getReward();
        uint256 batch1 = rewardToken.balanceOf(alice);
        assertApproxEqAbs(batch1, 350e18, 1e15);

        // Start new period
        _notifyReward(350e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();
        uint256 totalClaimed = rewardToken.balanceOf(alice);
        assertApproxEqAbs(totalClaimed, 700e18, 1e15);
    }

    function test_notifyRewardAmount_noStakers_rewardsStillSet() public {
        // Synthetix pattern allows notifyRewardAmount even with 0 stakers
        // Rewards just sit there; rewardPerToken won't increase until someone stakes
        _notifyReward(700e18);

        assertGt(vault.rewardRate(), 0);
        assertEq(vault.periodFinish(), block.timestamp + SEVEN_DAYS);
    }

    // ---------------------------------------------------------------
    //  Reward drip — time-based scenarios
    // ---------------------------------------------------------------

    function test_rewardDrip_linearOverTime() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        // At 1 day: ~1/7 of rewards
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(vault.earned(alice), 100e18, 1e15);

        // At 3.5 days: ~half
        vm.warp(block.timestamp + 2.5 days);
        assertApproxEqAbs(vault.earned(alice), 350e18, 1e15);

        // At 7 days: full
        vm.warp(block.timestamp + 3.5 days);
        assertApproxEqAbs(vault.earned(alice), 700e18, 1e15);
    }

    function test_rewardDrip_stopsAfterPeriodFinish() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        // Warp well past finish
        vm.warp(block.timestamp + SEVEN_DAYS + 30 days);

        // Should not earn more than the full amount
        assertApproxEqAbs(vault.earned(alice), 700e18, 1e15);
    }

    function test_rewardDrip_lateStaker_getsProRata() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        // Bob stakes at day 3.5 (halfway)
        vm.warp(block.timestamp + SEVEN_DAYS / 2);

        _mintAndApprove(bob, 100e18);
        vm.prank(bob);
        vault.stake(100e18);

        // Warp to end
        vm.warp(block.timestamp + SEVEN_DAYS / 2);

        // Alice got 100% for first half, 50% for second half = 75%
        // Bob got 0% for first half, 50% for second half = 25%
        assertApproxEqAbs(vault.earned(alice), 525e18, 1e15);
        assertApproxEqAbs(vault.earned(bob), 175e18, 1e15);
    }

    // ---------------------------------------------------------------
    //  Stake / withdraw / stake — reward accounting
    // ---------------------------------------------------------------

    function test_stake_withdraw_stake_rewardAccounting() public {
        _mintAndApprove(alice, 200e18);

        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        // Withdraw all — rewards accumulate in `rewards[alice]`
        vm.prank(alice);
        vault.withdraw(100e18);

        // Claim
        vm.prank(alice);
        vault.getReward();
        assertApproxEqAbs(rewardToken.balanceOf(alice), 700e18, 1e15);

        // Re-stake — no active reward period
        vm.prank(alice);
        stakeToken.approve(address(vault), 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        // No new rewards, earned should be 0
        assertEq(vault.earned(alice), 0);
    }

    // ---------------------------------------------------------------
    //  Top Staker Tracking
    // ---------------------------------------------------------------

    function test_topStakers_addedOnStake() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        assertTrue(vault.isTopStaker(alice));
        address[] memory tops = vault.getTopStakers();
        assertEq(tops.length, 1);
        assertEq(tops[0], alice);
    }

    function test_topStakers_sortedDescending() public {
        _mintAndApprove(alice, 50e18);
        _mintAndApprove(bob, 100e18);
        _mintAndApprove(carol, 75e18);

        vm.prank(alice);
        vault.stake(50e18);
        vm.prank(bob);
        vault.stake(100e18);
        vm.prank(carol);
        vault.stake(75e18);

        address[] memory tops = vault.getTopStakers();
        assertEq(tops.length, 3);
        assertEq(tops[0], bob);   // 100
        assertEq(tops[1], carol); // 75
        assertEq(tops[2], alice); // 50
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

    function test_topStakers_removedOnFullWithdraw() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        assertTrue(vault.isTopStaker(alice));

        vm.prank(alice);
        vault.withdraw(100e18);

        assertFalse(vault.isTopStaker(alice));
        assertEq(vault.getTopStakers().length, 0);
    }

    function test_topStakers_resortsOnPartialWithdraw() public {
        _mintAndApprove(alice, 100e18);
        _mintAndApprove(bob, 50e18);

        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(bob);
        vault.stake(50e18);

        // Alice withdraws to 30 — below Bob's 50
        vm.prank(alice);
        vault.withdraw(70e18);

        address[] memory tops = vault.getTopStakers();
        assertEq(tops[0], bob);   // 50
        assertEq(tops[1], alice); // 30
    }

    function test_topStakers_resortsOnAdditionalStake() public {
        _mintAndApprove(alice, 250e18);
        _mintAndApprove(bob, 100e18);

        vm.prank(alice);
        vault.stake(50e18);
        vm.prank(bob);
        vault.stake(100e18);

        // Alice is #2. She stakes 200 more => 250 total, becomes #1.
        vm.prank(alice);
        vault.stake(200e18);

        address[] memory tops = vault.getTopStakers();
        assertEq(tops[0], alice); // 250
        assertEq(tops[1], bob);   // 100
    }

    // ---------------------------------------------------------------
    //  Admin — setDaoAddress
    // ---------------------------------------------------------------

    function test_setDaoAddress() public {
        address dao = makeAddr("dao");

        vm.expectEmit(true, true, false, true);
        emit IStakingVault.DaoAddressUpdated(address(0), dao);

        vault.setDaoAddress(dao);
        assertEq(vault.daoAddress(), dao);
    }

    function test_setDaoAddress_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setDaoAddress(alice);
    }

    // ---------------------------------------------------------------
    //  Admin — setTopStakerCount
    // ---------------------------------------------------------------

    function test_setTopStakerCount_increases() public {
        vault.setTopStakerCount(10);
        assertEq(vault.topStakerCount(), 10);
    }

    function test_setTopStakerCount_trimsList() public {
        _mintAndApprove(alice, 30e18);
        _mintAndApprove(bob, 20e18);
        _mintAndApprove(carol, 10e18);

        vm.prank(alice);
        vault.stake(30e18);
        vm.prank(bob);
        vault.stake(20e18);
        vm.prank(carol);
        vault.stake(10e18);

        assertEq(vault.getTopStakers().length, 3);

        // Reduce to 2 — carol (smallest) should be evicted
        vault.setTopStakerCount(2);

        assertEq(vault.getTopStakers().length, 2);
        assertFalse(vault.isTopStaker(carol));
        assertTrue(vault.isTopStaker(alice));
        assertTrue(vault.isTopStaker(bob));
    }

    function test_setTopStakerCount_revertsZero() public {
        vm.expectRevert("StakingVault: zero top count");
        vault.setTopStakerCount(0);
    }

    function test_setTopStakerCount_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setTopStakerCount(5);
    }

    // ---------------------------------------------------------------
    //  Admin — setRewardsDuration
    // ---------------------------------------------------------------

    function test_setRewardsDuration_afterPeriodFinishes() public {
        // No active period, so periodFinish == 0 < block.timestamp
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

    function test_setRewardsDuration_worksAfterPeriodExpires() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);

        // Warp past period
        vm.warp(block.timestamp + SEVEN_DAYS + 1);

        vault.setRewardsDuration(14 days);
        assertEq(vault.rewardsDuration(), 14 days);
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

    function test_setPaused_doesNotBlockWithdraw() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        vault.setPaused(true);

        vm.prank(alice);
        vault.withdraw(100e18);
        assertEq(stakeToken.balanceOf(alice), 100e18);
    }

    function test_setPaused_doesNotBlockGetReward() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        _notifyReward(700e18);
        vm.warp(block.timestamp + SEVEN_DAYS);

        vault.setPaused(true);

        vm.prank(alice);
        vault.getReward();
        assertGt(rewardToken.balanceOf(alice), 0);
    }

    function test_setPaused_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IStakingVault.Paused(true);

        vault.setPaused(true);
    }

    // ---------------------------------------------------------------
    //  Admin — recoverERC20
    // ---------------------------------------------------------------

    function test_recoverERC20_recoversRandomToken() public {
        randomToken.mint(address(vault), 500e18);

        vault.recoverERC20(address(randomToken), 500e18);

        assertEq(randomToken.balanceOf(owner), 500e18);
        assertEq(randomToken.balanceOf(address(vault)), 0);
    }

    function test_recoverERC20_cannotRecoverStakingToken() public {
        stakeToken.mint(address(vault), 100e18);

        vm.expectRevert("StakingVault: cannot recover staking token");
        vault.recoverERC20(address(stakeToken), 100e18);
    }

    function test_recoverERC20_revertsNonOwner() public {
        randomToken.mint(address(vault), 100e18);

        vm.prank(alice);
        vm.expectRevert();
        vault.recoverERC20(address(randomToken), 100e18);
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
    //  topUp — PLS → reward token swap & auto-notify
    // ---------------------------------------------------------------

    function test_topUp_basic() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        // Send 10 PLS via topUp
        vm.deal(address(this), 10e18);
        vault.topUp{value: 10e18}();

        // Should have started reward period
        assertGt(vault.rewardRate(), 0);
        assertEq(vault.periodFinish(), block.timestamp + SEVEN_DAYS);
    }

    function test_topUp_emitsEvents() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        vm.deal(address(this), 10e18);

        vm.expectEmit(false, false, false, true);
        emit IStakingVault.ToppedUp(10e18, 10e18); // 1:1 swap rate

        vm.expectEmit(false, false, false, true);
        emit IStakingVault.RewardAdded(10e18);

        vault.topUp{value: 10e18}();
    }

    function test_topUp_revertsZeroPLS() public {
        vm.expectRevert("StakingVault: zero PLS");
        vault.topUp{value: 0}();
    }

    function test_topUp_revertsNoRouter() public {
        // Deploy a fresh vault without router
        StakingVault freshVault = new StakingVault(
            address(stakeToken), address(rewardToken), owner, TOP_COUNT
        );

        vm.deal(address(this), 1e18);
        vm.expectRevert("StakingVault: no router");
        freshVault.topUp{value: 1e18}();
    }

    function test_topUp_distributesRewardsCorrectly() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        // TopUp with 700 PLS (1:1 rate = 700 reward tokens)
        vm.deal(address(this), 700e18);
        vault.topUp{value: 700e18}();

        // Warp full period
        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();

        assertApproxEqAbs(rewardToken.balanceOf(alice), 700e18, 1e15);
    }

    function test_topUp_duringActivePeriod_restacks() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        // First topUp
        vm.deal(address(this), 700e18);
        vault.topUp{value: 700e18}();
        uint256 rateBefore = vault.rewardRate();

        // Warp halfway
        vm.warp(block.timestamp + SEVEN_DAYS / 2);

        // Second topUp
        vm.deal(address(this), 700e18);
        vault.topUp{value: 700e18}();
        uint256 rateAfter = vault.rewardRate();

        // Rate should increase (leftover + new combined)
        assertGt(rateAfter, rateBefore);
        assertEq(vault.periodFinish(), block.timestamp + SEVEN_DAYS);
    }

    function test_topUp_viaReceive() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        // Send PLS directly to vault (triggers receive → topUp)
        vm.deal(address(this), 10e18);
        (bool ok,) = address(vault).call{value: 10e18}("");
        assertTrue(ok);

        assertGt(vault.rewardRate(), 0);
        assertEq(vault.periodFinish(), block.timestamp + SEVEN_DAYS);
    }

    function test_topUp_multipleUsers_proportionalRewards() public {
        _mintAndApprove(alice, 75e18);
        _mintAndApprove(bob, 25e18);

        vm.prank(alice);
        vault.stake(75e18);
        vm.prank(bob);
        vault.stake(25e18);

        // TopUp with 1000 PLS
        vm.deal(address(this), 1000e18);
        vault.topUp{value: 1000e18}();

        vm.warp(block.timestamp + SEVEN_DAYS);

        assertApproxEqAbs(vault.earned(alice), 750e18, 1e15);
        assertApproxEqAbs(vault.earned(bob), 250e18, 1e15);
    }

    // ---------------------------------------------------------------
    //  processRewards — auto-notify for directly sent reward tokens
    // ---------------------------------------------------------------

    function test_processRewards_basic() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        // Simulate token factory sending eHEX directly to vault
        rewardToken.mint(address(vault), 700e18);

        // Anyone can call processRewards
        vault.processRewards();

        assertGt(vault.rewardRate(), 0);
        assertEq(vault.periodFinish(), block.timestamp + SEVEN_DAYS);
    }

    function test_processRewards_distributesCorrectly() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        // Send reward tokens directly
        rewardToken.mint(address(vault), 700e18);
        vault.processRewards();

        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();

        assertApproxEqAbs(rewardToken.balanceOf(alice), 700e18, 1e15);
    }

    function test_processRewards_revertsNoNewRewards() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        vm.expectRevert("StakingVault: no new rewards");
        vault.processRewards();
    }

    function test_processRewards_duringActivePeriod() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        // First batch
        rewardToken.mint(address(vault), 700e18);
        vault.processRewards();
        uint256 rateBefore = vault.rewardRate();

        // Halfway through, more tokens arrive
        vm.warp(block.timestamp + SEVEN_DAYS / 2);
        rewardToken.mint(address(vault), 700e18);
        vault.processRewards();

        assertGt(vault.rewardRate(), rateBefore);
        assertEq(vault.periodFinish(), block.timestamp + SEVEN_DAYS);
    }

    function test_processRewards_anyoneCanCall() public {
        _mintAndApprove(alice, 100e18);
        vm.prank(alice);
        vault.stake(100e18);

        rewardToken.mint(address(vault), 100e18);

        // Bob (random user) calls processRewards
        vm.prank(bob);
        vault.processRewards();

        assertGt(vault.rewardRate(), 0);
    }

    // ---------------------------------------------------------------
    //  Admin — setDexRouter
    // ---------------------------------------------------------------

    function test_setDexRouter() public {
        address newRouter = makeAddr("newRouter");

        vm.expectEmit(true, true, false, true);
        emit IStakingVault.DexRouterUpdated(address(router), newRouter);

        vault.setDexRouter(newRouter);
        assertEq(address(vault.dexRouter()), newRouter);
    }

    function test_setDexRouter_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setDexRouter(alice);
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
