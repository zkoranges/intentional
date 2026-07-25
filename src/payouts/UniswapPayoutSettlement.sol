// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import { ProductiveFundingAccount } from "../claims/ProductiveFundingAccount.sol";
import { IClaimAdapter } from "../claims/interfaces/IClaimAdapter.sol";
import { ClaimTypes } from "../claims/types/ClaimTypes.sol";
import { IPayoutExecutor } from "./interfaces/IPayoutExecutor.sol";
import { PayoutTypes } from "./types/PayoutTypes.sol";

/// @notice Fill-or-kill settlement for factor-signed asynchronous-claim quotes
///         whose payout leg converts the exact WETH funding into the quote's
///         signed payout asset through an immutable executor.
/// @dev Copy of the reviewed `AsyncClaimSettlement` with the payout deltas of
///      `uniswap_payouts_idea.md` §4.3 and the §12 any-asset generalization:
///      the payout asset is a signed quote field gated by a factor-controlled
///      allowlist that mirrors the adapter allowlist exactly.
contract UniswapPayoutSettlement is EIP712, ReentrancyGuardTransient {
    error InvalidFactor();
    error InvalidFundingAccount();
    error InvalidExecutor();
    error OnlyFactor(address caller);
    error ConfigurationSealed();
    error ConfigurationIncomplete();
    error InvalidAdapter();
    error AdapterAlreadyAllowed(address adapter);
    error AdapterNotAllowed(address adapter);
    error InvalidPayoutAsset();
    error PayoutAssetAlreadyAllowed(address asset);
    error PayoutAssetNotAllowed(address asset);
    error SettlementPaused();
    error OnlySeller(address caller, address seller);
    error QuoteFactorMismatch(address supplied);
    error ClaimPartyMissing();
    error ClaimControllerIsSeller(address seller);
    error ClaimReceiverIsSeller(address seller);
    error PaymentAssetMismatch(address supplied, address expected);
    error InvalidPaymentAmount();
    error InvalidMinimumPayout();
    error ClaimDataHashMismatch(bytes32 supplied, bytes32 expected);
    error BoundsHashMismatch(bytes32 supplied, bytes32 expected);
    error PayoutDataHashMismatch(bytes32 supplied, bytes32 expected);
    error QuoteExpired(uint256 deadline, uint256 timestamp);
    error QuoteDeadlineTooFar(uint256 deadline, uint256 maximum);
    error NonceAlreadyUsed(uint256 nonce);
    error NonceBelowFloor(uint256 nonce, uint256 floor);
    error NonceFloorNotIncreasing(uint256 supplied, uint256 current);
    error InvalidFactorSignature(address recovered);
    error InsufficientCapacity(uint256 required, uint256 available);
    error InvalidAcquisition();
    error InexactPayment(uint256 requested, uint256 paid);
    error InsufficientPayout(uint256 delivered, uint256 minimum);
    error PayoutResidue();

    event AdapterAllowed(address indexed adapter);
    event AdapterRevoked(address indexed adapter);
    event PayoutAssetAllowed(address indexed asset);
    event PayoutAssetRevoked(address indexed asset);
    event SettlementSealed(address indexed fundingAccount, uint256 adapterCount);
    event SettlementPauseChanged(bool paused);
    event NonceCancelled(uint256 indexed nonce);
    event NonceFloorAdvanced(uint256 previousFloor, uint256 newFloor);
    event ClaimSettled(
        bytes32 indexed quoteHash,
        address indexed adapter,
        address indexed seller,
        address factor,
        address claimController,
        address claimReceiver,
        address paymentAsset,
        uint256 paymentAmount,
        address payoutAsset,
        uint256 minimumPayoutAmount,
        uint256 payoutDelivered,
        bytes32 positionKey,
        uint256 claimId,
        uint256 pendingUnits,
        uint256 pendingReceived,
        uint256 claimableUnits,
        uint256 assetsReceived
    );

    bytes32 public constant PAYOUT_QUOTE_TYPEHASH = keccak256(
        "PayoutQuote(address factor,address seller,address adapter,address claimController,address claimReceiver,address paymentAsset,uint256 paymentAmount,bytes32 claimDataHash,bytes32 boundsHash,address payoutAsset,uint256 minimumPayoutAmount,bytes32 payoutDataHash,uint256 nonce,uint256 deadline)"
    );
    uint256 public constant MAX_QUOTE_LIFETIME = 15 minutes;

    address public immutable factorSigner;
    ProductiveFundingAccount public immutable fundingAccount;
    IPayoutExecutor public immutable payoutExecutor;

    // Core bindings are sealed, while these trust boundaries intentionally
    // remain factor-controlled for emergency revocation and upgrades.
    mapping(address adapter => bool allowed) public isAdapterAllowed;
    mapping(address asset => bool allowed) public isPayoutAssetAllowed;
    mapping(uint256 nonce => bool used) public nonceUsed;

    uint256 public adapterCount;
    uint256 public nonceFloor;
    bool public isSealed;
    bool public isPaused;

    modifier onlyFactor() {
        if (msg.sender != factorSigner) {
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

    constructor(
        address factorSigner_,
        ProductiveFundingAccount fundingAccount_,
        IPayoutExecutor payoutExecutor_
    )
        EIP712("Reservoir Uniswap Payouts", "1")
    {
        if (factorSigner_ == address(0)) {
            revert InvalidFactor();
        }
        if (
            address(fundingAccount_) == address(0) || address(fundingAccount_).code.length == 0
                || fundingAccount_.factor() != factorSigner_
        ) {
            revert InvalidFundingAccount();
        }
        if (
            address(payoutExecutor_) == address(0) || address(payoutExecutor_).code.length == 0
                || payoutExecutor_.settlement() != address(this)
                || payoutExecutor_.fundingAsset() != address(fundingAccount_.paymentAsset())
        ) {
            revert InvalidExecutor();
        }
        factorSigner = factorSigner_;
        fundingAccount = fundingAccount_;
        payoutExecutor = payoutExecutor_;
    }

    function allowAdapter(address adapter) external onlyFactor {
        if (adapter == address(0) || adapter.code.length == 0) {
            revert InvalidAdapter();
        }
        if (isAdapterAllowed[adapter]) {
            revert AdapterAlreadyAllowed(adapter);
        }
        isAdapterAllowed[adapter] = true;
        unchecked {
            ++adapterCount;
        }
        emit AdapterAllowed(adapter);
    }

    function revokeAdapter(address adapter) external onlyFactor {
        if (!isAdapterAllowed[adapter]) {
            revert AdapterNotAllowed(adapter);
        }
        isAdapterAllowed[adapter] = false;
        unchecked {
            --adapterCount;
        }
        emit AdapterRevoked(adapter);
    }

    /// @notice The factor signs every quote, so this rail is defence in depth
    ///         against a mis-built quote, not the primary control.
    function allowPayoutAsset(address asset) external onlyFactor {
        if (asset == address(0) || asset.code.length == 0 || asset == address(fundingAccount.paymentAsset())) {
            revert InvalidPayoutAsset();
        }
        if (isPayoutAssetAllowed[asset]) {
            revert PayoutAssetAlreadyAllowed(asset);
        }
        isPayoutAssetAllowed[asset] = true;
        emit PayoutAssetAllowed(asset);
    }

    function revokePayoutAsset(address asset) external onlyFactor {
        if (!isPayoutAssetAllowed[asset]) {
            revert PayoutAssetNotAllowed(asset);
        }
        isPayoutAssetAllowed[asset] = false;
        emit PayoutAssetRevoked(asset);
    }

    function setPaused(bool paused) external onlyFactor {
        isPaused = paused;
        emit SettlementPauseChanged(paused);
    }

    function cancelNonce(uint256 nonce) external onlyFactor {
        nonceUsed[nonce] = true;
        emit NonceCancelled(nonce);
    }

    function advanceNonceFloor(uint256 newFloor) external onlyFactor {
        uint256 current = nonceFloor;
        if (newFloor <= current) {
            revert NonceFloorNotIncreasing(newFloor, current);
        }
        nonceFloor = newFloor;
        emit NonceFloorAdvanced(current, newFloor);
    }

    function seal() external onlyFactor beforeSeal {
        if (
            adapterCount == 0 || address(payoutExecutor) == address(0) || !fundingAccount.isSealed()
                || fundingAccount.settlement() != address(this) || address(fundingAccount.paymentAsset()) == address(0)
        ) {
            revert ConfigurationIncomplete();
        }
        isSealed = true;
        emit SettlementSealed(address(fundingAccount), adapterCount);
    }

    function hashQuote(PayoutTypes.Quote calldata quote) public view returns (bytes32) {
        return _hashTypedDataV4(_quoteStructHash(quote));
    }

    function fill(
        PayoutTypes.Quote calldata quote,
        bytes calldata claimData,
        bytes calldata boundsData,
        bytes calldata payoutData,
        bytes calldata factorSignature
    )
        external
        nonReentrant
        returns (ClaimTypes.Acquisition memory acquisition)
    {
        bytes32 quoteHash = _validate(quote, claimData, boundsData, payoutData, factorSignature);

        // Effects precede every state-changing external interaction. A later
        // revert rolls this write back with the complete fill.
        nonceUsed[quote.nonce] = true;

        uint256 capacity = fundingAccount.availableFor(quote.paymentAmount);
        if (capacity != quote.paymentAmount) {
            revert InsufficientCapacity(quote.paymentAmount, capacity);
        }

        acquisition = IClaimAdapter(quote.adapter)
            .acquire(
                ClaimTypes.ClaimContext({
                seller: quote.seller, claimController: quote.claimController, claimReceiver: quote.claimReceiver
            }),
                claimData,
                boundsData
            );
        if (acquisition.positionKey == bytes32(0) || (acquisition.pendingUnits == 0 && acquisition.claimableUnits == 0))
        {
            revert InvalidAcquisition();
        }

        uint256 delivered = _payOut(quote, payoutData);

        _emitSettled(quoteHash, quote, delivered, acquisition);
    }

    function _payOut(PayoutTypes.Quote calldata quote, bytes calldata payoutData) private returns (uint256 delivered) {
        IERC20 payoutAsset = IERC20(quote.payoutAsset);
        uint256 payoutBefore = payoutAsset.balanceOf(quote.seller);

        uint256 paid = fundingAccount.materializeAndPay(address(payoutExecutor), quote.paymentAmount);
        if (paid != quote.paymentAmount) {
            revert InexactPayment(quote.paymentAmount, paid);
        }

        payoutExecutor.payout(quote.seller, payoutAsset, quote.paymentAmount, quote.minimumPayoutAmount, payoutData);

        // The executor's return value is deliberately discarded: the kernel
        // re-measures the seller's balance itself, mirroring the house rule of
        // re-checking `paid` above.
        delivered = payoutAsset.balanceOf(quote.seller) - payoutBefore;
        if (delivered < quote.minimumPayoutAmount) {
            revert InsufficientPayout(delivered, quote.minimumPayoutAmount);
        }
        if (
            IERC20(payoutExecutor.fundingAsset()).balanceOf(address(payoutExecutor)) != 0
                || payoutAsset.balanceOf(address(payoutExecutor)) != 0
        ) {
            revert PayoutResidue();
        }
    }

    function _validate(
        PayoutTypes.Quote calldata quote,
        bytes calldata claimData,
        bytes calldata boundsData,
        bytes calldata payoutData,
        bytes calldata factorSignature
    )
        private
        view
        returns (bytes32 quoteHash)
    {
        if (isPaused) {
            revert SettlementPaused();
        }
        if (!isSealed) {
            revert ConfigurationIncomplete();
        }
        if (msg.sender != quote.seller) {
            revert OnlySeller(msg.sender, quote.seller);
        }
        if (quote.factor != factorSigner) {
            revert QuoteFactorMismatch(quote.factor);
        }
        if (!isAdapterAllowed[quote.adapter]) {
            revert InvalidAdapter();
        }
        if (!isPayoutAssetAllowed[quote.payoutAsset]) {
            revert PayoutAssetNotAllowed(quote.payoutAsset);
        }
        if (quote.claimController == address(0) || quote.claimReceiver == address(0)) {
            revert ClaimPartyMissing();
        }
        if (quote.claimController == quote.seller) {
            revert ClaimControllerIsSeller(quote.seller);
        }
        if (quote.claimReceiver == quote.seller) {
            revert ClaimReceiverIsSeller(quote.seller);
        }

        address expectedPaymentAsset = address(fundingAccount.paymentAsset());
        if (quote.paymentAsset != expectedPaymentAsset) {
            revert PaymentAssetMismatch(quote.paymentAsset, expectedPaymentAsset);
        }
        if (quote.paymentAmount == 0) {
            revert InvalidPaymentAmount();
        }
        if (quote.minimumPayoutAmount == 0) {
            revert InvalidMinimumPayout();
        }

        bytes32 actualClaimDataHash = keccak256(claimData);
        if (actualClaimDataHash != quote.claimDataHash) {
            revert ClaimDataHashMismatch(actualClaimDataHash, quote.claimDataHash);
        }
        bytes32 actualBoundsHash = keccak256(boundsData);
        if (actualBoundsHash != quote.boundsHash) {
            revert BoundsHashMismatch(actualBoundsHash, quote.boundsHash);
        }
        bytes32 actualPayoutDataHash = keccak256(payoutData);
        if (actualPayoutDataHash != quote.payoutDataHash) {
            revert PayoutDataHashMismatch(actualPayoutDataHash, quote.payoutDataHash);
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > quote.deadline) {
            revert QuoteExpired(quote.deadline, block.timestamp);
        }
        uint256 maximumDeadline = block.timestamp + MAX_QUOTE_LIFETIME;
        if (quote.deadline > maximumDeadline) {
            revert QuoteDeadlineTooFar(quote.deadline, maximumDeadline);
        }
        if (quote.nonce < nonceFloor) {
            revert NonceBelowFloor(quote.nonce, nonceFloor);
        }
        if (nonceUsed[quote.nonce]) {
            revert NonceAlreadyUsed(quote.nonce);
        }

        quoteHash = hashQuote(quote);
        if (!SignatureChecker.isValidSignatureNow(factorSigner, quoteHash, factorSignature)) {
            (address recovered,,) = ECDSA.tryRecover(quoteHash, factorSignature);
            revert InvalidFactorSignature(recovered);
        }
    }

    function _emitSettled(
        bytes32 quoteHash,
        PayoutTypes.Quote calldata quote,
        uint256 delivered,
        ClaimTypes.Acquisition memory acquisition
    )
        private
    {
        emit ClaimSettled(
            quoteHash,
            quote.adapter,
            quote.seller,
            quote.factor,
            quote.claimController,
            quote.claimReceiver,
            quote.paymentAsset,
            quote.paymentAmount,
            quote.payoutAsset,
            quote.minimumPayoutAmount,
            delivered,
            acquisition.positionKey,
            acquisition.claimId,
            acquisition.pendingUnits,
            acquisition.pendingReceived,
            acquisition.claimableUnits,
            acquisition.assetsReceived
        );
    }

    function _quoteStructHash(PayoutTypes.Quote calldata quote) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PAYOUT_QUOTE_TYPEHASH,
                quote.factor,
                quote.seller,
                quote.adapter,
                quote.claimController,
                quote.claimReceiver,
                quote.paymentAsset,
                quote.paymentAmount,
                quote.claimDataHash,
                quote.boundsHash,
                quote.payoutAsset,
                quote.minimumPayoutAmount,
                quote.payoutDataHash,
                quote.nonce,
                quote.deadline
            )
        );
    }
}
