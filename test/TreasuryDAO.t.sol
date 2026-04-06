// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TreasuryDAO, IWPLS, IPulseXRouter, IBurnable} from "../src/TreasuryDAO.sol";
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
//  Mock DEX Router — always returns 1:1 swap
// ---------------------------------------------------------------

contract MockRouter {
    // For swapExactTokensForTokens: take tokenIn, mint tokenOut 1:1
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256, /* amountOutMin */
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        // Pull the input token
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        // Mint the output token to `to`
        MockERC20(path[path.length - 1]).mint(to, amountIn);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn;
    }
}

// ---------------------------------------------------------------
//  TreasuryDAO Tests
// ---------------------------------------------------------------

contract TreasuryDAOTest is Test {
    MockERC20 stakeToken;
    MockERC20 rewardToken;
    MockERC20 cabalToken; // the project token
    MockWPLS wplsToken;
    MockRouter router;
    StakingVault vault;
    TreasuryDAO dao;

    address owner; // test contract itself
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
        router = new MockRouter();

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
            address(router)
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
        assertEq(dao.dexRouter(), address(router));
        assertEq(dao.votingPeriod(), 7 days);
        assertEq(dao.quorumBps(), 1000);
        assertEq(dao.proposalCount(), 0);
    }

    function test_constructor_revertsZeroVault() public {
        vm.expectRevert("zero vault");
        new TreasuryDAO(address(0), address(cabalToken), address(wplsToken), address(router));
    }

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert("zero token");
        new TreasuryDAO(address(vault), address(0), address(wplsToken), address(router));
    }

    function test_constructor_revertsZeroWpls() public {
        vm.expectRevert("zero wpls");
        new TreasuryDAO(address(vault), address(cabalToken), address(0), address(router));
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
        // DAO should have more WPLS
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
        dao.propose(ITreasuryDAO.ProposalType.Marketing, 300e18, bob, "marketing spend");

        assertEq(dao.availableBalance(), 700e18);
    }

    // ---------------------------------------------------------------
    //  Propose
    // ---------------------------------------------------------------

    function test_propose_basic() public {
        vm.prank(alice);
        uint256 id = dao.propose(ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn it");

        assertEq(id, 0);
        assertEq(dao.proposalCount(), 1);

        ITreasuryDAO.Proposal memory p = dao.proposals(0);
        assertEq(p.amount, 100e18);
        assertEq(p.proposer, alice);
        assertEq(uint256(p.pType), uint256(ITreasuryDAO.ProposalType.BuyAndBurn));
        assertFalse(p.executed);
    }

    function test_propose_revertsNonTopStaker() public {
        vm.prank(nonStaker);
        vm.expectRevert("not top staker");
        dao.propose(ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn it");
    }

    function test_propose_revertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("zero amount");
        dao.propose(ITreasuryDAO.ProposalType.BuyAndBurn, 0, address(0), "burn it");
    }

    function test_propose_revertsEmptyDescription() public {
        vm.prank(alice);
        vm.expectRevert("empty description");
        dao.propose(ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "");
    }

    function test_propose_marketingRequiresTarget() public {
        vm.prank(alice);
        vm.expectRevert("target required");
        dao.propose(ITreasuryDAO.ProposalType.Marketing, 100e18, address(0), "marketing");
    }

    function test_propose_customRequiresTarget() public {
        vm.prank(alice);
        vm.expectRevert("target required");
        dao.propose(ITreasuryDAO.ProposalType.Custom, 100e18, address(0), "custom thing");
    }

    function test_propose_revertsInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert("insufficient available balance");
        dao.propose(ITreasuryDAO.ProposalType.BuyAndBurn, 2000e18, address(0), "too much");
    }

    function test_propose_locksFunds() public {
        vm.prank(alice);
        dao.propose(ITreasuryDAO.ProposalType.BuyAndBurn, 400e18, address(0), "burn");

        assertEq(dao.lockedAmount(), 400e18);
        assertEq(dao.availableBalance(), 600e18);
    }

    function test_propose_multipleProposals_lockStack() public {
        vm.prank(alice);
        dao.propose(ITreasuryDAO.ProposalType.BuyAndBurn, 300e18, address(0), "burn 1");
        vm.prank(bob);
        dao.propose(ITreasuryDAO.ProposalType.Marketing, 200e18, carol, "marketing 1");

        assertEq(dao.lockedAmount(), 500e18);
        assertEq(dao.availableBalance(), 500e18);
    }

    // ---------------------------------------------------------------
    //  Voting
    // ---------------------------------------------------------------

    function test_castVote_yes() public {
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        vm.prank(alice);
        dao.castVote(id, true);

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.yesVotes, 100e18); // alice has 100e18 staked

        ITreasuryDAO.Receipt memory r = dao.getReceipt(id, alice);
        assertTrue(r.hasVoted);
        assertTrue(r.support);
        assertEq(r.weight, 100e18);
    }

    function test_castVote_no() public {
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        vm.prank(bob);
        dao.castVote(id, false);

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.noVotes, 80e18); // bob has 80e18 staked
    }

    function test_castVote_revertsDoubleVote() public {
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        vm.prank(alice);
        dao.castVote(id, true);

        vm.prank(alice);
        vm.expectRevert("already voted");
        dao.castVote(id, true);
    }

    function test_castVote_revertsNoVotingPower() public {
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

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
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        // Warp past voting period
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        vm.expectRevert("voting not active");
        dao.castVote(id, true);
    }

    function test_castVote_multipleVoters() public {
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        vm.prank(alice);
        dao.castVote(id, true);
        vm.prank(bob);
        dao.castVote(id, true);
        vm.prank(carol);
        dao.castVote(id, false);

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.yesVotes, 180e18); // alice 100 + bob 80
        assertEq(p.noVotes, 60e18);   // carol 60
    }

    // ---------------------------------------------------------------
    //  State Transitions
    // ---------------------------------------------------------------

    function test_state_activeWhileVoting() public {
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Active));
    }

    function test_state_succeededAfterVoting() public {
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        // All three vote yes — well over quorum (10% of 240e18 totalStaked)
        vm.prank(alice);
        dao.castVote(id, true);
        vm.prank(bob);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Succeeded));
    }

    function test_state_defeatedNoVotes() public {
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        // No votes cast at all — no quorum
        vm.warp(block.timestamp + 7 days + 1);

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_state_defeatedMoreNoThanYes() public {
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        vm.prank(alice);
        dao.castVote(id, false); // 100e18 no
        vm.prank(bob);
        dao.castVote(id, true); // 80e18 yes

        vm.warp(block.timestamp + 7 days + 1);

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_state_defeatedInsufficientQuorum() public {
        // Quorum is 10% of totalStaked (240e18) = 24e18.
        // Only carol votes (60e18 staked) — but let's set quorum very high.
        dao.setQuorumBps(5000); // 50%

        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        // Only carol votes yes (60e18). totalStaked = 240e18. 50% = 120e18 needed.
        vm.prank(carol);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_state_executed() public {
        uint256 id = _proposeAndPass(ITreasuryDAO.ProposalType.Marketing, 50e18, bob, "marketing");

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

    function test_execute_marketing_transfersWPLS() public {
        address target = makeAddr("marketingWallet");
        uint256 id = _proposeAndPass(ITreasuryDAO.ProposalType.Marketing, 200e18, target, "marketing spend");

        uint256 balBefore = wplsToken.balanceOf(target);
        dao.executeProposal(id);
        assertEq(wplsToken.balanceOf(target), balBefore + 200e18);
    }

    function test_execute_custom_transfersWPLS() public {
        address target = makeAddr("customTarget");
        uint256 id = _proposeAndPass(ITreasuryDAO.ProposalType.Custom, 150e18, target, "custom op");

        dao.executeProposal(id);
        assertEq(wplsToken.balanceOf(target), 150e18);
    }

    function test_execute_buyAndBurn() public {
        uint256 id = _proposeAndPass(ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        // The mock router mints cabalToken to DAO, then DAO burns it
        dao.executeProposal(id);

        // cabalToken should have been burned (router mints 100e18, then burned)
        assertEq(cabalToken.balanceOf(address(dao)), 0);
    }

    function test_execute_unlocksFunds() public {
        uint256 id = _proposeAndPass(ITreasuryDAO.ProposalType.Marketing, 200e18, bob, "marketing");

        assertEq(dao.lockedAmount(), 200e18);

        dao.executeProposal(id);

        assertEq(dao.lockedAmount(), 0);
    }

    function test_execute_revertsNotSucceeded() public {
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        // Still active
        vm.expectRevert("not succeeded");
        dao.executeProposal(id);
    }

    function test_execute_revertsAlreadyExecuted() public {
        uint256 id = _proposeAndPass(ITreasuryDAO.ProposalType.Marketing, 50e18, bob, "marketing");

        dao.executeProposal(id);

        // Second call — state is now Executed, not Succeeded
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
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 300e18, address(0), "burn");

        assertEq(dao.lockedAmount(), 300e18);

        // No votes, warp past end
        vm.warp(block.timestamp + 7 days + 1);

        dao.unlockDefeated(id);

        assertEq(dao.lockedAmount(), 0);
        assertEq(dao.availableBalance(), 1000e18);
    }

    function test_unlockDefeated_revertsNotDefeated() public {
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        // Still active
        vm.expectRevert("not defeated");
        dao.unlockDefeated(id);
    }

    function test_unlockDefeated_revertsAlreadyUnlocked() public {
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 100e18, address(0), "burn");

        vm.warp(block.timestamp + 7 days + 1);
        dao.unlockDefeated(id);

        // Second call — executed flag is now true, state returns Defeated still
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
        // totalStaked = 240e18, quorum 10% => 24e18 needed
        // carol has 60e18 staked => votes count as 60e18 weight, well above 24e18
        uint256 id = _propose(alice, ITreasuryDAO.ProposalType.BuyAndBurn, 50e18, address(0), "burn");

        vm.prank(carol);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);

        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Succeeded));
    }

    // ---------------------------------------------------------------
    //  LP Expansion type
    // ---------------------------------------------------------------

    function test_propose_lpExpansion_requiresTarget() public {
        vm.prank(alice);
        vm.expectRevert("target required");
        dao.propose(ITreasuryDAO.ProposalType.LPExpansion, 100e18, address(0), "lp expansion");
    }

    function test_execute_lpExpansion_transfersWPLS() public {
        address lpTarget = makeAddr("lpTarget");
        uint256 id = _proposeAndPass(ITreasuryDAO.ProposalType.LPExpansion, 100e18, lpTarget, "lp expansion");

        dao.executeProposal(id);
        assertEq(wplsToken.balanceOf(lpTarget), 100e18);
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
        ITreasuryDAO.ProposalType pType,
        uint256 amount,
        address target,
        string memory desc
    ) internal returns (uint256) {
        vm.prank(proposer);
        return dao.propose(pType, amount, target, desc);
    }

    /// @dev Create a proposal, have alice+bob vote yes, warp past end.
    function _proposeAndPass(
        ITreasuryDAO.ProposalType pType,
        uint256 amount,
        address target,
        string memory desc
    ) internal returns (uint256) {
        uint256 id = _propose(alice, pType, amount, target, desc);

        vm.prank(alice);
        dao.castVote(id, true);
        vm.prank(bob);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);
        return id;
    }
}
