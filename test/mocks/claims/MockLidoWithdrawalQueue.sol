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

    IERC20 public immutable stETH;

    uint256 public constant override MIN_STETH_WITHDRAWAL_AMOUNT = 100;
    uint256 public constant override MAX_STETH_WITHDRAWAL_AMOUNT = 1000 ether;

    uint256 public lastRequestId;
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

    mapping(uint256 requestId => WithdrawalRequestStatus status) private _statuses;

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
        _statuses[requestId] = WithdrawalRequestStatus({
            amountOfStETH: overrideStatusAmount ? statusAmount : requested,
            amountOfShares: overrideStatusShares ? statusShares : pulled,
            owner: overrideStatusOwner ? statusOwner : owner,
            timestamp: block.timestamp,
            isFinalized: false,
            isClaimed: statusClaimed
        });

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
            statuses[i] = _statuses[requestIds[i]];
        }
    }

    function statusOf(uint256 requestId) external view returns (WithdrawalRequestStatus memory) {
        return _statuses[requestId];
    }
}
