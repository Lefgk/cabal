// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITreasuryDAO {
    // --- Enums ---
    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Executed
    }

    enum ActionType {
        SendPLS,        // send PLS to target
        BuyAndBurn,     // swap PLS→token on PulseX → tokens to DEAD
        AddAndBurnLP,   // swap half for token → addLiquidityETH → LP to DEAD
        Custom          // target.call{value}(data), fully open
    }

    // --- Structs ---
    struct Proposal {
        uint256 id;
        uint256 amount;
        address target;
        string description;
        address proposer;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 startTime;
        uint256 endTime;
        bool executed;
        uint256 voters;
        ActionType actionType;
        address actionToken;
        bytes data;
    }

    struct Receipt {
        bool hasVoted;
        bool support;
        uint256 weight;
    }

    struct Preset {
        string name;
        ActionType actionType;
        address actionToken;
        address target;
        bytes data;
        bool active;
    }

    // --- Events ---
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
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
    event ProposalExecuted(uint256 indexed proposalId, uint256 amount, address target);
    event ProposalDefeated(uint256 indexed proposalId);
    event FundsUnlocked(uint256 indexed proposalId, uint256 amount);
    event PLSReceived(address indexed from, uint256 amount);
    event StakingVaultUpdated(address indexed oldVault, address indexed newVault);
    event VotingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event DexRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event TokenAddressUpdated(address indexed oldToken, address indexed newToken);
    event MinVotersUpdated(uint256 oldMin, uint256 newMin);
    event SupermajorityPctUpdated(uint256 oldPct, uint256 newPct);
    event MaxProposalAmountUpdated(uint256 oldMax, uint256 newMax);
    event MinProposalAmountUpdated(uint256 oldMin, uint256 newMin);
    event PresetAdded(uint256 indexed presetId, string name, ActionType actionType);
    event PresetRemoved(uint256 indexed presetId);

    // --- Proposal lifecycle ---
    function propose(
        uint256 amount,
        address target,
        string calldata description,
        ActionType actionType,
        address actionToken,
        bytes calldata data
    ) external returns (uint256);

    function castVote(uint256 proposalId, bool support) external;

    function executeProposal(uint256 proposalId) external;
    function unlockDefeated(uint256 proposalId) external;
    function unlockDefeatedBatch(uint256[] calldata proposalIds) external;

    // --- Treasury ---
    function availableBalance() external view returns (uint256);

    // --- State queries ---
    function proposals(uint256 proposalId) external view returns (Proposal memory);
    function proposalCount() external view returns (uint256);
    function state(uint256 proposalId) external view returns (ProposalState);
    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory);
    function latestProposalIds(address proposer) external view returns (uint256);
    function votingPercent(uint256 proposalId) external view returns (uint256);

    // --- Admin ---
    function setStakingVault(address vault) external;
    function setVotingPeriod(uint256 period) external;
    function setMinVoters(uint256 count) external;
    function setSupermajorityPct(uint256 pct) external;
    function setMaxProposalAmount(uint256 amount) external;
    function setMinProposalAmount(uint256 amount) external;
    function setDexRouter(address router) external;
    function setToken(address token) external;

    // --- Presets ---
    function addPreset(
        string calldata name,
        ActionType actionType,
        address actionToken,
        address target,
        bytes calldata data
    ) external returns (uint256 presetId);
    function removePreset(uint256 presetId) external;
    function proposeFromPreset(uint256 presetId, uint256 amount, string calldata description) external returns (uint256);
    function getPreset(uint256 presetId) external view returns (Preset memory);
    function getActivePresets() external view returns (Preset[] memory);
}
