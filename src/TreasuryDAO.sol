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
    //  Custom errors
    // ---------------------------------------------------------------

    error ZeroVault();
    error ZeroWPLS();
    error ZeroRouter();
    error InvalidPreset();
    error PresetNotActive();
    error NotTopStaker();
    error EmptyDescription();
    error TargetRequired();
    error BelowMinAmount();
    error AboveMaxAmount();
    error ActionTokenRequired();
    error ActionTokenCannotBeWPLS();
    error DataRequired();
    error OneActiveProposalPerProposer();
    error InsufficientAvailableBalance();
    error InvalidProposal();
    error VotingNotActive();
    error AlreadyVoted();
    error NoVotingPower();
    error MustStakeBeforeVoting();
    error NotSucceeded();
    error NotDefeated();
    error NotExpired();
    error AlreadyExpired();
    error AlreadyUnlocked();
    error PLSTransferFailed();
    error CustomCallFailed();
    error ZeroAddress();
    error OutOfRange();
    error ZeroVoters();
    error MaxBelowMin();
    error InvalidMin();
    error EmptyName();
    error AlreadyRemoved();
    error MarketingWalletNotSet();
    error TokenNotWhitelisted();

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
    address public override marketingWallet;

    uint256 public votingPeriod = 7 days;
    uint256 public supermajorityPct = 65;  // yes/(yes+no) >= 65%
    uint256 public minVoters = 5;          // minimum unique voters to pass
    uint256 public executionWindow = 7 days; // time after voting ends to execute before expiry

    mapping(address => bool) public whitelistedTokens;

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
        if (_stakingVault == address(0)) revert ZeroVault();
        if (_wpls == address(0)) revert ZeroWPLS();
        if (_dexRouter == address(0)) revert ZeroRouter();

        stakingVault = IStakingVault(_stakingVault);
        token = _token;
        wpls = _wpls;
        dexRouter = _dexRouter;
        marketingWallet = 0x442604B9eA04719B9440F380eAAAA533bBBD70AC;

        // Default whitelisted tokens
        whitelistedTokens[0x90F055196778e541018482213Ca50648cEA1a050] = true; // ZKP
        whitelistedTokens[0x15D38573d2feeb82e7ad5187aB8c1D52810B1f07] = true; // USDC
        whitelistedTokens[0x0Cb6F5a34ad42ec934882A05265A7d5F59b51A2f] = true; // USDT
        whitelistedTokens[0xefD766cCb38EaF1dfd701853BFCe31359239F305] = true; // DAI
        whitelistedTokens[0x6B175474E89094C44Da98b954EedeAC495271d0F] = true; // pDAI
        whitelistedTokens[0xF6f8Db0aBa00007681F8fAF16A0FDa1c9B030b11] = true; // PRVX
        whitelistedTokens[0xA1077a294dDE1B09bB078844df40758a5D0f9a27] = true; // WPLS
        whitelistedTokens[0x95B303987A60C71504D99Aa1b13B4DA07b0790ab] = true; // PLSX
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
        if (presetId < 1 || presetId > presetCount) revert InvalidPreset();
        Preset storage preset = _presets[presetId];
        if (!preset.active) revert PresetNotActive();

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
        if (!stakingVault.isTopStaker(msg.sender)) revert NotTopStaker();
        if (bytes(description).length == 0) revert EmptyDescription();

        // Per-type validation
        if (actionType == ActionType.SendPLS) {
            if (marketingWallet == address(0)) revert MarketingWalletNotSet();
            target = marketingWallet;
            if (amount < minProposalAmount) revert BelowMinAmount();
            if (amount > maxProposalAmount) revert AboveMaxAmount();
        } else if (actionType == ActionType.BuyAndBurn) {
            if (actionToken == address(0)) revert ActionTokenRequired();
            if (actionToken == wpls) revert ActionTokenCannotBeWPLS();
            if (!whitelistedTokens[actionToken]) revert TokenNotWhitelisted();
            if (amount < minProposalAmount) revert BelowMinAmount();
            if (amount > maxProposalAmount) revert AboveMaxAmount();
        } else if (actionType == ActionType.AddAndBurnLP) {
            if (actionToken == address(0)) revert ActionTokenRequired();
            if (!whitelistedTokens[actionToken]) revert TokenNotWhitelisted();
            if (target != address(0) && !whitelistedTokens[target]) revert TokenNotWhitelisted();
            if (amount < minProposalAmount) revert BelowMinAmount();
            if (amount > maxProposalAmount) revert AboveMaxAmount();
        } else if (actionType == ActionType.Custom) {
            if (target == address(0)) revert TargetRequired();
            if (data.length == 0) revert DataRequired();
            // amount can be 0 for Custom
        }

        // 1 active proposal per wallet
        uint256 latestId = latestProposalIds[msg.sender];
        if (latestId != 0) {
            if (state(latestId) == ProposalState.Active) revert OneActiveProposalPerProposer();
        }

        // Auto-unlock any defeated/executed proposals to free locked funds
        _cleanupStaleProposals();

        // Ensure treasury can cover the proposal
        if (amount > 0) {
            if (amount > availableBalance()) revert InsufficientAvailableBalance();
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
            data: data,
            expired: false
        });

        latestProposalIds[msg.sender] = id;
        _activeProposalIds.push(id);

        emit ProposalCreated(id, msg.sender, amount, target, description, start, end);
        return id;
    }

    /// @notice Cast a yes/no vote weighted by staked balance.
    function castVote(uint256 proposalId, bool support) external override {
        if (proposalId < 1 || proposalId > proposalCount) revert InvalidProposal();

        ProposalState s = state(proposalId);
        if (s != ProposalState.Active) revert VotingNotActive();

        Receipt storage receipt = _receipts[proposalId][msg.sender];
        if (receipt.hasVoted) revert AlreadyVoted();

        uint256 weight = stakingVault.effectiveBalance(msg.sender);
        if (weight == 0) revert NoVotingPower();
        if (
            stakingVault.stakeTimestamp(msg.sender) == 0 ||
            stakingVault.stakeTimestamp(msg.sender) >= block.timestamp
        ) revert MustStakeBeforeVoting();

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
        if (proposalId < 1 || proposalId > proposalCount) revert InvalidProposal();
        if (state(proposalId) != ProposalState.Succeeded) revert NotSucceeded();

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
        if (proposalId < 1 || proposalId > proposalCount) revert InvalidProposal();
        if (state(proposalId) != ProposalState.Defeated) revert NotDefeated();

        Proposal storage p = _proposals[proposalId];
        // Use the executed flag to ensure we only unlock once
        if (p.executed) revert AlreadyUnlocked();
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

    /// @notice Refund a succeeded proposal that was never executed within the execution window.
    ///         Anyone may call once state() returns Expired.
    function expireProposal(uint256 proposalId) external override {
        if (proposalId < 1 || proposalId > proposalCount) revert InvalidProposal();
        if (state(proposalId) != ProposalState.Expired) revert NotExpired();
        Proposal storage p = _proposals[proposalId];
        if (p.expired) revert AlreadyExpired();
        p.expired = true;
        lockedAmount -= p.amount;
        emit ProposalExpired(proposalId, p.amount);
    }

    /// @dev Sweep _activeProposalIds: unlock defeated/expired, remove handled proposals.
    function _cleanupStaleProposals() internal {
        uint256 len = _activeProposalIds.length;
        uint256 i;
        while (i < len) {
            uint256 pid = _activeProposalIds[i];
            Proposal storage p = _proposals[pid];

            if (p.executed || p.expired) {
                // Already handled — just remove from tracking
                _activeProposalIds[i] = _activeProposalIds[len - 1];
                _activeProposalIds.pop();
                len--;
                continue;
            }

            ProposalState s = state(pid);
            if (s == ProposalState.Defeated) {
                p.executed = true;
                lockedAmount -= p.amount;
                emit FundsUnlocked(pid, p.amount);
                emit ProposalDefeated(pid);
                _activeProposalIds[i] = _activeProposalIds[len - 1];
                _activeProposalIds.pop();
                len--;
                continue;
            }
            if (s == ProposalState.Expired) {
                p.expired = true;
                lockedAmount -= p.amount;
                emit ProposalExpired(pid, p.amount);
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
        if (!ok) revert PLSTransferFailed();
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
        if (!success) revert CustomCallFailed();
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
        if (proposalId < 1 || proposalId > proposalCount) revert InvalidProposal();
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
        if (proposalId < 1 || proposalId > proposalCount) revert InvalidProposal();
        Proposal storage p = _proposals[proposalId];
        uint256 totalVotes = p.yesVotes + p.noVotes;
        if (totalVotes == 0) return 0;
        return p.yesVotes * 100 / totalVotes;
    }

    /// @notice Derive the current state of a proposal.
    function state(uint256 proposalId) public view override returns (ProposalState) {
        if (proposalId < 1 || proposalId > proposalCount) revert InvalidProposal();

        Proposal storage p = _proposals[proposalId];

        // Explicitly expired (funds already unlocked via expireProposal)
        if (p.expired) return ProposalState.Expired;

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
            // Execution window passed — anyone can call expireProposal to reclaim funds
            if (block.timestamp > p.endTime + executionWindow) return ProposalState.Expired;
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
        if (vault == address(0)) revert ZeroAddress();
        emit StakingVaultUpdated(address(stakingVault), vault);
        stakingVault = IStakingVault(vault);
    }

    function setVotingPeriod(uint256 period) external override onlyOwner {
        if (period < minVotingPeriod || period > maxVotingPeriod) revert OutOfRange();
        emit VotingPeriodUpdated(votingPeriod, period);
        votingPeriod = period;
    }

    function setMinVoters(uint256 count) external override onlyOwner {
        if (count == 0) revert ZeroVoters();
        emit MinVotersUpdated(minVoters, count);
        minVoters = count;
    }

    function setSupermajorityPct(uint256 pct) external override onlyOwner {
        if (pct < 51 || pct > 100) revert OutOfRange();
        emit SupermajorityPctUpdated(supermajorityPct, pct);
        supermajorityPct = pct;
    }

    function setMaxProposalAmount(uint256 amount) external override onlyOwner {
        if (amount < minProposalAmount) revert MaxBelowMin();
        emit MaxProposalAmountUpdated(maxProposalAmount, amount);
        maxProposalAmount = amount;
    }

    function setMinProposalAmount(uint256 amount) external override onlyOwner {
        if (amount == 0 || amount > maxProposalAmount) revert InvalidMin();
        emit MinProposalAmountUpdated(minProposalAmount, amount);
        minProposalAmount = amount;
    }

    function setDexRouter(address router) external override onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        emit DexRouterUpdated(dexRouter, router);
        dexRouter = router;
    }

    function setToken(address _token) external override onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        emit TokenAddressUpdated(token, _token);
        token = _token;
    }

    function setMarketingWallet(address wallet) external override onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        emit MarketingWalletUpdated(marketingWallet, wallet);
        marketingWallet = wallet;
    }

    function setExecutionWindow(uint256 window) external override onlyOwner {
        if (window < 1 hours || window > 30 days) revert OutOfRange();
        emit ExecutionWindowUpdated(executionWindow, window);
        executionWindow = window;
    }

    function addWhitelistedToken(address tokenAddr) external override onlyOwner {
        if (tokenAddr == address(0)) revert ZeroAddress();
        whitelistedTokens[tokenAddr] = true;
        emit TokenWhitelisted(tokenAddr);
    }

    function removeWhitelistedToken(address tokenAddr) external override onlyOwner {
        if (tokenAddr == address(0)) revert ZeroAddress();
        whitelistedTokens[tokenAddr] = false;
        emit TokenRemovedFromWhitelist(tokenAddr);
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
        if (bytes(name).length == 0) revert EmptyName();

        // Per-type validation (same rules as proposals)
        if (actionType == ActionType.SendPLS) {
            if (marketingWallet == address(0)) revert MarketingWalletNotSet();
            target = marketingWallet;
        } else if (actionType == ActionType.BuyAndBurn) {
            if (actionToken == address(0)) revert ActionTokenRequired();
            if (actionToken == wpls) revert ActionTokenCannotBeWPLS();
            if (!whitelistedTokens[actionToken]) revert TokenNotWhitelisted();
        } else if (actionType == ActionType.AddAndBurnLP) {
            if (actionToken == address(0)) revert ActionTokenRequired();
            if (!whitelistedTokens[actionToken]) revert TokenNotWhitelisted();
            if (target != address(0) && !whitelistedTokens[target]) revert TokenNotWhitelisted();
        } else if (actionType == ActionType.Custom) {
            if (target == address(0)) revert TargetRequired();
            if (data.length == 0) revert DataRequired();
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
        if (presetId < 1 || presetId > presetCount) revert InvalidPreset();
        if (!_presets[presetId].active) revert AlreadyRemoved();
        _presets[presetId].active = false;
        emit PresetRemoved(presetId);
    }

    /// @notice Get a single preset by ID.
    function getPreset(uint256 presetId) external view override returns (Preset memory) {
        if (presetId < 1 || presetId > presetCount) revert InvalidPreset();
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
