// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITreasuryDAO {
    // --- Enums ---
    enum ProposalType {
        BuyAndBurn,
        Marketing,
        LPExpansion,
        Custom
    }

    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Executed
    }

    // --- Structs ---
    struct Proposal {
        uint256 id;
        ProposalType pType;
        uint256 amount;
        address target;
        string description;
        address proposer;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 startTime;
        uint256 endTime;
        bool executed;
    }

    struct Receipt {
        bool hasVoted;
        bool support;
        uint256 weight;
    }

    // --- Events ---
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        ProposalType pType,
        uint256 amount,
        address target,
        string description,
        uint256 startTime,
        uint256 endTime
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 weight
    );
    event ProposalExecuted(uint256 indexed proposalId, ProposalType pType, uint256 amount, address target);
    event ProposalDefeated(uint256 indexed proposalId);
    event FundsUnlocked(uint256 indexed proposalId, uint256 amount);
    event WPLSDeposited(address indexed from, uint256 amount);
    event PLSReceived(address indexed from, uint256 amount);
    event StakingVaultUpdated(address indexed oldVault, address indexed newVault);
    event VotingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event QuorumBpsUpdated(uint256 oldBps, uint256 newBps);
    event DexRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event WplsAddressUpdated(address indexed oldWpls, address indexed newWpls);
    event TokenAddressUpdated(address indexed oldToken, address indexed newToken);

    // --- Proposal lifecycle ---
    function propose(
        ProposalType pType,
        uint256 amount,
        address target,
        string calldata description
    ) external returns (uint256);

    function castVote(uint256 proposalId, bool support) external;

    function executeProposal(uint256 proposalId) external;

    // --- Treasury ---
    function depositWPLS(uint256 amount) external;
    function availableBalance() external view returns (uint256);

    // --- State queries ---
    function proposals(uint256 proposalId) external view returns (Proposal memory);
    function proposalCount() external view returns (uint256);
    function state(uint256 proposalId) external view returns (ProposalState);
    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory);

    // --- Admin ---
    function setStakingVault(address vault) external;
    function setVotingPeriod(uint256 period) external;
    function setQuorumBps(uint256 bps) external;
    function setDexRouter(address router) external;
    function setWpls(address wpls) external;
    function setToken(address token) external;
}
