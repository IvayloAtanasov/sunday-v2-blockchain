// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IERC1155 } from "./interfaces/IERC1155.sol";

contract FundingVault is Owned {
    // collateral token loan receiver
    address public borrower;
    // sun token
    IERC1155 public assetToken;
    // sun token id
    uint256 assetTokenID;
    // token used for funding
    IERC20 public collateralToken;
    // funding value needed to cover installation cost
    uint256 public targetFunding;
    // total redeemable value for sun tokens (targetFunding + rewards)
    uint256 public redeemable;
    // rewards end date
    uint256 public maturity;
    // address allowed to set rewards
    address public rebaseAdapterAddress;
    // last reward date
    uint64 public rebasedAt;

    event RebaseAdapterChanged(address oldAdapter, address newAdapter);
    event Rebased(uint256 updatedRedeemable, int256 delta, uint64 updatedAt);
    event Redeemed(uint256 burned, uint256 received);

    modifier onlyRebaseAdapter() virtual {
        require(rebaseAdapterAddress != address(0), "NO_FEED_ADAPTER_SET");
        require(msg.sender == rebaseAdapterAddress, "ONLY_ADAPTER_ALLOWED");

        _;
    }

    modifier onlyBorrower() virtual {
        require(msg.sender == borrower, "ONLY_BORROWER_ALLOWED");

        _;
    }

    constructor(
        address borrowerAddress,
        address assetTokenAddress,
        uint256 assetTokenId,
        address collateralTokenAddress,
        uint256 funding,
        uint256 term // in seconds
    ) Owned(msg.sender) {
        require(funding > 0, "NO_FUNDING_SPECIFIED");

        borrower = borrowerAddress;

        assetToken = IERC1155(assetTokenAddress);
        assetTokenID = assetTokenId;
        collateralToken = IERC20(collateralTokenAddress);
        targetFunding = funding;
        redeemable = funding;

        maturity = block.timestamp + term;
    }

    /**
     * Get contract allowed to update yield rate
     */
    function getRebaseAdapter() external view returns (address) {
        return rebaseAdapterAddress;
    }

    /**
     * Change contract allowed to update yield rate
     */
    function setRebaseAdapter(address adapterContract) external onlyOwner() {
        address oldAddress = rebaseAdapterAddress;
        rebaseAdapterAddress = adapterContract;

        emit RebaseAdapterChanged(oldAddress, rebaseAdapterAddress);
    }

    /**
     * Change yield rate
     */
    function rebase(int256 valueDelta, uint64 updatedAt) external onlyRebaseAdapter {
        if (valueDelta >= 0) {
            redeemable += uint256(valueDelta);
        } else {
            uint256 absValueDelta = uint256(-valueDelta);
            require(redeemable >= absValueDelta, "REDEEMABLE_VALUE_UNDERFLOW");
            redeemable -= absValueDelta;
        }

        rebasedAt = updatedAt;

        emit Rebased(redeemable, valueDelta, rebasedAt);
    }

    /**
     * Borrower withdraws principal to finance asset
     */
    function withdraw() external onlyBorrower {
        uint256 collateralValueLocked = collateralToken.balanceOf(address(this));
        collateralToken.transfer(borrower, collateralValueLocked);
    }

    /**
     * Borrow funds to receive asset tokens at 1:1 rate
     */
    function borrow(uint256 amount, bytes calldata data) external {
        require(block.timestamp < maturity, "FUNDING_MATURITY_REACHED");

        collateralToken.transferFrom(msg.sender, address(this), amount);
        assetToken.safeTransferFrom(address(this), msg.sender, assetTokenID, amount, data);
    }

    /**
     * Burn asset tokens to redeem their principal and accrued profit over time
     */
    function redeem(uint256 amount) external {
        require(block.timestamp > maturity, "FUNDING_MATURITY_NOT_REACHED");

        assetToken.burn(msg.sender, assetTokenID, amount);
        uint256 redeemableForBurned = (amount * redeemable) / targetFunding;

        collateralToken.transfer(msg.sender, redeemableForBurned);

        emit Redeemed(amount, redeemableForBurned);
    }
}
