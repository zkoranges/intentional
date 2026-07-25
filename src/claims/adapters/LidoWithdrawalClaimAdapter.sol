// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IClaimAdapter } from "../interfaces/IClaimAdapter.sol";
import { ILidoWithdrawalQueue } from "../interfaces/ILidoWithdrawalQueue.sol";
import { ClaimTypes } from "../types/ClaimTypes.sol";

interface IStETHShares {
    function sharesOf(address account) external view returns (uint256);

    function transferShares(address recipient, uint256 sharesAmount) external returns (uint256 tokensAmount);
}

/// @notice Originates one Lido withdrawal request from measured stETH.
/// @dev The request is minted directly to the claim receiver. This adapter
///      intentionally does not acquire existing unstETH positions.
contract LidoWithdrawalClaimAdapter is IClaimAdapter {
    using SafeERC20 for IERC20;

    struct LidoOriginateData {
        address queue;
        address stETH;
        uint256 requestedStETH;
    }

    struct LidoOriginateBounds {
        uint256 maxStETHShortfall;
        uint256 minAmountOfShares;
    }

    error InvalidSettlement();
    error InvalidStETH();
    error InvalidQueue();
    error OnlySettlement(address caller);
    error InvalidSeller();
    error InvalidClaimController();
    error InvalidClaimReceiver();
    error AdapterAsClaimReceiver();
    error WithdrawalsPaused();
    error QueueMismatch(address supplied, address expected);
    error StETHMismatch(address supplied, address expected);
    error InvalidReceivedAmount(uint256 requested, uint256 received);
    error ExcessiveStETHShortfall(uint256 shortfall, uint256 maximum);
    error RequestAmountBelowMinimum(uint256 measured, uint256 minimum);
    error RequestAmountAboveMaximum(uint256 measured, uint256 maximum);
    error InvalidRequestIdCount(uint256 count);
    error InvalidRequestId();
    error InvalidStatusCount(uint256 count);
    error InvalidRequestOwner(address actual, address expected);
    error InvalidRequestAmount(uint256 actual, uint256 expected);
    error InsufficientRequestShares(uint256 actual, uint256 minimum);
    error RequestAlreadyClaimed(uint256 requestId);
    error ResidualQueueAllowance(uint256 allowance);
    error PreexistingStETHShares(uint256 shares);
    error ResidualStETHShares(uint256 shares);
    error ResidualStETH(uint256 balance);

    uint256 public constant MIN_STETH_WITHDRAWAL_AMOUNT = 100;
    uint256 public constant MAX_STETH_WITHDRAWAL_AMOUNT = 1000 ether;

    address public immutable settlement;
    IERC20 public immutable stETH;
    IStETHShares public immutable stETHShares;
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
        stETHShares = IStETHShares(address(stETH_));
        queue = queue_;
    }

    /// @inheritdoc IClaimAdapter
    /// @dev Originate mode has no claim before acquisition, so `exists` is
    ///      false and the request-specific fields are zero.
    function inspect(bytes calldata claimData) external view returns (ClaimTypes.ClaimFacts memory facts) {
        LidoOriginateData memory data = abi.decode(claimData, (LidoOriginateData));
        _requireEndpoints(data);

        facts.asset = address(0);
        facts.share = address(stETH);
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

        LidoOriginateData memory data = abi.decode(claimData, (LidoOriginateData));
        LidoOriginateBounds memory bounds = abi.decode(boundsData, (LidoOriginateBounds));
        _requireEndpoints(data);

        uint256 sharesBefore = stETHShares.sharesOf(address(this));
        if (queue.isPaused()) {
            revert WithdrawalsPaused();
        }

        uint256 balanceBefore = stETH.balanceOf(address(this));
        stETH.safeTransferFrom(context.seller, address(this), data.requestedStETH);
        uint256 balanceAfter = stETH.balanceOf(address(this));
        if (balanceAfter < balanceBefore) {
            revert InvalidReceivedAmount(data.requestedStETH, 0);
        }

        uint256 receivedStETH;
        unchecked {
            receivedStETH = balanceAfter - balanceBefore;
        }
        if (receivedStETH > data.requestedStETH) {
            revert InvalidReceivedAmount(data.requestedStETH, receivedStETH);
        }

        uint256 shortfall;
        unchecked {
            shortfall = data.requestedStETH - receivedStETH;
        }
        if (shortfall > bounds.maxStETHShortfall) {
            revert ExcessiveStETHShortfall(shortfall, bounds.maxStETHShortfall);
        }
        uint256 minimumAmount = queue.MIN_STETH_WITHDRAWAL_AMOUNT();
        uint256 maximumAmount = queue.MAX_STETH_WITHDRAWAL_AMOUNT();
        if (receivedStETH < minimumAmount) {
            revert RequestAmountBelowMinimum(receivedStETH, minimumAmount);
        }
        if (receivedStETH > maximumAmount) {
            revert RequestAmountAboveMaximum(receivedStETH, maximumAmount);
        }

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = receivedStETH;

        stETH.forceApprove(address(queue), 0);
        stETH.forceApprove(address(queue), receivedStETH);
        uint256[] memory requestIds = queue.requestWithdrawals(amounts, context.claimReceiver);
        if (requestIds.length != 1) {
            revert InvalidRequestIdCount(requestIds.length);
        }

        uint256 requestId = requestIds[0];
        if (requestId == 0) {
            revert InvalidRequestId();
        }

        uint256[] memory statusIds = new uint256[](1);
        statusIds[0] = requestId;
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses = queue.getWithdrawalStatus(statusIds);
        if (statuses.length != 1) {
            revert InvalidStatusCount(statuses.length);
        }

        ILidoWithdrawalQueue.WithdrawalRequestStatus memory status = statuses[0];
        if (status.owner != context.claimReceiver) {
            revert InvalidRequestOwner(status.owner, context.claimReceiver);
        }
        if (status.amountOfStETH != receivedStETH) {
            revert InvalidRequestAmount(status.amountOfStETH, receivedStETH);
        }
        if (status.amountOfShares == 0 || status.amountOfShares < bounds.minAmountOfShares) {
            revert InsufficientRequestShares(status.amountOfShares, bounds.minAmountOfShares);
        }
        if (status.isClaimed) {
            revert RequestAlreadyClaimed(requestId);
        }

        stETH.forceApprove(address(queue), 0);

        uint256 remainingAllowance = stETH.allowance(address(this), address(queue));
        if (remainingAllowance != 0) {
            revert ResidualQueueAllowance(remainingAllowance);
        }

        uint256 residualShares = stETHShares.sharesOf(address(this));
        if (residualShares < sharesBefore) {
            revert ResidualStETHShares(residualShares);
        }
        uint256 currentFlowResidual;
        unchecked {
            currentFlowResidual = residualShares - sharesBefore;
        }
        if (currentFlowResidual != 0) {
            stETHShares.transferShares(context.seller, currentFlowResidual);
        }
        uint256 remainingShares = stETHShares.sharesOf(address(this));
        if (remainingShares != sharesBefore) {
            revert ResidualStETHShares(remainingShares);
        }

        acquisition.positionKey = keccak256(abi.encode(address(queue), requestId));
        acquisition.claimId = requestId;
        acquisition.pendingUnits = status.amountOfShares;
        acquisition.pendingReceived = status.amountOfShares;
    }

    function _requireEndpoints(LidoOriginateData memory data) private view {
        if (data.queue != address(queue)) {
            revert QueueMismatch(data.queue, address(queue));
        }
        if (data.stETH != address(stETH)) {
            revert StETHMismatch(data.stETH, address(stETH));
        }
    }
}
