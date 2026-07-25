// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library PayoutTypes {
    /// @notice The reviewed v2 ClaimQuote shape plus the payout leg: the asset
    ///         the seller receives, the minimum measured delta, and the hash
    ///         binding the exact routing calldata into the signature.
    struct Quote {
        address factor;
        address seller;
        address adapter;
        address claimController;
        address claimReceiver;
        address paymentAsset; // funding asset (WETH) — kernel-checked
        uint256 paymentAmount; // exact funding amount drawn from the reserve
        bytes32 claimDataHash;
        bytes32 boundsHash;
        address payoutAsset; // asset the seller is paid in (allowlisted)
        uint256 minimumPayoutAmount; // minimum measured seller payout delta
        bytes32 payoutDataHash; // keccak256 of the encoded payout payload
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice ABI-encoded as `payoutData`; `payoutDataHash` binds it.
    struct UniswapPayoutData {
        bytes callData; // exact /swap response data, never altered
        bytes32 apiQuoteHash; // keccak256 of the exact retained /quote JSON string
    }
}
