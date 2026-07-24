// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAquaReserveAdapter } from "../interfaces/IAquaReserveAdapter.sol";

/// @notice Single-maker reserve adapter for one ERC-4626 vault and its asset.
contract ERC4626ReserveAdapter is IAquaReserveAdapter {
    using SafeERC20 for IERC20;

    error InvalidMakerAccount();
    error InvalidVault();
    error VaultAssetMismatch(address expected, address actual);
    error OnlyMakerAccount(address caller);
    error UnsupportedAsset(address supplied);
    error InsufficientWithdrawable(uint256 requested, uint256 withdrawable);
    error InexactMaterialization(uint256 requested, uint256 available);
    error ZeroSharesMinted(uint256 assets);
    error AdapterUnderlyingDust(uint256 remaining);

    event AssetsReinvested(address indexed asset, uint256 assets, uint256 shares);

    address public immutable makerAccount;
    address public immutable asset;
    IERC4626 public immutable vault;
    uint256 public immutable liquidityBufferAssets;

    uint256 private immutable _idleThreshold;

    modifier onlyMakerAccount() {
        if (msg.sender != makerAccount) {
            revert OnlyMakerAccount(msg.sender);
        }
        _;
    }

    constructor(address makerAccount_, IERC4626 vault_, uint256 idleThreshold_, uint256 liquidityBufferAssets_) {
        if (makerAccount_ == address(0)) {
            revert InvalidMakerAccount();
        }
        if (address(vault_) == address(0) || address(vault_).code.length == 0) {
            revert InvalidVault();
        }

        address asset_ = vault_.asset();
        if (asset_ == address(0) || asset_.code.length == 0) {
            revert VaultAssetMismatch(address(0), asset_);
        }

        makerAccount = makerAccount_;
        asset = asset_;
        vault = vault_;
        _idleThreshold = idleThreshold_;
        liquidityBufferAssets = liquidityBufferAssets_;
    }

    function availableFor(
        address requestedAsset,
        uint256 wanted
    )
        external
        view
        returns (uint256 canDeliver, uint256 exitCostWad)
    {
        if (requestedAsset != asset || wanted == 0) {
            return (0, 0);
        }

        uint256 idle;
        try IERC20(asset).balanceOf(makerAccount) returns (uint256 balance) {
            idle = balance;
        } catch { }

        uint256 withdrawable;
        try vault.maxWithdraw(makerAccount) returns (uint256 maximum) {
            withdrawable = maximum;
        } catch { }

        uint256 grossAvailable;
        unchecked {
            grossAvailable = type(uint256).max - idle < withdrawable ? type(uint256).max : idle + withdrawable;
        }
        uint256 safeAvailable = grossAvailable > liquidityBufferAssets ? grossAvailable - liquidityBufferAssets : 0;

        canDeliver = wanted < safeAvailable ? wanted : safeAvailable;
        exitCostWad = 0;
    }

    function materialize(address requestedAsset, uint256 amount) external onlyMakerAccount returns (uint256 delivered) {
        _requireAsset(requestedAsset);

        IERC20 underlying = IERC20(asset);
        uint256 idle = underlying.balanceOf(makerAccount);
        if (idle < amount) {
            uint256 shortfall;
            unchecked {
                shortfall = amount - idle;
            }
            uint256 withdrawable = vault.maxWithdraw(makerAccount);
            if (withdrawable < shortfall) {
                revert InsufficientWithdrawable(shortfall, withdrawable);
            }
            vault.withdraw(shortfall, makerAccount, makerAccount);
        }

        uint256 finalBalance = underlying.balanceOf(makerAccount);
        if (finalBalance < amount) {
            revert InexactMaterialization(amount, finalBalance);
        }
        return amount;
    }

    function reinvest(address requestedAsset) external onlyMakerAccount {
        _requireAsset(requestedAsset);

        IERC20 underlying = IERC20(asset);
        uint256 donated = underlying.balanceOf(address(this));
        if (donated != 0) {
            underlying.safeTransfer(makerAccount, donated);
        }
        uint256 idle = underlying.balanceOf(makerAccount);
        if (idle <= _idleThreshold) {
            return;
        }

        uint256 excess;
        unchecked {
            excess = idle - _idleThreshold;
        }
        uint256 maximum = vault.maxDeposit(makerAccount);
        uint256 depositAmount = excess < maximum ? excess : maximum;
        if (depositAmount == 0 || vault.previewDeposit(depositAmount) == 0) {
            return;
        }

        underlying.safeTransferFrom(makerAccount, address(this), depositAmount);
        underlying.forceApprove(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, makerAccount);
        if (shares == 0) {
            revert ZeroSharesMinted(depositAmount);
        }

        uint256 remaining = underlying.balanceOf(address(this));
        if (remaining != 0) {
            revert AdapterUnderlyingDust(remaining);
        }
        emit AssetsReinvested(asset, depositAmount, shares);
    }

    function idleThreshold(address requestedAsset) external view returns (uint256) {
        return requestedAsset == asset ? _idleThreshold : 0;
    }

    function _requireAsset(address requestedAsset) private view {
        if (requestedAsset != asset) {
            revert UnsupportedAsset(requestedAsset);
        }
    }
}
