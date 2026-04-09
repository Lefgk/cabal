// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakingVault} from "./interfaces/IStakingVault.sol";

interface IPulseXRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function WPLS() external pure returns (address);
}

/// @dev Minimal interface for unwrapping WPLS that arrives from tax distributions
///      when the factory transfers WPLS (not raw PLS) to the vault.
interface IWPLS {
    function balanceOf(address) external view returns (uint256);
    function withdraw(uint256) external;
}

/// @title StakingVault
/// @notice Synthetix StakingRewards-style vault with 7-day linear reward drip.
///         Stake an ERC-20 token, earn yield in a different reward token that
///         is released gradually over `rewardsDuration`. Tracks top N stakers
///         for DAO proposal eligibility.
contract StakingVault is IStakingVault, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    IERC20 public immutable STAKING_TOKEN;
    IERC20 public immutable REWARDS_TOKEN;

    // -------------------------------------------------------------------------
    // Reward state (Synthetix pattern)
    // -------------------------------------------------------------------------

    uint256 public rewardsDuration = 7 days;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    /// @notice Running sum of rewards that have been dripped into the accumulator
    ///         but not yet paid out. Invariant:
    ///         totalOwed ==
    ///           sum_i(rewards[i])  // materialized-but-unclaimed
    ///         + sum_i(balance_i * (rewardPerTokenStored - userRewardPerTokenPaid_i) / 1e18)
    ///                              // accrued-but-unmaterialized
    ///         It excludes the future (undripped) portion of the current period,
    ///         which equals `(periodFinish - now) * rewardRate`.
    ///         Needed so `processRewards()` can tell genuinely-new reward tokens
    ///         apart from already-committed ones sitting in the vault balance.
    uint256 public totalOwed;

    // -------------------------------------------------------------------------
    // Staking state
    // -------------------------------------------------------------------------

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    // -------------------------------------------------------------------------
    // Unique staker tracking
    // -------------------------------------------------------------------------

    uint256 public totalStakers;

    // -------------------------------------------------------------------------
    // Top staker tracking (sorted descending by staked amount)
    // -------------------------------------------------------------------------

    uint256 public topStakerCount;
    address[] internal _topStakers;
    mapping(address => bool) internal _isTopStaker;

    // -------------------------------------------------------------------------
    // DEX (for topUp swap)
    // -------------------------------------------------------------------------

    IPulseXRouter public dexRouter;

    // -------------------------------------------------------------------------
    // DAO
    // -------------------------------------------------------------------------

    address public daoAddress;

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    bool public paused;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier notPaused() {
        require(!paused, "StakingVault: paused");
        _;
    }

    /// @notice Runs before `updateReward` in user-facing entry points so that
    ///         any tax tokens the factory has dropped into the vault since the
    ///         last touch are folded into the drip before per-account math.
    ///         This is the self-healing equivalent of ZKP's
    ///         `stakingContract.topUp{value: pls}()` callback — since our v3
    ///         factory token can't call back into the vault, every stake /
    ///         withdraw / getReward picks up new taxes on behalf of stakers.
    modifier autoProcess() {
        _processRewardsIfNew();
        _;
    }

    modifier updateReward(address account) {
        uint256 newRPT = rewardPerToken();
        // When supply is zero, rewardPerToken() returns stored unchanged so the
        // delta is zero; the drip during a zero-supply window is effectively
        // held aside and re-enters via processRewards later.
        if (newRPT > rewardPerTokenStored && _totalSupply > 0) {
            totalOwed += ((newRPT - rewardPerTokenStored) * _totalSupply) / 1e18;
        }
        rewardPerTokenStored = newRPT;
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address _stakingToken,
        address _rewardsToken,
        address _owner,
        uint256 _topCount
    ) Ownable(_owner) {
        require(_stakingToken != address(0), "StakingVault: zero staking token");
        require(_rewardsToken != address(0), "StakingVault: zero rewards token");
        require(_topCount > 0, "StakingVault: zero top count");

        STAKING_TOKEN = IERC20(_stakingToken);
        REWARDS_TOKEN = IERC20(_rewardsToken);
        topStakerCount = _topCount;
    }

    // -------------------------------------------------------------------------
    // Views — Synthetix reward math
    // -------------------------------------------------------------------------

    function totalStaked() external view returns (uint256) {
        return _totalSupply;
    }

    function stakedBalance(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) /
            _totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return
            (_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) /
            1e18 +
            rewards[account];
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    // -------------------------------------------------------------------------
    // Core staking
    // -------------------------------------------------------------------------

    function stake(uint256 amount) external nonReentrant notPaused autoProcess updateReward(msg.sender) {
        require(amount > 0, "StakingVault: zero stake");

        if (_balances[msg.sender] == 0) {
            totalStakers += 1;
        }

        _totalSupply += amount;
        _balances[msg.sender] += amount;

        STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        _updateTopStakers(msg.sender);

        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant autoProcess updateReward(msg.sender) {
        require(amount > 0, "StakingVault: zero withdraw");
        require(_balances[msg.sender] >= amount, "StakingVault: insufficient balance");

        _totalSupply -= amount;
        _balances[msg.sender] -= amount;

        STAKING_TOKEN.safeTransfer(msg.sender, amount);

        if (_balances[msg.sender] == 0) {
            totalStakers -= 1;
            _removeFromTopStakers(msg.sender);
        } else {
            _updateTopStakers(msg.sender);
        }

        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant autoProcess updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            // Round-down dust in totalOwed accounting could otherwise underflow
            // if a single user's payout briefly exceeds the running total. Cap
            // at totalOwed for safety; the dust is bounded by O(num_stakers).
            if (reward > totalOwed) {
                totalOwed = 0;
            } else {
                totalOwed -= reward;
            }
            REWARDS_TOKEN.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    // -------------------------------------------------------------------------
    // Reward injection — Synthetix notifyRewardAmount
    // -------------------------------------------------------------------------

    /// @notice Called by the token contract (or anyone) when reward tokens are
    ///         deposited. Starts or extends the reward drip over `rewardsDuration`.
    ///         Caller must have approved this contract to spend `reward` of REWARDS_TOKEN.
    function notifyRewardAmount(uint256 reward) external nonReentrant updateReward(address(0)) {
        require(reward > 0, "StakingVault: zero reward");

        REWARDS_TOKEN.safeTransferFrom(msg.sender, address(this), reward);

        _startRewardPeriod(reward);

        emit RewardAdded(reward);
    }

    // -------------------------------------------------------------------------
    // Top-up — receive PLS, swap to reward token, auto-notify (ZKP pattern)
    // -------------------------------------------------------------------------

    /// @notice Receives PLS, swaps to the reward token via PulseX, and starts
    ///         (or extends) the reward drip automatically.
    function topUp() public payable nonReentrant updateReward(address(0)) {
        require(msg.value > 0, "StakingVault: zero PLS");
        require(address(dexRouter) != address(0), "StakingVault: no router");

        uint256 balBefore = REWARDS_TOKEN.balanceOf(address(this));

        // Swap PLS → WPLS → reward token via PulseX
        address[] memory path = new address[](2);
        path[0] = dexRouter.WPLS();
        path[1] = address(REWARDS_TOKEN);

        dexRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value}(
            0, // amountOutMin — accept any amount (MEV protection not critical for reward injection)
            path,
            address(this),
            block.timestamp
        );

        uint256 balAfter = REWARDS_TOKEN.balanceOf(address(this));
        uint256 reward = balAfter - balBefore;
        require(reward > 0, "StakingVault: swap yielded zero");

        _startRewardPeriod(reward);

        emit ToppedUp(msg.value, reward);
        emit RewardAdded(reward);
    }

    /// @dev Accept PLS silently. We MUST NOT auto-call topUp() from receive()
    ///      because the token factory's tax distribution routes PLS into the
    ///      vault mid-transfer (e.g. inside stake()/transferFrom). topUp() is
    ///      nonReentrant, and stake()/withdraw()/getReward() are nonReentrant,
    ///      so re-entering topUp() during a stake call would revert with
    ///      ReentrancyGuardReentrantCall and brick every user action.
    ///      Instead, accumulated PLS is swapped to REWARDS_TOKEN via
    ///      `_swapPendingPLSForRewardToken()` inside `_processRewardsIfNew()`,
    ///      which is invoked by the `autoProcess` modifier on the next
    ///      stake/withdraw/getReward (or by an explicit processRewards()).
    receive() external payable {}

    // -------------------------------------------------------------------------
    // Process rewards — auto-notify when reward tokens are sent directly
    // -------------------------------------------------------------------------

    /// @notice Detects any excess reward tokens in the contract (sent by the
    ///         token factory tax system) and starts/extends the reward drip.
    ///         Anyone can call this — it simply processes already-received tokens.
    function processRewards() external nonReentrant {
        uint256 oldPeriodFinish = periodFinish;
        _processRewardsIfNew();
        // Signal to callers that this was a no-op: useful for keepers /
        // explicit triggers. User-facing entry points (stake / withdraw /
        // getReward) use the internal helper directly and never revert.
        require(
            periodFinish > oldPeriodFinish,
            "StakingVault: no new rewards"
        );
    }

    /// @dev Snaps global reward state to `now`, then starts a new reward
    ///      period if there are uncommitted reward tokens sitting in the
    ///      vault. Safe to call repeatedly and safe to call when there is
    ///      nothing to do (no revert on no-op).
    /// @dev Swap any PLS sitting in the vault (deposited via receive() by
    ///      factory tax distributions) into REWARDS_TOKEN via the configured
    ///      router. Also unwraps any WPLS the factory may have transferred
    ///      directly. Wrapped in try/catch so a broken router/pair never
    ///      bricks stake/withdraw/getReward.
    function _swapPendingPLSForRewardToken() internal {
        if (address(dexRouter) == address(0)) return;

        // Unwrap any WPLS balance first.
        address wpls = dexRouter.WPLS();
        uint256 wplsBal = IWPLS(wpls).balanceOf(address(this));
        if (wplsBal > 0) {
            try IWPLS(wpls).withdraw(wplsBal) {} catch {}
        }

        uint256 plsBal = address(this).balance;
        if (plsBal == 0) return;

        // If rewards token is WPLS, no swap needed (already unwrapped above
        // into PLS which we'll re-wrap below by skipping swap). Handle the
        // degenerate "reward token is WPLS" case by re-wrapping.
        if (address(REWARDS_TOKEN) == wpls) {
            try IWPLS(wpls).withdraw(0) {} catch {} // no-op, just to appease linters
            // Re-wrap via a direct call: use dexRouter's receive-less path by
            // swapping PLS→WPLS is equivalent to deposit. Simplest: skip the
            // swap entirely — the balance is already WPLS after the wrap.
            // (We don't support this edge case optimally since our design
            // targets eHEX. Leave plsBal held until admin intervenes.)
            return;
        }

        address[] memory path = new address[](2);
        path[0] = wpls;
        path[1] = address(REWARDS_TOKEN);

        try dexRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: plsBal}(
            0, // accept any amount — MEV protection isn't critical for reward injection
            path,
            address(this),
            block.timestamp
        ) {} catch {
            // Swap failed (pair missing, liquidity thin, etc). Leave PLS in
            // place for the next attempt — DO NOT revert the parent action.
        }
    }

    function _processRewardsIfNew() internal {
        // --- 0. Convert any pending PLS (from factory tax) into reward token. ---
        _swapPendingPLSForRewardToken();

        // --- 1. Snap global state to now (same as updateReward(address(0))). ---
        uint256 newRPT = rewardPerToken();
        if (newRPT > rewardPerTokenStored && _totalSupply > 0) {
            totalOwed += ((newRPT - rewardPerTokenStored) * _totalSupply) / 1e18;
        }
        rewardPerTokenStored = newRPT;
        lastUpdateTime = lastTimeRewardApplicable();

        // --- 2. Look for uncommitted reward tokens. ---
        uint256 balance = REWARDS_TOKEN.balanceOf(address(this));
        // When the staking token IS the reward token, the staked principal sits
        // in the same balance — exclude it so stakes can't be paid out as rewards.
        if (address(STAKING_TOKEN) == address(REWARDS_TOKEN)) {
            balance -= _totalSupply;
        }

        uint256 futureDrip;
        if (block.timestamp < periodFinish) {
            futureDrip = (periodFinish - block.timestamp) * rewardRate;
        }
        uint256 committed = totalOwed + futureDrip;

        if (balance > committed) {
            uint256 reward = balance - committed;
            // Dust tolerance: the rewardPerToken / totalOwed math floor-divides
            // and leaves ≤ O(rewardsDuration) wei of residual between committed
            // and balance. Only restart the drip if the excess would produce a
            // nonzero per-second rate (>= 1 wei / second). This also stops the
            // autoProcess hook from spuriously extending periodFinish on every
            // user action when no real tax has arrived.
            if (reward >= rewardsDuration) {
                _startRewardPeriod(reward);
                emit RewardAdded(reward);
            }
        }
    }

    // -------------------------------------------------------------------------
    // DAO / top staker queries
    // -------------------------------------------------------------------------

    function isTopStaker(address account) external view returns (bool) {
        return _isTopStaker[account];
    }

    function getTopStakers() external view returns (address[] memory) {
        return _topStakers;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setDexRouter(address router) external onlyOwner {
        address old = address(dexRouter);
        dexRouter = IPulseXRouter(router);
        emit DexRouterUpdated(old, router);
    }

    function setDaoAddress(address dao) external onlyOwner {
        address old = daoAddress;
        daoAddress = dao;
        emit DaoAddressUpdated(old, dao);
    }

    function setTopStakerCount(uint256 count) external onlyOwner {
        require(count > 0, "StakingVault: zero top count");
        uint256 old = topStakerCount;
        topStakerCount = count;

        while (_topStakers.length > count) {
            address removed = _topStakers[_topStakers.length - 1];
            _isTopStaker[removed] = false;
            _topStakers.pop();
        }

        emit TopStakerCountUpdated(old, count);
    }

    function setRewardsDuration(uint256 duration) external onlyOwner {
        require(
            block.timestamp > periodFinish,
            "StakingVault: period not finished"
        );
        require(duration > 0, "StakingVault: zero duration");
        rewardsDuration = duration;
        emit RewardsDurationUpdated(duration);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /// @notice Recover tokens accidentally sent to this contract.
    ///         Cannot recover the staking token.
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(STAKING_TOKEN), "StakingVault: cannot recover staking token");
        IERC20(token).safeTransfer(owner(), amount);
    }

    // -------------------------------------------------------------------------
    // View helpers (interface compliance)
    // -------------------------------------------------------------------------

    function stakingToken() external view returns (address) {
        return address(STAKING_TOKEN);
    }

    function rewardsToken() external view returns (address) {
        return address(REWARDS_TOKEN);
    }

    // -------------------------------------------------------------------------
    // Internal — reward period management
    // -------------------------------------------------------------------------

    function _startRewardPeriod(uint256 reward) internal {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        uint256 balance = REWARDS_TOKEN.balanceOf(address(this));
        if (address(STAKING_TOKEN) == address(REWARDS_TOKEN)) {
            balance -= _totalSupply;
        }
        // Solvency: the new rewardRate must be sustainable from the funds that
        // are NOT already promised to existing stakers (totalOwed).
        require(balance >= totalOwed, "StakingVault: insolvent");
        uint256 available = balance - totalOwed;
        require(
            rewardRate <= available / rewardsDuration,
            "StakingVault: reward too high"
        );

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
    }

    // -------------------------------------------------------------------------
    // Internal — top staker management
    // -------------------------------------------------------------------------

    function _updateTopStakers(address account) internal {
        uint256 bal = _balances[account];
        uint256 len = _topStakers.length;
        uint256 maxLen = topStakerCount;

        // If already in list, remove first then re-insert.
        if (_isTopStaker[account]) {
            uint256 idx;
            for (uint256 i; i < len; ++i) {
                if (_topStakers[i] == account) {
                    idx = i;
                    break;
                }
            }
            for (uint256 i = idx; i < len - 1; ++i) {
                _topStakers[i] = _topStakers[i + 1];
            }
            _topStakers.pop();
            _isTopStaker[account] = false;
            len -= 1;
        }

        // Find insertion index (descending order).
        uint256 insertAt = len;
        for (uint256 i; i < len; ++i) {
            if (bal > _balances[_topStakers[i]]) {
                insertAt = i;
                break;
            }
        }

        if (insertAt >= maxLen) return;

        if (len < maxLen) {
            _topStakers.push(account);
            len += 1;
        } else {
            _isTopStaker[_topStakers[len - 1]] = false;
        }

        for (uint256 i = len - 1; i > insertAt; --i) {
            _topStakers[i] = _topStakers[i - 1];
        }
        _topStakers[insertAt] = account;
        _isTopStaker[account] = true;
    }

    function _removeFromTopStakers(address account) internal {
        if (!_isTopStaker[account]) return;

        uint256 len = _topStakers.length;
        for (uint256 i; i < len; ++i) {
            if (_topStakers[i] == account) {
                for (uint256 j = i; j < len - 1; ++j) {
                    _topStakers[j] = _topStakers[j + 1];
                }
                _topStakers.pop();
                _isTopStaker[account] = false;
                return;
            }
        }
    }
}
