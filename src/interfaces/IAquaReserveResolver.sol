// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @notice View-only reserve capacity used by Reservoir's SwapVM instruction.
interface IAquaReserveResolver {
    /// @return canDeliver Current buffered physical inventory, capped at wanted.
    /// @return exitCostWad Reserved v1 extension point. Must be zero in v1.
    function availableFor(address asset, uint256 wanted) external view returns (uint256 canDeliver, uint256 exitCostWad);
}

