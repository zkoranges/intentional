// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IERC7540RedeemTransferable } from "../../../src/claims/interfaces/IERC7540RedeemTransferable.sol";
import { IERC7575 } from "../../../src/claims/interfaces/IERC7575.sol";
import { MockERC7575Share } from "./MockERC7575Share.sol";

/// @notice Strict ERC-7540/8161 fixture with deterministic processing controls.
contract MockERC7540ERC8161Vault is IERC7540RedeemTransferable, IERC7575, IERC165 {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;

    bytes4 public constant ERC7540_OPERATOR_INTERFACE_ID = 0xe3bc4e65;
    bytes4 public constant ERC7540_REDEEM_INTERFACE_ID = 0x620ee8e4;
    bytes4 public constant ERC7575_INTERFACE_ID = 0x2f0a18c5;
    bytes4 public constant ERC8161_REDEEM_TRANSFERABLE_INTERFACE_ID = 0x7846f5bd;

    error InvalidAsset(address supplied);
    error InvalidController(address supplied);
    error InvalidReceiver(address supplied);
    error ZeroShares();
    error Unauthorized(address controller, address caller);
    error InsufficientPending(uint256 available, uint256 requested);
    error InsufficientClaimable(uint256 available, uint256 requested);
    error InvalidRate(uint256 supplied);
    error InvalidRequestId(uint256 supplied);
    error InvalidResidual(uint256 residual, uint256 pending);
    error PreviewUnsupported();

    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    event TransferRedeemRequest(uint256 indexed requestId, address indexed from, address indexed to, address sender);
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    address public immutable override asset;
    address public immutable override share;

    uint256 public nextRequestId = 1;
    uint256 public transferFeeWad;
    uint256 public redeemRateWad = WAD;
    uint256 public residualPendingOnTransfer;
    uint256 public transferCallCount;
    uint256 public redeemCallCount;
    bool public zeroRequestIdMode;
    bool public lieAboutRedeemReturn;
    uint256 public reportedRedeemAssets;

    mapping(bytes4 interfaceId => bool supported) private _supportedInterfaces;
    mapping(address controller => mapping(address operator => bool approved)) public override isOperator;
    mapping(uint256 requestId => mapping(address controller => uint256 shares)) public override pendingRedeemRequest;
    mapping(uint256 requestId => mapping(address controller => uint256 shares)) public override claimableRedeemRequest;

    constructor(IERC20 asset_) {
        if (address(asset_) == address(0) || address(asset_).code.length == 0) {
            revert InvalidAsset(address(asset_));
        }
        asset = address(asset_);

        MockERC7575Share share_ = new MockERC7575Share(address(this));
        share = address(share_);

        _supportedInterfaces[type(IERC165).interfaceId] = true;
        _supportedInterfaces[ERC7540_OPERATOR_INTERFACE_ID] = true;
        _supportedInterfaces[ERC7540_REDEEM_INTERFACE_ID] = true;
        _supportedInterfaces[ERC7575_INTERFACE_ID] = true;
        _supportedInterfaces[ERC8161_REDEEM_TRANSFERABLE_INTERFACE_ID] = true;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId != 0xffffffff && _supportedInterfaces[interfaceId];
    }

    function setInterfaceSupport(bytes4 interfaceId, bool supported) external {
        _supportedInterfaces[interfaceId] = supported;
    }

    function setOperator(address operator, bool approved) external returns (bool success) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId) {
        if (shares == 0) {
            revert ZeroShares();
        }
        if (controller == address(0)) {
            revert InvalidController(controller);
        }

        bool approvedOperator = isOperator[owner][msg.sender];
        bool spendAllowance = msg.sender != owner && !approvedOperator;
        MockERC7575Share(share).burnForRequest(owner, msg.sender, shares, spendAllowance);

        if (zeroRequestIdMode) {
            requestId = 0;
        } else {
            requestId = nextRequestId;
            nextRequestId = requestId + 1;
        }
        pendingRedeemRequest[requestId][controller] += shares;
        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
    }

    function transferRedeemRequest(uint256 requestId, address oldController, address newController) external {
        _requireControllerOrOperator(oldController);
        if (newController == address(0)) {
            revert InvalidController(newController);
        }

        uint256 pending = pendingRedeemRequest[requestId][oldController];
        uint256 residual = residualPendingOnTransfer;
        if (residual > pending) {
            revert InvalidResidual(residual, pending);
        }

        uint256 transferred = pending - residual;
        uint256 received = Math.mulDiv(transferred, WAD - transferFeeWad, WAD);
        pendingRedeemRequest[requestId][oldController] = residual;
        pendingRedeemRequest[requestId][newController] += received;
        ++transferCallCount;

        emit TransferRedeemRequest(requestId, oldController, newController, msg.sender);
    }

    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        _requireControllerOrOperator(controller);
        if (receiver == address(0)) {
            revert InvalidReceiver(receiver);
        }

        // ERC-7540 intentionally has no claim-by-ID method. This fixture
        // consumes the controller's first claimable cohort that covers the
        // requested shares; tests keep one seller cohort active at a time.
        uint256 requestId = _claimableRequestId(controller, shares);
        uint256 available = claimableRedeemRequest[requestId][controller];
        if (shares == 0 || shares > available) {
            revert InsufficientClaimable(available, shares);
        }

        claimableRedeemRequest[requestId][controller] = available - shares;
        uint256 paidAssets = Math.mulDiv(shares, redeemRateWad, WAD);
        IERC20(asset).safeTransfer(receiver, paidAssets);
        ++redeemCallCount;

        assets = lieAboutRedeemReturn ? reportedRedeemAssets : paidAssets;
    }

    function process(uint256 requestId, address controller, uint256 shares) external {
        uint256 pending = pendingRedeemRequest[requestId][controller];
        if (shares > pending) {
            revert InsufficientPending(pending, shares);
        }
        pendingRedeemRequest[requestId][controller] = pending - shares;
        claimableRedeemRequest[requestId][controller] += shares;
    }

    function mintShares(address receiver, uint256 shares) external {
        MockERC7575Share(share).mint(receiver, shares);
    }

    function setNextRequestId(uint256 requestId) external {
        if (requestId == 0) {
            revert InvalidRequestId(requestId);
        }
        nextRequestId = requestId;
    }

    function setZeroRequestIdMode(bool enabled) external {
        zeroRequestIdMode = enabled;
    }

    function setTransferFeeWad(uint256 feeWad) external {
        if (feeWad > WAD) {
            revert InvalidRate(feeWad);
        }
        transferFeeWad = feeWad;
    }

    function setRedeemRateWad(uint256 rateWad) external {
        redeemRateWad = rateWad;
    }

    function setResidualPendingOnTransfer(uint256 residual) external {
        residualPendingOnTransfer = residual;
    }

    function setRedeemReturnLie(bool enabled, uint256 reportedAssets) external {
        lieAboutRedeemReturn = enabled;
        reportedRedeemAssets = reportedAssets;
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        revert PreviewUnsupported();
    }

    function previewWithdraw(uint256) external pure returns (uint256) {
        revert PreviewUnsupported();
    }

    function _requireControllerOrOperator(address controller) private view {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) {
            revert Unauthorized(controller, msg.sender);
        }
    }

    function _claimableRequestId(address controller, uint256 shares) private view returns (uint256 requestId) {
        if (zeroRequestIdMode && claimableRedeemRequest[0][controller] >= shares) {
            return 0;
        }

        uint256 upperBound = nextRequestId;
        for (uint256 id = 1; id < upperBound; ++id) {
            if (claimableRedeemRequest[id][controller] >= shares) {
                return id;
            }
        }
        return upperBound;
    }
}
