// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal goose-fork MasterChef interface used for pass-through staking
///         (e.g. PulseX MasterChef). `deposit`/`withdraw` automatically harvest
///         the underlying incentive token (INC) to msg.sender.
interface IExternalChef {
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function emergencyWithdraw(uint256 _pid) external;
}
