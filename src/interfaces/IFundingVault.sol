// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IFundingVault {
  function rebase(int256 valueDelta, uint64 updatedAt) external;
}
