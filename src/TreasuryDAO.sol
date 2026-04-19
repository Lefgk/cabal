// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IStakingVault.sol";
import "./interfaces/ITreasuryDAO.sol";
import "./interfaces/IPulseXRouter.sol";

/// @title TreasuryDAO
/// @notice PTGC-style DAO for PulseChain. Treasury receives 1% tax from the token;
///         stakers vote on how to spend it. Uses 65% supermajority + min voter count
///         instead of quorum-of-total-staked. 1 active proposal per wallet.
contract TreasuryDAO is ITreasuryDAO, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    //  Constants
    // ---------------------------------------------------------------

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ---------------------------------------------------------------
    //  State
    // ---------------------------------------------------------------

    IStakingVault public stakingVault;
    address public immutable wpls;
    address public token;
    address public dexRouter;

    uint256 public votingPeriod = 7 days;
    uint256 public supermajorityPct = 65;  // yes/(yes+no) >= 65%
    uint256 public minVoters = 5;          // minimum unique voters to pass

    uint256 public override proposalCount;
    uint256 public lockedAmount;

    uint256 public maxProposalAmount = 100_000_000 ether; // 100M WPLS
    uint256 public minProposalAmount = 1 ether;           // 1 WPLS

    uint256 public minVotingPeriod = 5 minutes;
    uint256 public maxVotingPeriod = 30 days;

    mapping(uint256 => Proposal) internal _proposals;
    mapping(uint256 => mapping(address => Receipt)) internal _receipts;
    mapping(address => uint256) public override latestProposalIds;

    /// @notice IDs of proposals that are still active or awaiting unlock.
    uint256[] internal _activeProposalIds;

    uint256 public presetCount;
    mapping(uint256 => Preset) internal _presets;

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

    /// @notice Accept raw PLS into the treasury.
    receive() external payable {
        if (msg.value > 0) {
            emit PLSReceived(msg.sender, msg.value);
        }
    }

    /// @notice Native PLS balance not reserved by active proposals.
    function availableBalance() public view override returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > lockedAmount ? bal - lockedAmount : 0;
    }

    // ---------------------------------------------------------------
    //  Proposal lifecycle
    // ---------------------------------------------------------------

    /// @notice Create a proposal. Only top stakers may propose.
    ///         1 active proposal per wallet (PTGC-style).
    function propose(
        uint256 amount,
        address target,
        string calldata description,
        ActionType actionType,
        address actionToken,
        bytes calldata data
    ) external override returns (uint256) {
        return _propose(amount, target, description, actionType, actionToken, data);
    }

    /// @notice Create a proposal from a registered preset.
    function proposeFromPreset(
        uint256 presetId,
        uint256 amount,
        string calldata description
    ) external override returns (uint256) {
        require(presetId >= 1 && presetId <= presetCount, "invalid preset");
        Preset storage preset = _presets[presetId];
        require(preset.active, "preset not active");

        return _propose(amount, preset.target, description, preset.actionType, preset.actionToken, preset.data);
    }

    /// @dev Shared proposal creation logic for both propose() and proposeFromPreset().
    function _propose(
        uint256 amount,
        address target,
        string memory description,
        ActionType actionType,
        address actionToken,
        bytes memory data
    ) internal returns (uint256) {
        require(stakingVault.isTopStaker(msg.sender), "not top staker");
        require(bytes(description).length > 0, "empty description");

        // Per-type validation
        if (actionType == ActionType.SendPLS) {
            require(target != address(0), "target required");
            require(amount >= minProposalAmount, "below min amount");
            require(amount <= maxProposalAmount, "above max amount");
        } else if (actionType == ActionType.BuyAndBurn) {
            require(actionToken != address(0), "actionToken required");
            require(actionToken != wpls, "actionToken cannot be WPLS");
            require(amount >= minProposalAmount, "below min amount");
            require(amount <= maxProposalAmount, "above max amount");
        } else if (actionType == ActionType.AddAndBurnLP) {
            require(actionToken != address(0), "actionToken required");
            require(amount >= minProposalAmount, "below min amount");
            require(amount <= maxProposalAmount, "above max amount");
        } else if (actionType == ActionType.Custom) {
            require(target != address(0), "target required");
            require(data.length > 0, "data required");
            // amount can be 0 for Custom
        }

        // 1 active proposal per wallet
        uint256 latestId = latestProposalIds[msg.sender];
        if (latestId != 0) {
            require(state(latestId) != ProposalState.Active, "one active proposal per proposer");
        }

        // Auto-unlock any defeated/executed proposals to free locked funds
        _cleanupStaleProposals();

        // Ensure treasury can cover the proposal
        if (amount > 0) {
            require(amount <= availableBalance(), "insufficient available balance");
        }

        // Lock funds
        lockedAmount += amount;

        proposalCount++;
        uint256 id = proposalCount; // IDs start at 1 (0 = "no proposal")
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
            executed: false,
            voters: 0,
            actionType: actionType,
            actionToken: actionToken,
            data: data
        });

        latestProposalIds[msg.sender] = id;
        _activeProposalIds.push(id);

        emit ProposalCreated(id, msg.sender, amount, target, description, start, end);
        return id;
    }

    /// @notice Cast a yes/no vote weighted by staked balance.
    function castVote(uint256 proposalId, bool support) external override {
        require(proposalId >= 1 && proposalId <= proposalCount, "invalid proposal");

        ProposalState s = state(proposalId);
        require(s == ProposalState.Active, "voting not active");

        Receipt storage receipt = _receipts[proposalId][msg.sender];
        require(!receipt.hasVoted, "already voted");

        uint256 weight = stakingVault.effectiveBalance(msg.sender);
        require(weight > 0, "no voting power");
        require(
            stakingVault.stakeTimestamp(msg.sender) != 0 &&
            stakingVault.stakeTimestamp(msg.sender) < block.timestamp,
            "must stake at least 1 block before voting"
        );

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.weight = weight;

        Proposal storage p = _proposals[proposalId];

        if (support) {
            p.yesVotes += weight;
        } else {
            p.noVotes += weight;
        }
        p.voters += 1;

        stakingVault.lockForVote(msg.sender, p.endTime);

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /// @notice Execute a proposal that has succeeded. Anyone may call.
    ///         Dispatches to the appropriate action executor based on actionType.
    function executeProposal(uint256 proposalId) external override nonReentrant {
        require(proposalId >= 1 && proposalId <= proposalCount, "invalid proposal");
        require(state(proposalId) == ProposalState.Succeeded, "not succeeded");

        Proposal storage p = _proposals[proposalId];
        p.executed = true;

        // Unlock the reserved funds (they are about to be spent)
        lockedAmount -= p.amount;

        if (p.actionType == ActionType.SendPLS) {
            _executeSendPLS(p);
        } else if (p.actionType == ActionType.BuyAndBurn) {
            _executeBuyAndBurn(p);
        } else if (p.actionType == ActionType.AddAndBurnLP) {
            _executeAddAndBurnLP(p);
        } else if (p.actionType == ActionType.Custom) {
            _executeCustom(p);
        }

        emit ProposalExecuted(proposalId, p.amount, p.target);
    }

    /// @notice Unlock funds for a defeated proposal. Anyone may call.
    function unlockDefeated(uint256 proposalId) public {
        require(proposalId >= 1 && proposalId <= proposalCount, "invalid proposal");
        require(state(proposalId) == ProposalState.Defeated, "not defeated");

        Proposal storage p = _proposals[proposalId];
        // Use the executed flag to ensure we only unlock once
        require(!p.executed, "already unlocked");
        p.executed = true; // reuse flag to prevent double-unlock

        lockedAmount -= p.amount;
        emit FundsUnlocked(proposalId, p.amount);
        emit ProposalDefeated(proposalId);
    }

    /// @notice Batch-unlock defeated proposals to free locked treasury funds.
    function unlockDefeatedBatch(uint256[] calldata proposalIds) external {
        for (uint256 i; i < proposalIds.length;) {
            unlockDefeated(proposalIds[i]);
            unchecked { ++i; }
        }
    }

    /// @dev Sweep _activeProposalIds: unlock defeated, remove executed/unlocked.
    function _cleanupStaleProposals() internal {
        uint256 len = _activeProposalIds.length;
        uint256 i;
        while (i < len) {
            uint256 pid = _activeProposalIds[i];
            Proposal storage p = _proposals[pid];

            if (p.executed) {
                // Already executed or unlocked -- just remove from tracking
                _activeProposalIds[i] = _activeProposalIds[len - 1];
                _activeProposalIds.pop();
                len--;
                continue;
            }

            ProposalState s = state(pid);
            if (s == ProposalState.Defeated) {
                // Auto-unlock defeated proposal
                p.executed = true;
                lockedAmount -= p.amount;
                emit FundsUnlocked(pid, p.amount);
                emit ProposalDefeated(pid);
                _activeProposalIds[i] = _activeProposalIds[len - 1];
                _activeProposalIds.pop();
                len--;
                continue;
            }

            i++;
        }
    }

    // ---------------------------------------------------------------
    //  Action executors
    // ---------------------------------------------------------------

    /// @dev Send PLS to the proposal's target address.
    function _executeSendPLS(Proposal storage p) internal {
        (bool ok,) = p.target.call{value: p.amount}("");
        require(ok, "PLS transfer failed");
    }

    /// @dev Swap PLS→token on PulseX → try burn(), fallback to DEAD.
    function _executeBuyAndBurn(Proposal storage p) internal {
        // Swap PLS → token to this contract
        address[] memory path = new address[](2);
        path[0] = wpls;
        path[1] = p.actionToken;

        IPulseXRouter(dexRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: p.amount}(
            0,
            path,
            address(this),
            block.timestamp
        );

        // Burn acquired tokens
        uint256 tokenBal = IERC20(p.actionToken).balanceOf(address(this));
        if (tokenBal > 0) {
            _burnTokens(p.actionToken, tokenBal);
        }
    }

    /// @dev Swap PLS for token(s) → add liquidity → LP to DEAD.
    ///      If target == address(0): token/PLS pair via addLiquidityETH.
    ///      If target != address(0): token/token pair via addLiquidity.
    function _executeAddAndBurnLP(Proposal storage p) internal {
        uint256 half = p.amount / 2;
        uint256 otherHalf = p.amount - half;

        if (p.target == address(0)) {
            // ---- Token/PLS pair via addLiquidityETH ----

            // Swap half PLS → token
            address[] memory path = new address[](2);
            path[0] = wpls;
            path[1] = p.actionToken;

            IPulseXRouter(dexRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: half}(
                0, path, address(this), block.timestamp
            );

            uint256 tokenBal = IERC20(p.actionToken).balanceOf(address(this));
            IERC20(p.actionToken).approve(dexRouter, tokenBal);

            // Add liquidity — LP tokens go to DEAD
            IPulseXRouter(dexRouter).addLiquidityETH{value: otherHalf}(
                p.actionToken, tokenBal, 0, 0, DEAD, block.timestamp
            );

            // Burn any leftover tokens
            uint256 leftoverTokens = IERC20(p.actionToken).balanceOf(address(this));
            if (leftoverTokens > 0) {
                _burnTokens(p.actionToken, leftoverTokens);
            }

            // Revoke dangling approval
            IERC20(p.actionToken).approve(dexRouter, 0);
        } else {
            // ---- Token/token pair via addLiquidity ----
            address tokenA = p.actionToken;
            address tokenB = p.target;

            // Swap half PLS → tokenA
            address[] memory pathA = new address[](2);
            pathA[0] = wpls;
            pathA[1] = tokenA;
            IPulseXRouter(dexRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: half}(
                0, pathA, address(this), block.timestamp
            );

            // Swap other half PLS → tokenB
            address[] memory pathB = new address[](2);
            pathB[0] = wpls;
            pathB[1] = tokenB;
            IPulseXRouter(dexRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: otherHalf}(
                0, pathB, address(this), block.timestamp
            );

            uint256 balA = IERC20(tokenA).balanceOf(address(this));
            uint256 balB = IERC20(tokenB).balanceOf(address(this));
            IERC20(tokenA).approve(dexRouter, balA);
            IERC20(tokenB).approve(dexRouter, balB);

            // addLiquidity — LP to DEAD
            IPulseXRouter(dexRouter).addLiquidity(
                tokenA, tokenB, balA, balB, 0, 0, DEAD, block.timestamp
            );

            // Burn leftovers
            uint256 leftA = IERC20(tokenA).balanceOf(address(this));
            if (leftA > 0) _burnTokens(tokenA, leftA);
            uint256 leftB = IERC20(tokenB).balanceOf(address(this));
            if (leftB > 0) _burnTokens(tokenB, leftB);

            // Revoke approvals
            IERC20(tokenA).approve(dexRouter, 0);
            IERC20(tokenB).approve(dexRouter, 0);
        }
    }

    /// @dev Execute target.call{value}(data).
    function _executeCustom(Proposal storage p) internal {
        (bool success,) = p.target.call{value: p.amount}(p.data);
        require(success, "custom call failed");
    }

    // ---------------------------------------------------------------
    //  Internal helpers
    // ---------------------------------------------------------------

    /// @dev Try ERC20 burn(amount); fall back to transfer-to-DEAD if unsupported.
    function _burnTokens(address tokenAddr, uint256 amount) internal {
        (bool ok,) = tokenAddr.call(
            abi.encodeWithSignature("burn(uint256)", amount)
        );
        if (!ok) {
            IERC20(tokenAddr).safeTransfer(DEAD, amount);
        }
    }

    // ---------------------------------------------------------------
    //  State queries
    // ---------------------------------------------------------------

    function proposals(uint256 proposalId) external view override returns (Proposal memory) {
        require(proposalId >= 1 && proposalId <= proposalCount, "invalid proposal");
        return _proposals[proposalId];
    }

    function getReceipt(
        uint256 proposalId,
        address voter
    ) external view override returns (Receipt memory) {
        return _receipts[proposalId][voter];
    }

    /// @notice Yes-vote percentage: yesVotes * 100 / (yesVotes + noVotes).
    function votingPercent(uint256 proposalId) public view override returns (uint256) {
        require(proposalId >= 1 && proposalId <= proposalCount, "invalid proposal");
        Proposal storage p = _proposals[proposalId];
        uint256 totalVotes = p.yesVotes + p.noVotes;
        if (totalVotes == 0) return 0;
        return p.yesVotes * 100 / totalVotes;
    }

    /// @notice Derive the current state of a proposal.
    function state(uint256 proposalId) public view override returns (ProposalState) {
        require(proposalId >= 1 && proposalId <= proposalCount, "invalid proposal");

        Proposal storage p = _proposals[proposalId];

        // Already executed (or unlocked-defeated via the reused flag)
        if (p.executed) {
            if (_passesSupermajority(p)) {
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
        if (_passesSupermajority(p)) {
            return ProposalState.Succeeded;
        }

        return ProposalState.Defeated;
    }

    /// @dev PTGC-style: yes > no, yes% >= supermajorityPct, voters >= minVoters.
    function _passesSupermajority(Proposal storage p) internal view returns (bool) {
        if (p.yesVotes <= p.noVotes) return false;
        if (p.voters < minVoters) return false;
        uint256 totalVotes = p.yesVotes + p.noVotes;
        if (totalVotes == 0) return false;
        return p.yesVotes * 100 / totalVotes >= supermajorityPct;
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
        require(period >= minVotingPeriod && period <= maxVotingPeriod, "out of range");
        emit VotingPeriodUpdated(votingPeriod, period);
        votingPeriod = period;
    }

    function setMinVoters(uint256 count) external override onlyOwner {
        require(count > 0, "zero voters");
        emit MinVotersUpdated(minVoters, count);
        minVoters = count;
    }

    function setSupermajorityPct(uint256 pct) external override onlyOwner {
        require(pct >= 51 && pct <= 100, "out of range");
        emit SupermajorityPctUpdated(supermajorityPct, pct);
        supermajorityPct = pct;
    }

    function setMaxProposalAmount(uint256 amount) external override onlyOwner {
        require(amount >= minProposalAmount, "max < min");
        emit MaxProposalAmountUpdated(maxProposalAmount, amount);
        maxProposalAmount = amount;
    }

    function setMinProposalAmount(uint256 amount) external override onlyOwner {
        require(amount > 0 && amount <= maxProposalAmount, "invalid min");
        emit MinProposalAmountUpdated(minProposalAmount, amount);
        minProposalAmount = amount;
    }

    function setDexRouter(address router) external override onlyOwner {
        require(router != address(0), "zero address");
        emit DexRouterUpdated(dexRouter, router);
        dexRouter = router;
    }

    function setToken(address _token) external override onlyOwner {
        require(_token != address(0), "zero address");
        emit TokenAddressUpdated(token, _token);
        token = _token;
    }

    // ---------------------------------------------------------------
    //  Presets
    // ---------------------------------------------------------------

    /// @notice Register a new proposal preset. Only owner.
    function addPreset(
        string calldata name,
        ActionType actionType,
        address actionToken,
        address target,
        bytes calldata data
    ) external override onlyOwner returns (uint256 presetId) {
        require(bytes(name).length > 0, "empty name");

        // Per-type validation (same rules as proposals)
        if (actionType == ActionType.SendPLS) {
            require(target != address(0), "target required");
        } else if (actionType == ActionType.BuyAndBurn) {
            require(actionToken != address(0), "actionToken required");
            require(actionToken != wpls, "actionToken cannot be WPLS");
        } else if (actionType == ActionType.AddAndBurnLP) {
            require(actionToken != address(0), "actionToken required");
        } else if (actionType == ActionType.Custom) {
            require(target != address(0), "target required");
            require(data.length > 0, "data required");
        }

        presetCount++;
        presetId = presetCount;

        _presets[presetId] = Preset({
            name: name,
            actionType: actionType,
            actionToken: actionToken,
            target: target,
            data: data,
            active: true
        });

        emit PresetAdded(presetId, name, actionType);
    }

    /// @notice Deactivate a preset. Only owner.
    function removePreset(uint256 presetId) external override onlyOwner {
        require(presetId >= 1 && presetId <= presetCount, "invalid preset");
        require(_presets[presetId].active, "already removed");
        _presets[presetId].active = false;
        emit PresetRemoved(presetId);
    }

    /// @notice Get a single preset by ID.
    function getPreset(uint256 presetId) external view override returns (Preset memory) {
        require(presetId >= 1 && presetId <= presetCount, "invalid preset");
        return _presets[presetId];
    }

    /// @notice Get all active presets.
    function getActivePresets() external view override returns (Preset[] memory) {
        uint256 activeCount;
        for (uint256 i = 1; i <= presetCount; i++) {
            if (_presets[i].active) activeCount++;
        }

        Preset[] memory result = new Preset[](activeCount);
        uint256 idx;
        for (uint256 i = 1; i <= presetCount; i++) {
            if (_presets[i].active) {
                result[idx] = _presets[i];
                idx++;
            }
        }
        return result;
    }
}
