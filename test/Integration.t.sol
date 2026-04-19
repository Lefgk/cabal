// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {TreasuryDAO} from "../src/TreasuryDAO.sol";
import {IStakingVault} from "../src/interfaces/IStakingVault.sol";
import {ITreasuryDAO} from "../src/interfaces/ITreasuryDAO.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------
//  MockTaxToken
//
//  Minimal ERC20 that simulates the PulseFun v3 factory Dev-tax
//  behavior: on every transfer (except from excluded addresses), it
//  takes a 3.25% cut and forwards it as raw tokens to a configured
//  tax receiver. This mirrors how the production TSTT token sends
//  Dev-tax TSTT directly to the StakingVault.
// ---------------------------------------------------------------

contract MockTaxToken is ERC20 {
    uint256 public constant TAX_BPS = 325; // 3.25%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public taxReceiver;
    mapping(address => bool) public isExcluded;

    constructor() ERC20("Mock Tax Token", "MTT") {
        _mint(msg.sender, 1e27);
        // Deployer and the token itself are tax-excluded (mirrors production).
        isExcluded[msg.sender] = true;
        isExcluded[address(this)] = true;
    }

    function setTaxReceiver(address receiver) external {
        taxReceiver = receiver;
        // Receiver is excluded so the vault can distribute rewards to stakers
        // without taxing itself.
        if (receiver != address(0)) {
            isExcluded[receiver] = true;
        }
    }

    function addExclusion(address account) external {
        isExcluded[account] = true;
    }

    /// @dev Override ERC20 internal transfer hook. If the sender is not
    ///      excluded and a tax receiver is set, take 3.25% off the top and
    ///      route it as a raw transfer to the receiver.
    function _update(address from, address to, uint256 value) internal override {
        // Mints and burns skip the tax path.
        if (from == address(0) || to == address(0) || taxReceiver == address(0) || isExcluded[from]) {
            super._update(from, to, value);
            return;
        }

        uint256 tax = (value * TAX_BPS) / BPS_DENOMINATOR;
        uint256 net = value - tax;

        if (tax > 0) {
            super._update(from, taxReceiver, tax);
        }
        super._update(from, to, net);
    }
}

// ---------------------------------------------------------------
//  Minimal WPLS mock for the DAO (treasury holds WPLS)
// ---------------------------------------------------------------

contract MockWPLS is ERC20 {
    constructor() ERC20("Wrapped PLS", "WPLS") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ---------------------------------------------------------------
//  Integration: StakingVault + TreasuryDAO + MockTaxToken
// ---------------------------------------------------------------

contract VaultDAOIntegrationTest is Test {
    MockTaxToken tstt;
    MockWPLS wpls;
    StakingVault vault;
    TreasuryDAO dao;

    address deployer = address(this);
    address pair = makeAddr("pair"); // simulates a PulseX pair (non-excluded)
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address marketingWallet = makeAddr("marketingWallet");
    address dummyRouter = makeAddr("dummyRouter");

    uint256 constant TOP_COUNT = 3;
    uint256 constant SEVEN_DAYS = 7 days;
    uint256 constant TAX_BPS = 325;
    uint256 constant BPS = 10_000;

    function setUp() public {
        // Deploy the tax token — deployer is auto-excluded.
        tstt = new MockTaxToken();
        MockWPLS _tmpWpls = new MockWPLS();
        vm.etch(0xA1077a294dDE1B09bB078844df40758a5D0f9a27, address(_tmpWpls).code);
        wpls = MockWPLS(payable(0xA1077a294dDE1B09bB078844df40758a5D0f9a27));

        // Vault: single-token staking (STAKING_TOKEN == REWARDS_TOKEN == TSTT)
        vault = new StakingVault(address(tstt), address(tstt), deployer, TOP_COUNT);

        // DAO: stake vault + TSTT + WPLS + dummy router
        dao = new TreasuryDAO(address(vault), address(tstt), address(wpls), dummyRouter);
        vault.setDaoAddress(address(dao));

        // Mirror production exclusions: the vault itself must be excluded so
        // reward payouts don't get taxed. The pair (seller destination) is NOT
        // excluded — that's where tax is generated.
        tstt.setTaxReceiver(address(vault));
        tstt.addExclusion(address(vault));
    }

    // ---------------------------------------------------------------
    //  Helpers
    // ---------------------------------------------------------------

    /// @dev Give `user` `amount` TSTT with no tax (deployer is excluded) and
    ///      approve the vault.
    function _fundAndApprove(address user, uint256 amount) internal {
        tstt.transfer(user, amount);
        vm.prank(user);
        tstt.approve(address(vault), amount);
    }

    /// @dev Simulate a tax-generating transfer (e.g. a sell into a pair).
    ///      Returns the tax forwarded to the vault.
    function _taxedTransfer(address from, address to, uint256 amount) internal returns (uint256 tax) {
        tax = (amount * TAX_BPS) / BPS;
        vm.prank(from);
        tstt.transfer(to, amount);
    }

    /// @dev Fund the DAO treasury with WPLS so proposals can be made.
    function _fundTreasury(uint256 amount) internal {
        wpls.mint(address(this), amount);
        wpls.approve(address(dao), amount);
        dao.depositWPLS(amount);
    }

    // ---------------------------------------------------------------
    //  MockTaxToken sanity
    // ---------------------------------------------------------------

    function test_mockTaxToken_takesTaxFromNonExcludedSender() public {
        // Fund Bob from deployer (no tax, deployer excluded).
        tstt.transfer(bob, 1_000e18);
        assertEq(tstt.balanceOf(bob), 1_000e18);

        // Bob sells 1000 to the pair — 3.25% = 32.5 taxed to vault.
        vm.prank(bob);
        tstt.transfer(pair, 1_000e18);

        assertEq(tstt.balanceOf(bob), 0);
        assertEq(tstt.balanceOf(pair), 967.5e18);
        assertEq(tstt.balanceOf(address(vault)), 32.5e18);
    }

    function test_mockTaxToken_excludedSenderPaysNoTax() public {
        // Deployer → pair is tax-free (deployer excluded).
        tstt.transfer(pair, 1_000e18);
        assertEq(tstt.balanceOf(pair), 1_000e18);
        assertEq(tstt.balanceOf(address(vault)), 0);
    }

    // ---------------------------------------------------------------
    //  Full Flow A — dev funds pair, alice stakes, bob sells, process
    //                rewards, alice claims over time.
    // ---------------------------------------------------------------

    function test_fullFlowA_sellGeneratesTaxAliceClaims() public {
        // Dev seeds the pair (tax-free because deployer is excluded).
        tstt.transfer(pair, 100_000e18);

        // Alice stakes 1000 TSTT.
        _fundAndApprove(alice, 1_000e18);
        vm.prank(alice);
        vault.stake(1_000e18);

        // Bob buys 10000 TSTT (pair → bob is taxed in this mock since pair is
        // not excluded; that's fine for integration purposes).
        uint256 bobReceived;
        {
            uint256 sendAmount = 10_000e18;
            uint256 tax = (sendAmount * TAX_BPS) / BPS;
            bobReceived = sendAmount - tax;
            vm.prank(pair);
            tstt.transfer(bob, sendAmount);
            assertEq(tstt.balanceOf(bob), bobReceived);
        }

        // Vault has now received tax from that buy.
        uint256 vaultBalBeforeSell = tstt.balanceOf(address(vault));
        assertGt(vaultBalBeforeSell, 1_000e18); // stake + tax

        // Bob sells half back to the pair → more tax flows to vault.
        vm.prank(bob);
        tstt.transfer(pair, bobReceived / 2);

        uint256 vaultBalAfterSell = tstt.balanceOf(address(vault));
        assertGt(vaultBalAfterSell, vaultBalBeforeSell);

        // Tax collected = vault balance minus staked principal.
        uint256 taxCollected = vaultBalAfterSell - 1_000e18;

        // Anyone (carol) calls processRewards — permissionless.
        vm.prank(carol);
        vault.processRewards();

        assertGt(vault.rewardRate(), 0);
        assertEq(vault.periodFinish(), block.timestamp + SEVEN_DAYS);

        // Warp half period — Alice should have earned ~half the tax.
        vm.warp(block.timestamp + SEVEN_DAYS / 2);
        uint256 earnedHalf = vault.earned(alice);
        assertApproxEqAbs(earnedHalf, taxCollected / 2, taxCollected / 1000);

        // Warp to full period — Alice should be owed ~all tax.
        vm.warp(block.timestamp + SEVEN_DAYS / 2);
        assertApproxEqAbs(vault.earned(alice), taxCollected, taxCollected / 1000);

        // Alice claims. Because the vault is excluded, the reward payout is
        // tax-free — she gets the full amount.
        uint256 aliceBefore = tstt.balanceOf(alice);
        vm.prank(alice);
        vault.getReward();
        uint256 received = tstt.balanceOf(alice) - aliceBefore;
        assertApproxEqAbs(received, taxCollected, taxCollected / 1000);
    }

    // ---------------------------------------------------------------
    //  Full Flow B — multiple sells, processRewards twice, drip extends,
    //                multiple stakers get proportional rewards.
    // ---------------------------------------------------------------

    function test_fullFlowB_multipleSellsExtendDrip_proportionalRewards() public {
        // Alice stakes 750, Bob stakes 250 (75% / 25%)
        _fundAndApprove(alice, 750e18);
        _fundAndApprove(bob, 250e18);
        vm.prank(alice);
        vault.stake(750e18);
        vm.prank(bob);
        vault.stake(250e18);

        // Carol gets some tokens tax-free and sells into pair (generates tax).
        tstt.transfer(carol, 20_000e18);
        vm.prank(carol);
        tstt.transfer(pair, 10_000e18);
        uint256 tax1 = (10_000e18 * TAX_BPS) / BPS;

        // First processRewards.
        vault.processRewards();
        uint256 rate1 = vault.rewardRate();
        assertGt(rate1, 0);

        // Warp halfway.
        vm.warp(block.timestamp + SEVEN_DAYS / 2);

        // Carol sells again — more tax.
        vm.prank(carol);
        tstt.transfer(pair, 10_000e18);
        uint256 tax2 = (10_000e18 * TAX_BPS) / BPS;

        // Second processRewards — should extend drip and INCREASE rate
        // because leftover + new tax are combined.
        vault.processRewards();
        uint256 rate2 = vault.rewardRate();
        assertGt(rate2, rate1);
        assertEq(vault.periodFinish(), block.timestamp + SEVEN_DAYS);

        // Warp to end of new period and let everyone claim.
        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();
        vm.prank(bob);
        vault.getReward();

        // Total distributed is tax1 + tax2 (minus rounding dust). Alice gets
        // all of tax1 (she was the only active 75% holder during drip 1) plus
        // her 75% of drip 2. The easier invariant: Alice + Bob ≈ tax1 + tax2
        // and Alice ≈ 3 * Bob.
        uint256 aliceReward = tstt.balanceOf(alice);
        uint256 bobReward = tstt.balanceOf(bob);
        uint256 totalTax = tax1 + tax2;

        assertApproxEqAbs(aliceReward + bobReward, totalTax, totalTax / 1000);
        // Alice should be exactly 3x Bob because their stake ratio never changed.
        assertApproxEqAbs(aliceReward, bobReward * 3, totalTax / 1000);
    }

    // ---------------------------------------------------------------
    //  processRewards sanity — reverts when only staked principal
    //                          is in the vault.
    // ---------------------------------------------------------------

    function test_processRewards_revertsWhenOnlyStakedPrincipal() public {
        _fundAndApprove(alice, 1_000e18);
        vm.prank(alice);
        vault.stake(1_000e18);

        // Vault balance == stake balance, no tax has accumulated.
        assertEq(tstt.balanceOf(address(vault)), 1_000e18);

        vm.expectRevert("StakingVault: no new rewards");
        vault.processRewards();
    }

    // ---------------------------------------------------------------
    //  Top stakers change over time — DAO sees up-to-date list.
    // ---------------------------------------------------------------

    function test_topStakers_updateReflectsInDAOEligibility() public {
        _fundAndApprove(alice, 100e18);
        _fundAndApprove(bob, 50e18);
        _fundAndApprove(carol, 25e18);
        _fundAndApprove(dave, 200e18);

        vm.prank(alice);
        vault.stake(100e18);
        vm.prank(bob);
        vault.stake(50e18);
        vm.prank(carol);
        vault.stake(25e18);

        vm.warp(block.timestamp + 1);

        // Top 3: Alice, Bob, Carol.
        assertTrue(vault.isTopStaker(alice));
        assertTrue(vault.isTopStaker(bob));
        assertTrue(vault.isTopStaker(carol));
        assertFalse(vault.isTopStaker(dave));

        // Fund treasury so proposals are possible.
        _fundTreasury(1_000e18);

        // Carol can propose (she's a top staker).
        vm.prank(carol);
        uint256 pid = dao.propose(100e18, marketingWallet, "marketing");
        assertEq(pid, 0);

        // Dave now stakes 200 → becomes #1 top staker, evicts Carol.
        vm.prank(dave);
        vault.stake(200e18);

        assertTrue(vault.isTopStaker(dave));
        assertFalse(vault.isTopStaker(carol));

        // Carol can no longer propose.
        vm.prank(carol);
        vm.expectRevert("not top staker");
        dao.propose(50e18, marketingWallet, "another");

        // Dave can propose now.
        vm.prank(dave);
        uint256 pid2 = dao.propose(50e18, marketingWallet, "dave-prop");
        assertEq(pid2, 1);
    }

    // ---------------------------------------------------------------
    //  DAO proposal lifecycle with live staking.
    // ---------------------------------------------------------------

    function test_daoProposalLifecycle_propose_vote_execute() public {
        // Alice & Bob stake so they have voting power.
        _fundAndApprove(alice, 600e18);
        _fundAndApprove(bob, 400e18);
        vm.prank(alice);
        vault.stake(600e18);
        vm.prank(bob);
        vault.stake(400e18);

        // Advance so stakers satisfy the 1-block staking requirement
        vm.warp(block.timestamp + 1);

        // Fund treasury.
        _fundTreasury(500e18);
        assertEq(dao.availableBalance(), 500e18);

        // Alice (top staker) proposes 200 WPLS to marketing.
        vm.prank(alice);
        uint256 pid = dao.propose(200e18, marketingWallet, "marketing push");

        // Locked amount reserved.
        assertEq(dao.lockedAmount(), 200e18);
        assertEq(dao.availableBalance(), 300e18);

        // Both vote yes.
        vm.prank(alice);
        dao.castVote(pid, true);
        vm.prank(bob);
        dao.castVote(pid, true);

        // Still active until voting period ends.
        assertEq(uint8(dao.state(pid)), uint8(ITreasuryDAO.ProposalState.Active));

        // Fast-forward past voting period.
        vm.warp(block.timestamp + 7 days + 1);
        assertEq(uint8(dao.state(pid)), uint8(ITreasuryDAO.ProposalState.Succeeded));

        // Execute — anyone can call.
        vm.prank(carol);
        dao.executeProposal(pid);

        assertEq(uint8(dao.state(pid)), uint8(ITreasuryDAO.ProposalState.Executed));
        assertEq(wpls.balanceOf(marketingWallet), 200e18);
        assertEq(dao.lockedAmount(), 0);
        assertEq(dao.availableBalance(), 300e18);
    }

    function test_daoProposal_defeated_unlocksFunds() public {
        _fundAndApprove(alice, 600e18);
        _fundAndApprove(bob, 400e18);
        vm.prank(alice);
        vault.stake(600e18);
        vm.prank(bob);
        vault.stake(400e18);

        vm.warp(block.timestamp + 1);

        _fundTreasury(500e18);

        vm.prank(alice);
        uint256 pid = dao.propose(200e18, marketingWallet, "bad idea");

        // Bob (40% of stake, enough for quorum) votes NO; Alice does not vote.
        vm.prank(bob);
        dao.castVote(pid, false);

        vm.warp(block.timestamp + 7 days + 1);
        assertEq(uint8(dao.state(pid)), uint8(ITreasuryDAO.ProposalState.Defeated));

        dao.unlockDefeated(pid);
        assertEq(dao.lockedAmount(), 0);
        assertEq(dao.availableBalance(), 500e18);
    }

    // ---------------------------------------------------------------
    //  Round-trip: stake → tax → processRewards → claim → withdraw.
    //  Verify final balances balance to within rounding dust.
    // ---------------------------------------------------------------

    function test_roundTrip_stakeTaxClaimWithdraw_balancesConserved() public {
        // Alice stakes 1000.
        _fundAndApprove(alice, 1_000e18);
        // Snapshot her wallet BEFORE staking — she has the 1000 she's about to stake.
        uint256 aliceInitial = tstt.balanceOf(alice);
        vm.prank(alice);
        vault.stake(1_000e18);

        // Give pair some tokens from deployer (tax-free), then have pair
        // send to bob (taxed) to generate fee.
        tstt.transfer(pair, 100_000e18);
        uint256 sellAmount = 50_000e18;
        uint256 expectedTax = (sellAmount * TAX_BPS) / BPS;
        vm.prank(pair);
        tstt.transfer(bob, sellAmount);

        // Tax should have accrued to the vault.
        assertEq(tstt.balanceOf(address(vault)), 1_000e18 + expectedTax);

        // processRewards and wait full drip.
        vault.processRewards();
        vm.warp(block.timestamp + SEVEN_DAYS);

        // Alice exits — withdraws principal (minus 1% flex fee burned) and claims reward.
        vm.prank(alice);
        vault.exit();

        // 1% withdraw fee on 1000e18 = 10e18 burned to DEAD (not kept in vault)
        uint256 flexFee = (1_000e18 * 100) / 10_000; // 1%
        // Final balance should be initial stake minus fee + (approximately) full tax.
        uint256 aliceFinal = tstt.balanceOf(alice);
        assertApproxEqAbs(aliceFinal, aliceInitial - flexFee + expectedTax, expectedTax / 1000);

        // Vault holds only rounding dust (flex fee was burned, not kept in vault).
        assertLt(tstt.balanceOf(address(vault)), expectedTax / 1000 + 1e18);

        // Alice is no longer staked or a top staker.
        assertEq(vault.stakedBalance(alice), 0);
        assertEq(vault.totalStaked(), 0);
        assertFalse(vault.isTopStaker(alice));
    }

    // ---------------------------------------------------------------
    //  Edge case: drip period extends correctly when new tax arrives
    //             mid-drip.
    // ---------------------------------------------------------------

    function test_rewardDrip_extendsWhenNewTaxArrivesMidDrip() public {
        _fundAndApprove(alice, 1_000e18);
        vm.prank(alice);
        vault.stake(1_000e18);

        // Generate first batch of tax.
        tstt.transfer(carol, 20_000e18);
        vm.prank(carol);
        tstt.transfer(pair, 10_000e18);
        uint256 tax1 = (10_000e18 * TAX_BPS) / BPS;

        vault.processRewards();
        uint256 firstFinish = vault.periodFinish();

        // Warp 2 days in (5 days remain of first drip).
        vm.warp(block.timestamp + 2 days);

        // More tax arrives.
        vm.prank(carol);
        tstt.transfer(pair, 10_000e18);
        uint256 tax2 = (10_000e18 * TAX_BPS) / BPS;

        // Second processRewards — period must restart to now + 7 days,
        // which is strictly greater than the first finish.
        vault.processRewards();
        uint256 secondFinish = vault.periodFinish();
        assertEq(secondFinish, block.timestamp + SEVEN_DAYS);
        assertGt(secondFinish, firstFinish);

        // Warp to secondFinish and claim. Alice should receive ~tax1+tax2.
        vm.warp(secondFinish);
        vm.prank(alice);
        vault.getReward();

        uint256 total = tax1 + tax2;
        // After claiming, her non-staked TSTT balance is the reward she got.
        // (She was funded 1000 and staked all of it, so initial reward balance
        // is 0.)
        assertApproxEqAbs(tstt.balanceOf(alice), total, total / 1000);
    }

    // ---------------------------------------------------------------
    //  Regression: double processRewards mid-drip must NOT over-promise.
    //  Pre-fix the vault would credit already-accrued rewards to the
    //  fresh drip a second time, leading to safeTransfer underflow when
    //  the last claimer ran the contract dry. Asserts the conservation
    //  invariant holds across N processRewards calls within one period.
    // ---------------------------------------------------------------

    function test_regression_doubleProcessRewards_doesNotOverPromise() public {
        _fundAndApprove(alice, 1_000e18);
        vm.prank(alice);
        vault.stake(1_000e18);

        // Tax #1.
        tstt.transfer(carol, 30_000e18);
        vm.prank(carol);
        tstt.transfer(pair, 10_000e18);
        uint256 tax1 = (10_000e18 * TAX_BPS) / BPS;
        vault.processRewards();

        // Mid-drip #1.
        vm.warp(block.timestamp + 2 days);
        vm.prank(carol);
        tstt.transfer(pair, 10_000e18);
        uint256 tax2 = (10_000e18 * TAX_BPS) / BPS;
        vault.processRewards();

        // Mid-drip #2.
        vm.warp(block.timestamp + 2 days);
        vm.prank(carol);
        tstt.transfer(pair, 10_000e18);
        uint256 tax3 = (10_000e18 * TAX_BPS) / BPS;
        vault.processRewards();

        // Wait the full period out and exit.
        vm.warp(block.timestamp + SEVEN_DAYS + 1);
        vm.prank(alice);
        vault.exit();

        uint256 totalTax = tax1 + tax2 + tax3;
        uint256 flexFee = (1_000e18 * 100) / 10_000; // 1% withdraw fee

        // Conservation: alice ends with her stake back (minus 1% fee burned) PLUS up
        // to totalTax (never more — that's the bug). Fee is burned to DEAD. Allow tiny rounding dust.
        uint256 aliceFinal = tstt.balanceOf(alice);
        assertLe(aliceFinal, 1_000e18 - flexFee + totalTax);
        assertApproxEqAbs(aliceFinal, 1_000e18 - flexFee + totalTax, totalTax / 1000);

        // Vault holds only rounding dust (flex fee was burned, not kept in vault).
        assertLt(tstt.balanceOf(address(vault)), totalTax / 1000 + 1e18);

        // Internal accounting cleared.
        assertEq(vault.totalOwed(), 0);
    }

    // ---------------------------------------------------------------
    //  Auto-process: stake / withdraw / getReward should self-heal the
    //  drip without requiring a separate processRewards() call.
    // ---------------------------------------------------------------

    function test_autoProcess_stakeTriggersDripOnFreshTax() public {
        // Alice is already staked. Tax accumulates in the vault.
        _fundAndApprove(alice, 1_000e18);
        vm.prank(alice);
        vault.stake(1_000e18);

        // Generate tax without touching the vault directly.
        tstt.transfer(carol, 30_000e18);
        vm.prank(carol);
        tstt.transfer(pair, 10_000e18);
        uint256 tax1 = (10_000e18 * TAX_BPS) / BPS;

        // Drip has NOT started yet — no processRewards was called.
        assertEq(vault.periodFinish(), 0);
        assertEq(vault.rewardRate(), 0);

        // Bob stakes — his stake should auto-pick-up tax1 and start the drip.
        _fundAndApprove(bob, 500e18);
        vm.prank(bob);
        vault.stake(500e18);

        assertGt(vault.periodFinish(), block.timestamp);
        assertGt(vault.rewardRate(), 0);
        // Rate ≈ tax1 / 7d.
        uint256 expectedRate = tax1 / SEVEN_DAYS;
        assertApproxEqAbs(vault.rewardRate(), expectedRate, expectedRate / 100);
    }

    function test_autoProcess_getRewardTriggersDrip() public {
        _fundAndApprove(alice, 1_000e18);
        vm.prank(alice);
        vault.stake(1_000e18);

        tstt.transfer(carol, 20_000e18);
        vm.prank(carol);
        tstt.transfer(pair, 10_000e18);

        assertEq(vault.periodFinish(), 0);

        // Alice calls getReward on a cold vault. autoProcess kicks in and
        // starts the drip — she won't have anything to claim THIS tx, but
        // the drip is now live for the next 7 days.
        vm.prank(alice);
        vault.getReward();

        assertGt(vault.periodFinish(), block.timestamp);
        assertGt(vault.rewardRate(), 0);
    }

    function test_autoProcess_idempotent_noSpuriousExtend() public {
        _fundAndApprove(alice, 1_000e18);
        vm.prank(alice);
        vault.stake(1_000e18);

        // One tax event, one processRewards, real period set.
        tstt.transfer(carol, 20_000e18);
        vm.prank(carol);
        tstt.transfer(pair, 10_000e18);
        vault.processRewards();
        uint256 finishAfterFirst = vault.periodFinish();

        // Warp partway through, then stake with a SECOND staker without any
        // new tax. autoProcess must NOT extend the period (dust guard).
        vm.warp(block.timestamp + 2 days);

        _fundAndApprove(bob, 500e18);
        vm.prank(bob);
        vault.stake(500e18);

        // periodFinish unchanged — no fresh drip was started.
        assertEq(vault.periodFinish(), finishAfterFirst);
    }

    // ---------------------------------------------------------------
    //  Reward payout is tax-free because the vault is excluded.
    // ---------------------------------------------------------------

    function test_vaultRewardPayout_isTaxFree() public {
        _fundAndApprove(alice, 1_000e18);
        vm.prank(alice);
        vault.stake(1_000e18);

        // Generate exactly 100 TSTT of tax via a calculable sell.
        // 100 / 0.0325 = ~3076.923... → easier: send a round amount and
        // compute the actual tax rather than targeting 100.
        tstt.transfer(carol, 10_000e18);
        vm.prank(carol);
        tstt.transfer(pair, 10_000e18);
        uint256 tax = (10_000e18 * TAX_BPS) / BPS;

        vault.processRewards();
        vm.warp(block.timestamp + SEVEN_DAYS);

        vm.prank(alice);
        vault.getReward();

        // If reward payout were taxed at 3.25%, Alice would receive
        // tax * (1 - 0.0325). We assert she got the full amount (within
        // rounding), proving the vault's exclusion takes effect.
        uint256 taxedAmount = (tax * TAX_BPS) / BPS; // what she'd lose if taxed
        assertApproxEqAbs(tstt.balanceOf(alice), tax, tax / 1000);
        // And definitively greater than the taxed-payout amount.
        assertGt(tstt.balanceOf(alice), tax - taxedAmount);
    }

    // ---------------------------------------------------------------
    //  DAO proposal: top staker changes mid-vote, voting weight is
    //  taken at castVote time (live).
    // ---------------------------------------------------------------

    function test_daoVote_usesLiveStakeAtVoteTime() public {
        _fundAndApprove(alice, 500e18);
        _fundAndApprove(bob, 500e18);
        vm.prank(alice);
        vault.stake(500e18);
        vm.prank(bob);
        vault.stake(500e18);

        vm.warp(block.timestamp + 1);

        _fundTreasury(1_000e18);

        vm.prank(alice);
        uint256 pid = dao.propose(100e18, marketingWallet, "p");

        // Alice withdraws 400 — her live balance drops to 100 before voting.
        vm.prank(alice);
        vault.withdraw(400e18);

        // Alice votes with her current (100) balance.
        vm.prank(alice);
        dao.castVote(pid, true);

        // Receipt shows weight = 100e18, not 500e18.
        ITreasuryDAO.Receipt memory r = dao.getReceipt(pid, alice);
        assertEq(r.weight, 100e18);
        assertTrue(r.support);

        // Bob votes no with full 500.
        vm.prank(bob);
        dao.castVote(pid, false);

        vm.warp(block.timestamp + 7 days + 1);

        // 100 yes vs 500 no → defeated.
        assertEq(uint8(dao.state(pid)), uint8(ITreasuryDAO.ProposalState.Defeated));
    }

    // ---------------------------------------------------------------
    //  processRewards: staker withdraws principal, excess tax alone
    //  still distributable (guard against double-counting principal).
    // ---------------------------------------------------------------

    function test_processRewards_excludesStakedPrincipal() public {
        _fundAndApprove(alice, 1_000e18);
        vm.prank(alice);
        vault.stake(1_000e18);

        // Generate tax.
        tstt.transfer(carol, 10_000e18);
        vm.prank(carol);
        tstt.transfer(pair, 10_000e18);
        uint256 tax = (10_000e18 * TAX_BPS) / BPS;

        // Vault balance = stake (1000) + tax.
        assertEq(tstt.balanceOf(address(vault)), 1_000e18 + tax);

        vault.processRewards();

        // Distributed reward = tax / rewardsDuration * rewardsDuration ≈ tax
        // (dust aside). Verify rewardRate reflects only tax, not principal.
        uint256 expectedRate = tax / SEVEN_DAYS;
        assertEq(vault.rewardRate(), expectedRate);
    }
}
