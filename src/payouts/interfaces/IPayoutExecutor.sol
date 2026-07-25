// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPayoutExecutor {
    /// @notice Convert the funded input and deliver `payoutAsset` to `recipient`.
    /// @dev The caller must have already transferred exactly `fundingAmount` of
    ///      the funding asset to this contract. Returns the recipient's measured
    ///      payout delta; the caller must not treat the return value as
    ///      authoritative and re-measures the delta itself.
    function payout(
        address recipient,
        IERC20 payoutAsset,
        uint256 fundingAmount,
        uint256 minimumPayoutAmount,
        bytes calldata payoutData
    )
        external
        returns (uint256 delivered);

    function settlement() external view returns (address);
    function fundingAsset() external view returns (address);
    function proxy() external view returns (address);
    function proxySelector() external view returns (bytes4);
}
