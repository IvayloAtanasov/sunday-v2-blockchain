// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface ILendingVault {
    function rebase(int256 valueDelta, uint64 updatedAt) external;

    /// `LendingVault.Phase` as its ABI representation, so this interface stays standalone
    function phase() external view returns (uint8);

    function lastRebasedAt() external view returns (uint64);

    function rebaseAdapter() external view returns (address);
}
