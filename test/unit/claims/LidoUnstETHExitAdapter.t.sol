// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LidoUnstETHExitAdapter } from "../../../src/claims/adapters/LidoUnstETHExitAdapter.sol";
import { ClaimTypes } from "../../../src/claims/types/ClaimTypes.sol";
import { MockLidoWithdrawalQueue } from "../../mocks/claims/MockLidoWithdrawalQueue.sol";
import { MockStETH } from "../../mocks/claims/MockStETH.sol";

/// @notice Race and precondition coverage for the existing-unstETH exit
///         adapter. The settlement role is played by this test contract; each
///         race between quote-time reads and fill-time state has its own test.
contract LidoUnstETHExitAdapterTest is Test {
    error ForcedLaterFailure();

    uint256 private constant AMOUNT = 10 ether;

    address private seller;
    address private receiver;
    address private thirdParty;
    MockStETH private stETH;
    MockLidoWithdrawalQueue private queue;
    LidoUnstETHExitAdapter private adapter;

    function setUp() public {
        seller = makeAddr("seller");
        receiver = makeAddr("receiver");
        thirdParty = makeAddr("thirdParty");
        stETH = new MockStETH();
        queue = new MockLidoWithdrawalQueue(IERC20(address(stETH)));
        adapter = new LidoUnstETHExitAdapter(address(this), IERC20(address(stETH)), queue);
    }

    // --- inspect ---

    function testInspectReportsPendingExistingRequest() public {
        uint256 requestId = _createSellerRequest(AMOUNT);

        ClaimTypes.ClaimFacts memory facts = adapter.inspect(_claimData(requestId));

        assertEq(facts.positionKey, keccak256(abi.encode(address(queue), requestId)));
        assertEq(facts.asset, address(0));
        assertEq(facts.share, address(stETH));
        assertEq(facts.claimId, requestId);
        assertEq(facts.pendingUnits, AMOUNT);
        assertEq(facts.claimableUnits, 0);
        assertTrue(facts.exists);
    }

    function testInspectReportsFinalizedRequestAsClaimable() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        queue.finalizeUpTo(requestId);

        ClaimTypes.ClaimFacts memory facts = adapter.inspect(_claimData(requestId));

        assertEq(facts.pendingUnits, 0);
        assertEq(facts.claimableUnits, AMOUNT);
        assertTrue(facts.exists);
    }

    function testInspectReportsClaimedRequestAsNonexistent() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        queue.finalizeUpTo(requestId);
        vm.prank(seller);
        queue.claimWithdrawal(requestId);

        ClaimTypes.ClaimFacts memory facts = adapter.inspect(_claimData(requestId));

        assertEq(facts.pendingUnits, 0);
        assertEq(facts.claimableUnits, 0);
        assertFalse(facts.exists);
    }

    // --- happy paths and unit mapping ---

    function testAcquirePendingTransfersNFTAndReportsPendingUnits() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        _approveAdapter(requestId);

        ClaimTypes.Acquisition memory acquired = _acquire(requestId);

        assertEq(acquired.positionKey, keccak256(abi.encode(address(queue), requestId)));
        assertEq(acquired.claimId, requestId);
        assertEq(acquired.pendingUnits, AMOUNT);
        assertEq(acquired.pendingReceived, AMOUNT);
        assertEq(acquired.claimableUnits, 0);
        assertEq(acquired.assetsReceived, 0);

        assertEq(queue.ownerOf(requestId), receiver);
        assertEq(queue.balanceOf(seller), 0);
        assertEq(queue.balanceOf(receiver), 1);
        assertEq(queue.getWithdrawalRequests(receiver).length, 1);
        assertEq(queue.getWithdrawalRequests(receiver)[0], requestId);
        assertEq(queue.getWithdrawalRequests(seller).length, 0);
        assertEq(queue.getApproved(requestId), address(0));
    }

    function testAcquireFinalizedTransfersNFTAndReportsClaimableUnits() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        queue.finalizeUpTo(requestId);
        _approveAdapter(requestId);

        ClaimTypes.Acquisition memory acquired = _acquire(requestId);

        assertEq(acquired.pendingUnits, 0);
        assertEq(acquired.pendingReceived, 0);
        assertEq(acquired.claimableUnits, AMOUNT);
        assertEq(acquired.assetsReceived, 0);
        assertEq(queue.ownerOf(requestId), receiver);
    }

    /// @dev The signed quote binds requestId and amount bounds, never the
    ///      finalization state. Finalization between quote and fill keeps the
    ///      exact same claimData/bounds valid and is buyer-favourable: the
    ///      receiver ends up with a claimable position instead of a pending
    ///      one at the same price.
    function testPendingQuoteFinalizedBeforeFillStaysValidAndBuyerFavourable() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory quoteTimeClaimData = _claimData(requestId);
        bytes memory quoteTimeBounds = _exactBounds(requestId);
        _approveAdapter(requestId);

        queue.finalizeUpTo(requestId);

        ClaimTypes.Acquisition memory acquired = adapter.acquire(_context(), quoteTimeClaimData, quoteTimeBounds);

        assertEq(acquired.pendingUnits, 0);
        assertEq(acquired.claimableUnits, AMOUNT);
        assertGt(acquired.pendingUnits + acquired.claimableUnits, 0);
        assertEq(queue.ownerOf(requestId), receiver);
    }

    // --- races: seller acts between quote and fill ---

    function testRevertsWhenSellerClaimsFirst() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory quoteTimeClaimData = _claimData(requestId);
        bytes memory quoteTimeBounds = _exactBounds(requestId);
        _approveAdapter(requestId);
        queue.finalizeUpTo(requestId);
        vm.prank(seller);
        queue.claimWithdrawal(requestId);

        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.RequestAlreadyClaimed.selector, requestId));
        adapter.acquire(_context(), quoteTimeClaimData, quoteTimeBounds);

        assertEq(queue.balanceOf(receiver), 0);
        assertEq(queue.getWithdrawalRequests(receiver).length, 0);
    }

    function testRevertsWhenSellerTransfersRequestAway() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory quoteTimeClaimData = _claimData(requestId);
        bytes memory quoteTimeBounds = _exactBounds(requestId);
        _approveAdapter(requestId);
        vm.prank(seller);
        queue.transferFrom(seller, thirdParty, requestId);

        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.InvalidRequestOwner.selector, thirdParty, seller));
        adapter.acquire(_context(), quoteTimeClaimData, quoteTimeBounds);

        assertEq(queue.ownerOf(requestId), thirdParty);
        assertEq(queue.balanceOf(receiver), 0);
    }

    function testRevertsWhenSellerRevokesApprovalFirst() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory quoteTimeClaimData = _claimData(requestId);
        bytes memory quoteTimeBounds = _exactBounds(requestId);
        _approveAdapter(requestId);
        vm.prank(seller);
        queue.approve(address(0), requestId);

        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.TransferNotApproved.selector, requestId));
        adapter.acquire(_context(), quoteTimeClaimData, quoteTimeBounds);

        assertEq(queue.ownerOf(requestId), seller);
    }

    // --- signed-bounds enforcement ---

    function testRevertsWhenStETHAmountDriftsBelowSignedMinimum() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory quoteTimeBounds = _exactBounds(requestId);
        _approveAdapter(requestId);
        queue.setRequestAmounts(requestId, AMOUNT - 1, AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(LidoUnstETHExitAdapter.StETHAmountOutOfBounds.selector, AMOUNT - 1, AMOUNT, AMOUNT)
        );
        adapter.acquire(_context(), _claimData(requestId), quoteTimeBounds);

        assertEq(queue.ownerOf(requestId), seller);
    }

    function testRevertsWhenStETHAmountDriftsAboveSignedMaximum() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory quoteTimeBounds = _exactBounds(requestId);
        _approveAdapter(requestId);
        queue.setRequestAmounts(requestId, AMOUNT + 1, AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(LidoUnstETHExitAdapter.StETHAmountOutOfBounds.selector, AMOUNT + 1, AMOUNT, AMOUNT)
        );
        adapter.acquire(_context(), _claimData(requestId), quoteTimeBounds);
    }

    function testRevertsWhenShareAmountDriftsOutsideSignedBounds() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory quoteTimeBounds = _exactBounds(requestId);
        _approveAdapter(requestId);
        queue.setRequestAmounts(requestId, AMOUNT, AMOUNT - 1);

        vm.expectRevert(
            abi.encodeWithSelector(LidoUnstETHExitAdapter.ShareAmountOutOfBounds.selector, AMOUNT - 1, AMOUNT, AMOUNT)
        );
        adapter.acquire(_context(), _claimData(requestId), quoteTimeBounds);

        queue.setRequestAmounts(requestId, AMOUNT, AMOUNT + 1);
        vm.expectRevert(
            abi.encodeWithSelector(LidoUnstETHExitAdapter.ShareAmountOutOfBounds.selector, AMOUNT + 1, AMOUNT, AMOUNT)
        );
        adapter.acquire(_context(), _claimData(requestId), quoteTimeBounds);
    }

    function testRevertsWhenRequestSharesBecomeZeroEvenWithZeroFloor() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        _approveAdapter(requestId);
        queue.setRequestAmounts(requestId, AMOUNT, 0);

        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.EmptyRequestShares.selector, requestId));
        adapter.acquire(_context(), _claimData(requestId), _bounds(0, type(uint256).max, 0, type(uint256).max));
    }

    function testRevertsOnInvertedSignedBounds() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        _approveAdapter(requestId);

        vm.expectRevert(LidoUnstETHExitAdapter.InvalidBounds.selector);
        adapter.acquire(_context(), _claimData(requestId), _bounds(AMOUNT, AMOUNT - 1, AMOUNT, AMOUNT));

        vm.expectRevert(LidoUnstETHExitAdapter.InvalidBounds.selector);
        adapter.acquire(_context(), _claimData(requestId), _bounds(AMOUNT, AMOUNT, AMOUNT, AMOUNT - 1));
    }

    // --- wrong owner / receiver / queue / requestId ---

    function testRevertsWhenQuotedSellerDoesNotOwnTheRequest() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory claimData = _claimData(requestId);
        bytes memory bounds = _exactBounds(requestId);
        ClaimTypes.ClaimContext memory context = _context();
        context.seller = thirdParty;

        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.InvalidRequestOwner.selector, seller, thirdParty));
        adapter.acquire(context, claimData, bounds);
    }

    function testRevertsForWrongQueueEndpoint() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory bounds = _exactBounds(requestId);
        address wrongQueue = makeAddr("wrongQueue");
        bytes memory claimData = abi.encode(
            LidoUnstETHExitAdapter.LidoExitData({ queue: wrongQueue, stETH: address(stETH), requestId: requestId })
        );

        vm.expectRevert(
            abi.encodeWithSelector(LidoUnstETHExitAdapter.QueueMismatch.selector, wrongQueue, address(queue))
        );
        adapter.acquire(_context(), claimData, bounds);
    }

    function testRevertsForWrongStETHEndpoint() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory bounds = _exactBounds(requestId);
        address wrongStETH = makeAddr("wrongStETH");
        bytes memory claimData = abi.encode(
            LidoUnstETHExitAdapter.LidoExitData({ queue: address(queue), stETH: wrongStETH, requestId: requestId })
        );

        vm.expectRevert(
            abi.encodeWithSelector(LidoUnstETHExitAdapter.StETHMismatch.selector, wrongStETH, address(stETH))
        );
        adapter.acquire(_context(), claimData, bounds);
    }

    function testRevertsForZeroOrOutOfRangeRequestId() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory bounds = _exactBounds(requestId);

        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.InvalidRequestId.selector, 0));
        adapter.acquire(_context(), _claimData(0), bounds);

        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.InvalidRequestId.selector, requestId + 1));
        adapter.acquire(_context(), _claimData(requestId + 1), bounds);
    }

    function testRevertsForMissingOrInvalidClaimParties() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory claimData = _claimData(requestId);
        bytes memory bounds = _exactBounds(requestId);

        ClaimTypes.ClaimContext memory context = _context();
        context.seller = address(0);
        vm.expectRevert(LidoUnstETHExitAdapter.InvalidSeller.selector);
        adapter.acquire(context, claimData, bounds);

        context = _context();
        context.claimController = address(0);
        vm.expectRevert(LidoUnstETHExitAdapter.InvalidClaimController.selector);
        adapter.acquire(context, claimData, bounds);

        context = _context();
        context.claimReceiver = address(0);
        vm.expectRevert(LidoUnstETHExitAdapter.InvalidClaimReceiver.selector);
        adapter.acquire(context, claimData, bounds);

        context = _context();
        context.claimReceiver = address(adapter);
        vm.expectRevert(LidoUnstETHExitAdapter.AdapterAsClaimReceiver.selector);
        adapter.acquire(context, claimData, bounds);

        context = _context();
        context.claimReceiver = address(queue);
        vm.expectRevert(LidoUnstETHExitAdapter.QueueAsClaimReceiver.selector);
        adapter.acquire(context, claimData, bounds);
    }

    // --- approvals and settlement guard ---

    function testRevertsWithoutERC721Approval() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory claimData = _claimData(requestId);
        bytes memory bounds = _exactBounds(requestId);

        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.TransferNotApproved.selector, requestId));
        adapter.acquire(_context(), claimData, bounds);

        assertEq(queue.ownerOf(requestId), seller);
    }

    function testOperatorApprovalAuthorizesAcquisition() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        vm.prank(seller);
        queue.setApprovalForAll(address(adapter), true);

        ClaimTypes.Acquisition memory acquired = _acquire(requestId);

        assertEq(acquired.pendingUnits, AMOUNT);
        assertEq(queue.ownerOf(requestId), receiver);
    }

    function testOnlyImmutableSettlementCanAcquire() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory claimData = _claimData(requestId);
        bytes memory bounds = _exactBounds(requestId);
        address caller = makeAddr("notSettlement");

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.OnlySettlement.selector, caller));
        adapter.acquire(_context(), claimData, bounds);
    }

    // --- queue response-shape and measured postconditions ---

    function testRevertsUnlessExactlyOneStatusIsReturned() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory claimData = _claimData(requestId);
        bytes memory bounds = _exactBounds(requestId);
        _approveAdapter(requestId);

        queue.setResponseLengths(1, 0);
        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.InvalidStatusCount.selector, 0));
        adapter.acquire(_context(), claimData, bounds);

        queue.setResponseLengths(1, 2);
        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.InvalidStatusCount.selector, 2));
        adapter.acquire(_context(), claimData, bounds);
    }

    function testRevertsWhenAmountsDriftDuringTransfer() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory claimData = _claimData(requestId);
        bytes memory bounds = _exactBounds(requestId);
        _approveAdapter(requestId);
        queue.setPostTransferAmountDrift(AMOUNT - 1, AMOUNT, true);

        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.RequestAmountsChanged.selector, requestId));
        adapter.acquire(_context(), claimData, bounds);
    }

    function testRevertsWhenTransferDeliversToAnotherOwner() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory claimData = _claimData(requestId);
        bytes memory bounds = _exactBounds(requestId);
        _approveAdapter(requestId);
        queue.setPostTransferOwnerHijack(thirdParty, true);

        vm.expectRevert(
            abi.encodeWithSelector(LidoUnstETHExitAdapter.InvalidPostTransferOwner.selector, thirdParty, receiver)
        );
        adapter.acquire(_context(), claimData, bounds);
    }

    function testRevertsWhenFinalizationRegressesMidFill() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory claimData = _claimData(requestId);
        bytes memory bounds = _exactBounds(requestId);
        queue.finalizeUpTo(requestId);
        _approveAdapter(requestId);
        queue.setDefinalizeOnTransfer(true);

        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.FinalizationRegressed.selector, requestId));
        adapter.acquire(_context(), claimData, bounds);
    }

    // --- atomicity ---

    function testPreconditionFailureLeavesSellerPositionFullyIntact() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        _approveAdapter(requestId);
        bytes memory tooTightBounds = _bounds(AMOUNT + 1, AMOUNT + 2, 0, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoUnstETHExitAdapter.StETHAmountOutOfBounds.selector, AMOUNT, AMOUNT + 1, AMOUNT + 2
            )
        );
        adapter.acquire(_context(), _claimData(requestId), tooTightBounds);

        assertEq(queue.ownerOf(requestId), seller);
        assertEq(queue.getApproved(requestId), address(adapter));
        assertEq(queue.balanceOf(seller), 1);
        assertEq(queue.balanceOf(receiver), 0);
        assertEq(queue.getWithdrawalRequests(seller).length, 1);
    }

    function testLaterFailureRollsBackTheEntireTransfer() public {
        uint256 requestId = _createSellerRequest(AMOUNT);
        bytes memory claimData = _claimData(requestId);
        bytes memory bounds = _exactBounds(requestId);
        _approveAdapter(requestId);

        vm.expectRevert(ForcedLaterFailure.selector);
        this.acquireThenRevert(_context(), claimData, bounds);

        assertEq(queue.ownerOf(requestId), seller);
        assertEq(queue.balanceOf(receiver), 0);
        assertEq(queue.getWithdrawalRequests(seller).length, 1);
    }

    function acquireThenRevert(
        ClaimTypes.ClaimContext calldata context,
        bytes calldata claimData,
        bytes calldata boundsData
    )
        external
    {
        adapter.acquire(context, claimData, boundsData);
        revert ForcedLaterFailure();
    }

    // --- helpers ---

    function _createSellerRequest(uint256 amount) private returns (uint256 requestId) {
        stETH.mint(seller, amount);
        vm.startPrank(seller);
        stETH.approve(address(queue), amount);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory requestIds = queue.requestWithdrawals(amounts, seller);
        vm.stopPrank();
        requestId = requestIds[0];
        assertEq(queue.ownerOf(requestId), seller);
    }

    function _approveAdapter(uint256 requestId) private {
        vm.prank(seller);
        queue.approve(address(adapter), requestId);
    }

    function _acquire(uint256 requestId) private returns (ClaimTypes.Acquisition memory) {
        return adapter.acquire(_context(), _claimData(requestId), _exactBounds(requestId));
    }

    function _context() private view returns (ClaimTypes.ClaimContext memory) {
        return ClaimTypes.ClaimContext({ seller: seller, claimController: receiver, claimReceiver: receiver });
    }

    function _claimData(uint256 requestId) private view returns (bytes memory) {
        return abi.encode(
            LidoUnstETHExitAdapter.LidoExitData({ queue: address(queue), stETH: address(stETH), requestId: requestId })
        );
    }

    function _exactBounds(uint256 requestId) private view returns (bytes memory) {
        MockLidoWithdrawalQueue.WithdrawalRequestStatus memory status = queue.statusOf(requestId);
        return _bounds(status.amountOfStETH, status.amountOfStETH, status.amountOfShares, status.amountOfShares);
    }

    function _bounds(
        uint256 minAmount,
        uint256 maxAmount,
        uint256 minShares,
        uint256 maxShares
    )
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(
            LidoUnstETHExitAdapter.LidoExitBounds({
                minAmountOfStETH: minAmount,
                maxAmountOfStETH: maxAmount,
                minAmountOfShares: minShares,
                maxAmountOfShares: maxShares
            })
        );
    }
}
