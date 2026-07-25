// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ClaimTypes } from "../types/ClaimTypes.sol";

interface IClaimAdapter {
    function inspect(bytes calldata claimData) external view returns (ClaimTypes.ClaimFacts memory facts);

    function acquire(
        ClaimTypes.ClaimContext calldata context,
        bytes calldata claimData,
        bytes calldata boundsData
    )
        external
        returns (ClaimTypes.Acquisition memory acquisition);
}
