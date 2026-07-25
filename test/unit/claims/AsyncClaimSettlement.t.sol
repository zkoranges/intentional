// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AsyncClaimSettlement } from "../../../src/claims/AsyncClaimSettlement.sol";
import { ProductiveFundingAccount } from "../../../src/claims/ProductiveFundingAccount.sol";
import { ClaimTypes } from "../../../src/claims/types/ClaimTypes.sol";
import { ERC4626ReserveAdapter } from "../../../src/adapters/ERC4626ReserveAdapter.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { RevertingERC4626 } from "../../mocks/RevertingERC4626.sol";
import { KernelClaimAdapter } from "../../mocks/claims/KernelClaimAdapter.sol";

contract TestERC1271Factor {
    bytes4 private constant MAGIC_VALUE = 0x1626ba7e;

    address public immutable owner;
    mapping(bytes32 digest => bool approved) public approvedDigest;

    constructor(address owner_) {
        owner = owner_;
    }

    function approveDigest(bytes32 digest) external {
        require(msg.sender == owner, "owner only");
        approvedDigest[digest] = true;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == owner, "owner only");
        bool success;
        (success, result) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return approvedDigest[digest] ? MAGIC_VALUE : bytes4(0xffffffff);
    }
}

contract AsyncClaimSettlementTest is Test {
    uint256 private constant FACTOR_KEY = 0xA11CE;
    uint256 private constant WRONG_KEY = 0xB0B;
    uint256 private constant FUNDING = 1000e18;
    uint256 private constant PAYMENT = 100e18;
    bytes32 private constant POSITION_KEY = keccak256("kernel.position");

    address private factor;
    address private seller = makeAddr("seller");
    address private claimController = makeAddr("claim-controller");
    address private claimReceiver = makeAddr("claim-receiver");
    address private stranger = makeAddr("stranger");

    MockERC20 private paymentAsset;
    RevertingERC4626 private vault;
    ProductiveFundingAccount private fundingAccount;
    ERC4626ReserveAdapter private reserveAdapter;
    AsyncClaimSettlement private settlement;
    KernelClaimAdapter private claimAdapter;

    bytes private claimData;
    bytes private boundsData;

    function setUp() public {
        factor = vm.addr(FACTOR_KEY);
        paymentAsset = new MockERC20("Payment WETH", "pWETH", 18);
        vault = new RevertingERC4626(IERC20(address(paymentAsset)), "Funding Vault", "fWETH");
        fundingAccount = new ProductiveFundingAccount(factor);
        reserveAdapter = new ERC4626ReserveAdapter(address(fundingAccount), vault, 0, 0);

        vm.prank(factor);
        fundingAccount.configureReserve(reserveAdapter);

        settlement = new AsyncClaimSettlement(factor, fundingAccount);
        claimAdapter = new KernelClaimAdapter(address(settlement));

        paymentAsset.mint(address(fundingAccount), FUNDING);
        vm.startPrank(factor);
        fundingAccount.prepareInventory();
        fundingAccount.configureSettlement(address(settlement));
        fundingAccount.seal();
        settlement.allowAdapter(address(claimAdapter));
        settlement.seal();
        vm.stopPrank();

        claimData = abi.encode(POSITION_KEY, uint256(7), uint256(60e18), uint256(40e18));
        boundsData = abi.encode(uint256(100e18), uint256(1e18), uint256(1e18));
    }

    function test_ValidFillConsumesNonceAcquiresThenPaysExactly() public {
        ClaimTypes.Quote memory quote = _quote(1, address(claimAdapter));
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        claimAdapter.configureNonceCheck(quote.nonce, true);

        uint256 sellerBefore = paymentAsset.balanceOf(seller);
        uint256 sharesBefore = vault.balanceOf(address(fundingAccount));
        uint256 expectedBurn = vault.previewWithdraw(PAYMENT);

        vm.prank(seller);
        ClaimTypes.Acquisition memory acquisition = settlement.fill(quote, claimData, boundsData, signature);

        assertEq(acquisition.positionKey, POSITION_KEY);
        assertEq(acquisition.claimId, 7);
        assertEq(acquisition.pendingUnits, 60e18);
        assertEq(acquisition.claimableUnits, 40e18);
        assertTrue(claimAdapter.acquired());
        assertEq(claimAdapter.acquireCount(), 1);
        assertTrue(settlement.nonceUsed(quote.nonce));
        assertEq(paymentAsset.balanceOf(seller) - sellerBefore, PAYMENT);
        assertEq(sharesBefore - vault.balanceOf(address(fundingAccount)), expectedBurn);
        assertEq(paymentAsset.balanceOf(address(fundingAccount)), 0);
    }

    function test_ReplayAndSellerOnlyValidation() public {
        ClaimTypes.Quote memory quote = _quote(2, address(claimAdapter));
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AsyncClaimSettlement.OnlySeller.selector, stranger, seller));
        settlement.fill(quote, claimData, boundsData, signature);

        vm.prank(seller);
        settlement.fill(quote, claimData, boundsData, signature);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AsyncClaimSettlement.NonceAlreadyUsed.selector, quote.nonce));
        settlement.fill(quote, claimData, boundsData, signature);
    }

    function test_InvalidFactorAndWrongDomainSignatures() public {
        ClaimTypes.Quote memory quote = _quote(3, address(claimAdapter));
        bytes memory wrongSignature = _sign(quote, WRONG_KEY, settlement);

        vm.prank(seller);
        vm.expectPartialRevert(AsyncClaimSettlement.InvalidFactorSignature.selector);
        settlement.fill(quote, claimData, boundsData, wrongSignature);

        AsyncClaimSettlement otherDomain = new AsyncClaimSettlement(factor, fundingAccount);
        bytes memory wrongDomainSignature = _sign(quote, FACTOR_KEY, otherDomain);
        vm.prank(seller);
        vm.expectPartialRevert(AsyncClaimSettlement.InvalidFactorSignature.selector);
        settlement.fill(quote, claimData, boundsData, wrongDomainSignature);
    }

    function test_QuoteIdentityAndByteHashesAreBound() public {
        ClaimTypes.Quote memory quote = _quote(4, address(claimAdapter));
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        bytes memory changedClaimData = abi.encode(POSITION_KEY, uint256(8), uint256(60e18), uint256(40e18));

        vm.prank(seller);
        vm.expectPartialRevert(AsyncClaimSettlement.ClaimDataHashMismatch.selector);
        settlement.fill(quote, changedClaimData, boundsData, signature);

        vm.prank(seller);
        vm.expectPartialRevert(AsyncClaimSettlement.BoundsHashMismatch.selector);
        settlement.fill(quote, claimData, abi.encode(uint256(99e18)), signature);

        quote.factor = stranger;
        signature = _sign(quote, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AsyncClaimSettlement.QuoteFactorMismatch.selector, stranger));
        settlement.fill(quote, claimData, boundsData, signature);
    }

    function test_PaymentClaimPartiesAndAdapterAreValidated() public {
        ClaimTypes.Quote memory quote = _quote(5, address(claimAdapter));

        quote.paymentAsset = address(0x1234);
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectPartialRevert(AsyncClaimSettlement.PaymentAssetMismatch.selector);
        settlement.fill(quote, claimData, boundsData, signature);

        quote = _quote(6, address(claimAdapter));
        quote.paymentAmount = 0;
        signature = _sign(quote, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectRevert(AsyncClaimSettlement.InvalidPaymentAmount.selector);
        settlement.fill(quote, claimData, boundsData, signature);

        quote = _quote(7, address(claimAdapter));
        quote.claimReceiver = address(0);
        signature = _sign(quote, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectRevert(AsyncClaimSettlement.ClaimPartyMissing.selector);
        settlement.fill(quote, claimData, boundsData, signature);

        KernelClaimAdapter unlisted = new KernelClaimAdapter(address(settlement));
        quote = _quote(8, address(unlisted));
        signature = _sign(quote, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectRevert(AsyncClaimSettlement.InvalidAdapter.selector);
        settlement.fill(quote, claimData, boundsData, signature);
    }

    function test_ExpiredQuoteRevertsWithoutConsumingNonce() public {
        ClaimTypes.Quote memory quote = _quote(9, address(claimAdapter));
        quote.deadline = block.timestamp + 1;
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        vm.warp(block.timestamp + 2);

        vm.prank(seller);
        vm.expectPartialRevert(AsyncClaimSettlement.QuoteExpired.selector);
        settlement.fill(quote, claimData, boundsData, signature);

        assertFalse(settlement.nonceUsed(quote.nonce));
        assertFalse(claimAdapter.acquired());
    }

    function test_InsufficientCapacityPreventsAcquisitionAndRollsNonceBack() public {
        ClaimTypes.Quote memory quote = _quote(10, address(claimAdapter));
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        vault.setWithdrawLimit(PAYMENT - 1);

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(AsyncClaimSettlement.InsufficientCapacity.selector, PAYMENT, PAYMENT - 1)
        );
        settlement.fill(quote, claimData, boundsData, signature);

        assertFalse(settlement.nonceUsed(quote.nonce));
        assertFalse(claimAdapter.acquired());
        assertEq(claimAdapter.acquireCount(), 0);
        assertEq(paymentAsset.balanceOf(seller), 0);
    }

    function test_AcquisitionFailureAndInvalidReceiptAreAtomic() public {
        ClaimTypes.Quote memory quote = _quote(11, address(claimAdapter));
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        claimAdapter.configureFailure(true);

        vm.prank(seller);
        vm.expectRevert(KernelClaimAdapter.ForcedAcquireFailure.selector);
        settlement.fill(quote, claimData, boundsData, signature);
        assertFalse(settlement.nonceUsed(quote.nonce));
        assertEq(paymentAsset.balanceOf(seller), 0);

        claimAdapter.configureFailure(false);
        claimAdapter.configureInvalidReturn(true);
        quote = _quote(12, address(claimAdapter));
        signature = _sign(quote, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectRevert(AsyncClaimSettlement.InvalidAcquisition.selector);
        settlement.fill(quote, claimData, boundsData, signature);

        assertFalse(settlement.nonceUsed(quote.nonce));
        assertFalse(claimAdapter.acquired(), "adapter mutation did not roll back");
        assertEq(paymentAsset.balanceOf(seller), 0);
    }

    function test_FundingFailureAfterAcquisitionRollsEverythingBack() public {
        ClaimTypes.Quote memory quote = _quote(13, address(claimAdapter));
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        uint256 sharesBefore = vault.balanceOf(address(fundingAccount));
        vault.setRevertWithdraw(true);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(RevertingERC4626.ForcedVaultRevert.selector, vault.withdraw.selector));
        settlement.fill(quote, claimData, boundsData, signature);

        assertFalse(settlement.nonceUsed(quote.nonce));
        assertFalse(claimAdapter.acquired());
        assertEq(claimAdapter.acquireCount(), 0);
        assertEq(vault.balanceOf(address(fundingAccount)), sharesBefore);
        assertEq(paymentAsset.balanceOf(seller), 0);
    }

    function test_NoncePrecedesExternalCallAndReentrancyCannotDoubleFill() public {
        ClaimTypes.Quote memory quote = _quote(14, address(claimAdapter));
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        claimAdapter.configureNonceCheck(quote.nonce, true);
        claimAdapter.configureReentry(
            abi.encodeCall(AsyncClaimSettlement.fill, (quote, claimData, boundsData, signature))
        );

        vm.prank(seller);
        settlement.fill(quote, claimData, boundsData, signature);

        assertTrue(claimAdapter.reentryAttempted());
        assertFalse(claimAdapter.reentrySucceeded());
        assertEq(claimAdapter.acquireCount(), 1);
        assertEq(paymentAsset.balanceOf(seller), PAYMENT);
    }

    function test_AdapterCannotCallFundingAccountDirectly() public {
        ClaimTypes.Quote memory quote = _quote(15, address(claimAdapter));
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        claimAdapter.configureFundingAttack(fundingAccount, seller, PAYMENT);

        vm.prank(seller);
        settlement.fill(quote, claimData, boundsData, signature);

        assertTrue(claimAdapter.fundingAttackAttempted());
        assertFalse(claimAdapter.fundingAttackSucceeded());
        assertEq(paymentAsset.balanceOf(seller), PAYMENT);
    }

    function test_ProductionControlsPauseCancelNonceFloorAndDeadlineCap() public {
        ClaimTypes.Quote memory quote = _quote(100, address(claimAdapter));
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);

        vm.prank(factor);
        settlement.cancelNonce(quote.nonce);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AsyncClaimSettlement.NonceAlreadyUsed.selector, quote.nonce));
        settlement.fill(quote, claimData, boundsData, signature);

        quote = _quote(101, address(claimAdapter));
        signature = _sign(quote, FACTOR_KEY, settlement);
        vm.prank(factor);
        settlement.setPaused(true);
        vm.prank(seller);
        vm.expectRevert(AsyncClaimSettlement.SettlementPaused.selector);
        settlement.fill(quote, claimData, boundsData, signature);

        vm.startPrank(factor);
        settlement.setPaused(false);
        settlement.advanceNonceFloor(200);
        vm.stopPrank();
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AsyncClaimSettlement.NonceBelowFloor.selector, 101, 200));
        settlement.fill(quote, claimData, boundsData, signature);

        quote = _quote(200, address(claimAdapter));
        quote.deadline = block.timestamp + settlement.MAX_QUOTE_LIFETIME() + 1;
        signature = _sign(quote, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectPartialRevert(AsyncClaimSettlement.QuoteDeadlineTooFar.selector);
        settlement.fill(quote, claimData, boundsData, signature);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AsyncClaimSettlement.OnlyFactor.selector, stranger));
        settlement.setPaused(true);
    }

    function test_RevokedAdapterCannotFillAndCanBeRestoredPostSeal() public {
        ClaimTypes.Quote memory quote = _quote(201, address(claimAdapter));
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);

        vm.prank(factor);
        settlement.revokeAdapter(address(claimAdapter));
        vm.prank(seller);
        vm.expectRevert(AsyncClaimSettlement.InvalidAdapter.selector);
        settlement.fill(quote, claimData, boundsData, signature);

        vm.prank(factor);
        settlement.allowAdapter(address(claimAdapter));
        vm.prank(seller);
        settlement.fill(quote, claimData, boundsData, signature);
        assertEq(paymentAsset.balanceOf(seller), PAYMENT);
    }

    function test_ContractWalletFactorCanAuthorizeAQuoteThroughERC1271() public {
        TestERC1271Factor contractFactor = new TestERC1271Factor(address(this));
        ProductiveFundingAccount safeFunding = new ProductiveFundingAccount(address(contractFactor));
        RevertingERC4626 safeVault = new RevertingERC4626(IERC20(address(paymentAsset)), "Safe Funding Vault", "sfWETH");
        ERC4626ReserveAdapter safeReserve = new ERC4626ReserveAdapter(address(safeFunding), safeVault, 0, 0);
        contractFactor.execute(
            address(safeFunding), abi.encodeCall(ProductiveFundingAccount.configureReserve, (safeReserve))
        );

        AsyncClaimSettlement safeKernel = new AsyncClaimSettlement(address(contractFactor), safeFunding);
        KernelClaimAdapter safeClaimAdapter = new KernelClaimAdapter(address(safeKernel));
        paymentAsset.mint(address(safeFunding), FUNDING);
        contractFactor.execute(address(safeFunding), abi.encodeCall(ProductiveFundingAccount.prepareInventory, ()));
        contractFactor.execute(
            address(safeFunding), abi.encodeCall(ProductiveFundingAccount.configureSettlement, (address(safeKernel)))
        );
        contractFactor.execute(address(safeFunding), abi.encodeCall(ProductiveFundingAccount.seal, ()));
        contractFactor.execute(
            address(safeKernel), abi.encodeCall(AsyncClaimSettlement.allowAdapter, (address(safeClaimAdapter)))
        );
        contractFactor.execute(address(safeKernel), abi.encodeCall(AsyncClaimSettlement.seal, ()));

        ClaimTypes.Quote memory quote = ClaimTypes.Quote({
            factor: address(contractFactor),
            seller: seller,
            adapter: address(safeClaimAdapter),
            claimController: claimController,
            claimReceiver: claimReceiver,
            paymentAsset: address(paymentAsset),
            paymentAmount: PAYMENT,
            claimDataHash: keccak256(claimData),
            boundsHash: keccak256(boundsData),
            nonce: 301,
            deadline: block.timestamp + 10 minutes
        });
        contractFactor.approveDigest(safeKernel.hashQuote(quote));

        vm.prank(seller);
        safeKernel.fill(quote, claimData, boundsData, hex"01");
        assertEq(paymentAsset.balanceOf(seller), PAYMENT);
    }

    function test_KernelConfigurationIsFactorControlledSingleAssignmentAndSealed() public {
        ProductiveFundingAccount freshFunding = new ProductiveFundingAccount(factor);
        RevertingERC4626 freshVault = new RevertingERC4626(IERC20(address(paymentAsset)), "Fresh Vault", "fFRESH");
        ERC4626ReserveAdapter freshReserve = new ERC4626ReserveAdapter(address(freshFunding), freshVault, 0, 0);
        vm.prank(factor);
        freshFunding.configureReserve(freshReserve);
        AsyncClaimSettlement freshKernel = new AsyncClaimSettlement(factor, freshFunding);
        KernelClaimAdapter freshClaimAdapter = new KernelClaimAdapter(address(freshKernel));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AsyncClaimSettlement.OnlyFactor.selector, stranger));
        freshKernel.allowAdapter(address(freshClaimAdapter));

        vm.prank(factor);
        freshKernel.allowAdapter(address(freshClaimAdapter));
        vm.prank(factor);
        vm.expectRevert(
            abi.encodeWithSelector(AsyncClaimSettlement.AdapterAlreadyAllowed.selector, address(freshClaimAdapter))
        );
        freshKernel.allowAdapter(address(freshClaimAdapter));

        vm.prank(factor);
        vm.expectRevert(AsyncClaimSettlement.ConfigurationIncomplete.selector);
        freshKernel.seal();

        vm.startPrank(factor);
        freshFunding.configureSettlement(address(freshKernel));
        freshFunding.seal();
        freshKernel.seal();
        freshKernel.allowAdapter(address(claimAdapter));
        assertTrue(freshKernel.isAdapterAllowed(address(claimAdapter)));
        freshKernel.revokeAdapter(address(claimAdapter));
        assertFalse(freshKernel.isAdapterAllowed(address(claimAdapter)));
        vm.stopPrank();

        assertTrue(freshKernel.isSealed());
    }

    function test_ConstructorRejectsInvalidFactorAndMismatchedFunding() public {
        vm.expectRevert(AsyncClaimSettlement.InvalidFactor.selector);
        new AsyncClaimSettlement(address(0), fundingAccount);

        ProductiveFundingAccount otherFunding = new ProductiveFundingAccount(stranger);
        vm.expectRevert(AsyncClaimSettlement.InvalidFundingAccount.selector);
        new AsyncClaimSettlement(factor, otherFunding);
    }

    function _quote(uint256 nonce, address adapterAddress) private view returns (ClaimTypes.Quote memory) {
        return ClaimTypes.Quote({
            factor: factor,
            seller: seller,
            adapter: adapterAddress,
            claimController: claimController,
            claimReceiver: claimReceiver,
            paymentAsset: address(paymentAsset),
            paymentAmount: PAYMENT,
            claimDataHash: keccak256(claimData),
            boundsHash: keccak256(boundsData),
            nonce: nonce,
            deadline: block.timestamp + 10 minutes
        });
    }

    function _sign(
        ClaimTypes.Quote memory quote,
        uint256 privateKey,
        AsyncClaimSettlement kernel
    )
        private
        view
        returns (bytes memory)
    {
        bytes32 digest = kernel.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
