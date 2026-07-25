// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import { ProductiveFundingAccount } from "./ProductiveFundingAccount.sol";
import { IClaimAdapter } from "./interfaces/IClaimAdapter.sol";
import { ClaimTypes } from "./types/ClaimTypes.sol";

/// @notice Fill-or-kill settlement for factor-signed asynchronous-claim quotes.
contract AsyncClaimSettlement is EIP712, ReentrancyGuardTransient {
    error InvalidFactor();
    error InvalidFundingAccount();
    error OnlyFactor(address caller);
    error ConfigurationSealed();
    error ConfigurationIncomplete();
    error InvalidAdapter();
    error AdapterAlreadyAllowed(address adapter);
    error AdapterNotAllowed(address adapter);
    error SettlementPaused();
    error OnlySeller(address caller, address seller);
    error QuoteFactorMismatch(address supplied);
    error ClaimPartyMissing();
    error PaymentAssetMismatch(address supplied, address expected);
    error InvalidPaymentAmount();
    error ClaimDataHashMismatch(bytes32 supplied, bytes32 expected);
    error BoundsHashMismatch(bytes32 supplied, bytes32 expected);
    error QuoteExpired(uint256 deadline, uint256 timestamp);
    error QuoteDeadlineTooFar(uint256 deadline, uint256 maximum);
    error NonceAlreadyUsed(uint256 nonce);
    error NonceBelowFloor(uint256 nonce, uint256 floor);
    error NonceFloorNotIncreasing(uint256 supplied, uint256 current);
    error InvalidFactorSignature(address recovered);
    error InsufficientCapacity(uint256 required, uint256 available);
    error InvalidAcquisition();
    error InexactPayment(uint256 requested, uint256 paid);

    event AdapterAllowed(address indexed adapter);
    event AdapterRevoked(address indexed adapter);
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
        bytes32 positionKey,
        uint256 claimId,
        uint256 pendingUnits,
        uint256 pendingReceived,
        uint256 claimableUnits,
        uint256 assetsReceived
    );

    bytes32 public constant CLAIM_QUOTE_TYPEHASH = keccak256(
        "ClaimQuote(address factor,address seller,address adapter,address claimController,address claimReceiver,address paymentAsset,uint256 paymentAmount,bytes32 claimDataHash,bytes32 boundsHash,uint256 nonce,uint256 deadline)"
    );
    uint256 public constant MAX_QUOTE_LIFETIME = 15 minutes;

    address public immutable factorSigner;
    ProductiveFundingAccount public immutable fundingAccount;

    mapping(address adapter => bool allowed) public isAdapterAllowed;
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

    constructor(address factorSigner_, ProductiveFundingAccount fundingAccount_) EIP712("Reservoir v2", "1") {
        if (factorSigner_ == address(0)) {
            revert InvalidFactor();
        }
        if (
            address(fundingAccount_) == address(0) || address(fundingAccount_).code.length == 0
                || fundingAccount_.factor() != factorSigner_
        ) {
            revert InvalidFundingAccount();
        }
        factorSigner = factorSigner_;
        fundingAccount = fundingAccount_;
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
            adapterCount == 0 || !fundingAccount.isSealed() || fundingAccount.settlement() != address(this)
                || address(fundingAccount.paymentAsset()) == address(0)
        ) {
            revert ConfigurationIncomplete();
        }
        isSealed = true;
        emit SettlementSealed(address(fundingAccount), adapterCount);
    }

    function hashQuote(ClaimTypes.Quote calldata quote) public view returns (bytes32) {
        return _hashTypedDataV4(_quoteStructHash(quote));
    }

    function fill(
        ClaimTypes.Quote calldata quote,
        bytes calldata claimData,
        bytes calldata boundsData,
        bytes calldata factorSignature
    )
        external
        nonReentrant
        returns (ClaimTypes.Acquisition memory acquisition)
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
        if (quote.claimController == address(0) || quote.claimReceiver == address(0)) {
            revert ClaimPartyMissing();
        }

        address expectedPaymentAsset = address(fundingAccount.paymentAsset());
        if (quote.paymentAsset != expectedPaymentAsset) {
            revert PaymentAssetMismatch(quote.paymentAsset, expectedPaymentAsset);
        }
        if (quote.paymentAmount == 0) {
            revert InvalidPaymentAmount();
        }

        bytes32 actualClaimDataHash = keccak256(claimData);
        if (actualClaimDataHash != quote.claimDataHash) {
            revert ClaimDataHashMismatch(actualClaimDataHash, quote.claimDataHash);
        }
        bytes32 actualBoundsHash = keccak256(boundsData);
        if (actualBoundsHash != quote.boundsHash) {
            revert BoundsHashMismatch(actualBoundsHash, quote.boundsHash);
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

        bytes32 quoteHash = hashQuote(quote);
        if (!SignatureChecker.isValidSignatureNow(factorSigner, quoteHash, factorSignature)) {
            (address recovered,,) = ECDSA.tryRecover(quoteHash, factorSignature);
            revert InvalidFactorSignature(recovered);
        }

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

        uint256 paid = fundingAccount.materializeAndPay(quote.seller, quote.paymentAmount);
        if (paid != quote.paymentAmount) {
            revert InexactPayment(quote.paymentAmount, paid);
        }

        emit ClaimSettled(
            quoteHash,
            quote.adapter,
            quote.seller,
            quote.factor,
            quote.claimController,
            quote.claimReceiver,
            quote.paymentAsset,
            quote.paymentAmount,
            acquisition.positionKey,
            acquisition.claimId,
            acquisition.pendingUnits,
            acquisition.pendingReceived,
            acquisition.claimableUnits,
            acquisition.assetsReceived
        );
    }

    function _quoteStructHash(ClaimTypes.Quote calldata quote) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CLAIM_QUOTE_TYPEHASH,
                quote.factor,
                quote.seller,
                quote.adapter,
                quote.claimController,
                quote.claimReceiver,
                quote.paymentAsset,
                quote.paymentAmount,
                quote.claimDataHash,
                quote.boundsHash,
                quote.nonce,
                quote.deadline
            )
        );
    }
}
