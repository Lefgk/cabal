// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IStakingVault.sol";
import "./interfaces/ITreasuryDAO.sol";

/// @dev Minimal interface for WPLS wrap/unwrap
interface IWPLS {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title TreasuryDAO
/// @notice PTGC-style DAO for PulseChain. Treasury receives 1% tax from the token;
///         stakers vote on how to spend it. Proposals simply send WPLS to a target address.
contract TreasuryDAO is ITreasuryDAO, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    //  State
    // ---------------------------------------------------------------

    IStakingVault public stakingVault;
    address public wpls;
    address public token;
    address public dexRouter;

    uint256 public votingPeriod = 7 days;
    uint256 public quorumBps = 1000; // 10 %

    uint256 public override proposalCount;
    uint256 public lockedAmount;

    uint256 public constant MIN_VOTING_PERIOD = 1 days;
    uint256 public constant MAX_VOTING_PERIOD = 30 days;
    uint256 public constant MAX_QUORUM_BPS = 5000; // 50 %
    uint256 public constant BPS_DENOMINATOR = 10_000;

    mapping(uint256 => Proposal) internal _proposals;
    mapping(uint256 => mapping(address => Receipt)) internal _receipts;

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    constructor(
        address _stakingVault,
        address _token,
        address _wpls,
        address _dexRouter
    ) Ownable(msg.sender) {
        require(_stakingVault != address(0), "zero vault");
        require(_token != address(0), "zero token");
        require(_wpls != address(0), "zero wpls");
        require(_dexRouter != address(0), "zero router");

        stakingVault = IStakingVault(_stakingVault);
        token = _token;
        wpls = _wpls;
        dexRouter = _dexRouter;
    }

    // ---------------------------------------------------------------
    //  Treasury: receive funds
    // ---------------------------------------------------------------

    /// @notice Accept raw PLS and auto-wrap to WPLS.
    receive() external payable {
        if (msg.value > 0) {
            IWPLS(wpls).deposit{value: msg.value}();
            emit PLSReceived(msg.sender, msg.value);
        }
    }

    /// @notice Deposit WPLS directly into the treasury.
    function depositWPLS(uint256 amount) external override {
        require(amount > 0, "zero amount");
        IERC20(wpls).safeTransferFrom(msg.sender, address(this), amount);
        emit WPLSDeposited(msg.sender, amount);
    }

    /// @notice WPLS balance not reserved by active proposals.
    function availableBalance() public view override returns (uint256) {
        uint256 bal = IERC20(wpls).balanceOf(address(this));
        return bal > lockedAmount ? bal - lockedAmount : 0;
    }

    // ---------------------------------------------------------------
    //  Proposal lifecycle
    // ---------------------------------------------------------------

    /// @notice Create a proposal. Only top stakers may propose.
    ///         Proposals send WPLS to a target address. The description
    ///         should explain the purpose (buy & burn, marketing, LP, etc).
    function propose(
        uint256 amount,
        address target,
        string calldata description
    ) external override returns (uint256) {
        require(stakingVault.isTopStaker(msg.sender), "not top staker");
        require(amount > 0, "zero amount");
        require(target != address(0), "target required");
        require(bytes(description).length > 0, "empty description");

        // Ensure treasury can cover the proposal
        require(amount <= availableBalance(), "insufficient available balance");

        // Lock funds
        lockedAmount += amount;

        uint256 id = proposalCount++;
        uint256 start = block.timestamp;
        uint256 end = start + votingPeriod;

        _proposals[id] = Proposal({
            id: id,
            amount: amount,
            target: target,
            description: description,
            proposer: msg.sender,
            yesVotes: 0,
            noVotes: 0,
            startTime: start,
            endTime: end,
            executed: false
        });

        emit ProposalCreated(id, msg.sender, amount, target, description, start, end);
        return id;
    }

    /// @notice Cast a yes/no vote weighted by staked balance.
    function castVote(uint256 proposalId, bool support) external override {
        require(proposalId < proposalCount, "invalid proposal");

        ProposalState s = state(proposalId);
        require(s == ProposalState.Active, "voting not active");

        Receipt storage receipt = _receipts[proposalId][msg.sender];
        require(!receipt.hasVoted, "already voted");

        uint256 weight = stakingVault.stakedBalance(msg.sender);
        require(weight > 0, "no voting power");

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.weight = weight;

        if (support) {
            _proposals[proposalId].yesVotes += weight;
        } else {
            _proposals[proposalId].noVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /// @notice Execute a proposal that has succeeded. Anyone may call.
    ///         Sends WPLS to the proposal's target address.
    function executeProposal(uint256 proposalId) external override nonReentrant {
        require(proposalId < proposalCount, "invalid proposal");
        require(state(proposalId) == ProposalState.Succeeded, "not succeeded");

        Proposal storage p = _proposals[proposalId];
        p.executed = true;

        // Unlock the reserved funds (they are about to be spent)
        lockedAmount -= p.amount;

        // Transfer WPLS to target
        IERC20(wpls).safeTransfer(p.target, p.amount);

        emit ProposalExecuted(proposalId, p.amount, p.target);
    }

    /// @notice Unlock funds for a defeated proposal. Anyone may call.
    function unlockDefeated(uint256 proposalId) external {
        require(proposalId < proposalCount, "invalid proposal");
        require(state(proposalId) == ProposalState.Defeated, "not defeated");

        Proposal storage p = _proposals[proposalId];
        // Use the executed flag to ensure we only unlock once
        require(!p.executed, "already unlocked");
        p.executed = true; // reuse flag to prevent double-unlock

        lockedAmount -= p.amount;
        emit FundsUnlocked(proposalId, p.amount);
        emit ProposalDefeated(proposalId);
    }

    // ---------------------------------------------------------------
    //  State queries
    // ---------------------------------------------------------------

    function proposals(uint256 proposalId) external view override returns (Proposal memory) {
        require(proposalId < proposalCount, "invalid proposal");
        return _proposals[proposalId];
    }

    function getReceipt(
        uint256 proposalId,
        address voter
    ) external view override returns (Receipt memory) {
        return _receipts[proposalId][voter];
    }

    /// @notice Derive the current state of a proposal.
    function state(uint256 proposalId) public view override returns (ProposalState) {
        require(proposalId < proposalCount, "invalid proposal");

        Proposal storage p = _proposals[proposalId];

        // Already executed (or unlocked-defeated via the reused flag)
        if (p.executed) {
            if (p.yesVotes > p.noVotes && _meetsQuorum(p)) {
                return ProposalState.Executed;
            }
            return ProposalState.Defeated;
        }

        // Voting still open
        if (block.timestamp <= p.endTime) {
            if (block.timestamp < p.startTime) {
                return ProposalState.Pending;
            }
            return ProposalState.Active;
        }

        // Voting ended, not yet executed
        if (p.yesVotes > p.noVotes && _meetsQuorum(p)) {
            return ProposalState.Succeeded;
        }

        return ProposalState.Defeated;
    }

    function _meetsQuorum(Proposal storage p) internal view returns (bool) {
        uint256 totalVotes = p.yesVotes + p.noVotes;
        uint256 staked = stakingVault.totalStaked();
        if (staked == 0) return false;
        return totalVotes * BPS_DENOMINATOR >= quorumBps * staked;
    }

    // ---------------------------------------------------------------
    //  Admin
    // ---------------------------------------------------------------

    function setStakingVault(address vault) external override onlyOwner {
        require(vault != address(0), "zero address");
        emit StakingVaultUpdated(address(stakingVault), vault);
        stakingVault = IStakingVault(vault);
    }

    function setVotingPeriod(uint256 period) external override onlyOwner {
        require(period >= MIN_VOTING_PERIOD && period <= MAX_VOTING_PERIOD, "out of range");
        emit VotingPeriodUpdated(votingPeriod, period);
        votingPeriod = period;
    }

    function setQuorumBps(uint256 bps) external override onlyOwner {
        require(bps > 0 && bps <= MAX_QUORUM_BPS, "invalid bps");
        emit QuorumBpsUpdated(quorumBps, bps);
        quorumBps = bps;
    }

    function setDexRouter(address router) external override onlyOwner {
        require(router != address(0), "zero address");
        emit DexRouterUpdated(dexRouter, router);
        dexRouter = router;
    }

    function setWpls(address _wpls) external override onlyOwner {
        require(_wpls != address(0), "zero address");
        emit WplsAddressUpdated(wpls, _wpls);
        wpls = _wpls;
    }

    function setToken(address _token) external override onlyOwner {
        require(_token != address(0), "zero address");
        emit TokenAddressUpdated(token, _token);
        token = _token;
    }
}
