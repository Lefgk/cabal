// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal goose-fork MasterChef interface used for pass-through staking
///         (e.g. PulseX MasterChef). `deposit`/`withdraw` automatically harvest
///         the underlying incentive token (INC) to msg.sender.
interface IExternalChef {
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function emergencyWithdraw(uint256 _pid) external;

    /// @notice PulseX MC pool count (used for V4 auto-discovery scan).
    function poolLength() external view returns (uint256);

    /// @notice PulseX MC pool layout: (lpToken, allocPoint, lastRewardBlock, accIncPerShare).
    function poolInfo(uint256 _pid) external view returns (
        address lpToken,
        uint256 allocPoint,
        uint256 lastRewardBlock,
        uint256 accIncPerShare
    );
}
