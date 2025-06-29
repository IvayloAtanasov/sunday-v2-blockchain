// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "../interfaces/IERC20.sol";
import { OwnerIsCreator } from "lib/chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";

/**
 * THIS IS AN EXAMPLE CONTRACT THAT USES HARDCODED VALUES FOR CLARITY.
 * THIS IS AN EXAMPLE CONTRACT THAT USES UN-AUDITED CODE.
 * DO NOT USE THIS CODE IN PRODUCTION.
 *
 * Token contract would need to have some funds locked for gas. Therefore there is also needed a way to withdraw them.
 * Forked from: https://cll-devrel.gitbook.io/tokenized-rwa-bootcamp-2024/day-1/exercise-1-cross-chain-real-estate
 */
contract Withdraw is OwnerIsCreator {
    error NothingToWithdraw();
    error FailedToWithdrawEth(address owner, address target, uint256 value);

    function withdraw(address _beneficiary) public onlyOwner {
        uint256 amount = address(this).balance;

        if (amount == 0) revert NothingToWithdraw();

        (bool sent,) = _beneficiary.call{value: amount}("");

        if (!sent) revert FailedToWithdrawEth(msg.sender, _beneficiary, amount);
    }

    function withdrawToken(address _beneficiary, address _token) public onlyOwner {
        uint256 amount = IERC20(_token).balanceOf(address(this));

        if (amount == 0) revert NothingToWithdraw();

        IERC20(_token).transfer(_beneficiary, amount);
    }
}
