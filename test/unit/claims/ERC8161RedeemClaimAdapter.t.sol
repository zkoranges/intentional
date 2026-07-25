// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IERC7540RedeemTransferable } from "../../../src/claims/interfaces/IERC7540RedeemTransferable.sol";
import { ClaimTypes } from "../../../src/claims/types/ClaimTypes.sol";
import { ERC8161RedeemClaimAdapter } from "../../../src/claims/adapters/ERC8161RedeemClaimAdapter.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockERC7540ERC8161Vault } from "../../mocks/claims/MockERC7540ERC8161Vault.sol";

contract ERC8161KernelStub { }

contract ERC8161RedeemClaimAdapterTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TOTAL = 100e18;

    address internal kernel;
    address internal seller = makeAddr("seller");
    address internal factorController = makeAddr("factorController");
    address internal claimReceiver = makeAddr("claimReceiver");

    MockERC20 internal asset;
    MockERC7540ERC8161Vault internal vault;
    ERC8161RedeemClaimAdapter internal adapter;
    address internal shareToken;

    ClaimTypes.ClaimContext internal context;
    uint256 internal requestId;

    function setUp() public {
        asset = new MockERC20("Mock Claim Asset", "MCA", 18);
        vault = new MockERC7540ERC8161Vault(asset);
        shareToken = vault.share();
        kernel = address(new ERC8161KernelStub());
        adapter = new ERC8161RedeemClaimAdapter(IERC7540RedeemTransferable(address(vault)), kernel);

        asset.mint(address(vault), 1000e18);
        requestId = _request(seller, seller, TOTAL);

        vm.prank(seller);
        vault.setOperator(address(adapter), true);

        context = ClaimTypes.ClaimContext({
            seller: seller, claimController: factorController, claimReceiver: claimReceiver
        });
    }

    function test_ConstructorBindsExternalShareAssetVaultAndKernel() public view {
        assertEq(address(adapter.vault()), address(vault));
        assertEq(adapter.asset(), address(asset));
        assertEq(adapter.share(), vault.share());
        assertNotEq(adapter.share(), address(vault));
        assertEq(adapter.settlement(), kernel);
    }

    function test_ConstructorRequiresEveryReviewedInterface() public {
        _expectUnsupportedInterface(adapter.ERC7540_OPERATOR_INTERFACE_ID());
        _expectUnsupportedInterface(adapter.ERC7540_REDEEM_INTERFACE_ID());
        _expectUnsupportedInterface(adapter.ERC7575_INTERFACE_ID());
        _expectUnsupportedInterface(adapter.ERC8161_REDEEM_TRANSFERABLE_INTERFACE_ID());
    }

    function test_ConstructorRequiresDeployedSettlementCode() public {
        vm.expectRevert(abi.encodeWithSelector(ERC8161RedeemClaimAdapter.InvalidSettlement.selector, address(0)));
        new ERC8161RedeemClaimAdapter(IERC7540RedeemTransferable(address(vault)), address(0));

        address eoa = makeAddr("settlementEOA");
        vm.expectRevert(abi.encodeWithSelector(ERC8161RedeemClaimAdapter.InvalidSettlement.selector, eoa));
        new ERC8161RedeemClaimAdapter(IERC7540RedeemTransferable(address(vault)), eoa);
    }

    function test_InspectReportsBoundPositionWithoutCallingPreviews() public view {
        ClaimTypes.ClaimFacts memory facts = adapter.inspect(_claimData(requestId, seller));

        assertEq(facts.positionKey, keccak256(abi.encode(address(vault), requestId, seller)));
        assertEq(facts.asset, address(asset));
        assertEq(facts.share, vault.share());
        assertEq(facts.claimId, requestId);
        assertEq(facts.pendingUnits, TOTAL);
        assertEq(facts.claimableUnits, 0);
        assertTrue(facts.exists);
    }

    function test_InspectEmptyPositionReportsNonexistent() public view {
        ClaimTypes.ClaimFacts memory facts = adapter.inspect(_claimData(requestId + 100, seller));
        assertEq(facts.pendingUnits, 0);
        assertEq(facts.claimableUnits, 0);
        assertFalse(facts.exists);
    }

    function test_AcquirePendingOnlyTransfersWholePosition() public {
        ClaimTypes.Acquisition memory acquired = _acquire(_bounds(TOTAL, WAD, WAD));

        _assertAcquisition(acquired, TOTAL, TOTAL, 0, 0);
        assertEq(vault.pendingRedeemRequest(requestId, seller), 0);
        assertEq(vault.claimableRedeemRequest(requestId, seller), 0);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), TOTAL);
        assertEq(vault.transferCallCount(), 1);
        assertEq(vault.redeemCallCount(), 0);
        _assertZeroDust();
    }

    function test_AcquireClaimableOnlyRedeemsToReceiver() public {
        vault.process(requestId, seller, TOTAL);

        ClaimTypes.Acquisition memory acquired = _acquire(_bounds(TOTAL, WAD, WAD));

        _assertAcquisition(acquired, 0, 0, TOTAL, TOTAL);
        assertEq(vault.pendingRedeemRequest(requestId, seller), 0);
        assertEq(vault.claimableRedeemRequest(requestId, seller), 0);
        assertEq(asset.balanceOf(claimReceiver), TOTAL);
        assertEq(vault.transferCallCount(), 0);
        assertEq(vault.redeemCallCount(), 1);
        _assertZeroDust();
    }

    function test_AcquireMixedRunsPendingAndClaimableLegs() public {
        uint256 claimable = 40e18;
        vault.process(requestId, seller, claimable);

        ClaimTypes.Acquisition memory acquired = _acquire(_bounds(TOTAL, WAD, WAD));

        _assertAcquisition(acquired, TOTAL - claimable, TOTAL - claimable, claimable, claimable);
        assertEq(vault.pendingRedeemRequest(requestId, seller), 0);
        assertEq(vault.claimableRedeemRequest(requestId, seller), 0);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), 60e18);
        assertEq(asset.balanceOf(claimReceiver), 40e18);
        assertEq(vault.transferCallCount(), 1);
        assertEq(vault.redeemCallCount(), 1);
        _assertZeroDust();
    }

    function testFuzz_AcquireEveryConstantTotalSplit(uint256 claimable) public {
        claimable = bound(claimable, 0, TOTAL);
        vault.process(requestId, seller, claimable);

        ClaimTypes.Acquisition memory acquired = _acquire(_bounds(TOTAL, WAD, WAD));

        uint256 pending = TOTAL - claimable;
        _assertAcquisition(acquired, pending, pending, claimable, claimable);
        assertEq(vault.pendingRedeemRequest(requestId, seller), 0);
        assertEq(vault.claimableRedeemRequest(requestId, seller), 0);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), pending);
        assertEq(asset.balanceOf(claimReceiver), claimable);
    }

    function test_AcquireMeasuresDeltaOverPreexistingFactorPosition() public {
        uint256 preexisting = 7e18;
        vault.setNextRequestId(requestId);
        _request(factorController, factorController, preexisting);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), preexisting);

        ClaimTypes.Acquisition memory acquired = _acquire(_bounds(TOTAL, WAD, WAD));

        assertEq(acquired.pendingReceived, TOTAL);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), preexisting + TOTAL);
    }

    function test_AcquireMeasuresDeltaOverPreexistingReceiverAssets() public {
        uint256 preexisting = 11e18;
        asset.mint(claimReceiver, preexisting);
        vault.process(requestId, seller, TOTAL);

        ClaimTypes.Acquisition memory acquired = _acquire(_bounds(TOTAL, WAD, WAD));

        assertEq(acquired.assetsReceived, TOTAL);
        assertEq(asset.balanceOf(claimReceiver), preexisting + TOTAL);
    }

    function test_TotalDriftAboveQuoteRevertsBeforeMovement() public {
        bytes memory signedBounds = _bounds(TOTAL, WAD, WAD);
        vault.setNextRequestId(requestId);
        _request(seller, seller, 1);

        vm.expectRevert(
            abi.encodeWithSelector(ERC8161RedeemClaimAdapter.TotalSharesMismatch.selector, TOTAL, TOTAL + 1)
        );
        _acquire(signedBounds);

        assertEq(vault.pendingRedeemRequest(requestId, seller), TOTAL + 1);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), 0);
    }

    function test_TotalDriftBelowQuoteRevertsBeforeMovement() public {
        uint256 removed = 10e18;
        bytes memory signedBounds = _bounds(TOTAL, WAD, WAD);
        vault.process(requestId, seller, removed);
        vm.prank(seller);
        vault.redeem(removed, seller, seller);

        vm.expectRevert(
            abi.encodeWithSelector(ERC8161RedeemClaimAdapter.TotalSharesMismatch.selector, TOTAL, TOTAL - removed)
        );
        _acquire(signedBounds);

        assertEq(vault.pendingRedeemRequest(requestId, seller), TOTAL - removed);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), 0);
    }

    function test_RequestIdZeroRejectedByInspectAndAcquire() public {
        vault.setZeroRequestIdMode(true);
        uint256 zeroId = _request(seller, seller, 1e18);
        assertEq(zeroId, 0);
        bytes memory zeroClaim = _claimData(0, seller);

        vm.expectRevert(ERC8161RedeemClaimAdapter.RequestIdZero.selector);
        adapter.inspect(zeroClaim);

        vm.prank(kernel);
        vm.expectRevert(ERC8161RedeemClaimAdapter.RequestIdZero.selector);
        adapter.acquire(context, zeroClaim, _bounds(1e18, WAD, WAD));
    }

    function test_PermittedTransferFeeUsesMeasuredPendingDelta() public {
        vault.setTransferFeeWad(0.01e18);

        ClaimTypes.Acquisition memory acquired = _acquire(_bounds(TOTAL, 0.99e18, WAD));

        assertEq(acquired.pendingUnits, TOTAL);
        assertEq(acquired.pendingReceived, 99e18);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), 99e18);
    }

    function test_ExcessiveTransferFeeRevertsAndRollsTransferBack() public {
        vault.setTransferFeeWad(0.02e18);

        vm.expectRevert(
            abi.encodeWithSelector(ERC8161RedeemClaimAdapter.PendingTransferRateBelowFloor.selector, 99e18, 98e18)
        );
        _acquire(_bounds(TOTAL, 0.99e18, WAD));

        assertEq(vault.pendingRedeemRequest(requestId, seller), TOTAL);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), 0);
    }

    function test_TransferFloorUsesFullPrecisionCeil() public {
        vault.setTransferFeeWad(WAD);

        vm.expectRevert(
            abi.encodeWithSelector(ERC8161RedeemClaimAdapter.PendingTransferRateBelowFloor.selector, 100, 0)
        );
        _acquire(_bounds(TOTAL, 1, WAD));
    }

    function test_PermittedRedemptionImpairmentUsesMeasuredAssetDelta() public {
        vault.process(requestId, seller, TOTAL);
        vault.setRedeemRateWad(0.9e18);

        ClaimTypes.Acquisition memory acquired = _acquire(_bounds(TOTAL, WAD, 0.9e18));

        assertEq(acquired.claimableUnits, TOTAL);
        assertEq(acquired.assetsReceived, 90e18);
    }

    function test_ExcessiveRedemptionImpairmentRevertsAndRollsRedeemBack() public {
        vault.process(requestId, seller, TOTAL);
        vault.setRedeemRateWad(0.89e18);

        vm.expectRevert(
            abi.encodeWithSelector(ERC8161RedeemClaimAdapter.RedemptionRateBelowFloor.selector, 90e18, 89e18)
        );
        _acquire(_bounds(TOTAL, WAD, 0.9e18));

        assertEq(vault.claimableRedeemRequest(requestId, seller), TOTAL);
        assertEq(asset.balanceOf(claimReceiver), 0);
    }

    function test_RedemptionFloorUsesFullPrecisionCeil() public {
        vault.process(requestId, seller, TOTAL);
        vault.setRedeemRateWad(0);

        vm.expectRevert(abi.encodeWithSelector(ERC8161RedeemClaimAdapter.RedemptionRateBelowFloor.selector, 100, 0));
        _acquire(_bounds(TOTAL, WAD, 1));
    }

    function test_RedeemReturnValueIsIgnoredInFavorOfReceiverDelta() public {
        vault.process(requestId, seller, TOTAL);
        vault.setRedeemRateWad(0.9e18);
        vault.setRedeemReturnLie(true, type(uint256).max);

        ClaimTypes.Acquisition memory acquired = _acquire(_bounds(TOTAL, WAD, 0.9e18));

        assertEq(acquired.assetsReceived, 90e18);
        assertEq(asset.balanceOf(claimReceiver), 90e18);
    }

    function test_LyingRedeemReturnCannotHideImpairment() public {
        vault.process(requestId, seller, TOTAL);
        vault.setRedeemRateWad(0.8e18);
        vault.setRedeemReturnLie(true, TOTAL);

        vm.expectRevert(
            abi.encodeWithSelector(ERC8161RedeemClaimAdapter.RedemptionRateBelowFloor.selector, 90e18, 80e18)
        );
        _acquire(_bounds(TOTAL, WAD, 0.9e18));
    }

    function test_ResidualSellerStateRevertsAndRollsTransferBack() public {
        vault.setResidualPendingOnTransfer(1);

        vm.expectRevert(abi.encodeWithSelector(ERC8161RedeemClaimAdapter.SellerPositionNotDrained.selector, 1, 0));
        _acquire(_bounds(TOTAL, WAD, WAD));

        assertEq(vault.pendingRedeemRequest(requestId, seller), TOTAL);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), 0);
    }

    function test_MissingAndRevokedOperatorApprovalRejectAcquisition() public {
        vm.prank(seller);
        vault.setOperator(address(adapter), false);

        vm.expectRevert(
            abi.encodeWithSelector(ERC8161RedeemClaimAdapter.OperatorNotApproved.selector, seller, address(adapter))
        );
        _acquire(_bounds(TOTAL, WAD, WAD));

        vm.prank(seller);
        vault.setOperator(address(adapter), true);
        _acquire(_bounds(TOTAL, WAD, WAD));

        vault.mintShares(seller, 1e18);
        uint256 secondId;
        vm.prank(seller);
        secondId = vault.requestRedeem(1e18, seller, seller);
        vm.prank(seller);
        vault.setOperator(address(adapter), false);

        vm.prank(kernel);
        vm.expectRevert(
            abi.encodeWithSelector(ERC8161RedeemClaimAdapter.OperatorNotApproved.selector, seller, address(adapter))
        );
        adapter.acquire(context, _claimData(secondId, seller), _bounds(1e18, WAD, WAD));
    }

    function test_OnlyImmutableKernelCanAcquire() public {
        vm.expectRevert(abi.encodeWithSelector(ERC8161RedeemClaimAdapter.OnlySettlement.selector, address(this)));
        adapter.acquire(context, _claimData(requestId, seller), _bounds(TOTAL, WAD, WAD));
    }

    function test_SellerControllerMustEqualContextSeller() public {
        ClaimTypes.ClaimContext memory wrongContext = context;
        wrongContext.seller = makeAddr("wrongSeller");

        vm.prank(kernel);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC8161RedeemClaimAdapter.SellerControllerMismatch.selector, wrongContext.seller, seller
            )
        );
        adapter.acquire(wrongContext, _claimData(requestId, seller), _bounds(TOTAL, WAD, WAD));
    }

    function test_ClaimControllerAndReceiverMustBeNonzero() public {
        ClaimTypes.ClaimContext memory wrongContext = context;
        wrongContext.claimController = address(0);
        vm.prank(kernel);
        vm.expectRevert(abi.encodeWithSelector(ERC8161RedeemClaimAdapter.InvalidClaimController.selector, address(0)));
        adapter.acquire(wrongContext, _claimData(requestId, seller), _bounds(TOTAL, WAD, WAD));

        wrongContext = context;
        wrongContext.claimReceiver = address(0);
        vm.prank(kernel);
        vm.expectRevert(abi.encodeWithSelector(ERC8161RedeemClaimAdapter.InvalidClaimReceiver.selector, address(0)));
        adapter.acquire(wrongContext, _claimData(requestId, seller), _bounds(TOTAL, WAD, WAD));
    }

    function test_AdapterCannotTakePendingControllerCustody() public {
        ClaimTypes.ClaimContext memory wrongContext = context;
        wrongContext.claimController = address(adapter);

        vm.prank(kernel);
        vm.expectRevert(ERC8161RedeemClaimAdapter.AdapterAsClaimController.selector);
        adapter.acquire(wrongContext, _claimData(requestId, seller), _bounds(TOTAL, WAD, WAD));

        assertEq(vault.pendingRedeemRequest(requestId, seller), TOTAL);
        assertEq(vault.pendingRedeemRequest(requestId, address(adapter)), 0);
        assertEq(vault.transferCallCount(), 0);
        assertEq(vault.redeemCallCount(), 0);
        _assertZeroDust();
    }

    function test_AdapterCannotBeTheClaimReceiver() public {
        ClaimTypes.ClaimContext memory wrongContext = context;
        wrongContext.claimReceiver = address(adapter);

        vm.prank(kernel);
        vm.expectRevert(ERC8161RedeemClaimAdapter.AdapterAsClaimReceiver.selector);
        adapter.acquire(wrongContext, _claimData(requestId, seller), _bounds(TOTAL, WAD, WAD));

        assertEq(vault.pendingRedeemRequest(requestId, seller), TOTAL);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), 0);
        assertEq(vault.transferCallCount(), 0);
        assertEq(vault.redeemCallCount(), 0);
        _assertZeroDust();
    }

    function test_ClaimIdentityIsBoundToImmutableEndpointMetadata() public {
        ERC8161RedeemClaimAdapter.ERC8161ClaimData memory claim =
            abi.decode(_claimData(requestId, seller), (ERC8161RedeemClaimAdapter.ERC8161ClaimData));

        claim.vault = makeAddr("wrongVault");
        vm.expectRevert(
            abi.encodeWithSelector(ERC8161RedeemClaimAdapter.ClaimVaultMismatch.selector, address(vault), claim.vault)
        );
        adapter.inspect(abi.encode(claim));

        claim.vault = address(vault);
        claim.share = makeAddr("wrongShare");
        vm.expectRevert(
            abi.encodeWithSelector(ERC8161RedeemClaimAdapter.ClaimShareMismatch.selector, vault.share(), claim.share)
        );
        adapter.inspect(abi.encode(claim));

        claim.share = vault.share();
        claim.asset = makeAddr("wrongAsset");
        vm.expectRevert(
            abi.encodeWithSelector(ERC8161RedeemClaimAdapter.ClaimAssetMismatch.selector, address(asset), claim.asset)
        );
        adapter.inspect(abi.encode(claim));
    }

    function test_ExpectedTotalMustBeNonzero() public {
        vm.expectRevert(ERC8161RedeemClaimAdapter.EmptyPosition.selector);
        _acquire(_bounds(0, WAD, WAD));
    }

    function test_PreexistingAdapterAssetDustRevertsAndAcquisitionRollsBack() public {
        asset.mint(address(adapter), 1);

        vm.expectRevert(abi.encodeWithSelector(ERC8161RedeemClaimAdapter.AdapterTokenDust.selector, address(asset), 1));
        _acquire(_bounds(TOTAL, WAD, WAD));

        assertEq(vault.pendingRedeemRequest(requestId, seller), TOTAL);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), 0);
    }

    function test_PreexistingAdapterShareDustRevertsAndAcquisitionRollsBack() public {
        vault.mintShares(address(adapter), 1);

        vm.expectRevert(abi.encodeWithSelector(ERC8161RedeemClaimAdapter.AdapterTokenDust.selector, shareToken, 1));
        _acquire(_bounds(TOTAL, WAD, WAD));

        assertEq(vault.pendingRedeemRequest(requestId, seller), TOTAL);
        assertEq(vault.pendingRedeemRequest(requestId, factorController), 0);
    }

    function _request(address owner, address controller, uint256 shares) internal returns (uint256 id) {
        vault.mintShares(owner, shares);
        vm.prank(owner);
        id = vault.requestRedeem(shares, controller, owner);
    }

    function _acquire(bytes memory boundsData) internal returns (ClaimTypes.Acquisition memory acquisition) {
        vm.prank(kernel);
        acquisition = adapter.acquire(context, _claimData(requestId, seller), boundsData);
    }

    function _claimData(uint256 id, address controller) internal view returns (bytes memory) {
        return abi.encode(
            ERC8161RedeemClaimAdapter.ERC8161ClaimData({
                vault: address(vault),
                share: shareToken,
                asset: address(asset),
                requestId: id,
                sellerController: controller
            })
        );
    }

    function _bounds(
        uint256 expectedTotal,
        uint256 minPendingRateWad,
        uint256 minAssetsPerShareWad
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            ERC8161RedeemClaimAdapter.ERC8161Bounds({
                expectedTotalShares: expectedTotal,
                minPendingTransferRateWad: minPendingRateWad,
                minAssetsPerClaimableShareWad: minAssetsPerShareWad
            })
        );
    }

    function _assertAcquisition(
        ClaimTypes.Acquisition memory acquired,
        uint256 pending,
        uint256 pendingReceived,
        uint256 claimable,
        uint256 assetsReceived
    )
        internal
        view
    {
        assertEq(acquired.positionKey, keccak256(abi.encode(address(vault), requestId, seller)));
        assertEq(acquired.claimId, requestId);
        assertEq(acquired.pendingUnits, pending);
        assertEq(acquired.pendingReceived, pendingReceived);
        assertEq(acquired.claimableUnits, claimable);
        assertEq(acquired.assetsReceived, assetsReceived);
    }

    function _assertZeroDust() internal view {
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(IERC20(shareToken).balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
    }

    function _expectUnsupportedInterface(bytes4 interfaceId) internal {
        MockERC7540ERC8161Vault unsupported = new MockERC7540ERC8161Vault(asset);
        unsupported.setInterfaceSupport(interfaceId, false);

        vm.expectRevert(abi.encodeWithSelector(ERC8161RedeemClaimAdapter.UnsupportedInterface.selector, interfaceId));
        new ERC8161RedeemClaimAdapter(IERC7540RedeemTransferable(address(unsupported)), kernel);
    }
}
