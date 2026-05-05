// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakingVault} from "./interfaces/IStakingVault.sol";
import {IPulseXRouter} from "./interfaces/IPulseXRouter.sol";
import {IWPLS} from "./interfaces/IWPLS.sol";

/// @title StakingVault
/// @notice Flex-only staking vault. Synthetix rewardPerToken accumulator over the
///         single staked balance per user. 1% withdraw fee burned.
///         Reward token funded via notifyRewardAmount() or topUp() (PLS → reward swap).
contract StakingVault is IStakingVault, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error IsPaused();
    error ZeroRewardsToken();
    error InvalidTopCount();
    error ZeroStake();
    error ZeroWithdraw();
    error InsufficientBalance();
    error ZeroReward();
    error ZeroPLS();
    error NoRouter();
    error SwapYieldedZero();
    error NoNewRewards();
    error TokenAlreadySet();
    error ZeroAddress();
    error PeriodNotFinished();
    error ZeroDuration();
    error CannotRecoverStakingToken();
    error CannotRecoverRewardsToken();
    error Insolvent();
    error RewardTooHigh();

    // -------------------------------------------------------------------------
    // Tokens
    // -------------------------------------------------------------------------

    IERC20 public STAKING_TOKEN;
    IERC20 public immutable REWARDS_TOKEN;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant BPS = 10_000;
    /// @dev Precision multiplier for rewardPerToken accumulator.
    ///      Must be large enough to avoid truncation when reward token has
    ///      fewer decimals than staking token (e.g. pHEX 8 dec vs TSTT 18 dec).
    uint256 internal constant PRECISION = 1e30;
    uint256 public constant MAX_TOP_STAKER_COUNT = 100;
    uint256 public constant FLEX_WITHDRAW_FEE_BPS = 100; // 1%
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;

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

    /// @notice Running sum of rewards dripped into the accumulator but not yet paid out.
    uint256 public totalOwed;

    // -------------------------------------------------------------------------
    // Staking state
    // -------------------------------------------------------------------------

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    /// @notice Minimum PLS amount to trigger an auto-swap (skip dust).
    uint256 public minSwapThreshold = 1e18;

    // -------------------------------------------------------------------------
    // Unique staker tracking
    // -------------------------------------------------------------------------

    uint256 public totalStakers;
    mapping(address => uint256) public stakeTimestamp;

    // -------------------------------------------------------------------------
    // Top staker tracking (sorted descending by balance)
    // -------------------------------------------------------------------------

    uint256 public topStakerCount;
    address[] internal _topStakers;
    mapping(address => bool) internal _isTopStaker;

    // -------------------------------------------------------------------------
    // DEX (for topUp swap)
    // -------------------------------------------------------------------------

    IPulseXRouter public dexRouter;

    // -------------------------------------------------------------------------
    // DAO + Dev (kept for tax routing / admin reads)
    // -------------------------------------------------------------------------

    address public daoAddress;
    address public devWallet = 0xD6f895e6dE0a34c556774E0818e2a8C2E510aF5B;

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    bool public paused;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier notPaused() {
        if (paused) revert IsPaused();
        _;
    }

    modifier autoProcess() {
        _processRewardsIfNew();
        _;
    }

    modifier updateReward(address account) {
        uint256 newRPT = rewardPerToken();
        if (newRPT > rewardPerTokenStored && _totalSupply > 0) {
            totalOwed += ((newRPT - rewardPerTokenStored) * _totalSupply) / PRECISION;
        }
        rewardPerTokenStored = newRPT;
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            _materializeRewards(account);
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
        if (_rewardsToken == address(0)) revert ZeroRewardsToken();
        if (_topCount == 0 || _topCount > MAX_TOP_STAKER_COUNT) revert InvalidTopCount();

        if (_stakingToken != address(0)) {
            STAKING_TOKEN = IERC20(_stakingToken);
        }
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
            ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) /
            _totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        uint256 currentRPT = rewardPerToken();
        return (_balances[account] * (currentRPT - userRewardPerTokenPaid[account])) / PRECISION + rewards[account];
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    // -------------------------------------------------------------------------
    // Core staking — Flex (1% withdraw fee burned)
    // -------------------------------------------------------------------------

    function stake(uint256 amount) external nonReentrant notPaused autoProcess updateReward(msg.sender) {
        if (amount == 0) revert ZeroStake();

        // Fee-on-transfer safe: credit only the amount actually received.
        uint256 balBefore = STAKING_TOKEN.balanceOf(address(this));
        STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = STAKING_TOKEN.balanceOf(address(this)) - balBefore;
        if (received == 0) revert ZeroStake();

        if (_balances[msg.sender] == 0) {
            totalStakers += 1;
            stakeTimestamp[msg.sender] = block.timestamp;
        }

        _balances[msg.sender] += received;
        _totalSupply += received;

        _updateTopStakers(msg.sender);

        emit Staked(msg.sender, received);
    }

    function withdraw(uint256 amount) public nonReentrant autoProcess updateReward(msg.sender) {
        if (amount == 0) revert ZeroWithdraw();
        if (_balances[msg.sender] < amount) revert InsufficientBalance();

        _balances[msg.sender] -= amount;
        _totalSupply -= amount;

        uint256 fee = (amount * FLEX_WITHDRAW_FEE_BPS) / BPS;
        if (fee > 0) {
            _burnTokens(fee);
        }
        STAKING_TOKEN.safeTransfer(msg.sender, amount - fee);

        if (_balances[msg.sender] == 0) {
            totalStakers -= 1;
            stakeTimestamp[msg.sender] = 0;
            _removeFromTopStakers(msg.sender);
        } else {
            _updateTopStakers(msg.sender);
        }

        emit Withdrawn(msg.sender, amount, fee);
    }

    function getReward() public nonReentrant autoProcess updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            totalOwed = totalOwed > reward ? totalOwed - reward : 0;
            REWARDS_TOKEN.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /// @dev Try ERC20 burn(amount); fall back to transfer-to-dead if unsupported.
    function _burnTokens(uint256 amount) internal {
        (bool ok, ) = address(STAKING_TOKEN).call(
            abi.encodeWithSignature("burn(uint256)", amount)
        );
        if (!ok) {
            STAKING_TOKEN.safeTransfer(DEAD, amount);
        }
    }

    // -------------------------------------------------------------------------
    // Reward injection — Synthetix notifyRewardAmount
    // -------------------------------------------------------------------------

    function notifyRewardAmount(uint256 reward) external onlyOwner nonReentrant updateReward(address(0)) {
        if (reward == 0) revert ZeroReward();

        REWARDS_TOKEN.safeTransferFrom(msg.sender, address(this), reward);

        _startRewardPeriod(reward);

        emit RewardAdded(reward);
    }

    // -------------------------------------------------------------------------
    // Top-up — receive PLS, swap to reward token, auto-notify
    // -------------------------------------------------------------------------

    function topUp() public payable nonReentrant updateReward(address(0)) {
        if (msg.value == 0) revert ZeroPLS();
        if (address(dexRouter) == address(0)) revert NoRouter();

        uint256 balBefore = REWARDS_TOKEN.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = WPLS;
        path[1] = address(REWARDS_TOKEN);

        dexRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value}(
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 balAfter = REWARDS_TOKEN.balanceOf(address(this));
        uint256 reward = balAfter - balBefore;
        if (reward == 0) revert SwapYieldedZero();

        _startRewardPeriod(reward);

        emit ToppedUp(msg.value, reward);
        emit RewardAdded(reward);
    }

    receive() external payable {}

    // -------------------------------------------------------------------------
    // Process rewards — auto-notify when reward tokens are sent directly
    // -------------------------------------------------------------------------

    function processRewards() external nonReentrant {
        uint256 oldPeriodFinish = periodFinish;
        _processRewardsIfNew();
        if (periodFinish <= oldPeriodFinish) revert NoNewRewards();
    }

    function _swapPendingPLSForRewardToken() internal {
        if (address(dexRouter) == address(0)) return;

        // If rewards ARE WPLS, leave WPLS as-is — don't unwrap
        if (address(REWARDS_TOKEN) == WPLS) return;

        address[] memory path = new address[](2);
        path[0] = WPLS;
        path[1] = address(REWARDS_TOKEN);

        // Swap any excess WPLS held by the vault directly (no unwrap/rewrap)
        uint256 wplsBal = IWPLS(WPLS).balanceOf(address(this));
        // If staking token is WPLS, exclude user deposits
        if (address(STAKING_TOKEN) == WPLS) {
            wplsBal = wplsBal > _totalSupply ? wplsBal - _totalSupply : 0;
        }
        if (wplsBal >= minSwapThreshold) {
            IERC20(WPLS).approve(address(dexRouter), wplsBal);
            uint256 rewardBefore = REWARDS_TOKEN.balanceOf(address(this));
            try dexRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                wplsBal, 0, path, address(this), block.timestamp
            ) {
                uint256 received = REWARDS_TOKEN.balanceOf(address(this)) - rewardBefore;
                emit PLSSwapped(wplsBal, received);
            } catch {
                IERC20(WPLS).approve(address(dexRouter), 0);
            }
        }

        // Swap any raw PLS held by the vault
        uint256 plsBal = address(this).balance;
        if (plsBal >= minSwapThreshold) {
            uint256 rewardBefore = REWARDS_TOKEN.balanceOf(address(this));
            try dexRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: plsBal}(
                0, path, address(this), block.timestamp
            ) {
                uint256 received = REWARDS_TOKEN.balanceOf(address(this)) - rewardBefore;
                emit PLSSwapped(plsBal, received);
            } catch {}
        }
    }

    function _processRewardsIfNew() internal {
        // 0. Swap pending PLS
        _swapPendingPLSForRewardToken();

        // 1. Snap global state to now
        uint256 newRPT = rewardPerToken();
        if (newRPT > rewardPerTokenStored && _totalSupply > 0) {
            totalOwed += ((newRPT - rewardPerTokenStored) * _totalSupply) / PRECISION;
        }
        rewardPerTokenStored = newRPT;
        lastUpdateTime = lastTimeRewardApplicable();

        // 2. Look for uncommitted reward tokens
        uint256 balance = REWARDS_TOKEN.balanceOf(address(this));
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
            if (reward >= rewardsDuration) {
                _startRewardPeriod(reward);
                emit RewardAdded(reward);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Top staker queries
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

    function setDevWallet(address dev) external onlyOwner {
        address old = devWallet;
        devWallet = dev;
        emit DevWalletUpdated(old, dev);
    }

    function setTopStakerCount(uint256 count) external onlyOwner {
        if (count == 0 || count > MAX_TOP_STAKER_COUNT) revert InvalidTopCount();
        uint256 old = topStakerCount;
        topStakerCount = count;

        while (_topStakers.length > count) {
            address removed = _topStakers[_topStakers.length - 1];
            _isTopStaker[removed] = false;
            _topStakers.pop();
        }

        emit TopStakerCountUpdated(old, count);
    }

    /// @notice Set the staking token (one-time only, for deploy-before-token flow).
    function setStakingToken(address _stakingToken) external onlyOwner {
        if (address(STAKING_TOKEN) != address(0)) revert TokenAlreadySet();
        if (_stakingToken == address(0)) revert ZeroAddress();
        STAKING_TOKEN = IERC20(_stakingToken);
    }

    function setMinSwapThreshold(uint256 threshold) external onlyOwner {
        minSwapThreshold = threshold;
    }

    function setRewardsDuration(uint256 duration) external onlyOwner {
        if (block.timestamp <= periodFinish) revert PeriodNotFinished();
        if (duration == 0) revert ZeroDuration();
        rewardsDuration = duration;
        emit RewardsDurationUpdated(duration);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function recoverERC20(address token, uint256 amount) external onlyOwner {
        if (token == address(STAKING_TOKEN)) revert CannotRecoverStakingToken();
        if (token == address(REWARDS_TOKEN)) revert CannotRecoverRewardsToken();
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
    // Internal — reward materialization
    // -------------------------------------------------------------------------

    function _materializeRewards(address account) internal {
        uint256 currentRPT = rewardPerTokenStored;
        uint256 delta = currentRPT - userRewardPerTokenPaid[account];
        if (delta > 0) {
            rewards[account] += (_balances[account] * delta) / PRECISION;
        }
        userRewardPerTokenPaid[account] = currentRPT;
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
        if (balance < totalOwed) revert Insolvent();
        uint256 available = balance - totalOwed;
        if (rewardRate > available / rewardsDuration) revert RewardTooHigh();

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
    }

    // -------------------------------------------------------------------------
    // Internal — top staker management (ranked by raw balance)
    // -------------------------------------------------------------------------

    function _updateTopStakers(address account) internal {
        uint256 bal = _balances[account];
        uint256 len = _topStakers.length;
        uint256 maxLen = topStakerCount;

        if (_isTopStaker[account]) {
            uint256 idx;
            for (uint256 i; i < len;) {
                if (_topStakers[i] == account) {
                    idx = i;
                    break;
                }
                unchecked { ++i; }
            }
            for (uint256 i = idx; i < len - 1;) {
                _topStakers[i] = _topStakers[i + 1];
                unchecked { ++i; }
            }
            _topStakers.pop();
            _isTopStaker[account] = false;
            len -= 1;
        }

        uint256 insertAt = len;
        for (uint256 i; i < len;) {
            if (bal > _balances[_topStakers[i]]) {
                insertAt = i;
                break;
            }
            unchecked { ++i; }
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
        for (uint256 i; i < len;) {
            if (_topStakers[i] == account) {
                for (uint256 j = i; j < len - 1;) {
                    _topStakers[j] = _topStakers[j + 1];
                    unchecked { ++j; }
                }
                _topStakers.pop();
                _isTopStaker[account] = false;
                return;
            }
            unchecked { ++i; }
        }
    }
}
