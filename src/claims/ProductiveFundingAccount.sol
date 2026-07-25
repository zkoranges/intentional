// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ERC4626ReserveAdapter } from "../adapters/ERC4626ReserveAdapter.sol";
import { IAquaReserveAdapter } from "../interfaces/IAquaReserveAdapter.sol";

/// @notice Single-factor, single-asset productive funding account for Reservoir v2.
/// @dev Reuses the shipped v1 reserve adapter without exposing its
///      state-changing methods to any caller other than this account.
contract ProductiveFundingAccount {
    using SafeERC20 for IERC20;

    error InvalidFactor();
    error OnlyFactor(address caller);
    error OnlySettlement(address caller);
    error ConfigurationSealed();
    error ConfigurationIncomplete();
    error AlreadyConfigured();
    error InvalidAdapter();
    error InvalidSettlement();
    error AdapterBindingMismatch(address adapter);
    error NonZeroReserveParameter();
    error InvalidRecipient();
    error InvalidAmount();
    error FundingPaused();
    error FundingNotPaused();
    error InvalidShareAmount();
    error InexactMaterialization(uint256 requested, uint256 delivered);
    error InexactPayment(uint256 requested, uint256 received);

    event ReserveConfigured(address indexed asset, address indexed adapter, address indexed vault);
    event SettlementConfigured(address indexed settlement);
    event FundingSealed(address indexed settlement, address indexed adapter);
    event InventoryPrepared(address indexed asset);
    event PaymentMade(address indexed recipient, address indexed asset, uint256 amount);
    event PauseChanged(bool paused);
    event AssetsWithdrawn(address indexed recipient, address indexed asset, uint256 amount);
    event SharesWithdrawn(address indexed recipient, address indexed vault, uint256 shares);

    address public immutable factor;

    IAquaReserveAdapter public reserveAdapter;
    IERC20 public paymentAsset;
    IERC4626 public vault;
    address public settlement;
    bool public isSealed;
    bool public isPaused;

    modifier onlyFactor() {
        if (msg.sender != factor) {
            revert OnlyFactor(msg.sender);
        }
        _;
    }

    modifier beforeSeal() {
        if (isSealed) {
            revert ConfigurationSealed();
        }
        _;
    }

    constructor(address factor_) {
        if (factor_ == address(0)) {
            revert InvalidFactor();
        }
        factor = factor_;
    }

    function configureReserve(IAquaReserveAdapter adapter_) external onlyFactor beforeSeal {
        if (address(reserveAdapter) != address(0)) {
            revert AlreadyConfigured();
        }
        if (address(adapter_) == address(0) || address(adapter_).code.length == 0) {
            revert InvalidAdapter();
        }

        ERC4626ReserveAdapter shippedAdapter = ERC4626ReserveAdapter(address(adapter_));
        address asset_ = shippedAdapter.asset();
        IERC4626 vault_ = shippedAdapter.vault();
        if (
            shippedAdapter.makerAccount() != address(this) || asset_ == address(0) || asset_.code.length == 0
                || address(vault_) == address(0) || address(vault_).code.length == 0 || vault_.asset() != asset_
        ) {
            revert AdapterBindingMismatch(address(adapter_));
        }
        if (adapter_.idleThreshold(asset_) != 0 || shippedAdapter.liquidityBufferAssets() != 0) {
            revert NonZeroReserveParameter();
        }

        reserveAdapter = adapter_;
        paymentAsset = IERC20(asset_);
        vault = vault_;

        paymentAsset.forceApprove(address(adapter_), type(uint256).max);
        IERC20(address(vault_)).forceApprove(address(adapter_), type(uint256).max);

        emit ReserveConfigured(asset_, address(adapter_), address(vault_));
    }

    function configureSettlement(address settlement_) external onlyFactor beforeSeal {
        if (settlement != address(0)) {
            revert AlreadyConfigured();
        }
        if (settlement_ == address(0) || settlement_.code.length == 0) {
            revert InvalidSettlement();
        }
        settlement = settlement_;
        emit SettlementConfigured(settlement_);
    }

    function prepareInventory() external onlyFactor beforeSeal {
        _reinvestInventory();
    }

    /// @notice Deposits new factor-provided payment assets after launch.
    /// @dev This is intentionally factor-only. The factor transfers underlying
    ///      to this account first, then calls this function.
    function reinvestInventory() external onlyFactor {
        if (isPaused) {
            revert FundingPaused();
        }
        _reinvestInventory();
    }

    function _reinvestInventory() private {
        IAquaReserveAdapter adapter = reserveAdapter;
        if (address(adapter) == address(0)) {
            revert ConfigurationIncomplete();
        }
        adapter.reinvest(address(paymentAsset));
        emit InventoryPrepared(address(paymentAsset));
    }

    /// @notice Stops new payments while preserving factor recovery.
    function setPaused(bool paused) external onlyFactor {
        isPaused = paused;
        emit PauseChanged(paused);
    }

    /// @notice Recovers exact underlying while payments are paused.
    function withdrawAssets(address recipient, uint256 amount) external onlyFactor returns (uint256 withdrawn) {
        if (!isPaused) {
            revert FundingNotPaused();
        }
        if (recipient == address(0) || recipient == address(this)) {
            revert InvalidRecipient();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }

        uint256 delivered = reserveAdapter.materialize(address(paymentAsset), amount);
        if (delivered != amount) {
            revert InexactMaterialization(amount, delivered);
        }
        paymentAsset.safeTransfer(recipient, amount);
        emit AssetsWithdrawn(recipient, address(paymentAsset), amount);
        return amount;
    }

    /// @notice Recovers vault shares directly while payments are paused.
    function withdrawShares(address recipient, uint256 shares) external onlyFactor returns (uint256 withdrawn) {
        if (!isPaused) {
            revert FundingNotPaused();
        }
        if (recipient == address(0) || recipient == address(this)) {
            revert InvalidRecipient();
        }
        if (shares == 0) {
            revert InvalidShareAmount();
        }

        IERC20(address(vault)).safeTransfer(recipient, shares);
        emit SharesWithdrawn(recipient, address(vault), shares);
        return shares;
    }

    function seal() external onlyFactor beforeSeal {
        if (
            address(reserveAdapter) == address(0) || address(paymentAsset) == address(0) || address(vault) == address(0)
                || settlement == address(0)
        ) {
            revert ConfigurationIncomplete();
        }
        isSealed = true;
        emit FundingSealed(settlement, address(reserveAdapter));
    }

    /// @notice Returns complete same-state payment capacity, conservatively returning zero on failure.
    function availableFor(uint256 wanted) external view returns (uint256 canDeliver) {
        if (!isSealed || isPaused || wanted == 0) {
            return 0;
        }
        try reserveAdapter.availableFor(address(paymentAsset), wanted) returns (
            uint256 available, uint256 exitCostWad
        ) {
            if (exitCostWad != 0 || available > wanted) {
                return 0;
            }
            return available;
        } catch {
            return 0;
        }
    }

    /// @notice Materializes and transfers the exact fixed payment.
    /// @dev Callable only by the sealed settlement kernel. Recipient balance-delta
    ///      verification deliberately rejects fee-on-transfer payment assets.
    function materializeAndPay(address recipient, uint256 amount) external returns (uint256 paid) {
        if (msg.sender != settlement) {
            revert OnlySettlement(msg.sender);
        }
        if (!isSealed) {
            revert ConfigurationIncomplete();
        }
        if (isPaused) {
            revert FundingPaused();
        }
        if (recipient == address(0) || recipient == address(this)) {
            revert InvalidRecipient();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }

        uint256 recipientBefore = paymentAsset.balanceOf(recipient);
        uint256 delivered = reserveAdapter.materialize(address(paymentAsset), amount);
        if (delivered != amount) {
            revert InexactMaterialization(amount, delivered);
        }

        paymentAsset.safeTransfer(recipient, amount);
        uint256 recipientAfter = paymentAsset.balanceOf(recipient);
        uint256 received = recipientAfter >= recipientBefore ? recipientAfter - recipientBefore : 0;
        if (received != amount) {
            revert InexactPayment(amount, received);
        }

        emit PaymentMade(recipient, address(paymentAsset), amount);
        return amount;
    }
}
