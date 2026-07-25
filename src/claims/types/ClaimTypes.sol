// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library ClaimTypes {
    struct Quote {
        address factor;
        address seller;
        address adapter;
        address claimController;
        address claimReceiver;
        address paymentAsset;
        uint256 paymentAmount;
        bytes32 claimDataHash;
        bytes32 boundsHash;
        uint256 nonce;
        uint256 deadline;
    }

    struct ClaimContext {
        address seller;
        address claimController;
        address claimReceiver;
    }

    struct ClaimFacts {
        bytes32 positionKey;
        address asset;
        address share;
        uint256 claimId;
        uint256 pendingUnits;
        uint256 claimableUnits;
        bool exists;
    }

    struct Acquisition {
        bytes32 positionKey;
        uint256 claimId;
        uint256 pendingUnits;
        uint256 pendingReceived;
        uint256 claimableUnits;
        uint256 assetsReceived;
    }
}
