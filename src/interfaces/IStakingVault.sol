// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStakingVault {
    // --- Events ---
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event DaoAddressUpdated(address indexed oldDao, address indexed newDao);
    event TopStakerCountUpdated(uint256 oldCount, uint256 newCount);
    event Paused(bool isPaused);

    // --- Core staking ---
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
    function exit() external;

    // --- Reward injection (called by token tax / anyone) ---
    function notifyRewardAmount(uint256 reward) external;

    // --- Views ---
    function earned(address account) external view returns (uint256);
    function lastTimeRewardApplicable() external view returns (uint256);
    function rewardPerToken() external view returns (uint256);
    function getRewardForDuration() external view returns (uint256);

    // --- DAO / top staker queries ---
    function isTopStaker(address account) external view returns (bool);
    function totalStakers() external view returns (uint256);
    function getTopStakers() external view returns (address[] memory);

    // --- Admin ---
    function setDaoAddress(address dao) external;
    function setTopStakerCount(uint256 count) external;
    function setRewardsDuration(uint256 duration) external;
    function setPaused(bool _paused) external;
    function recoverERC20(address token, uint256 amount) external;

    // --- State views ---
    function stakingToken() external view returns (address);
    function rewardsToken() external view returns (address);
    function stakedBalance(address user) external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function daoAddress() external view returns (address);
    function topStakerCount() external view returns (uint256);
    function rewardRate() external view returns (uint256);
    function rewardsDuration() external view returns (uint256);
    function periodFinish() external view returns (uint256);
}
