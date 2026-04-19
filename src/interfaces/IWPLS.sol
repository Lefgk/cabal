// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal interface for Wrapped PLS (WPLS)
interface IWPLS {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
