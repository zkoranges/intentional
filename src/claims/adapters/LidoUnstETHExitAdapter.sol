// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IClaimAdapter } from "../interfaces/IClaimAdapter.sol";
import { ILidoWithdrawalQueue } from "../interfaces/ILidoWithdrawalQueue.sol";
import { ClaimTypes } from "../types/ClaimTypes.sol";

/// @notice Acquires one existing Lido withdrawal request (unstETH NFT) from
///         its current owner. The NFT moves seller -> claimReceiver in the
///         same transaction as the kernel payment; the adapter never takes
///         custody of the position or of any token.
/// @dev Modelled on LidoWithdrawalClaimAdapter: same immutable endpoint
///      bindings, onlySettlement guard, and measured postconditions. This
///      adapter intentionally does not originate withdrawal requests.
///
///      Unit mapping: the request's share amount is the position size. An
///      unfinalized request reports it as pendingUnits, a finalized-unclaimed
///      request as claimableUnits, so the kernel invariant
///      `pendingUnits + claimableUnits != 0` holds in both states and a
///      request that finalizes between quote signing and fill stays fillable
///      (strictly buyer-favourable: the buyer receives a claimable position
///      instead of a pending one at the same price).
contract LidoUnstETHExitAdapter is IClaimAdapter {
    struct LidoExitData {
        address queue;
        address stETH;
        uint256 requestId;
    }

    struct LidoExitBounds {
        uint256 minAmountOfStETH;
        uint256 maxAmountOfStETH;
        uint256 minAmountOfShares;
        uint256 maxAmountOfShares;
    }

    error InvalidSettlement();
    error InvalidStETH();
    error InvalidQueue();
    error OnlySettlement(address caller);
    error InvalidSeller();
    error InvalidClaimController();
    error InvalidClaimReceiver();
    error AdapterAsClaimReceiver();
    error QueueAsClaimReceiver();
    error QueueMismatch(address supplied, address expected);
    error StETHMismatch(address supplied, address expected);
    error InvalidBounds();
    error InvalidRequestId(uint256 requestId);
    error InvalidStatusCount(uint256 count);
    error RequestAlreadyClaimed(uint256 requestId);
    error InvalidRequestOwner(address actual, address expected);
    error StETHAmountOutOfBounds(uint256 actual, uint256 minimum, uint256 maximum);
    error ShareAmountOutOfBounds(uint256 actual, uint256 minimum, uint256 maximum);
    error EmptyRequestShares(uint256 requestId);
    error TransferNotApproved(uint256 requestId);
    error InvalidPostTransferOwner(address actual, address expected);
    error RequestAmountsChanged(uint256 requestId);
    error FinalizationRegressed(uint256 requestId);

    address public immutable settlement;
    IERC20 public immutable stETH;
    ILidoWithdrawalQueue public immutable queue;

    modifier onlySettlement() {
        if (msg.sender != settlement) {
            revert OnlySettlement(msg.sender);
        }
        _;
    }

    constructor(address settlement_, IERC20 stETH_, ILidoWithdrawalQueue queue_) {
        if (settlement_ == address(0) || settlement_.code.length == 0) {
            revert InvalidSettlement();
        }
        if (address(stETH_) == address(0) || address(stETH_).code.length == 0) {
            revert InvalidStETH();
        }
        if (address(queue_) == address(0) || address(queue_).code.length == 0) {
            revert InvalidQueue();
        }

        settlement = settlement_;
        stETH = stETH_;
        queue = queue_;
    }

    /// @inheritdoc IClaimAdapter
    /// @dev Exit mode inspects a live position. A claimed (burned) request is
    ///      reported as nonexistent with zero units; the eventual payout is
    ///      native ETH, which has no token address, so `asset` stays zero.
    function inspect(bytes calldata claimData) external view returns (ClaimTypes.ClaimFacts memory facts) {
        LidoExitData memory data = abi.decode(claimData, (LidoExitData));
        _requireEndpoints(data);
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory status = _readSingleStatus(data.requestId);

        facts.positionKey = keccak256(abi.encode(address(queue), data.requestId));
        facts.asset = address(0);
        facts.share = address(stETH);
        facts.claimId = data.requestId;
        if (!status.isClaimed) {
            if (status.isFinalized) {
                facts.claimableUnits = status.amountOfShares;
            } else {
                facts.pendingUnits = status.amountOfShares;
            }
        }
        facts.exists = !status.isClaimed;
    }

    /// @inheritdoc IClaimAdapter
    function acquire(
        ClaimTypes.ClaimContext calldata context,
        bytes calldata claimData,
        bytes calldata boundsData
    )
        external
        onlySettlement
        returns (ClaimTypes.Acquisition memory acquisition)
    {
        if (context.seller == address(0)) {
            revert InvalidSeller();
        }
        if (context.claimController == address(0)) {
            revert InvalidClaimController();
        }
        if (context.claimReceiver == address(0)) {
            revert InvalidClaimReceiver();
        }
        if (context.claimReceiver == address(this)) {
            revert AdapterAsClaimReceiver();
        }

        LidoExitData memory data = abi.decode(claimData, (LidoExitData));
        LidoExitBounds memory bounds = abi.decode(boundsData, (LidoExitBounds));
        _requireEndpoints(data);
        if (context.claimReceiver == address(queue)) {
            revert QueueAsClaimReceiver();
        }
        if (bounds.minAmountOfStETH > bounds.maxAmountOfStETH || bounds.minAmountOfShares > bounds.maxAmountOfShares) {
            revert InvalidBounds();
        }

        uint256 requestId = data.requestId;
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory status = _readSingleStatus(requestId);

        // A seller claim (burn) between quote and fill fails here, atomically.
        if (status.isClaimed) {
            revert RequestAlreadyClaimed(requestId);
        }
        // A seller transfer between quote and fill fails here, atomically.
        // The queue-status owner and the ERC-721 owner must both be the
        // signed seller; on the canonical queue they agree by construction.
        if (status.owner != context.seller) {
            revert InvalidRequestOwner(status.owner, context.seller);
        }
        address erc721Owner = queue.ownerOf(requestId);
        if (erc721Owner != context.seller) {
            revert InvalidRequestOwner(erc721Owner, context.seller);
        }

        // The signed quote binds the position economics. On the canonical
        // queue amounts are immutable after origination, so any drift outside
        // the signed bounds means the position is not the one that was quoted.
        if (status.amountOfStETH < bounds.minAmountOfStETH || status.amountOfStETH > bounds.maxAmountOfStETH) {
            revert StETHAmountOutOfBounds(status.amountOfStETH, bounds.minAmountOfStETH, bounds.maxAmountOfStETH);
        }
        if (status.amountOfShares == 0) {
            revert EmptyRequestShares(requestId);
        }
        if (status.amountOfShares < bounds.minAmountOfShares || status.amountOfShares > bounds.maxAmountOfShares) {
            revert ShareAmountOutOfBounds(status.amountOfShares, bounds.minAmountOfShares, bounds.maxAmountOfShares);
        }

        // Explicit approval precheck so a missing ERC-721 approval fails with
        // this adapter's error instead of a queue-internal one.
        if (queue.getApproved(requestId) != address(this) && !queue.isApprovedForAll(context.seller, address(this))) {
            revert TransferNotApproved(requestId);
        }

        bool finalizedBefore = status.isFinalized;

        queue.transferFrom(context.seller, context.claimReceiver, requestId);

        // Measured postconditions: re-read everything the payment depends on.
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory post = _readSingleStatus(requestId);
        if (post.isClaimed) {
            revert RequestAlreadyClaimed(requestId);
        }
        address ownerAfter = queue.ownerOf(requestId);
        if (ownerAfter != context.claimReceiver) {
            revert InvalidPostTransferOwner(ownerAfter, context.claimReceiver);
        }
        if (post.owner != context.claimReceiver) {
            revert InvalidPostTransferOwner(post.owner, context.claimReceiver);
        }
        if (post.amountOfStETH != status.amountOfStETH || post.amountOfShares != status.amountOfShares) {
            revert RequestAmountsChanged(requestId);
        }
        if (finalizedBefore && !post.isFinalized) {
            revert FinalizationRegressed(requestId);
        }

        acquisition.positionKey = keccak256(abi.encode(address(queue), requestId));
        acquisition.claimId = requestId;
        if (post.isFinalized) {
            acquisition.claimableUnits = post.amountOfShares;
        } else {
            acquisition.pendingUnits = post.amountOfShares;
            acquisition.pendingReceived = post.amountOfShares;
        }
    }

    function _readSingleStatus(uint256 requestId)
        private
        view
        returns (ILidoWithdrawalQueue.WithdrawalRequestStatus memory status)
    {
        if (requestId == 0 || requestId > queue.getLastRequestId()) {
            revert InvalidRequestId(requestId);
        }
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses = queue.getWithdrawalStatus(requestIds);
        if (statuses.length != 1) {
            revert InvalidStatusCount(statuses.length);
        }
        status = statuses[0];
    }

    function _requireEndpoints(LidoExitData memory data) private view {
        if (data.queue != address(queue)) {
            revert QueueMismatch(data.queue, address(queue));
        }
        if (data.stETH != address(stETH)) {
            revert StETHMismatch(data.stETH, address(stETH));
        }
    }
}
