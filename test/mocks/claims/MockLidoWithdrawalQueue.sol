// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILidoWithdrawalQueue } from "../../../src/claims/interfaces/ILidoWithdrawalQueue.sol";

contract MockLidoWithdrawalQueue is ILidoWithdrawalQueue {
    using SafeERC20 for IERC20;

    error RequestFailed();
    error StatusFailed();
    error InvalidAmountsLength(uint256 length);
    error PullShortfallExceedsAmount(uint256 shortfall, uint256 amount);
    error InvalidRequestId(uint256 requestId);
    error RequestAlreadyClaimed(uint256 requestId);
    error RequestNotFinalized(uint256 requestId);
    error NotOwner(address caller, address owner);
    error NotOwnerOrApproved(address caller);
    error TransferFromIncorrectOwner(address from, address owner);
    error TransferToZeroAddress();
    error TransferToThemselves();

    IERC20 public immutable stETH;

    uint256 public constant override MIN_STETH_WITHDRAWAL_AMOUNT = 100;
    uint256 public constant override MAX_STETH_WITHDRAWAL_AMOUNT = 1000 ether;

    uint256 public lastRequestId;
    uint256 public lastFinalizedRequestId;
    bool public paused;
    bool public bunkerMode;
    bool public failRequest;
    bool public failStatus;
    bool public returnZeroRequestId;
    uint256 public requestIdsLength = 1;
    uint256 public statusLength = 1;
    uint256 public pullShortfall;

    bool public overrideStatusOwner;
    address public statusOwner;
    bool public overrideStatusAmount;
    uint256 public statusAmount;
    bool public overrideStatusShares;
    uint256 public statusShares;
    bool public statusClaimed;

    // Hostile-queue hooks that mutate state inside transferFrom, so the
    // adapter's measured postconditions can be exercised.
    bool public postTransferAmountDriftEnabled;
    uint256 public postTransferDriftAmount;
    uint256 public postTransferDriftShares;
    bool public postTransferOwnerHijackEnabled;
    address public postTransferHijacker;
    bool public definalizeOnTransfer;

    mapping(uint256 requestId => WithdrawalRequestStatus status) private _statuses;
    mapping(uint256 requestId => address approved) private _tokenApprovals;
    mapping(address owner => mapping(address operator => bool approved)) private _operatorApprovals;
    mapping(address owner => uint256[] requestIds) private _requestsByOwner;
    mapping(uint256 requestId => uint256 indexPlusOne) private _ownedIndex;
    mapping(address owner => uint256 count) private _balances;

    constructor(IERC20 stETH_) {
        stETH = stETH_;
    }

    function setFailure(bool requestFailure, bool statusFailure) external {
        failRequest = requestFailure;
        failStatus = statusFailure;
    }

    function setPaused(bool enabled) external {
        paused = enabled;
    }

    function setBunkerMode(bool enabled) external {
        bunkerMode = enabled;
    }

    function isPaused() external view override returns (bool) {
        return paused;
    }

    function isBunkerModeActive() external view override returns (bool) {
        return bunkerMode;
    }

    function setResponseLengths(uint256 idsLength, uint256 statusesLength) external {
        requestIdsLength = idsLength;
        statusLength = statusesLength;
    }

    function setReturnZeroRequestId(bool enabled) external {
        returnZeroRequestId = enabled;
    }

    function setPullShortfall(uint256 shortfall) external {
        pullShortfall = shortfall;
    }

    function setStatusOwner(address owner, bool enabled) external {
        statusOwner = owner;
        overrideStatusOwner = enabled;
    }

    function setStatusAmount(uint256 amount, bool enabled) external {
        statusAmount = amount;
        overrideStatusAmount = enabled;
    }

    function setStatusShares(uint256 shares, bool enabled) external {
        statusShares = shares;
        overrideStatusShares = enabled;
    }

    function setStatusClaimed(bool claimed) external {
        statusClaimed = claimed;
    }

    /// @dev Canonical-style finalization: a request is finalized when its id
    ///      is at or below the last finalized request id.
    function finalizeUpTo(uint256 requestId) external {
        lastFinalizedRequestId = requestId;
    }

    /// @dev Simulates amount/share drift between quote-time reads and the
    ///      adapter's post-transfer re-read.
    function setPostTransferAmountDrift(uint256 amount, uint256 shares, bool enabled) external {
        postTransferDriftAmount = amount;
        postTransferDriftShares = shares;
        postTransferAmountDriftEnabled = enabled;
    }

    /// @dev Simulates a queue that reassigns ownership during transferFrom.
    function setPostTransferOwnerHijack(address hijacker, bool enabled) external {
        postTransferHijacker = hijacker;
        postTransferOwnerHijackEnabled = enabled;
    }

    /// @dev Simulates a queue whose finalization pointer regresses mid-fill.
    function setDefinalizeOnTransfer(bool enabled) external {
        definalizeOnTransfer = enabled;
    }

    /// @dev Direct status mutation: models a queue whose recorded economics
    ///      no longer match what the factor signed.
    function setRequestAmounts(uint256 requestId, uint256 amountOfStETH, uint256 amountOfShares) external {
        _statuses[requestId].amountOfStETH = amountOfStETH;
        _statuses[requestId].amountOfShares = amountOfShares;
    }

    function requestWithdrawals(
        uint256[] calldata amounts,
        address owner
    )
        external
        returns (uint256[] memory requestIds)
    {
        if (failRequest) {
            revert RequestFailed();
        }
        if (amounts.length != 1) {
            revert InvalidAmountsLength(amounts.length);
        }

        uint256 requested = amounts[0];
        if (pullShortfall > requested) {
            revert PullShortfallExceedsAmount(pullShortfall, requested);
        }
        uint256 pulled;
        unchecked {
            pulled = requested - pullShortfall;
        }
        stETH.safeTransferFrom(msg.sender, address(this), pulled);

        uint256 requestId;
        unchecked {
            requestId = ++lastRequestId;
        }
        address recordedOwner = overrideStatusOwner ? statusOwner : owner;
        _statuses[requestId] = WithdrawalRequestStatus({
            amountOfStETH: overrideStatusAmount ? statusAmount : requested,
            amountOfShares: overrideStatusShares ? statusShares : pulled,
            owner: recordedOwner,
            timestamp: block.timestamp,
            isFinalized: false,
            isClaimed: statusClaimed
        });
        _addOwnership(recordedOwner, requestId);

        requestIds = new uint256[](requestIdsLength);
        if (requestIdsLength != 0) {
            requestIds[0] = returnZeroRequestId ? 0 : requestId;
            for (uint256 i = 1; i < requestIdsLength; ++i) {
                requestIds[i] = requestId + i;
            }
        }
    }

    function getWithdrawalStatus(uint256[] calldata requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses)
    {
        if (failStatus) {
            revert StatusFailed();
        }

        statuses = new WithdrawalRequestStatus[](statusLength);
        uint256 copyLength = statusLength < requestIds.length ? statusLength : requestIds.length;
        for (uint256 i; i < copyLength; ++i) {
            uint256 requestId = requestIds[i];
            if (requestId == 0 || requestId > lastRequestId) {
                revert InvalidRequestId(requestId);
            }
            statuses[i] = _statusWithFinalization(requestId);
        }
    }

    function statusOf(uint256 requestId) external view returns (WithdrawalRequestStatus memory) {
        return _statusWithFinalization(requestId);
    }

    function getWithdrawalRequests(address owner) external view returns (uint256[] memory requestIds) {
        return _requestsByOwner[owner];
    }

    function getLastRequestId() external view returns (uint256) {
        return lastRequestId;
    }

    function getLastFinalizedRequestId() external view returns (uint256) {
        return lastFinalizedRequestId;
    }

    /// @dev Canonical semantics: only the owner of a finalized, unclaimed
    ///      request may claim; the claim burns the NFT. The mock records the
    ///      state transition without paying ether.
    function claimWithdrawal(uint256 requestId) external {
        WithdrawalRequestStatus storage status = _requireExisting(requestId);
        if (status.isClaimed) {
            revert RequestAlreadyClaimed(requestId);
        }
        if (!status.isFinalized && requestId > lastFinalizedRequestId) {
            revert RequestNotFinalized(requestId);
        }
        if (status.owner != msg.sender) {
            revert NotOwner(msg.sender, status.owner);
        }

        status.isClaimed = true;
        delete _tokenApprovals[requestId];
        _removeOwnership(status.owner, requestId);
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function ownerOf(uint256 requestId) external view returns (address) {
        WithdrawalRequestStatus storage status = _requireExisting(requestId);
        if (status.isClaimed) {
            revert RequestAlreadyClaimed(requestId);
        }
        return status.owner;
    }

    function approve(address to, uint256 requestId) external {
        WithdrawalRequestStatus storage status = _requireExisting(requestId);
        if (status.isClaimed) {
            revert RequestAlreadyClaimed(requestId);
        }
        if (msg.sender != status.owner && !_operatorApprovals[status.owner][msg.sender]) {
            revert NotOwnerOrApproved(msg.sender);
        }
        _tokenApprovals[requestId] = to;
    }

    function getApproved(uint256 requestId) external view returns (address) {
        WithdrawalRequestStatus storage status = _requireExisting(requestId);
        if (status.isClaimed) {
            revert RequestAlreadyClaimed(requestId);
        }
        return _tokenApprovals[requestId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function transferFrom(address from, address to, uint256 requestId) external {
        if (to == address(0)) {
            revert TransferToZeroAddress();
        }
        if (to == from) {
            revert TransferToThemselves();
        }
        WithdrawalRequestStatus storage status = _requireExisting(requestId);
        if (status.isClaimed) {
            revert RequestAlreadyClaimed(requestId);
        }
        if (status.owner != from) {
            revert TransferFromIncorrectOwner(from, status.owner);
        }
        if (msg.sender != from && _tokenApprovals[requestId] != msg.sender && !_operatorApprovals[from][msg.sender]) {
            revert NotOwnerOrApproved(msg.sender);
        }

        delete _tokenApprovals[requestId];
        _removeOwnership(from, requestId);
        address newOwner = postTransferOwnerHijackEnabled ? postTransferHijacker : to;
        status.owner = newOwner;
        _addOwnership(newOwner, requestId);

        if (postTransferAmountDriftEnabled) {
            status.amountOfStETH = postTransferDriftAmount;
            status.amountOfShares = postTransferDriftShares;
        }
        if (definalizeOnTransfer) {
            lastFinalizedRequestId = 0;
        }
    }

    function _statusWithFinalization(uint256 requestId) private view returns (WithdrawalRequestStatus memory status) {
        status = _statuses[requestId];
        if (!status.isFinalized && requestId != 0 && requestId <= lastFinalizedRequestId) {
            status.isFinalized = true;
        }
    }

    function _requireExisting(uint256 requestId) private view returns (WithdrawalRequestStatus storage status) {
        if (requestId == 0 || requestId > lastRequestId) {
            revert InvalidRequestId(requestId);
        }
        status = _statuses[requestId];
    }

    function _addOwnership(address owner, uint256 requestId) private {
        _requestsByOwner[owner].push(requestId);
        _ownedIndex[requestId] = _requestsByOwner[owner].length;
        unchecked {
            ++_balances[owner];
        }
    }

    function _removeOwnership(address owner, uint256 requestId) private {
        uint256[] storage owned = _requestsByOwner[owner];
        uint256 index = _ownedIndex[requestId];
        if (index != 0 && index <= owned.length) {
            uint256 lastIndex = owned.length;
            if (index != lastIndex) {
                uint256 movedId = owned[lastIndex - 1];
                owned[index - 1] = movedId;
                _ownedIndex[movedId] = index;
            }
            owned.pop();
        }
        delete _ownedIndex[requestId];
        if (_balances[owner] != 0) {
            unchecked {
                --_balances[owner];
            }
        }
    }
}
