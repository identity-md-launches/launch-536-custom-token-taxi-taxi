// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The launch registry queried after the token's constructor has run.
interface ILaunchFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}
