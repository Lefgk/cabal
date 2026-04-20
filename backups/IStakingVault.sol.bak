// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStakingVault {
    // --- Structs ---
    struct LockPosition {
        uint256 amount;
        uint256 lockTime;
        uint256 unlockTime;
        uint256 duration;
        uint256 multiplier;      // BPS (10000 = 1x)
        uint256 rewardPerTokenPaid;
        uint256 pendingRewards;
    }

    // --- Events ---
    event Staked(address indexed user, uint256 amount);
    event StakedLocked(address indexed user, uint256 amount, uint256 duration, uint256 multiplier, uint256 lockId);
    event Withdrawn(address indexed user, uint256 amount, uint256 fee);
    event Unlocked(address indexed user, uint256 lockId, uint256 amount, uint256 penalty);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward);
    event ToppedUp(uint256 plsAmount, uint256 rewardAmount);
    event PenaltyDistributed(uint256 total, uint256 toStakers, uint256 toBurn, uint256 toDao, uint256 toDev);
    event RewardsDurationUpdated(uint256 newDuration);
    event DaoAddressUpdated(address indexed oldDao, address indexed newDao);
    event DexRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event DevWalletUpdated(address indexed oldDev, address indexed newDev);
    event TopStakerCountUpdated(uint256 oldCount, uint256 newCount);
    event Paused(bool isPaused);
    event VoteLocked(address indexed voter, uint256 lockUntil);
    event PenaltySwapped(uint256 stakingTokenAmount, uint256 rewardTokenReceived);
    event PenaltySwapFailed(uint256 amount);
    event PLSSwapped(uint256 plsAmount, uint256 rewardTokenReceived);
    event PenaltyTokensRescued(uint256 amount, address recipient);

    // --- Core staking ---
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
    function exit() external;

    // --- Lock staking ---
    function stakeLocked(uint256 amount, uint256 duration) external;
    function unlock(uint256[] calldata lockIds) external;

    // --- Reward injection (called by token tax / anyone) ---
    function notifyRewardAmount(uint256 reward) external;
    function topUp() external payable;
    function processRewards() external;

    // --- Views ---
    function earned(address account) external view returns (uint256);
    function lastTimeRewardApplicable() external view returns (uint256);
    function rewardPerToken() external view returns (uint256);
    function getRewardForDuration() external view returns (uint256);

    // --- DAO / top staker queries ---
    function isTopStaker(address account) external view returns (bool);
    function totalStakers() external view returns (uint256);
    function getTopStakers() external view returns (address[] memory);

    // --- Vote lock ---
    function lockForVote(address voter, uint256 lockUntil) external;

    // --- Admin ---
    function setDexRouter(address router) external;
    function setDaoAddress(address dao) external;
    function setDevWallet(address dev) external;
    function setTopStakerCount(uint256 count) external;
    function setRewardsDuration(uint256 duration) external;
    function setPaused(bool _paused) external;
    function recoverERC20(address token, uint256 amount) external;
    function rescuePendingPenaltyTokens(address recipient) external;

    // --- State views ---
    function stakingToken() external view returns (address);
    function rewardsToken() external view returns (address);
    function stakedBalance(address user) external view returns (uint256);
    function flexBalance(address user) external view returns (uint256);
    function effectiveBalance(address user) external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function totalRawStaked() external view returns (uint256);
    function totalEffectiveStaked() external view returns (uint256);
    function daoAddress() external view returns (address);
    function devWallet() external view returns (address);
    function topStakerCount() external view returns (uint256);
    function voteLockEnd(address user) external view returns (uint256);
    function stakeTimestamp(address user) external view returns (uint256);
    function rewardRate() external view returns (uint256);
    function rewardsDuration() external view returns (uint256);
    function periodFinish() external view returns (uint256);

    // --- Lock views ---
    function lockCount(address user) external view returns (uint256);
    function getLock(address user, uint256 lockId) external view returns (LockPosition memory);
    function getUserLocks(address user) external view returns (LockPosition[] memory);
    function pendingRewardForLock(address user, uint256 lockId) external view returns (uint256);
    function getMultiplierForDuration(uint256 duration) external pure returns (uint256);
    function getLockTiers() external pure returns (uint256[] memory durations, uint256[] memory multipliers);
}
