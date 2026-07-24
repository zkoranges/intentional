// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { IAquaReserveResolver } from "./IAquaReserveResolver.sol";

/// @notice A single-maker, single-asset ERC-4626 reserve.
interface IAquaReserveAdapter is IAquaReserveResolver {
    /// @notice Makes exactly amount underlying available to the configured maker.
    /// @dev Exact-or-revert. Partial filling happens in ReserveClamp.
    function materialize(address asset, uint256 amount) external returns (uint256 delivered);

    /// @notice Deposits eligible maker idle inventory into the configured vault.
    function reinvest(address asset) external;

    function idleThreshold(address asset) external view returns (uint256);
}

