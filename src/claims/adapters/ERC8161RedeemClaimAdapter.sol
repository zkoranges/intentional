// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IClaimAdapter } from "../interfaces/IClaimAdapter.sol";
import { IERC7540RedeemTransferable } from "../interfaces/IERC7540RedeemTransferable.sol";
import { IERC7575 } from "../interfaces/IERC7575.sol";
import { ClaimTypes } from "../types/ClaimTypes.sol";

/// @notice Acquires one nonzero-ID ERC-7540 redeem position through ERC-8161.
/// @dev The adapter is deliberately immutable because ERC-7540 operator approval
///      applies to the entire controller account at the configured vault.
contract ERC8161RedeemClaimAdapter is IClaimAdapter {
    uint256 public constant WAD = 1e18;

    bytes4 public constant ERC7540_OPERATOR_INTERFACE_ID = 0xe3bc4e65;
    bytes4 public constant ERC7540_REDEEM_INTERFACE_ID = 0x620ee8e4;
    bytes4 public constant ERC7575_INTERFACE_ID = 0x2f0a18c5;
    bytes4 public constant ERC8161_REDEEM_TRANSFERABLE_INTERFACE_ID = 0x7846f5bd;

    struct ERC8161ClaimData {
        address vault;
        address share;
        address asset;
        uint256 requestId;
        address sellerController;
    }

    struct ERC8161Bounds {
        uint256 expectedTotalShares;
        uint256 minPendingTransferRateWad;
        uint256 minAssetsPerClaimableShareWad;
    }

    error InvalidVault(address supplied);
    error InvalidSettlement(address supplied);
    error UnsupportedInterface(bytes4 interfaceId);
    error InvalidAsset(address supplied);
    error InvalidShare(address supplied);
    error ClaimVaultMismatch(address expected, address supplied);
    error ClaimShareMismatch(address expected, address supplied);
    error ClaimAssetMismatch(address expected, address supplied);
    error VaultShareChanged(address expected, address actual);
    error VaultAssetChanged(address expected, address actual);
    error RequestIdZero();
    error InvalidSellerController(address supplied);
    error SellerControllerMismatch(address expected, address supplied);
    error InvalidClaimController(address supplied);
    error InvalidClaimReceiver(address supplied);
    error AdapterAsClaimController();
    error AdapterAsClaimReceiver();
    error OnlySettlement(address caller);
    error OperatorNotApproved(address controller, address operator);
    error EmptyPosition();
    error TotalSharesMismatch(uint256 expected, uint256 actual);
    error SellerPositionNotDrained(uint256 pendingRemaining, uint256 claimableRemaining);
    error PendingBalanceDecreased(uint256 beforeBalance, uint256 afterBalance);
    error AssetBalanceDecreased(uint256 beforeBalance, uint256 afterBalance);
    error PendingTransferRateBelowFloor(uint256 minimum, uint256 actual);
    error RedemptionRateBelowFloor(uint256 minimum, uint256 actual);
    error AdapterTokenDust(address token, uint256 balance);
    error AdapterNativeDust(uint256 balance);

    IERC7540RedeemTransferable public immutable vault;
    address public immutable share;
    address public immutable asset;
    address public immutable settlement;

    modifier onlySettlement() {
        if (msg.sender != settlement) {
            revert OnlySettlement(msg.sender);
        }
        _;
    }

    constructor(IERC7540RedeemTransferable vault_, address settlement_) {
        address vaultAddress = address(vault_);
        if (vaultAddress == address(0) || vaultAddress.code.length == 0) {
            revert InvalidVault(vaultAddress);
        }
        if (settlement_ == address(0) || settlement_.code.length == 0) {
            revert InvalidSettlement(settlement_);
        }

        _requireInterface(vaultAddress, ERC7540_OPERATOR_INTERFACE_ID);
        _requireInterface(vaultAddress, ERC7540_REDEEM_INTERFACE_ID);
        _requireInterface(vaultAddress, ERC7575_INTERFACE_ID);
        _requireInterface(vaultAddress, ERC8161_REDEEM_TRANSFERABLE_INTERFACE_ID);

        address asset_ = IERC7575(vaultAddress).asset();
        if (asset_ == address(0) || asset_.code.length == 0) {
            revert InvalidAsset(asset_);
        }
        address share_ = IERC7575(vaultAddress).share();
        if (share_ == address(0) || share_.code.length == 0) {
            revert InvalidShare(share_);
        }

        vault = vault_;
        asset = asset_;
        share = share_;
        settlement = settlement_;
    }

    function inspect(bytes calldata claimData) external view returns (ClaimTypes.ClaimFacts memory facts) {
        ERC8161ClaimData memory claim = abi.decode(claimData, (ERC8161ClaimData));
        _validateClaim(claim);

        uint256 pending = vault.pendingRedeemRequest(claim.requestId, claim.sellerController);
        uint256 claimable = vault.claimableRedeemRequest(claim.requestId, claim.sellerController);

        facts = ClaimTypes.ClaimFacts({
            positionKey: _positionKey(claim.requestId, claim.sellerController),
            asset: asset,
            share: share,
            claimId: claim.requestId,
            pendingUnits: pending,
            claimableUnits: claimable,
            exists: pending != 0 || claimable != 0
        });
    }

    function acquire(
        ClaimTypes.ClaimContext calldata context,
        bytes calldata claimData,
        bytes calldata boundsData
    )
        external
        onlySettlement
        returns (ClaimTypes.Acquisition memory acquisition)
    {
        ERC8161ClaimData memory claim = abi.decode(claimData, (ERC8161ClaimData));
        ERC8161Bounds memory bounds = abi.decode(boundsData, (ERC8161Bounds));
        _validateClaim(claim);

        if (claim.sellerController != context.seller) {
            revert SellerControllerMismatch(context.seller, claim.sellerController);
        }
        if (context.claimController == address(0)) {
            revert InvalidClaimController(context.claimController);
        }
        if (context.claimReceiver == address(0)) {
            revert InvalidClaimReceiver(context.claimReceiver);
        }
        if (context.claimController == address(this)) {
            revert AdapterAsClaimController();
        }
        if (context.claimReceiver == address(this)) {
            revert AdapterAsClaimReceiver();
        }
        if (!vault.isOperator(claim.sellerController, address(this))) {
            revert OperatorNotApproved(claim.sellerController, address(this));
        }
        if (bounds.expectedTotalShares == 0) {
            revert EmptyPosition();
        }

        uint256 pending = vault.pendingRedeemRequest(claim.requestId, claim.sellerController);
        uint256 claimable = vault.claimableRedeemRequest(claim.requestId, claim.sellerController);
        uint256 total = pending + claimable;
        if (total != bounds.expectedTotalShares) {
            revert TotalSharesMismatch(bounds.expectedTotalShares, total);
        }

        uint256 controllerPendingBefore = vault.pendingRedeemRequest(claim.requestId, context.claimController);
        uint256 receiverAssetsBefore = IERC20(asset).balanceOf(context.claimReceiver);

        // Partial processing can make both legs nonzero. This must not be if/else.
        if (pending != 0) {
            vault.transferRedeemRequest(claim.requestId, claim.sellerController, context.claimController);
        }
        if (claimable != 0) {
            // ERC-7540 previews revert for asynchronous redemption. The return
            // value is intentionally ignored; the receiver delta is authoritative.
            vault.redeem(claimable, context.claimReceiver, claim.sellerController);
        }

        uint256 pendingRemaining = vault.pendingRedeemRequest(claim.requestId, claim.sellerController);
        uint256 claimableRemaining = vault.claimableRedeemRequest(claim.requestId, claim.sellerController);
        if (pendingRemaining != 0 || claimableRemaining != 0) {
            revert SellerPositionNotDrained(pendingRemaining, claimableRemaining);
        }

        uint256 controllerPendingAfter = vault.pendingRedeemRequest(claim.requestId, context.claimController);
        if (controllerPendingAfter < controllerPendingBefore) {
            revert PendingBalanceDecreased(controllerPendingBefore, controllerPendingAfter);
        }
        uint256 pendingReceived = controllerPendingAfter - controllerPendingBefore;

        uint256 receiverAssetsAfter = IERC20(asset).balanceOf(context.claimReceiver);
        if (receiverAssetsAfter < receiverAssetsBefore) {
            revert AssetBalanceDecreased(receiverAssetsBefore, receiverAssetsAfter);
        }
        uint256 assetsReceived = receiverAssetsAfter - receiverAssetsBefore;

        uint256 minimumPending = Math.mulDiv(pending, bounds.minPendingTransferRateWad, WAD, Math.Rounding.Ceil);
        if (pendingReceived < minimumPending) {
            revert PendingTransferRateBelowFloor(minimumPending, pendingReceived);
        }

        uint256 minimumAssets = Math.mulDiv(claimable, bounds.minAssetsPerClaimableShareWad, WAD, Math.Rounding.Ceil);
        if (assetsReceived < minimumAssets) {
            revert RedemptionRateBelowFloor(minimumAssets, assetsReceived);
        }

        _requireZeroDust();

        acquisition = ClaimTypes.Acquisition({
            positionKey: _positionKey(claim.requestId, claim.sellerController),
            claimId: claim.requestId,
            pendingUnits: pending,
            pendingReceived: pendingReceived,
            claimableUnits: claimable,
            assetsReceived: assetsReceived
        });
    }

    function _validateClaim(ERC8161ClaimData memory claim) private view {
        if (claim.vault != address(vault)) {
            revert ClaimVaultMismatch(address(vault), claim.vault);
        }
        if (claim.share != share) {
            revert ClaimShareMismatch(share, claim.share);
        }
        if (claim.asset != asset) {
            revert ClaimAssetMismatch(asset, claim.asset);
        }
        if (claim.requestId == 0) {
            revert RequestIdZero();
        }
        if (claim.sellerController == address(0)) {
            revert InvalidSellerController(claim.sellerController);
        }

        address currentShare = IERC7575(address(vault)).share();
        if (currentShare != share) {
            revert VaultShareChanged(share, currentShare);
        }
        address currentAsset = IERC7575(address(vault)).asset();
        if (currentAsset != asset) {
            revert VaultAssetChanged(asset, currentAsset);
        }
    }

    function _positionKey(uint256 requestId, address sellerController) private view returns (bytes32) {
        return keccak256(abi.encode(address(vault), requestId, sellerController));
    }

    function _requireZeroDust() private view {
        uint256 assetBalance = IERC20(asset).balanceOf(address(this));
        if (assetBalance != 0) {
            revert AdapterTokenDust(asset, assetBalance);
        }
        if (share != asset) {
            uint256 shareBalance = IERC20(share).balanceOf(address(this));
            if (shareBalance != 0) {
                revert AdapterTokenDust(share, shareBalance);
            }
        }
        if (address(this).balance != 0) {
            revert AdapterNativeDust(address(this).balance);
        }
    }

    function _requireInterface(address endpoint, bytes4 interfaceId) private view {
        if (!ERC165Checker.supportsInterface(endpoint, interfaceId)) {
            revert UnsupportedInterface(interfaceId);
        }
    }
}
