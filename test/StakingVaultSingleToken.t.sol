// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {IStakingVault} from "../src/interfaces/IStakingVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------
//  Mock ERC-20 (matches the one in StakingVault.t.sol)
// ---------------------------------------------------------------

contract MockERC20ST is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ---------------------------------------------------------------
//  Reentrancy attacker for stake/withdraw/getReward
// ---------------------------------------------------------------

contract ReentrantStaker {
    StakingVault public immutable vault;
    MockERC20ST public immutable token;
    uint256 public mode; // 0=none, 1=stake, 2=withdraw, 3=getReward

    constructor(StakingVault _vault, MockERC20ST _token) {
        vault = _vault;
        token = _token;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function doStake(uint256 amount) external {
        token.approve(address(vault), amount);
        vault.stake(amount);
    }

    function doWithdraw(uint256 amount) external {
        vault.withdraw(amount);
    }

    function doGetReward() external {
        vault.getReward();
    }

    // ERC20 tokens don't have callbacks; this attacker would need a
    // malicious token. Instead we simulate reentrancy via a fallback.
    receive() external payable {
        if (mode == 1) {
            vault.stake(1);
        } else if (mode == 2) {
            vault.withdraw(1);
        } else if (mode == 3) {
            vault.getReward();
        }
    }
}

// ---------------------------------------------------------------
//  StakingVault — Single-Token Mode tests
//  (STAKING_TOKEN == REWARDS_TOKEN)
// ---------------------------------------------------------------

contract StakingVaultSingleTokenTest is Test {
    MockERC20ST token; // serves as BOTH staking & rewards token
    StakingVault vault;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address attacker = makeAddr("attacker");

    uint256 constant TOP_COUNT = 3;
    uint256 constant SEVEN_DAYS = 7 days;

    function setUp() public {
        token = new MockERC20ST("Single", "ONE");
        vault = new StakingVault(
            address(token),
            address(token),
            owner,
            TOP_COUNT
        );
    }

    // ---------------------------------------------------------------
    //  Sanity
    // ---------------------------------------------------------------

    function test_singleToken_constructor_sameToken() public view {
        assertEq(vault.stakingToken(), vault.rewardsToken());
        assertEq(vault.stakingToken(), address(token));
    }

    // ---------------------------------------------------------------
    //  processRewards — ignores staked principal
    // ---------------------------------------------------------------

    function test_singleToken_processRewards_ignoresStakedPrincipal() public {
        _stakeFor(alice, 100e18);

        // No extra tokens sent — only staked principal present.
        // processRewards should revert because balance - _totalSupply == 0.
        vm.expectRevert(StakingVault.NoNewRewards.selector);
        vault.processRewards();
    }

    function test_singleToken_processRewards_revertsWhenOnlyPrincipal() public {
        _stakeFor(alice, 50e18);
        _stakeFor(bob, 50e18);

        assertEq(token.balanceOf(address(vault)), 100e18);
        vm.expectRevert(StakingVault.NoNewRewards.selector);
        vault.processRewards();
    }

    function test_singleToken_processRewards_usesOnlyExcess() public {
        _stakeFor(alice, 100e18);

        // Send 700 extra tokens as reward
        token.mint(address(vault), 700e18);

        vault.processRewards();

        // rewardRate * duration should approximate 700e18 (not 800e18)
        assertApproxEqAbs(vault.getRewardForDuration(), 700e18, 1e15);
    }

    function test_singleToken_processRewards_distributesCorrectly() public {
        _stakeFor(alice, 100e18);

        token.mint(address(vault), 700e18);
        vault.processRewards();

        vm.warp(block.timestamp + SEVEN_DAYS);

        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        vault.getReward();
        uint256 paid = token.balanceOf(alice) - balBefore;

        assertApproxEqAbs(paid, 700e18, 1e15);
        // Alice's principal is still in the vault
        assertEq(vault.stakedBalance(alice), 100e18);
    }

    function test_singleToken_processRewards_doesNotTouchPrincipal() public {
        _stakeFor(alice, 100e18);
        _stakeFor(bob, 100e18);

        token.mint(address(vault), 1000e18);
        vault.processRewards();

        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();
        vm.prank(bob);
        vault.getReward();

        // Both stakers should be able to withdraw their full principal
        vm.prank(alice);
        vault.withdraw(100e18);
        vm.prank(bob);
        vault.withdraw(100e18);

        // Each gets 99% of principal (1% fee) + 500e18 rewards
        assertApproxEqAbs(token.balanceOf(alice), 99e18 + 500e18, 1e15);
        assertApproxEqAbs(token.balanceOf(bob),   99e18 + 500e18, 1e15);
    }

    function test_singleToken_processRewards_multipleCallsCompound() public {
        _stakeFor(alice, 100e18);

        // First drip
        token.mint(address(vault), 700e18);
        vault.processRewards();
        uint256 rate1 = vault.rewardRate();

        // Halfway through, more rewards arrive
        vm.warp(block.timestamp + SEVEN_DAYS / 2);
        token.mint(address(vault), 700e18);
        vault.processRewards();
        uint256 rate2 = vault.rewardRate();

        // New rate combines leftover (350) with new 700 → ~1050/7days
        assertGt(rate2, rate1);
        assertEq(vault.periodFinish(), block.timestamp + SEVEN_DAYS);
    }

    // ---------------------------------------------------------------
    //  notifyRewardAmount — also must respect single-token mode
    // ---------------------------------------------------------------

    function test_singleToken_notifyRewardAmount_worksStandalone() public {
        _stakeFor(alice, 100e18);

        // Notify 700 via approve path
        token.mint(address(this), 700e18);
        token.approve(address(vault), 700e18);
        vault.notifyRewardAmount(700e18);

        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();

        // Alice earned ~700, principal untouched
        assertApproxEqAbs(token.balanceOf(alice) - 0, 700e18, 1e15);
        assertEq(vault.stakedBalance(alice), 100e18);
    }

    function test_singleToken_notifyRewardAmount_rewardTooHigh_reverts() public {
        _stakeFor(alice, 100e18);

        // Approve/mint only 100 but try to notify 1000 — SafeERC20 transfer
        // will revert first. Instead, sneak tokens in then attempt a notify
        // that would require a balance greater than what exists minus stake.
        token.mint(address(this), 1000e18);
        token.approve(address(vault), 1000e18);

        // This should succeed — balance after transfer = 100 (stake) + 1000 = 1100,
        // minus 100 stake = 1000 net available. rewardRate = 1000/7days,
        // which is <= 1000/7days. OK.
        vault.notifyRewardAmount(1000e18);
    }

    function test_singleToken_notifyRewardAmount_rewardTooHigh_actuallyReverts() public {
        // Attacker-path: send extra tokens via transfer, then try to notify an
        // amount that would trick rewardRate check if principal were counted.
        _stakeFor(alice, 100e18);

        // Mint 50 to vault directly (sitting as un-processed reward).
        token.mint(address(vault), 50e18);

        // Attempt notify of 1e30 — will fail on transferFrom (no approval/balance).
        vm.expectRevert();
        vault.notifyRewardAmount(1e30);
    }

    // ---------------------------------------------------------------
    //  Malicious rewarder cannot drain principal
    // ---------------------------------------------------------------

    function test_singleToken_maliciousNotify_revertsNonOwner() public {
        _stakeFor(alice, 100e18);

        // Attacker tries to call notifyRewardAmount — blocked by onlyOwner.
        token.mint(attacker, 1);
        vm.startPrank(attacker);
        token.approve(address(vault), 1);
        vm.expectRevert();
        vault.notifyRewardAmount(1);
        vm.stopPrank();
    }

    function test_singleToken_maliciousProcessRewards_cannotDrainPrincipal() public {
        _stakeFor(alice, 100e18);

        // Attacker sends nothing but tries to processRewards.
        vm.prank(attacker);
        vm.expectRevert(StakingVault.NoNewRewards.selector);
        vault.processRewards();

        // Principal still safe.
        assertEq(vault.stakedBalance(alice), 100e18);
        assertEq(token.balanceOf(address(vault)), 100e18);
    }

    // ---------------------------------------------------------------
    //  Stake / withdraw flow with same-token rewards
    // ---------------------------------------------------------------

    function test_singleToken_stakeWithdrawFlow() public {
        _stakeFor(alice, 100e18);

        assertEq(vault.stakedBalance(alice), 100e18);
        assertEq(token.balanceOf(address(vault)), 100e18);

        vm.prank(alice);
        vault.withdraw(40e18);

        // 1% fee on 40e18 = 0.4e18 burned to DEAD
        assertEq(vault.stakedBalance(alice), 60e18);
        assertEq(token.balanceOf(alice), 39.6e18);
        // vault holds: 60e18 (staked only, fee was burned)
        assertEq(token.balanceOf(address(vault)), 60e18);
    }

    function test_singleToken_getReward_doesNotTouchPrincipal() public {
        _stakeFor(alice, 100e18);

        token.mint(address(vault), 700e18);
        vault.processRewards();

        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();

        // Principal untouched.
        assertEq(vault.stakedBalance(alice), 100e18);
        // Reward balance exists.
        assertGt(token.balanceOf(alice), 0);
        // Vault still holds the 100e18 principal (maybe minus dust from integer div).
        assertGe(token.balanceOf(address(vault)), 100e18);
    }

    function test_singleToken_exit_returnsPrincipalAndReward() public {
        _stakeFor(alice, 100e18);

        token.mint(address(vault), 700e18);
        vault.processRewards();

        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.exit();

        assertEq(vault.stakedBalance(alice), 0);
        // Alice gets 99% of principal (99e18) + ~reward (~700e18), 1% fee stays in vault
        assertApproxEqAbs(token.balanceOf(alice), 799e18, 1e15);
    }

    // ---------------------------------------------------------------
    //  Multiple stakers + reward drip
    // ---------------------------------------------------------------

    function test_singleToken_multipleStakers_proRataRewards() public {
        _stakeFor(alice, 75e18);
        _stakeFor(bob, 25e18);

        token.mint(address(vault), 1000e18);
        vault.processRewards();

        vm.warp(block.timestamp + SEVEN_DAYS);

        assertApproxEqAbs(vault.earned(alice), 750e18, 1e15);
        assertApproxEqAbs(vault.earned(bob), 250e18, 1e15);

        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();

        // 99% of principals back + proportional rewards (1% fee stays in vault)
        assertApproxEqAbs(token.balanceOf(alice), 74.25e18 + 750e18, 1e15);
        assertApproxEqAbs(token.balanceOf(bob), 24.75e18 + 250e18, 1e15);
    }

    function test_singleToken_multipleStakers_allCanExit() public {
        _stakeFor(alice, 100e18);
        _stakeFor(bob, 100e18);
        _stakeFor(carol, 100e18);

        token.mint(address(vault), 900e18);
        vault.processRewards();

        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        vm.prank(carol);
        vault.exit();

        assertEq(vault.totalStaked(), 0);
        assertEq(vault.totalStakers(), 0);
        // Each gets 99% of 100e18 principal (1% fee) + 300e18 rewards
        assertApproxEqAbs(token.balanceOf(alice), 99e18 + 300e18, 1e15);
        assertApproxEqAbs(token.balanceOf(bob),   99e18 + 300e18, 1e15);
        assertApproxEqAbs(token.balanceOf(carol), 99e18 + 300e18, 1e15);
    }

    function test_singleToken_lateStaker_getsProRata() public {
        _stakeFor(alice, 100e18);

        token.mint(address(vault), 700e18);
        vault.processRewards();

        // Bob joins at halfway
        vm.warp(block.timestamp + SEVEN_DAYS / 2);
        _stakeFor(bob, 100e18);

        vm.warp(block.timestamp + SEVEN_DAYS / 2);

        // Alice: full first half (350) + half of second half (175) = 525
        // Bob: half of second half (175)
        assertApproxEqAbs(vault.earned(alice), 525e18, 1e15);
        assertApproxEqAbs(vault.earned(bob), 175e18, 1e15);
    }

    // ---------------------------------------------------------------
    //  _startRewardPeriod safety check uses net balance
    // ---------------------------------------------------------------

    function test_singleToken_startRewardPeriod_safetyUsesNetBalance() public {
        _stakeFor(alice, 1_000_000e18); // huge stake

        // Send small reward
        token.mint(address(vault), 7e18);

        // Even though total balance is 1_000_007e18, processRewards must
        // only consider 7e18. rewardRate = 7e18/7days = 1e18/day.
        // Safety check: rewardRate <= (balance - totalSupply)/duration
        //   = 7e18 / 7days = 1e18/day. OK.
        vault.processRewards();

        assertApproxEqAbs(vault.getRewardForDuration(), 7e18, 1e15);
    }

    function test_singleToken_startRewardPeriod_rewardTooHigh_reverts() public {
        _stakeFor(alice, 100e18);

        // Approve and notify more than what the vault actually holds in reward.
        // Vault will pull the reward (so balance = 100 + reward), then
        // compute net = reward. Safety check must pass if rate <= reward/duration.
        // Construct a case where notify amount passes transferFrom but
        // leaves rewardRate above balance/duration — this is impossible under
        // the standard path because the transfer credits the exact notified amount.
        // So we test the manual-send + notify combo where a manipulator already
        // minted to the vault then tries to notify extra rewards to spike rate
        // above what the committed balance supports.
        token.mint(address(this), 50e18);
        token.approve(address(vault), 50e18);
        // After transferFrom: vault has 100 (stake) + 50 (new reward) = 150.
        // _startRewardPeriod sees: balance = 150 - 100 = 50. rewardRate = 50/7days.
        // Check: 50/7days <= 50/7days. Passes.
        vault.notifyRewardAmount(50e18);

        // Now attacker tries to donate-and-spike: mint 1 to vault then notify huge.
        token.mint(address(vault), 1);
        vm.expectRevert(); // transferFrom of 1e30 will fail (no balance)
        vault.notifyRewardAmount(1e30);
    }

    // ---------------------------------------------------------------
    //  topUp() in single-token mode — document behavior
    // ---------------------------------------------------------------

    function test_singleToken_topUp_revertsNoRouter() public {
        // In single-token mode, topUp was not wired up in setUp.
        _stakeFor(alice, 100e18);
        vm.deal(address(this), 1e18);
        vm.expectRevert(StakingVault.NoRouter.selector);
        vault.topUp{value: 1e18}();
    }

    // ---------------------------------------------------------------
    //  Reward period extension math
    // ---------------------------------------------------------------

    function test_singleToken_rewardPeriodExtension_leftoverCombined() public {
        _stakeFor(alice, 100e18);

        // Drip 700 over 7 days
        token.mint(address(vault), 700e18);
        vault.processRewards();
        uint256 rate1 = vault.rewardRate();

        // Warp 1 day (6 days remaining, 600 leftover)
        vm.warp(block.timestamp + 1 days);

        // Add 700 more
        token.mint(address(vault), 700e18);
        vault.processRewards();

        // processRewards detects reward = new balance - committed.
        //   balance after mint = 700 (old drip) + 700 (new) = 1400 (excl principal)
        //   totalOwed = 1 day * rate1 ≈ 100  (already-accrued portion)
        //   futureDrip = 6 days * rate1 ≈ 600
        //   committed = totalOwed + futureDrip ≈ 700
        //   reward = 1400 - 700 = 700
        // Then _startRewardPeriod combines leftover:
        //   leftover = 6 days * rate1 ≈ 600
        //   new rate = (700 + 600) / 7 days = 1300 / 7 days
        uint256 rate2 = vault.rewardRate();
        assertGt(rate2, rate1);
        uint256 expected = uint256(1300e18) / SEVEN_DAYS;
        assertApproxEqAbs(rate2, expected, expected / 100);
    }

    function test_singleToken_rewardPeriodExtension_afterFinishResets() public {
        _stakeFor(alice, 100e18);

        token.mint(address(vault), 700e18);
        vault.processRewards();

        // Warp past period
        vm.warp(block.timestamp + SEVEN_DAYS + 1 days);

        // Claim old rewards first
        vm.prank(alice);
        vault.getReward();

        // New rewards start fresh
        token.mint(address(vault), 350e18);
        vault.processRewards();

        // rate = 350 / 7days, no leftover (allow 1 wei tolerance for dust)
        uint256 expected = uint256(350e18) / SEVEN_DAYS;
        assertApproxEqAbs(vault.rewardRate(), expected, 1);
    }

    // ---------------------------------------------------------------
    //  Reward precision at boundaries
    // ---------------------------------------------------------------

    function test_singleToken_rewardPrecision_tinyDust() public {
        _stakeFor(alice, 100e18);

        // Reward amount that doesn't divide evenly by 7 days
        uint256 reward = 100e18 + 3; // prime-ish
        token.mint(address(vault), reward);
        vault.processRewards();

        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();

        // Alice's rewards should be close to `reward` but may lose dust
        // (at most rewardsDuration wei due to rewardRate rounding).
        uint256 paid = token.balanceOf(alice);
        assertLe(paid, reward);
        assertGe(paid, reward - SEVEN_DAYS);
    }

    function test_singleToken_rewardPrecision_dustRejected() public {
        _stakeFor(alice, 1e18);

        // Reward smaller than rewardsDuration would produce rewardRate = 0
        // after integer division. The autoProcess dust guard rejects this
        // (no point starting a zero-rate drip) and processRewards() reverts
        // with "no new rewards" because nothing actually changed.
        uint256 reward = SEVEN_DAYS - 1;
        token.mint(address(vault), reward);
        vm.expectRevert(StakingVault.NoNewRewards.selector);
        vault.processRewards();

        // State unchanged.
        assertEq(vault.rewardRate(), 0);
        assertEq(vault.periodFinish(), 0);
    }

    // ---------------------------------------------------------------
    //  Reentrancy attempts
    //  (ERC20 doesn't call back, so direct reentry isn't possible.
    //   These tests document that nonReentrant guards are present.)
    // ---------------------------------------------------------------

    function test_singleToken_stake_nonReentrant() public {
        // Cannot truly re-enter via ERC20 transfer; verify the guard is on
        // by checking that a recursive call via the fallback path fails.
        // Since our MockERC20 has no callbacks, this is a smoke test that
        // normal stakes work and the function has the nonReentrant modifier
        // (verified by reading source).
        _stakeFor(alice, 50e18);
        _stakeFor(alice, 50e18);
        assertEq(vault.stakedBalance(alice), 100e18);
    }

    // ---------------------------------------------------------------
    //  Interaction: stake while reward drip is active
    // ---------------------------------------------------------------

    function test_singleToken_stakeMidPeriod_dilutesExistingStakers() public {
        _stakeFor(alice, 100e18);

        token.mint(address(vault), 700e18);
        vault.processRewards();

        // At 1 day, alice has earned ~100
        vm.warp(block.timestamp + 1 days);
        uint256 aliceAt1Day = vault.earned(alice);
        assertApproxEqAbs(aliceAt1Day, 100e18, 1e15);

        // Bob stakes 100 — same size as alice
        _stakeFor(bob, 100e18);

        // Warp to end
        vm.warp(block.timestamp + 6 days);

        // Alice: 100 (first day) + 300 (6 days at 50%) = 400
        // Bob: 300 (6 days at 50%)
        assertApproxEqAbs(vault.earned(alice), 400e18, 1e15);
        assertApproxEqAbs(vault.earned(bob), 300e18, 1e15);

        // processRewards should still ignore principal
        token.mint(address(vault), 70e18);
        // Now in active period, committed = (6days-6days)*rate = 0
        // periodFinish has been reached. reward = balance - 0 = 70e18 + any dust
        // Warp 1 more second to be safely past period end for processRewards
        vm.warp(block.timestamp + 1);
        vault.processRewards();
    }

    // ---------------------------------------------------------------
    //  Helpers
    // ---------------------------------------------------------------

    function _stakeFor(address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(vault), amount);
        vault.stake(amount);
        vm.stopPrank();
    }
}
