// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TreasuryDAO} from "../src/TreasuryDAO.sol";
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
//  Mock PulseX Router
// ---------------------------------------------------------------

contract MockPulseXRouter {
    address public immutable wplsAddr;
    MockERC20 public outputToken;

    // Track LP burns for assertions
    uint256 public lastLPLiquidity;
    address public lastLPTo;

    // Track addLiquidity calls
    address public lastLiqTokenA;
    address public lastLiqTokenB;

    constructor(address _wpls) {
        wplsAddr = _wpls;
    }

    /// @dev Set the token minted on swap (configurable per test)
    function setOutputToken(address _token) external {
        outputToken = MockERC20(_token);
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256, address[] calldata path, address to, uint256
    ) external payable {
        // Mint 1:1 output tokens — use path[1] as the output token
        MockERC20(path[1]).mint(to, msg.value);
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256, address[] calldata path, address to, uint256
    ) external {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        outputToken.mint(to, amountIn);
    }

    function addLiquidityETH(
        address tokenAddr,
        uint256 amountTokenDesired,
        uint256,
        uint256,
        address to,
        uint256
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        // Pull tokens from caller
        IERC20(tokenAddr).transferFrom(msg.sender, address(this), amountTokenDesired);
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = msg.value; // simplified: LP = ETH amount

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
        liquidity = amountADesired; // simplified

        lastLPLiquidity = liquidity;
        lastLPTo = to;
        lastLiqTokenA = tokenA;
        lastLiqTokenB = tokenB;
    }

    receive() external payable {}
}

// ---------------------------------------------------------------
//  Mock ERC-20 without burn() — for fallback-to-DEAD tests
// ---------------------------------------------------------------

contract MockNoBurnToken is ERC20 {
    constructor() ERC20("NoBurn", "NOBURN") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ---------------------------------------------------------------
//  Helper to receive PLS for Custom action tests
// ---------------------------------------------------------------

contract MockTarget {
    uint256 public lastValue;
    bytes public lastData;
    bool public shouldRevert;

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    fallback() external payable {
        if (shouldRevert) revert("target reverted");
        lastValue = msg.value;
        lastData = msg.data;
    }

    receive() external payable {
        if (shouldRevert) revert("target reverted");
        lastValue = msg.value;
    }
}

// ---------------------------------------------------------------
//  TreasuryDAO Tests
// ---------------------------------------------------------------

contract TreasuryDAOTest is Test {
    MockERC20 stakeToken;
    MockERC20 rewardToken;
    MockERC20 cabalToken;
    MockERC20 burnToken; // token for BuyAndBurn / AddAndBurnLP tests
    MockWPLS wplsToken;
    MockPulseXRouter mockRouter;
    StakingVault vault;
    TreasuryDAO dao;

    address owner;
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave  = makeAddr("dave");
    address eve   = makeAddr("eve");
    address frank = makeAddr("frank");
    address nonStaker = makeAddr("nonStaker");

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant TOP_COUNT = 10;

    function setUp() public {
        owner = address(this);

        stakeToken  = new MockERC20("Stake", "STK");
        rewardToken = new MockERC20("Reward", "RWD");
        cabalToken  = new MockERC20("Cabal", "CABAL");
        burnToken   = new MockERC20("BurnToken", "BURN");
        MockWPLS _tmpWpls = new MockWPLS();
        vm.etch(0xA1077a294dDE1B09bB078844df40758a5D0f9a27, address(_tmpWpls).code);
        wplsToken = MockWPLS(payable(0xA1077a294dDE1B09bB078844df40758a5D0f9a27));

        mockRouter = new MockPulseXRouter(address(wplsToken));
        mockRouter.setOutputToken(address(burnToken));

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
            address(mockRouter)
        );

        vault.setDaoAddress(address(dao));

        // Make 6 stakers so we can hit minVoters=5 in tests
        _stakeAs(alice, 100e18);
        _stakeAs(bob,    80e18);
        _stakeAs(carol,  60e18);
        _stakeAs(dave,   50e18);
        _stakeAs(eve,    40e18);
        _stakeAs(frank,  30e18);

        // Fund DAO with raw PLS
        vm.deal(address(dao), 1000e18);
        // Fund WPLS with PLS backing for router swap mocks
        vm.deal(address(wplsToken), 10000e18);

        // Advance 1 second so stakers satisfy the "must stake before voting block" check
        vm.warp(block.timestamp + 1);
    }

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    function test_constructor_setsState() public view {
        assertEq(address(dao.stakingVault()), address(vault));
        assertEq(dao.token(), address(cabalToken));
        assertEq(dao.wpls(), address(wplsToken));
        assertEq(dao.dexRouter(), address(mockRouter));
        assertEq(dao.votingPeriod(), 7 days);
        assertEq(dao.supermajorityPct(), 65);
        assertEq(dao.minVoters(), 5);
        assertEq(dao.maxProposalAmount(), 100_000_000 ether);
        assertEq(dao.minProposalAmount(), 1 ether);
        assertEq(dao.proposalCount(), 0);
    }

    function test_constructor_revertsZeroVault() public {
        vm.expectRevert(TreasuryDAO.ZeroVault.selector);
        new TreasuryDAO(address(0), address(cabalToken), address(wplsToken), address(mockRouter));
    }

    function test_constructor_acceptsZeroToken() public {
        TreasuryDAO d = new TreasuryDAO(address(vault), address(0), address(wplsToken), address(mockRouter));
        assertEq(d.token(), address(0));
    }

    function test_constructor_revertsZeroWpls() public {
        vm.expectRevert(TreasuryDAO.ZeroWPLS.selector);
        new TreasuryDAO(address(vault), address(cabalToken), address(0), address(mockRouter));
    }

    function test_constructor_revertsZeroRouter() public {
        vm.expectRevert(TreasuryDAO.ZeroRouter.selector);
        new TreasuryDAO(address(vault), address(cabalToken), address(wplsToken), address(0));
    }

    // ---------------------------------------------------------------
    //  Receive
    // ---------------------------------------------------------------

    function test_receive_acceptsPLS() public {
        uint256 balBefore = address(dao).balance;
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool ok,) = address(dao).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(address(dao).balance, balBefore + 5 ether);
    }

    // ---------------------------------------------------------------
    //  Available Balance
    // ---------------------------------------------------------------

    function test_availableBalance_noLocks() public view {
        assertEq(dao.availableBalance(), 1000e18);
    }

    function test_availableBalance_reducedByLocks() public {
        vm.prank(alice);
        dao.propose(300e18, bob, "marketing spend", ITreasuryDAO.ActionType.SendPLS, address(0), "");
        assertEq(dao.availableBalance(), 700e18);
    }

    // ---------------------------------------------------------------
    //  Propose — SendWPLS (default)
    // ---------------------------------------------------------------

    function test_propose_basic() public {
        vm.prank(alice);
        uint256 id = dao.propose(100e18, bob, "send to bob", ITreasuryDAO.ActionType.SendPLS, address(0), "");

        assertEq(id, 1);
        assertEq(dao.proposalCount(), 1);

        ITreasuryDAO.Proposal memory p = dao.proposals(1);
        assertEq(p.amount, 100e18);
        assertEq(p.proposer, alice);
        assertEq(p.target, bob);
        assertFalse(p.executed);
        assertEq(p.voters, 0);
        assertEq(uint8(p.actionType), uint8(ITreasuryDAO.ActionType.SendPLS));
    }

    function test_propose_revertsNonTopStaker() public {
        vm.prank(nonStaker);
        vm.expectRevert(TreasuryDAO.NotTopStaker.selector);
        dao.propose(100e18, bob, "send funds", ITreasuryDAO.ActionType.SendPLS, address(0), "");
    }

    function test_propose_revertsBelowMinAmount() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.BelowMinAmount.selector);
        dao.propose(0, bob, "send funds", ITreasuryDAO.ActionType.SendPLS, address(0), "");
    }

    function test_propose_revertsAboveMaxAmount() public {
        vm.deal(address(dao), 200_000_000 ether);
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.AboveMaxAmount.selector);
        dao.propose(100_000_001 ether, bob, "too much", ITreasuryDAO.ActionType.SendPLS, address(0), "");
    }

    function test_propose_revertsEmptyDescription() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.EmptyDescription.selector);
        dao.propose(100e18, bob, "", ITreasuryDAO.ActionType.SendPLS, address(0), "");
    }

    function test_propose_revertsZeroTarget() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.TargetRequired.selector);
        dao.propose(100e18, address(0), "send funds", ITreasuryDAO.ActionType.SendPLS, address(0), "");
    }

    function test_propose_revertsInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.InsufficientAvailableBalance.selector);
        dao.propose(2000e18, bob, "too much", ITreasuryDAO.ActionType.SendPLS, address(0), "");
    }

    function test_propose_locksFunds() public {
        vm.prank(alice);
        dao.propose(400e18, bob, "spend", ITreasuryDAO.ActionType.SendPLS, address(0), "");
        assertEq(dao.lockedAmount(), 400e18);
        assertEq(dao.availableBalance(), 600e18);
    }

    function test_propose_setsLatestProposalId() public {
        vm.prank(alice);
        uint256 id = dao.propose(100e18, bob, "spend", ITreasuryDAO.ActionType.SendPLS, address(0), "");
        assertEq(dao.latestProposalIds(alice), id);
    }

    // ---------------------------------------------------------------
    //  1 active proposal per wallet
    // ---------------------------------------------------------------

    function test_propose_revertsSecondActiveProposal() public {
        vm.prank(alice);
        dao.propose(100e18, bob, "first", ITreasuryDAO.ActionType.SendPLS, address(0), "");

        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.OneActiveProposalPerProposer.selector);
        dao.propose(100e18, bob, "second", ITreasuryDAO.ActionType.SendPLS, address(0), "");
    }

    function test_propose_allowsNewAfterFirstDefeated() public {
        vm.prank(alice);
        dao.propose(100e18, bob, "first", ITreasuryDAO.ActionType.SendPLS, address(0), "");

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        uint256 id2 = dao.propose(100e18, bob, "second", ITreasuryDAO.ActionType.SendPLS, address(0), "");
        assertEq(id2, 2);
    }

    function test_propose_allowsNewAfterFirstExecuted() public {
        uint256 id = _proposeAndPass(50e18, bob, "first");
        dao.executeProposal(id);

        vm.prank(alice);
        uint256 id2 = dao.propose(50e18, bob, "second", ITreasuryDAO.ActionType.SendPLS, address(0), "");
        assertEq(id2, 2);
    }

    function test_propose_differentProposersCanBothHaveActive() public {
        vm.prank(alice);
        dao.propose(100e18, bob, "alice spend", ITreasuryDAO.ActionType.SendPLS, address(0), "");

        vm.prank(bob);
        dao.propose(100e18, carol, "bob spend", ITreasuryDAO.ActionType.SendPLS, address(0), "");

        assertEq(dao.proposalCount(), 2);
    }

    // ---------------------------------------------------------------
    //  Voting
    // ---------------------------------------------------------------

    function test_castVote_yes_usesEffectiveBalance() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.yesVotes, 100e18);
        assertEq(p.voters, 1);

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
        assertEq(p.voters, 1);
    }

    function test_castVote_revertsDoubleVote() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);

        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.AlreadyVoted.selector);
        dao.castVote(id, true);
    }

    function test_castVote_revertsNoVotingPower() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.prank(nonStaker);
        vm.expectRevert(TreasuryDAO.NoVotingPower.selector);
        dao.castVote(id, true);
    }

    function test_castVote_revertsInvalidProposal() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.InvalidProposal.selector);
        dao.castVote(999, true);
    }

    function test_castVote_revertsAfterVotingEnds() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.VotingNotActive.selector);
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
        assertEq(p.voters, 3);
    }

    function test_castVote_lockedStaker_usesEffectiveBalance() public {
        address gina = makeAddr("gina");
        stakeToken.mint(gina, 50e18);
        vm.startPrank(gina);
        stakeToken.approve(address(vault), 50e18);
        vault.stakeLocked(50e18, 365 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        uint256 id = _propose(alice, 50e18, bob, "spend");

        vm.prank(gina);
        dao.castVote(id, true);

        ITreasuryDAO.Receipt memory r = dao.getReceipt(id, gina);
        assertEq(r.weight, 150e18); // 50 * 3x
    }

    // ---------------------------------------------------------------
    //  Supermajority + Min Voters
    // ---------------------------------------------------------------

    function test_supermajority_passesAt65Pct() public {
        uint256 id = _proposeAndPass(50e18, bob, "spend");
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Succeeded));
    }

    function test_supermajority_failsBelowMinVoters() public {
        // Only 4 voters (below minVoters=5), all yes
        uint256 id = _propose(alice, 50e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);
        vm.prank(bob);
        dao.castVote(id, true);
        vm.prank(carol);
        dao.castVote(id, true);
        vm.prank(dave);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_supermajority_failsBelow65Pct() public {
        // 5 voters, yes=3 no=2 → 60% yes → below 65%
        uint256 id = _propose(alice, 50e18, bob, "spend");

        // Make all stakers have equal weight for clean math
        address v1 = makeAddr("v1");
        address v2 = makeAddr("v2");
        address v3 = makeAddr("v3");
        address v4 = makeAddr("v4");
        address v5 = makeAddr("v5");
        _stakeAs(v1, 100e18);
        _stakeAs(v2, 100e18);
        _stakeAs(v3, 100e18);
        _stakeAs(v4, 100e18);
        _stakeAs(v5, 100e18);
        vm.warp(block.timestamp + 1);

        vm.prank(v1);
        dao.castVote(id, true);
        vm.prank(v2);
        dao.castVote(id, true);
        vm.prank(v3);
        dao.castVote(id, true);
        vm.prank(v4);
        dao.castVote(id, false);
        vm.prank(v5);
        dao.castVote(id, false);

        vm.warp(block.timestamp + 7 days + 1);
        // 3/5 = 60% < 65%
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_supermajority_passesAtExactly65Pct() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");

        // Need yes/(yes+no) = 65%. Use 20 units: 13 yes, 7 no.
        address[] memory voters = new address[](20);
        for (uint256 i; i < 20; i++) {
            voters[i] = makeAddr(string(abi.encodePacked("voter", vm.toString(i))));
            _stakeAs(voters[i], 10e18);
        }
        vm.warp(block.timestamp + 1);

        // 13 yes
        for (uint256 i; i < 13; i++) {
            vm.prank(voters[i]);
            dao.castVote(id, true);
        }
        // 7 no
        for (uint256 i = 13; i < 20; i++) {
            vm.prank(voters[i]);
            dao.castVote(id, false);
        }

        vm.warp(block.timestamp + 7 days + 1);
        // 130/200 = 65% exactly
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Succeeded));
    }

    function test_supermajority_failsAt64Pct() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");

        // 16 yes, 9 no = 64% → fail
        address[] memory voters = new address[](25);
        for (uint256 i; i < 25; i++) {
            voters[i] = makeAddr(string(abi.encodePacked("voter", vm.toString(i))));
            _stakeAs(voters[i], 10e18);
        }
        vm.warp(block.timestamp + 1);

        for (uint256 i; i < 16; i++) {
            vm.prank(voters[i]);
            dao.castVote(id, true);
        }
        for (uint256 i = 16; i < 25; i++) {
            vm.prank(voters[i]);
            dao.castVote(id, false);
        }

        vm.warp(block.timestamp + 7 days + 1);
        // 160/250 = 64%
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_supermajority_noVotesDefeated() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");
        vm.warp(block.timestamp + 7 days + 1);
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_supermajority_moreNoThanYes() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, false);
        vm.prank(bob);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    function test_votingPercent_basic() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);  // 100e18 yes
        vm.prank(carol);
        dao.castVote(id, false); // 60e18 no

        // 100/(100+60) = 62%
        assertEq(dao.votingPercent(id), 62);
    }

    function test_votingPercent_zeroVotes() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");
        assertEq(dao.votingPercent(id), 0);
    }

    // ---------------------------------------------------------------
    //  State Transitions
    // ---------------------------------------------------------------

    function test_state_activeWhileVoting() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Active));
    }

    function test_state_executed() public {
        uint256 id = _proposeAndPass(50e18, bob, "marketing");
        dao.executeProposal(id);
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Executed));
    }

    function test_state_revertsInvalidId() public {
        vm.expectRevert(TreasuryDAO.InvalidProposal.selector);
        dao.state(999);
    }

    function test_state_executedFlagDefeatedBranch() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");
        vm.warp(block.timestamp + 7 days + 1);
        dao.unlockDefeated(id);
        assertEq(uint256(dao.state(id)), uint256(ITreasuryDAO.ProposalState.Defeated));
    }

    // ---------------------------------------------------------------
    //  Execute Proposal — SendWPLS
    // ---------------------------------------------------------------

    function test_execute_transfersPLS() public {
        address target = makeAddr("targetWallet");
        uint256 id = _proposeAndPass(200e18, target, "marketing spend");

        uint256 balBefore = target.balance;
        dao.executeProposal(id);
        assertEq(target.balance, balBefore + 200e18);
    }

    function test_execute_unlocksFunds() public {
        uint256 id = _proposeAndPass(200e18, bob, "spend");
        assertEq(dao.lockedAmount(), 200e18);
        dao.executeProposal(id);
        assertEq(dao.lockedAmount(), 0);
    }

    function test_execute_revertsNotSucceeded() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");
        vm.expectRevert(TreasuryDAO.NotSucceeded.selector);
        dao.executeProposal(id);
    }

    function test_execute_revertsAlreadyExecuted() public {
        uint256 id = _proposeAndPass(50e18, bob, "spend");
        dao.executeProposal(id);
        vm.expectRevert(TreasuryDAO.NotSucceeded.selector);
        dao.executeProposal(id);
    }

    function test_execute_revertsInvalidId() public {
        vm.expectRevert(TreasuryDAO.InvalidProposal.selector);
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
        vm.expectRevert(TreasuryDAO.NotDefeated.selector);
        dao.unlockDefeated(id);
    }

    function test_unlockDefeated_revertsAlreadyUnlocked() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");
        vm.warp(block.timestamp + 7 days + 1);
        dao.unlockDefeated(id);
        vm.expectRevert(TreasuryDAO.AlreadyUnlocked.selector);
        dao.unlockDefeated(id);
    }

    // ---------------------------------------------------------------
    //  Proposal Amount Caps
    // ---------------------------------------------------------------

    function test_propose_minAmountBoundary() public {
        vm.prank(alice);
        uint256 id = dao.propose(1 ether, bob, "min spend", ITreasuryDAO.ActionType.SendPLS, address(0), "");
        assertEq(id, 1);
    }

    function test_propose_maxAmountBoundary() public {
        vm.deal(address(dao), 100_000_000 ether);
        vm.prank(alice);
        uint256 id = dao.propose(100_000_000 ether, bob, "max spend", ITreasuryDAO.ActionType.SendPLS, address(0), "");
        assertEq(id, 1);
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
        vm.expectRevert(TreasuryDAO.ZeroAddress.selector);
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
        vm.expectRevert(TreasuryDAO.OutOfRange.selector);
        dao.setVotingPeriod(0);
    }

    function test_setVotingPeriod_revertsTooHigh() public {
        vm.expectRevert(TreasuryDAO.OutOfRange.selector);
        dao.setVotingPeriod(31 days);
    }

    function test_setMinVoters() public {
        dao.setMinVoters(10);
        assertEq(dao.minVoters(), 10);
    }

    function test_setMinVoters_revertsZero() public {
        vm.expectRevert(TreasuryDAO.ZeroVoters.selector);
        dao.setMinVoters(0);
    }

    function test_setSupermajorityPct() public {
        dao.setSupermajorityPct(75);
        assertEq(dao.supermajorityPct(), 75);
    }

    function test_setSupermajorityPct_revertsTooLow() public {
        vm.expectRevert(TreasuryDAO.OutOfRange.selector);
        dao.setSupermajorityPct(50);
    }

    function test_setSupermajorityPct_revertsTooHigh() public {
        vm.expectRevert(TreasuryDAO.OutOfRange.selector);
        dao.setSupermajorityPct(101);
    }

    function test_setMaxProposalAmount() public {
        dao.setMaxProposalAmount(500 ether);
        assertEq(dao.maxProposalAmount(), 500 ether);
    }

    function test_setMaxProposalAmount_revertsBelowMin() public {
        vm.expectRevert(TreasuryDAO.MaxBelowMin.selector);
        dao.setMaxProposalAmount(0);
    }

    function test_setMinProposalAmount() public {
        dao.setMinProposalAmount(10 ether);
        assertEq(dao.minProposalAmount(), 10 ether);
    }

    function test_setMinProposalAmount_revertsZero() public {
        vm.expectRevert(TreasuryDAO.InvalidMin.selector);
        dao.setMinProposalAmount(0);
    }

    function test_setDexRouter() public {
        address newRouter = makeAddr("newRouter");
        dao.setDexRouter(newRouter);
        assertEq(dao.dexRouter(), newRouter);
    }

    function test_setDexRouter_revertsZero() public {
        vm.expectRevert(TreasuryDAO.ZeroAddress.selector);
        dao.setDexRouter(address(0));
    }

    function test_setToken() public {
        address newToken = makeAddr("newToken");
        dao.setToken(newToken);
        assertEq(dao.token(), newToken);
    }

    function test_setToken_revertsZero() public {
        vm.expectRevert(TreasuryDAO.ZeroAddress.selector);
        dao.setToken(address(0));
    }

    // ---------------------------------------------------------------
    //  Admin access control (non-owner)
    // ---------------------------------------------------------------

    function test_setVotingPeriod_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        dao.setVotingPeriod(2 days);
    }

    function test_setMinVoters_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        dao.setMinVoters(10);
    }

    function test_setSupermajorityPct_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        dao.setSupermajorityPct(75);
    }

    function test_setDexRouter_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        dao.setDexRouter(makeAddr("r"));
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
        dao.setVotingPeriod(dao.minVotingPeriod());
        assertEq(dao.votingPeriod(), 5 minutes);
    }

    function test_setVotingPeriod_maxBoundary() public {
        dao.setVotingPeriod(dao.maxVotingPeriod());
        assertEq(dao.votingPeriod(), 30 days);
    }

    // ---------------------------------------------------------------
    //  Voting weight & staker set changes
    // ---------------------------------------------------------------

    function test_castVote_weightSnapshot_ignoresLaterStakeChanges() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        vault.withdraw(90e18);

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.yesVotes, 100e18, "yes tally is snapshot weight");
    }

    function test_castVote_formerTopStakerCanStillVote() public {
        // Fill up top staker slots beyond current 6
        address[] memory extras = new address[](5);
        for (uint256 i; i < 5; i++) {
            extras[i] = makeAddr(string(abi.encodePacked("extra", vm.toString(i))));
            _stakeAs(extras[i], 200e18); // all outrank frank (30e18)
        }

        uint256 id = _propose(alice, 50e18, bob, "spend");

        assertFalse(vault.isTopStaker(frank), "frank should no longer be top staker");

        // Frank still has stake, still has voting power
        vm.prank(frank);
        dao.castVote(id, true);

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.yesVotes, 30e18);
    }

    function test_propose_newlyPromotedTopStakerCanPropose() public {
        address gina = makeAddr("gina");
        _stakeAs(gina, 120e18);
        assertTrue(vault.isTopStaker(gina));

        vm.prank(gina);
        uint256 id = dao.propose(50e18, bob, "gina spend", ITreasuryDAO.ActionType.SendPLS, address(0), "");
        assertEq(id, 1);
    }

    // ---------------------------------------------------------------
    //  State query edge cases
    // ---------------------------------------------------------------

    function test_getReceipt_defaultForNonVoter() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");
        ITreasuryDAO.Receipt memory r = dao.getReceipt(id, carol);
        assertFalse(r.hasVoted);
        assertFalse(r.support);
        assertEq(r.weight, 0);
    }

    function test_proposals_revertsInvalidId() public {
        vm.expectRevert(TreasuryDAO.InvalidProposal.selector);
        dao.proposals(42);
    }

    // ---------------------------------------------------------------
    //  Double execute / lifecycle re-entry prevention
    // ---------------------------------------------------------------

    function test_execute_cannotReExecuteAfterStateSetToExecuted() public {
        uint256 id = _proposeAndPass(50e18, bob, "spend");
        dao.executeProposal(id);
        vm.expectRevert(TreasuryDAO.NotSucceeded.selector);
        dao.executeProposal(id);
    }

    function test_unlockDefeated_cannotBeCalledOnExecuted() public {
        uint256 id = _proposeAndPass(50e18, bob, "spend");
        dao.executeProposal(id);
        vm.expectRevert(TreasuryDAO.NotDefeated.selector);
        dao.unlockDefeated(id);
    }

    function test_executeProposal_cannotExecuteAfterDefeatUnlock() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");
        vm.warp(block.timestamp + 7 days + 1);
        dao.unlockDefeated(id);
        vm.expectRevert(TreasuryDAO.NotSucceeded.selector);
        dao.executeProposal(id);
    }

    // ---------------------------------------------------------------
    //  Flows between proposals
    // ---------------------------------------------------------------

    function test_unlockDefeated_freesBalanceForNewProposal() public {
        uint256 id1 = _propose(alice, 900e18, bob, "big spend");
        vm.warp(block.timestamp + 7 days + 1);
        dao.unlockDefeated(id1);

        assertEq(dao.availableBalance(), 1000e18);

        vm.prank(bob);
        uint256 id2 = dao.propose(800e18, carol, "reuse", ITreasuryDAO.ActionType.SendPLS, address(0), "");
        assertEq(id2, 2);
        assertEq(dao.lockedAmount(), 800e18);
    }

    function test_execute_reducesDaoBalance() public {
        address target = makeAddr("t3");
        uint256 id = _proposeAndPass(250e18, target, "spend");

        uint256 daoBefore = address(dao).balance;
        dao.executeProposal(id);
        assertEq(address(dao).balance, daoBefore - 250e18);
        assertEq(target.balance, 250e18);
    }

    // ---------------------------------------------------------------
    //  Admin changes mid-proposal
    // ---------------------------------------------------------------

    function test_setVotingPeriod_doesNotAffectExistingProposal() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");
        uint256 originalEnd = dao.proposals(id).endTime;
        dao.setVotingPeriod(2 days);
        assertEq(dao.proposals(id).endTime, originalEnd);
    }

    function test_setStakingVault_midProposal_preservesProposal() public {
        uint256 id = _propose(alice, 100e18, bob, "spend");

        StakingVault v = new StakingVault(address(stakeToken), address(rewardToken), owner, TOP_COUNT);
        v.setDaoAddress(address(dao));
        dao.setStakingVault(address(v));

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(p.amount, 100e18);
        assertEq(dao.lockedAmount(), 100e18);

        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.NoVotingPower.selector);
        dao.castVote(id, true);
    }

    // ---------------------------------------------------------------
    //  Vote-lock: withdraw blocked while active vote
    // ---------------------------------------------------------------

    function test_voteLock_withdrawRevertsWhileLocked() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);

        vm.prank(alice);
        vm.expectRevert(StakingVault.TokensVoteLocked.selector);
        vault.withdraw(10e18);
    }

    function test_voteLock_withdrawSucceedsAfterProposalEnds() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");

        vm.prank(alice);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        vault.withdraw(10e18);
        assertEq(vault.flexBalance(alice), 90e18);
    }

    function test_voteLock_twoProposals_lockedUntilLatestEnds() public {
        uint256 id1 = _propose(alice, 50e18, bob, "spend 1");
        vm.prank(alice);
        dao.castVote(id1, true);

        vm.warp(block.timestamp + 3 days);
        uint256 id2 = _propose(bob, 50e18, carol, "spend 2");
        vm.prank(alice);
        dao.castVote(id2, true);

        // Past proposal 1 end
        vm.warp(block.timestamp + 4 days + 1);

        // Still locked -- proposal 2 hasn't ended yet
        vm.prank(alice);
        vm.expectRevert(StakingVault.TokensVoteLocked.selector);
        vault.withdraw(10e18);

        // Past proposal 2 end
        vm.warp(block.timestamp + 3 days);

        vm.prank(alice);
        vault.withdraw(10e18);
        assertEq(vault.flexBalance(alice), 90e18);
    }

    function test_voteLock_nonDaoCannotCallLockForVote() public {
        vm.prank(alice);
        vm.expectRevert(StakingVault.NotDAO.selector);
        vault.lockForVote(alice, block.timestamp + 7 days);
    }

    function test_voteLock_exitRevertsWhileLocked() public {
        uint256 id = _propose(alice, 50e18, bob, "spend");
        vm.prank(alice);
        dao.castVote(id, true);

        vm.prank(alice);
        vm.expectRevert(StakingVault.TokensVoteLocked.selector);
        vault.exit();
    }

    // ---------------------------------------------------------------
    //  Events
    // ---------------------------------------------------------------

    function test_propose_emitsEvent() public {
        uint256 start = block.timestamp;
        uint256 end = start + dao.votingPeriod();
        vm.expectEmit(true, true, false, true, address(dao));
        emit ITreasuryDAO.ProposalCreated(1, alice, 100e18, bob, "spend", start, end);
        vm.prank(alice);
        dao.propose(100e18, bob, "spend", ITreasuryDAO.ActionType.SendPLS, address(0), "");
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

    function test_receive_emitsPLSReceived() public {
        vm.deal(alice, 10 ether);
        vm.expectEmit(true, false, false, true, address(dao));
        emit ITreasuryDAO.PLSReceived(alice, 3 ether);
        vm.prank(alice);
        (bool ok,) = address(dao).call{value: 3 ether}("");
        assertTrue(ok);
    }

    function test_receive_zeroValueNoop() public {
        uint256 balBefore = address(dao).balance;
        vm.prank(alice);
        (bool ok,) = address(dao).call{value: 0}("");
        assertTrue(ok);
        assertEq(address(dao).balance, balBefore);
    }

    // ---------------------------------------------------------------
    //  BuyAndBurn action type
    // ---------------------------------------------------------------

    function test_buyAndBurn_propose_basic() public {
        vm.prank(alice);
        uint256 id = dao.propose(
            100e18, address(0), "buy and burn",
            ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), ""
        );
        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(uint8(p.actionType), uint8(ITreasuryDAO.ActionType.BuyAndBurn));
        assertEq(p.actionToken, address(burnToken));
    }

    function test_buyAndBurn_propose_revertsNoActionToken() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.ActionTokenRequired.selector);
        dao.propose(100e18, address(0), "buy and burn", ITreasuryDAO.ActionType.BuyAndBurn, address(0), "");
    }

    function test_buyAndBurn_propose_revertsWPLSasActionToken() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.ActionTokenCannotBeWPLS.selector);
        dao.propose(100e18, address(0), "buy wpls", ITreasuryDAO.ActionType.BuyAndBurn, address(wplsToken), "");
    }

    function test_buyAndBurn_execute_burnsTokens() public {
        uint256 id = _proposeAndPassAction(
            100e18, address(0), "buy and burn",
            ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), ""
        );

        dao.executeProposal(id);

        // MockERC20 has burn(), so tokens are actually burned (not sent to DEAD)
        assertEq(burnToken.balanceOf(DEAD), 0, "tokens burned, not sent to DEAD");
        // DAO holds no leftover tokens
        assertEq(burnToken.balanceOf(address(dao)), 0);
    }

    function test_buyAndBurn_execute_fallbackToDead_whenNoBurn() public {
        // Deploy a token without burn() — plain ERC20
        MockNoBurnToken noBurnToken = new MockNoBurnToken();
        mockRouter.setOutputToken(address(noBurnToken));

        uint256 id = _proposeAndPassAction(
            100e18, address(0), "buy and burn no-burn token",
            ITreasuryDAO.ActionType.BuyAndBurn, address(noBurnToken), ""
        );

        uint256 deadBefore = noBurnToken.balanceOf(DEAD);
        dao.executeProposal(id);
        uint256 deadAfter = noBurnToken.balanceOf(DEAD);

        // Fallback: tokens sent to DEAD
        assertEq(deadAfter - deadBefore, 100e18);
    }

    function test_buyAndBurn_execute_unlocksFunds() public {
        uint256 id = _proposeAndPassAction(
            100e18, address(0), "buy and burn",
            ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), ""
        );
        assertEq(dao.lockedAmount(), 100e18);
        dao.executeProposal(id);
        assertEq(dao.lockedAmount(), 0);
    }

    // ---------------------------------------------------------------
    //  AddAndBurnLP action type
    // ---------------------------------------------------------------

    function test_addAndBurnLP_propose_basic() public {
        vm.prank(alice);
        uint256 id = dao.propose(
            100e18, address(0), "add LP and burn",
            ITreasuryDAO.ActionType.AddAndBurnLP, address(burnToken), ""
        );
        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(uint8(p.actionType), uint8(ITreasuryDAO.ActionType.AddAndBurnLP));
    }

    function test_addAndBurnLP_propose_revertsNoActionToken() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.ActionTokenRequired.selector);
        dao.propose(100e18, address(0), "add LP", ITreasuryDAO.ActionType.AddAndBurnLP, address(0), "");
    }

    function test_addAndBurnLP_execute_sendsLPToDead() public {
        uint256 id = _proposeAndPassAction(
            100e18, address(0), "add LP and burn",
            ITreasuryDAO.ActionType.AddAndBurnLP, address(burnToken), ""
        );

        dao.executeProposal(id);

        // Router should have sent LP to DEAD
        assertEq(mockRouter.lastLPTo(), DEAD);
        assertGt(mockRouter.lastLPLiquidity(), 0);
    }

    function test_addAndBurnLP_execute_leftoverTokensBurnedToDead() public {
        uint256 id = _proposeAndPassAction(
            100e18, address(0), "add LP and burn",
            ITreasuryDAO.ActionType.AddAndBurnLP, address(burnToken), ""
        );

        dao.executeProposal(id);

        // DAO should have no leftover burnTokens
        assertEq(burnToken.balanceOf(address(dao)), 0);
    }

    // ---------------------------------------------------------------
    //  Custom action type
    // ---------------------------------------------------------------

    function test_custom_propose_basic() public {
        MockTarget target = new MockTarget();
        bytes memory data = hex"deadbeef";

        vm.prank(alice);
        uint256 id = dao.propose(
            50e18, address(target), "custom call",
            ITreasuryDAO.ActionType.Custom, address(0), data
        );
        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(uint8(p.actionType), uint8(ITreasuryDAO.ActionType.Custom));
        assertEq(p.data, data);
    }

    function test_custom_propose_revertsNoTarget() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.TargetRequired.selector);
        dao.propose(50e18, address(0), "custom", ITreasuryDAO.ActionType.Custom, address(0), hex"01");
    }

    function test_custom_propose_revertsNoData() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.DataRequired.selector);
        dao.propose(50e18, bob, "custom", ITreasuryDAO.ActionType.Custom, address(0), "");
    }

    function test_custom_propose_allowsZeroAmount() public {
        MockTarget target = new MockTarget();
        vm.prank(alice);
        uint256 id = dao.propose(
            0, address(target), "custom no value",
            ITreasuryDAO.ActionType.Custom, address(0), hex"01"
        );
        assertEq(id, 1);
        assertEq(dao.lockedAmount(), 0);
    }

    function test_custom_execute_callsTargetWithValueAndData() public {
        MockTarget target = new MockTarget();
        bytes memory data = hex"deadbeef";

        uint256 id = _proposeAndPassAction(
            10e18, address(target), "custom call",
            ITreasuryDAO.ActionType.Custom, address(0), data
        );

        dao.executeProposal(id);

        assertEq(target.lastValue(), 10e18);
        assertEq(target.lastData(), data);
    }

    function test_custom_execute_zeroAmount_noPLSSent() public {
        MockTarget target = new MockTarget();
        bytes memory data = abi.encodeWithSignature("setShouldRevert(bool)", false);

        uint256 id = _proposeAndPassAction(
            0, address(target), "custom zero",
            ITreasuryDAO.ActionType.Custom, address(0), data
        );

        uint256 plsBefore = address(dao).balance;
        dao.executeProposal(id);
        // PLS balance unchanged (nothing sent)
        assertEq(address(dao).balance, plsBefore);
        assertEq(target.lastValue(), 0);
    }

    function test_custom_execute_revertsOnFailedCall() public {
        MockTarget target = new MockTarget();
        target.setShouldRevert(true);
        bytes memory data = hex"01";

        uint256 id = _proposeAndPassAction(
            10e18, address(target), "custom fail",
            ITreasuryDAO.ActionType.Custom, address(0), data
        );

        vm.expectRevert(TreasuryDAO.CustomCallFailed.selector);
        dao.executeProposal(id);
    }

    // ---------------------------------------------------------------
    //  Propose validation per action type
    // ---------------------------------------------------------------

    function test_buyAndBurn_propose_revertsBelowMin() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.BelowMinAmount.selector);
        dao.propose(0, address(0), "buy", ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), "");
    }

    function test_addAndBurnLP_propose_revertsBelowMin() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.BelowMinAmount.selector);
        dao.propose(0, address(0), "lp", ITreasuryDAO.ActionType.AddAndBurnLP, address(burnToken), "");
    }

    // ---------------------------------------------------------------
    //  AddAndBurnLP — token/token pair
    // ---------------------------------------------------------------

    function test_addAndBurnLP_tokenToken_propose() public {
        MockERC20 tokenB = new MockERC20("TokenB", "TKB");

        vm.prank(alice);
        uint256 id = dao.propose(
            100e18, address(tokenB), "LP burn OMEGA/HEX",
            ITreasuryDAO.ActionType.AddAndBurnLP, address(burnToken), ""
        );
        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(uint8(p.actionType), uint8(ITreasuryDAO.ActionType.AddAndBurnLP));
        assertEq(p.actionToken, address(burnToken));
        assertEq(p.target, address(tokenB));
    }

    function test_addAndBurnLP_tokenToken_execute() public {
        MockERC20 tokenB = new MockERC20("TokenB", "TKB");

        uint256 id = _proposeAndPassAction(
            100e18, address(tokenB), "LP burn token/token",
            ITreasuryDAO.ActionType.AddAndBurnLP, address(burnToken), ""
        );

        dao.executeProposal(id);

        // Router should have received addLiquidity call with LP to DEAD
        assertEq(mockRouter.lastLPTo(), DEAD);
        assertGt(mockRouter.lastLPLiquidity(), 0);
        assertEq(mockRouter.lastLiqTokenA(), address(burnToken));
        assertEq(mockRouter.lastLiqTokenB(), address(tokenB));

        // DAO should have no leftover tokens
        assertEq(burnToken.balanceOf(address(dao)), 0);
        assertEq(tokenB.balanceOf(address(dao)), 0);
    }

    function test_addAndBurnLP_plsPair_stillWorks() public {
        // target == address(0) should still use addLiquidityETH path
        uint256 id = _proposeAndPassAction(
            100e18, address(0), "LP burn PLS pair",
            ITreasuryDAO.ActionType.AddAndBurnLP, address(burnToken), ""
        );

        dao.executeProposal(id);

        assertEq(mockRouter.lastLPTo(), DEAD);
        assertGt(mockRouter.lastLPLiquidity(), 0);
    }

    // ---------------------------------------------------------------
    //  Preset CRUD
    // ---------------------------------------------------------------

    function test_addPreset_basic() public {
        uint256 id = dao.addPreset(
            "Buy & Burn OMEGA",
            ITreasuryDAO.ActionType.BuyAndBurn,
            address(burnToken),
            address(0),
            ""
        );
        assertEq(id, 1);
        assertEq(dao.presetCount(), 1);

        ITreasuryDAO.Preset memory p = dao.getPreset(1);
        assertEq(p.name, "Buy & Burn OMEGA");
        assertEq(uint8(p.actionType), uint8(ITreasuryDAO.ActionType.BuyAndBurn));
        assertEq(p.actionToken, address(burnToken));
        assertEq(p.target, address(0));
        assertTrue(p.active);
    }

    function test_addPreset_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(dao));
        emit ITreasuryDAO.PresetAdded(1, "Buy & Burn OMEGA", ITreasuryDAO.ActionType.BuyAndBurn);
        dao.addPreset("Buy & Burn OMEGA", ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), address(0), "");
    }

    function test_addPreset_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        dao.addPreset("test", ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), address(0), "");
    }

    function test_addPreset_revertsEmptyName() public {
        vm.expectRevert(TreasuryDAO.EmptyName.selector);
        dao.addPreset("", ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), address(0), "");
    }

    function test_addPreset_validatesPerType() public {
        // BuyAndBurn requires actionToken
        vm.expectRevert(TreasuryDAO.ActionTokenRequired.selector);
        dao.addPreset("bad", ITreasuryDAO.ActionType.BuyAndBurn, address(0), address(0), "");

        // SendWPLS requires target
        vm.expectRevert(TreasuryDAO.TargetRequired.selector);
        dao.addPreset("bad", ITreasuryDAO.ActionType.SendPLS, address(0), address(0), "");

        // Custom requires target + data
        vm.expectRevert(TreasuryDAO.TargetRequired.selector);
        dao.addPreset("bad", ITreasuryDAO.ActionType.Custom, address(0), address(0), hex"01");

        vm.expectRevert(TreasuryDAO.DataRequired.selector);
        dao.addPreset("bad", ITreasuryDAO.ActionType.Custom, address(0), bob, "");
    }

    function test_removePreset_basic() public {
        dao.addPreset("Buy & Burn", ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), address(0), "");

        vm.expectEmit(true, false, false, true, address(dao));
        emit ITreasuryDAO.PresetRemoved(1);
        dao.removePreset(1);

        ITreasuryDAO.Preset memory p = dao.getPreset(1);
        assertFalse(p.active);
    }

    function test_removePreset_revertsInvalidId() public {
        vm.expectRevert(TreasuryDAO.InvalidPreset.selector);
        dao.removePreset(99);
    }

    function test_removePreset_revertsAlreadyRemoved() public {
        dao.addPreset("test", ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), address(0), "");
        dao.removePreset(1);

        vm.expectRevert(TreasuryDAO.AlreadyRemoved.selector);
        dao.removePreset(1);
    }

    function test_removePreset_revertsNonOwner() public {
        dao.addPreset("test", ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), address(0), "");
        vm.prank(alice);
        vm.expectRevert();
        dao.removePreset(1);
    }

    function test_getActivePresets() public {
        dao.addPreset("A", ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), address(0), "");
        dao.addPreset("B", ITreasuryDAO.ActionType.AddAndBurnLP, address(burnToken), address(0), "");
        dao.addPreset("C", ITreasuryDAO.ActionType.SendPLS, address(0), bob, "");

        ITreasuryDAO.Preset[] memory all = dao.getActivePresets();
        assertEq(all.length, 3);

        // Remove B
        dao.removePreset(2);
        ITreasuryDAO.Preset[] memory active = dao.getActivePresets();
        assertEq(active.length, 2);
        assertEq(active[0].name, "A");
        assertEq(active[1].name, "C");
    }

    function test_getPreset_revertsInvalidId() public {
        vm.expectRevert(TreasuryDAO.InvalidPreset.selector);
        dao.getPreset(1);
    }

    // ---------------------------------------------------------------
    //  proposeFromPreset
    // ---------------------------------------------------------------

    function test_proposeFromPreset_happyPath() public {
        dao.addPreset("Buy & Burn OMEGA", ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), address(0), "");

        vm.prank(alice);
        uint256 id = dao.proposeFromPreset(1, 100e18, "let's burn OMEGA");

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(uint8(p.actionType), uint8(ITreasuryDAO.ActionType.BuyAndBurn));
        assertEq(p.actionToken, address(burnToken));
        assertEq(p.amount, 100e18);
        assertEq(p.proposer, alice);
    }

    function test_proposeFromPreset_execute() public {
        dao.addPreset("Buy & Burn OMEGA", ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), address(0), "");

        vm.prank(alice);
        uint256 id = dao.proposeFromPreset(1, 100e18, "burn it");
        _voteAndWarp(id);

        dao.executeProposal(id);

        // BuyAndBurn should have burned tokens
        assertEq(burnToken.balanceOf(address(dao)), 0);
    }

    function test_proposeFromPreset_revertsInactivePreset() public {
        dao.addPreset("test", ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), address(0), "");
        dao.removePreset(1);

        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.PresetNotActive.selector);
        dao.proposeFromPreset(1, 100e18, "should fail");
    }

    function test_proposeFromPreset_revertsInvalidPresetId() public {
        vm.prank(alice);
        vm.expectRevert(TreasuryDAO.InvalidPreset.selector);
        dao.proposeFromPreset(99, 100e18, "should fail");
    }

    function test_proposeFromPreset_revertsNotTopStaker() public {
        dao.addPreset("test", ITreasuryDAO.ActionType.BuyAndBurn, address(burnToken), address(0), "");

        vm.prank(nonStaker);
        vm.expectRevert(TreasuryDAO.NotTopStaker.selector);
        dao.proposeFromPreset(1, 100e18, "should fail");
    }

    function test_proposeFromPreset_sendWPLS() public {
        dao.addPreset("Send to treasury", ITreasuryDAO.ActionType.SendPLS, address(0), bob, "");

        vm.prank(alice);
        uint256 id = dao.proposeFromPreset(1, 50e18, "send WPLS");

        ITreasuryDAO.Proposal memory p = dao.proposals(id);
        assertEq(uint8(p.actionType), uint8(ITreasuryDAO.ActionType.SendPLS));
        assertEq(p.target, bob);
        assertEq(p.amount, 50e18);
    }

    function test_proposeFromPreset_tokenTokenLP() public {
        MockERC20 tokenB = new MockERC20("TokenB", "TKB");
        dao.addPreset(
            "OMEGA/HEX LP Burn",
            ITreasuryDAO.ActionType.AddAndBurnLP,
            address(burnToken),
            address(tokenB),
            ""
        );

        vm.prank(alice);
        uint256 id = dao.proposeFromPreset(1, 100e18, "LP burn from preset");
        _voteAndWarp(id);

        dao.executeProposal(id);

        assertEq(mockRouter.lastLPTo(), DEAD);
        assertEq(mockRouter.lastLiqTokenA(), address(burnToken));
        assertEq(mockRouter.lastLiqTokenB(), address(tokenB));
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

    /// @dev Propose with SendPLS defaults
    function _propose(
        address proposer,
        uint256 amount,
        address target,
        string memory desc
    ) internal returns (uint256) {
        vm.prank(proposer);
        return dao.propose(amount, target, desc, ITreasuryDAO.ActionType.SendPLS, address(0), "");
    }

    /// @dev Create a SendPLS proposal, have 5 stakers vote yes, warp past end.
    function _proposeAndPass(
        uint256 amount,
        address target,
        string memory desc
    ) internal returns (uint256) {
        uint256 id = _propose(alice, amount, target, desc);
        _voteAndWarp(id);
        return id;
    }

    /// @dev Create a proposal with a specific action type, have 5 stakers vote yes, warp past end.
    function _proposeAndPassAction(
        uint256 amount,
        address target,
        string memory desc,
        ITreasuryDAO.ActionType actionType,
        address actionToken,
        bytes memory data
    ) internal returns (uint256) {
        vm.prank(alice);
        uint256 id = dao.propose(amount, target, desc, actionType, actionToken, data);
        _voteAndWarp(id);
        return id;
    }

    /// @dev Have 5 stakers vote yes and warp past voting period.
    function _voteAndWarp(uint256 id) internal {
        vm.prank(alice);
        dao.castVote(id, true);
        vm.prank(bob);
        dao.castVote(id, true);
        vm.prank(carol);
        dao.castVote(id, true);
        vm.prank(dave);
        dao.castVote(id, true);
        vm.prank(eve);
        dao.castVote(id, true);

        vm.warp(block.timestamp + 7 days + 1);
    }
}
