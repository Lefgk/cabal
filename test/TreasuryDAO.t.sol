// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TreasuryDAO, IWPLS} from "../src/TreasuryDAO.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {ITreasuryDAO} from "../src/interfaces/ITreasuryDAO.sol";
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

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

// ---------------------------------------------------------------
//  Mock WPLS — wraps PLS
// ---------------------------------------------------------------

contract MockWPLS is ERC20 {
    constructor() ERC20("Wrapped PLS", "WPLS") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    receive() external payable {}
}

// ---------------------------------------------------------------
//  TreasuryDAO Tests
// ---------------------------------------------------------------

contract TreasuryDAOTest is Test {
    MockERC20 stakeToken;
    MockERC20 rewardToken;
    MockERC20 cabalToken;
    MockWPLS wplsToken;
    address router;
    StakingVault vault;
    TreasuryDAO dao;

    address owner;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address nonStaker = makeAddr("nonStaker");

    uint256 constant TOP_COUNT = 5;

    function setUp() public {
        owner = address(this);

        stakeToken = new MockERC20("Stake", "STK");
        rewardToken = new MockERC20("Reward", "RWD");
        cabalToken = new MockERC20("Cabal", "CABAL");
        wplsToken = new MockWPLS();
        router = makeAddr("router");

        vault = new StakingVault(
            address(stakeToken),
            address(rewardToken),
            owner,
            TOP_COUNT
        );

        dao = new TreasuryDAO(
            address(vault),
            address(cabalToken),
            address(wplsToken),
            router
        );

        vault.setDaoAddress(address(dao));

        // Make alice, bob, carol top stakers
        _stakeAs(alice, 100e18);
        _stakeAs(bob, 80e18);
        _stakeAs(carol, 60e18);

        // Fund DAO with WPLS
        wplsToken.mint(address(dao), 1000e18);
    }

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    function test_constructor_setsState() public view {
        assertEq(address(dao.stakingVault()), address(vault));
        assertEq(dao.token(), address(cabalToken));
        assertEq(dao.wpls(), address(wplsToken));
        assertEq(dao.dexRouter(), router);
        assertEq(dao.votingPeriod(), 7 days);
        assertEq(dao.quorumBps(), 1000);
        assertEq(dao.proposalCount(), 0);
    }

    function test_constructor_revertsZeroVault() public {
        vm.expectRevert("zero vault");
        new TreasuryDAO(address(0), address(cabalToken), address(wplsToken), router);
    }

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert("zero token");
        new TreasuryDAO(address(vault), address(0), address(wplsToken), router);
    }

    function test_constructor_revertsZeroWpls() public {
        vm.expectRevert("zero wpls");
        new TreasuryDAO(address(vault), address(cabalToken), address(0), router);
    }

    function test_constructor_revertsZeroRouter() public {
        vm.expectRevert("zero router");
        new TreasuryDAO(address(vault), address(cabalToken), address(wplsToken), address(0));
    }

    // ---------------------------------------------------------------
    //  Receive / depositWPLS
    // ---------------------------------------------------------------

    function test_receive_wrapsPLS() public {
        uint256 balBefore = wplsToken.balanceOf(address(dao));
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool ok,) = address(dao).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(wplsToken.balanceOf(address(dao)), balBefore + 5 ether);
    }

    function test_depositWPLS() public {
        wplsToken.mint(alice, 100e18);
        vm.startPrank(alice);
        wplsToken.approve(address(dao), 100e18);
        dao.depositWPLS(100e18);
        vm.stopPrank();
        assertEq(wplsToken.balanceOf(address(dao)), 1100e18);
    }

    function test_depositWPLS_revertsZero() public {
        vm.expectRevert("zero amount");
        dao.depositWPLS(0);
    }

    // ---------------------------------------------------------------
    //  Available Balance
    // ---------------------------------------------------------------

    function test_availableBalance_noLocks() public view {
        assertEq(dao.availableBalance(), 1000e18);
    }

    function test_availableBalance_reducedByLocks() public {
        vm.prank(alice);
        dao.propose(300e18, bob, "marketing spend");

        assertEq(dao.availableBalance(), 700e18);
    }

    // ---------------------------------------------------------------
    //  Propose
    // ---------------------------------------------------------------

    function test_propose_basic() public {
        vm.prank(alice);
        uint256 id = dao.propose(100e18, bob, "send to bob");

        assertEq(id, 0);
        assertEq(dao.proposalCount(), 1);

        ITreasuryDAO.Proposal memory p = dao.proposals(0);
        assertEq(p.amount, 100e18);
        assertEq(p.proposer, alice);
        assertEq(p.target, bob);
        assertFalse(p.executed);
    }

    function test_propose_revertsNonTopStaker() public {
        vm.prank(nonStaker);
        vm.expectRevert("not top staker");
        dao.propose(100e18, bob, "send funds");
    }

    function test_propose_revertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("zero amount");
        dao.propose(0, bob, "send funds");
    }

    function test_propose_revertsEmptyDescription() public {
        vm.prank(alice);
        vm.expectRevert("empty description");
        dao.propose(100e18, bob, "");
    }

    function test_propose_revertsZeroTarget() public {
        vm.prank(alice);
        vm.expectRevert("target required");
        dao.propose(100e18, address(0), "send funds");
    }

    function test_propose_revertsInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert("insufficient available balance");
        dao.propose(2000e18, bob, "too much");
    }

    function test_propose_locksFunds() public {
        vm.prank(alice);
        dao.propose(400e18, bob, "spend");

        assertEq(dao.lockedAmount(), 400e18);
        assertEq(dao.availableBalance(), 600e18);
    }

    function test_propose_multipleProposals_lockStack() public {
        vm.prank(alice);
        dao.propose(300e18, bob, "spend 1");
        vm.prank(bob);
        dao.propose(200e18, carol, "spend 2");

        assertEq(dao.lockedAmount(), 500e18);
        assertEq(dao.availableBalance(), 500e18);
    }

    // ---------------------------------------------------------------
    //  Voting
    // ---------------------------------------------------------------

    function test_castVote_yes() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.yesVotes, 100e18);

        ITreasuryDAO.Receipt memory r = dao.getReceipt(id, alice);
        assertTrue(r.hasVoted);
        assertTrue(r.support);
        assertEq(r.weight, 100e18);
    }

    function test_castVote_no() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.prank(bob);
        dao.castVote(id, false);

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.noVotes, 80e18);
    }

    function test_castVote_revertsDoubleVote() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);

        vm.prank(alice);
        vm.expectRevert("already voted");
        dao.castVote(id, true);
    }

    function test_castVote_revertsNoVotingPower() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.prank(nonStaker);
        vm.expectRevert("no voting power");
        dao.castVote(id, true);
    }

    function test_castVote_revertsInvalidProposal() public {
        vm.prank(alice);
        vm.expectRevert("invalid proposal");
        dao.castVote(999, true);
    }

    function test_castVote_revertsAfterVotingEnds() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        vm.expectRevert("voting not active");
        dao.castVote(id, true);
    }

    function test_castVote_multipleVoters() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);
        vm.prank(bob);
        dao.castVote(id, true);
        vm.prank(carol);
        dao.castVote(id, false);

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.yesVotes, 180e18);
        assertEq(p.noVotes, 60e18);
    }

    // ---------------------------------------------------------------
    //  State Transitions
    // ---------------------------------------------------------------

    function test_state_activeWhileVoting() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Active));
    }

    function test_state_succeededAfterVoting() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);
        vm.prank(bob);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Succeeded));
    }

    function test_state_defeatedNoVotes() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.warp(block.timestamp + 7 days + 1);

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_state_defeatedMoreNoThanYes() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, false);
        vm.prank(bob);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_state_defeatedInsufficientQuorum() public {
        dao.setQuorumBps(5000); // 50%

        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.prank(carol);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_state_executed() public {
        uint256 id = _proposeAndPass(50e18, bob, "marketing");

        dao.executeProposal(id);

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Executed));
    }

    function test_state_revertsInvalidId() public {
        vm.expectRevert("invalid proposal");
        dao.state(0);
    }

    // ---------------------------------------------------------------
    //  Execute Proposal
    // ---------------------------------------------------------------

    function test_execute_transfersWPLS() public {
        address target = makeAddr("targetWallet");
        uint256 id = _proposeAndPass(200e18, target, "marketing spend");

        uint256 balBefore = wplsToken.balanceOf(target);
        dao.executeProposal(id);
        assertEq(wplsToken.balanceOf(target), balBefore + 200e18);
    }

    function test_execute_unlocksFunds() public {
        uint256 id = _proposeAndPass(200e18, bob, "spend");

        assertEq(dao.lockedAmount(), 200e18);

        dao.executeProposal(id);

        assertEq(dao.lockedAmount(), 0);
    }

    function test_execute_revertsNotSucceeded() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.expectRevert("not succeeded");
        dao.executeProposal(id);
    }

    function test_execute_revertsAlreadyExecuted() public {
        uint256 id = _proposeAndPass(50e18, bob, "spend");

        dao.executeProposal(id);

        vm.expectRevert("not succeeded");
        dao.executeProposal(id);
    }

    function test_execute_revertsInvalidId() public {
        vm.expectRevert("invalid proposal");
        dao.executeProposal(999);
    }

    // ---------------------------------------------------------------
    //  Unlock Defeated
    // ---------------------------------------------------------------

    function test_unlockDefeated_basic() public {
        uint256 id = _propose(alice, 300e18, bob, "spend");

        assertEq(dao.lockedAmount(), 300e18);

        vm.warp(block.timestamp + 7 days + 1);

        dao.unlockDefeated(id);

        assertEq(dao.lockedAmount(), 0);
        assertEq(dao.availableBalance(), 1000e18);
    }

    function test_unlockDefeated_revertsNotDefeated() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.expectRevert("not defeated");
        dao.unlockDefeated(id);
    }

    function test_unlockDefeated_revertsAlreadyUnlocked() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.warp(block.timestamp + 7 days + 1);
        dao.unlockDefeated(id);

        vm.expectRevert("already unlocked");
        dao.unlockDefeated(id);
    }

    // ---------------------------------------------------------------
    //  Admin Functions
    // ---------------------------------------------------------------

    function test_setStakingVault() public {
        address newVault = makeAddr("newVault");
        dao.setStakingVault(newVault);
        assertEq(address(dao.stakingVault()), newVault);
    }

    function test_setStakingVault_revertsZero() public {
        vm.expectRevert("zero address");
        dao.setStakingVault(address(0));
    }

    function test_setStakingVault_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        dao.setStakingVault(alice);
    }

    function test_setVotingPeriod() public {
        dao.setVotingPeriod(14 days);
        assertEq(dao.votingPeriod(), 14 days);
    }

    function test_setVotingPeriod_revertsTooLow() public {
        vm.expectRevert("out of range");
        dao.setVotingPeriod(0);
    }

    function test_setVotingPeriod_revertsTooHigh() public {
        vm.expectRevert("out of range");
        dao.setVotingPeriod(31 days);
    }

    function test_setQuorumBps() public {
        dao.setQuorumBps(2000);
        assertEq(dao.quorumBps(), 2000);
    }

    function test_setQuorumBps_revertsZero() public {
        vm.expectRevert("invalid bps");
        dao.setQuorumBps(0);
    }

    function test_setQuorumBps_revertsTooHigh() public {
        vm.expectRevert("invalid bps");
        dao.setQuorumBps(5001);
    }

    function test_setDexRouter() public {
        address newRouter = makeAddr("newRouter");
        dao.setDexRouter(newRouter);
        assertEq(dao.dexRouter(), newRouter);
    }

    function test_setDexRouter_revertsZero() public {
        vm.expectRevert("zero address");
        dao.setDexRouter(address(0));
    }

    function test_setWpls() public {
        address newWpls = makeAddr("newWpls");
        dao.setWpls(newWpls);
        assertEq(dao.wpls(), newWpls);
    }

    function test_setWpls_revertsZero() public {
        vm.expectRevert("zero address");
        dao.setWpls(address(0));
    }

    function test_setToken() public {
        address newToken = makeAddr("newToken");
        dao.setToken(newToken);
        assertEq(dao.token(), newToken);
    }

    function test_setToken_revertsZero() public {
        vm.expectRevert("zero address");
        dao.setToken(address(0));
    }

    // ---------------------------------------------------------------
    //  Quorum edge cases
    // ---------------------------------------------------------------

    function test_quorum_exactThreshold() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");

        vm.prank(carol);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Succeeded));
    }

    // ---------------------------------------------------------------
    //  Events
    // ---------------------------------------------------------------

    function test_propose_emitsEvent() public {
        uint256 start = block.timestamp;
        uint256 end = start + dao.votingPeriod();
        vm.expectEmit(true, true, false, true, address(dao));
        emit ITreasuryDAO.ProposalCreated(0, alice, 100e18, bob, "spend", start, end);
        vm.prank(alice);
        dao.propose(100e18, bob, "spend");
    }

    function test_castVote_emitsEvent() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");
        vm.expectEmit(true, true, false, true, address(dao));
        emit ITreasuryDAO.VoteCast(id, alice, true, 100e18);
        vm.prank(alice);
        dao.castVote(id, true);
    }

    function test_execute_emitsEvent() public {
        uint256 id = _proposeAndPass(50e18, bob, "spend");
        vm.expectEmit(true, false, false, true, address(dao));
        emit ITreasuryDAO.ProposalExecuted(id, 50e18, bob);
        dao.executeProposal(id);
    }

    function test_unlockDefeated_emitsEvents() public {
        uint256 id = _propose(alice, 300e18, bob, "spend");
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectEmit(true, false, false, true, address(dao));
        emit ITreasuryDAO.FundsUnlocked(id, 300e18);
        vm.expectEmit(true, false, false, true, address(dao));
        emit ITreasuryDAO.ProposalDefeated(id);
        dao.unlockDefeated(id);
    }

    function test_depositWPLS_emitsEvent() public {
        wplsToken.mint(alice, 50e18);
        vm.startPrank(alice);
        wplsToken.approve(address(dao), 50e18);
        vm.expectEmit(true, false, false, true, address(dao));
        emit ITreasuryDAO.WPLSDeposited(alice, 50e18);
        dao.depositWPLS(50e18);
        vm.stopPrank();
    }

    function test_receive_emitsEventAndWraps() public {
        vm.deal(alice, 10 ether);
        vm.expectEmit(true, false, false, true, address(dao));
        emit ITreasuryDAO.PLSReceived(alice, 3 ether);
        vm.prank(alice);
        (bool ok,) = address(dao).call{value: 3 ether}("");
        assertTrue(ok);
    }

    function test_receive_zeroValueNoop() public {
        uint256 balBefore = wplsToken.balanceOf(address(dao));
        vm.prank(alice);
        (bool ok,) = address(dao).call{value: 0}("");
        assertTrue(ok);
        assertEq(wplsToken.balanceOf(address(dao)), balBefore);
    }

    // ---------------------------------------------------------------
    //  Admin access control (non-owner)
    // ---------------------------------------------------------------

    function test_setVotingPeriod_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        dao.setVotingPeriod(2 days);
    }

    function test_setQuorumBps_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        dao.setQuorumBps(2000);
    }

    function test_setDexRouter_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        dao.setDexRouter(makeAddr("r"));
    }

    function test_setWpls_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        dao.setWpls(makeAddr("w"));
    }

    function test_setToken_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        dao.setToken(makeAddr("t"));
    }

    // ---------------------------------------------------------------
    //  Admin boundary values
    // ---------------------------------------------------------------

    function test_setVotingPeriod_minBoundary() public {
        dao.setVotingPeriod(dao.MIN_VOTING_PERIOD());
        assertEq(dao.votingPeriod(), 1 days);
    }

    function test_setVotingPeriod_maxBoundary() public {
        dao.setVotingPeriod(dao.MAX_VOTING_PERIOD());
        assertEq(dao.votingPeriod(), 30 days);
    }

    function test_setQuorumBps_maxBoundary() public {
        dao.setQuorumBps(dao.MAX_QUORUM_BPS());
        assertEq(dao.quorumBps(), 5000);
    }

    // ---------------------------------------------------------------
    //  Voting weight snapshot & staker set changes
    // ---------------------------------------------------------------

    /// @dev Voter's weight at vote time is snapshotted and not changed by later un/re-stake.
    ///      Vote-lock prevents withdraw during the active voting period, so we
    ///      warp past the proposal end before withdrawing.
    function test_castVote_weightSnapshot_ignoresLaterStakeChanges() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);

        // Warp past proposal end so withdraw is unlocked
        vm.warp(block.timestamp + 7 days + 1);

        // Alice withdraws most of her stake AFTER voting
        vm.prank(alice);
        vault.withdraw(90e18);

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.yesVotes, 100e18, "yes tally is snapshot weight");

        ITreasuryDAO.Receipt memory r = dao.getReceipt(id, alice);
        assertEq(r.weight, 100e18);
    }

    /// @dev A previously-top-staker who dropped out can still vote as long as weight > 0.
    function test_castVote_formerTopStakerCanStillVote() public {
        // Add 5th staker to fill top list; then push carol out by boosting a 6th
        address dave = makeAddr("dave");
        address eve = makeAddr("eve");
        _stakeAs(dave, 70e18);
        _stakeAs(eve, 65e18);

        uint256 id = _propose(alice, 50e18, bob, "spend");

        // Now bump a sixth staker above carol so carol drops from top set
        address frank = makeAddr("frank");
        _stakeAs(frank, 75e18);
        assertFalse(vault.isTopStaker(carol), "carol should no longer be top staker");

        // Carol still has stake, still has voting power
        vm.prank(carol);
        dao.castVote(id, true);

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.yesVotes, 60e18);
    }

    /// @dev A user who wasn't a top staker at setUp, but became one, can propose.
    function test_propose_newlyPromotedTopStakerCanPropose() public {
        address dave = makeAddr("dave");
        _stakeAs(dave, 120e18); // larger than alice; definitely top
        assertTrue(vault.isTopStaker(dave));

        vm.prank(dave);
        uint256 id = dao.propose(50e18, bob, "dave spend");
        assertEq(id, 0);
    }

    // ---------------------------------------------------------------
    //  Quorum boundary precision
    // ---------------------------------------------------------------

    /// @dev At quorum of 10% of 240e18 = 24e18 votes. Vote exactly at = succeed.
    function test_quorum_justBelowFails() public {
        // Use a fresh vault so totalStaked is controllable.
        StakingVault v = new StakingVault(address(stakeToken), address(rewardToken), owner, TOP_COUNT);
        v.setDaoAddress(address(dao));
        dao.setStakingVault(address(v));

        // total = 1000e18; 10% = 100e18
        address a = makeAddr("a1");
        address b = makeAddr("b1");
        _stakeInto(v, a, 99e18);   // just below quorum
        _stakeInto(v, b, 901e18);  // bring total to 1000e18, b doesn't vote

        vm.prank(a);
        uint256 id = dao.propose(10e18, bob, "spend");

        vm.prank(a);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_quorum_justAbovePasses() public {
        StakingVault v = new StakingVault(address(stakeToken), address(rewardToken), owner, TOP_COUNT);
        v.setDaoAddress(address(dao));
        dao.setStakingVault(address(v));

        address a = makeAddr("a2");
        address b = makeAddr("b2");
        _stakeInto(v, a, 100e18); // exactly quorum
        _stakeInto(v, b, 900e18);

        vm.prank(a);
        uint256 id = dao.propose(10e18, bob, "spend");

        vm.prank(a);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Succeeded));
    }

    // ---------------------------------------------------------------
    //  State query edge cases
    // ---------------------------------------------------------------

    function test_state_executedFlagDefeatedBranch() public {
        // A defeated proposal that was unlocked (p.executed=true) reports Defeated.
        uint256 id = _propose(alice, 100e18, bob, "spend");
        vm.warp(block.timestamp + 7 days + 1);
        dao.unlockDefeated(id);
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_getReceipt_defaultForNonVoter() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");
        ITreasuryDAO.Receipt memory r = dao.getReceipt(id, carol);
        assertFalse(r.hasVoted);
        assertFalse(r.support);
        assertEq(r.weight, 0);
    }

    function test_proposals_revertsInvalidId() public {
        vm.expectRevert("invalid proposal");
        dao.proposals(42);
    }

    // ---------------------------------------------------------------
    //  Double execute / lifecycle re-entry prevention
    // ---------------------------------------------------------------

    function test_execute_cannotReExecuteAfterStateSetToExecuted() public {
        uint256 id = _proposeAndPass(50e18, bob, "spend");
        dao.executeProposal(id);
        // state now Executed; second execute should revert with "not succeeded"
        vm.expectRevert("not succeeded");
        dao.executeProposal(id);
    }

    function test_unlockDefeated_cannotBeCalledOnExecuted() public {
        uint256 id = _proposeAndPass(50e18, bob, "spend");
        dao.executeProposal(id);
        vm.expectRevert("not defeated");
        dao.unlockDefeated(id);
    }

    function test_executeProposal_cannotExecuteAfterDefeatUnlock() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");
        vm.warp(block.timestamp + 7 days + 1);
        dao.unlockDefeated(id);
        vm.expectRevert("not succeeded");
        dao.executeProposal(id);
    }

    // ---------------------------------------------------------------
    //  Flows between proposals
    // ---------------------------------------------------------------

    function test_unlockDefeated_freesBalanceForNewProposal() public {
        uint256 id1 = _propose(alice, 900e18, bob, "big spend");
        vm.warp(block.timestamp + 7 days + 1);
        dao.unlockDefeated(id1);

        // Now the full 1000e18 is usable again.
        assertEq(dao.availableBalance(), 1000e18);

        vm.prank(bob);
        uint256 id2 = dao.propose(800e18, carol, "reuse");
        assertEq(id2, 1);
        assertEq(dao.lockedAmount(), 800e18);
    }

    function test_execute_reducesDaoBalance() public {
        address target = makeAddr("t3");
        uint256 id = _proposeAndPass(250e18, target, "spend");

        uint256 daoBefore = wplsToken.balanceOf(address(dao));
        dao.executeProposal(id);
        assertEq(wplsToken.balanceOf(address(dao)), daoBefore - 250e18);
        assertEq(wplsToken.balanceOf(target), 250e18);
    }

    // ---------------------------------------------------------------
    //  Admin changes mid-proposal
    // ---------------------------------------------------------------

    /// @dev Changing votingPeriod after a proposal is created must not affect its endTime.
    function test_setVotingPeriod_doesNotAffectExistingProposal() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");
        uint256 originalEnd = dao.proposals(id).endTime;

        dao.setVotingPeriod(2 days);

        assertEq(dao.proposals(id).endTime, originalEnd);
    }

    /// @dev Swapping the staking vault invalidates unresolved proposals' voting power source,
    ///      but the proposal id, amount, lock, etc. remain intact.
    function test_setStakingVault_midProposal_preservesProposal() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        StakingVault v = new StakingVault(address(stakeToken), address(rewardToken), owner, TOP_COUNT);
        v.setDaoAddress(address(dao));
        dao.setStakingVault(address(v));

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.amount, 100e18);
        assertEq(dao.lockedAmount(), 100e18);

        // Alice no longer has voting power under the new (empty) vault
        vm.prank(alice);
        vm.expectRevert("no voting power");
        dao.castVote(id, true);
    }

    // ---------------------------------------------------------------
    //  Vote-lock: withdraw blocked while active vote
    // ---------------------------------------------------------------

    function test_voteLock_withdrawRevertsWhileLocked() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);

        // Attempt withdraw while vote is active — should revert
        vm.prank(alice);
        vm.expectRevert("StakingVault: tokens locked by active vote");
        vault.withdraw(10e18);
    }

    function test_voteLock_withdrawSucceedsAfterProposalEnds() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);

        // Warp past proposal end
        vm.warp(block.timestamp + 7 days + 1);

        // Withdraw should succeed now
        vm.prank(alice);
        vault.withdraw(10e18);
        assertEq(vault.stakedBalance(alice), 90e18);
    }

    function test_voteLock_twoProposals_lockedUntilLatestEnds() public {
        // Proposal 1: created now, ends in 7 days
        uint256 id1 = _propose(alice, 50e18, bob, "spend 1");

        vm.prank(alice);
        dao.castVote(id1, true);

        // Proposal 2: created 3 days later, ends in 10 days from start
        vm.warp(block.timestamp + 3 days);
        uint256 id2 = _propose(bob, 50e18, carol, "spend 2");

        vm.prank(alice);
        dao.castVote(id2, true);

        // Warp past proposal 1 end (7 days from start = 4 days from now)
        vm.warp(block.timestamp + 4 days + 1);

        // Still locked — proposal 2 hasn't ended yet (ends 7 days after it was created)
        vm.prank(alice);
        vm.expectRevert("StakingVault: tokens locked by active vote");
        vault.withdraw(10e18);

        // Warp past proposal 2 end
        vm.warp(block.timestamp + 3 days);

        // Now withdraw succeeds
        vm.prank(alice);
        vault.withdraw(10e18);
        assertEq(vault.stakedBalance(alice), 90e18);
    }

    function test_voteLock_nonDaoCannotCallLockForVote() public {
        vm.prank(alice);
        vm.expectRevert("StakingVault: caller is not DAO");
        vault.lockForVote(alice, block.timestamp + 7 days);
    }

    function test_voteLock_exitRevertsWhileLocked() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);

        // exit() calls withdraw() internally, should also revert
        vm.prank(alice);
        vm.expectRevert("StakingVault: tokens locked by active vote");
        vault.exit();
    }

    // ---------------------------------------------------------------
    //  Additional helpers
    // ---------------------------------------------------------------

    function _stakeInto(StakingVault v, address user, uint256 amount) internal {
        stakeToken.mint(user, amount);
        vm.startPrank(user);
        stakeToken.approve(address(v), amount);
        v.stake(amount);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    //  Helpers
    // ---------------------------------------------------------------

    function _stakeAs(address user, uint256 amount) internal {
        stakeToken.mint(user, amount);
        vm.startPrank(user);
        stakeToken.approve(address(vault), amount);
        vault.stake(amount);
        vm.stopPrank();
    }

    function _propose(
        address proposer,
        uint256 amount,
        address target,
        string memory desc
    ) internal returns (uint256) {
        vm.prank(proposer);
        return dao.propose(amount, target, desc);
    }

    /// @dev Create a proposal, have alice+bob vote yes, warp past end.
    function _proposeAndPass(
        uint256 amount,
        address target,
        string memory desc
    ) internal returns (uint256) {
        uint256 id = _propose(alice, amount, target, desc);

        vm.prank(alice);
        dao.castVote(id, true);
        vm.prank(bob);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);
        return id;
    }
}
