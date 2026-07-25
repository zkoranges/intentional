// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

/// @notice Canonical surface of Lido's WithdrawalQueueERC721 used by this
///         system: the withdrawal-request queue plus the ERC-721 face of the
///         unstETH position NFTs (mainnet 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1).
interface ILidoWithdrawalQueue {
    struct WithdrawalRequestStatus {
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    function requestWithdrawals(
        uint256[] calldata amounts,
        address owner
    )
        external
        returns (uint256[] memory requestIds);

    function getWithdrawalStatus(uint256[] calldata requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);

    function getWithdrawalRequests(address owner) external view returns (uint256[] memory requestIds);

    function getLastRequestId() external view returns (uint256);

    function getLastFinalizedRequestId() external view returns (uint256);

    /// @dev Canonical single-argument form; the queue resolves the checkpoint
    ///      hint itself and sends the claimed ether to the request owner.
    function claimWithdrawal(uint256 requestId) external;

    function MIN_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);

    function MAX_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);

    function isPaused() external view returns (bool);

    function isBunkerModeActive() external view returns (bool);

    // --- ERC-721 face (unstETH position NFTs) ---
    // Canonical semantics: `ownerOf` and `getApproved` revert for a claimed
    // (burned) request; `getWithdrawalStatus` keeps returning it with
    // `isClaimed = true`.

    function balanceOf(address owner) external view returns (uint256);

    function ownerOf(uint256 requestId) external view returns (address);

    function approve(address to, uint256 requestId) external;

    function getApproved(uint256 requestId) external view returns (address);

    function setApprovalForAll(address operator, bool approved) external;

    function isApprovedForAll(address owner, address operator) external view returns (bool);

    function transferFrom(address from, address to, uint256 requestId) external;
}
