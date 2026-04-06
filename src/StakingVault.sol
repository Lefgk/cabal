// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakingVault} from "./interfaces/IStakingVault.sol";

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

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
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

    function stake(uint256 amount) external nonReentrant notPaused updateReward(msg.sender) {
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

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
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

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
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

        if (block.timestamp >= periodFinish) {
            // No active period — start fresh.
            rewardRate = reward / rewardsDuration;
        } else {
            // Active period — add leftover + new reward and restart timer.
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        // Ensure the contract actually holds enough to cover the full period.
        uint256 balance = REWARDS_TOKEN.balanceOf(address(this));
        require(
            rewardRate <= balance / rewardsDuration,
            "StakingVault: reward too high"
        );

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardAdded(reward);
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
