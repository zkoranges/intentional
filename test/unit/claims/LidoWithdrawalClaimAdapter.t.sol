// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LidoWithdrawalClaimAdapter } from "../../../src/claims/adapters/LidoWithdrawalClaimAdapter.sol";
import { ClaimTypes } from "../../../src/claims/types/ClaimTypes.sol";
import { MockLidoWithdrawalQueue } from "../../mocks/claims/MockLidoWithdrawalQueue.sol";
import { MockStETH } from "../../mocks/claims/MockStETH.sol";

contract LidoWithdrawalClaimAdapterTest is Test {
    error ForcedLaterFailure();

    uint256 private constant REQUESTED = 10 ether;

    address private seller;
    address private receiver;
    MockStETH private stETH;
    MockLidoWithdrawalQueue private queue;
    LidoWithdrawalClaimAdapter private adapter;

    function setUp() public {
        seller = makeAddr("seller");
        receiver = makeAddr("receiver");
        stETH = new MockStETH();
        queue = new MockLidoWithdrawalQueue(IERC20(address(stETH)));
        adapter = new LidoWithdrawalClaimAdapter(address(this), IERC20(address(stETH)), queue);
    }

    function testInspectReportsAnUncreatedLidoClaim() public view {
        ClaimTypes.ClaimFacts memory facts = adapter.inspect(_claimData(REQUESTED));

        assertEq(facts.positionKey, bytes32(0));
        assertEq(facts.asset, address(0));
        assertEq(facts.share, address(stETH));
        assertEq(facts.claimId, 0);
        assertEq(facts.pendingUnits, 0);
        assertEq(facts.claimableUnits, 0);
        assertFalse(facts.exists);
    }

    function testAcquireExactTransferReconcilesReceiptAndClearsCustody() public {
        stETH.setRequireZeroFirstApproval(true);
        _fundAndApprove(REQUESTED);

        ClaimTypes.Acquisition memory acquired = _acquire(REQUESTED, 0, REQUESTED);

        assertEq(acquired.positionKey, keccak256(abi.encode(address(queue), uint256(1))));
        assertEq(acquired.claimId, 1);
        assertEq(acquired.pendingUnits, REQUESTED);
        assertEq(acquired.pendingReceived, REQUESTED);
        assertEq(acquired.claimableUnits, 0);
        assertEq(acquired.assetsReceived, 0);

        MockLidoWithdrawalQueue.WithdrawalRequestStatus memory status = queue.statusOf(1);
        assertEq(status.owner, receiver);
        assertEq(status.amountOfStETH, REQUESTED);
        assertEq(status.amountOfShares, REQUESTED);
        assertFalse(status.isClaimed);

        assertEq(stETH.balanceOf(address(adapter)), 0);
        assertEq(stETH.allowance(address(adapter), address(queue)), 0);
        assertEq(stETH.balanceOf(address(queue)), REQUESTED);
    }

    function testAcquireAcceptsOneWeiShortMeasuredReceipt() public {
        _fundAndApprove(REQUESTED);
        stETH.setNextTransferShortfall(1);

        ClaimTypes.Acquisition memory acquired = _acquire(REQUESTED, 1, REQUESTED - 1);

        assertEq(acquired.pendingUnits, REQUESTED - 1);
        assertEq(acquired.pendingReceived, REQUESTED - 1);
        assertEq(queue.statusOf(1).amountOfStETH, REQUESTED - 1);
        assertEq(stETH.balanceOf(address(adapter)), 0);
    }

    function testAcquireAcceptsTwoWeiShortMeasuredReceipt() public {
        _fundAndApprove(REQUESTED);
        stETH.setNextTransferShortfall(2);

        ClaimTypes.Acquisition memory acquired = _acquire(REQUESTED, 2, REQUESTED - 2);

        assertEq(acquired.pendingUnits, REQUESTED - 2);
        assertEq(acquired.pendingReceived, REQUESTED - 2);
        assertEq(queue.statusOf(1).amountOfStETH, REQUESTED - 2);
        assertEq(stETH.balanceOf(address(adapter)), 0);
    }

    function testAcquireAcceptsDocumentedMinimum() public {
        uint256 minimum = adapter.MIN_STETH_WITHDRAWAL_AMOUNT();
        _fundAndApprove(minimum);

        ClaimTypes.Acquisition memory acquired = _acquire(minimum, 0, minimum);

        assertEq(acquired.pendingReceived, minimum);
    }

    function testAcquireAcceptsDocumentedMaximum() public {
        uint256 maximum = adapter.MAX_STETH_WITHDRAWAL_AMOUNT();
        _fundAndApprove(maximum);

        ClaimTypes.Acquisition memory acquired = _acquire(maximum, 0, maximum);

        assertEq(acquired.pendingReceived, maximum);
    }

    function testRevertsWhenTransferShortfallExceedsSignedMaximum() public {
        _fundAndApprove(REQUESTED);
        stETH.setNextTransferShortfall(3);

        vm.expectRevert(abi.encodeWithSelector(LidoWithdrawalClaimAdapter.ExcessiveStETHShortfall.selector, 3, 2));
        _acquire(REQUESTED, 2, 1);
    }

    function testRevertsWhenMeasuredAmountIsBelowDocumentedMinimum() public {
        uint256 minimum = adapter.MIN_STETH_WITHDRAWAL_AMOUNT();
        _fundAndApprove(minimum);
        stETH.setNextTransferShortfall(1);

        vm.expectRevert(
            abi.encodeWithSelector(LidoWithdrawalClaimAdapter.RequestAmountBelowMinimum.selector, minimum - 1, minimum)
        );
        _acquire(minimum, 1, 1);
    }

    function testRevertsWhenMeasuredAmountIsAboveDocumentedMaximum() public {
        uint256 maximum = adapter.MAX_STETH_WITHDRAWAL_AMOUNT();
        _fundAndApprove(maximum + 1);

        vm.expectRevert(
            abi.encodeWithSelector(LidoWithdrawalClaimAdapter.RequestAmountAboveMaximum.selector, maximum + 1, maximum)
        );
        _acquire(maximum + 1, 0, 1);
    }

    function testRevertsWhenQueueRequestFails() public {
        _fundAndApprove(REQUESTED);
        queue.setFailure(true, false);

        vm.expectRevert(MockLidoWithdrawalQueue.RequestFailed.selector);
        _acquire(REQUESTED, 0, 1);
    }

    function testRevertsBeforePullWhenCanonicalQueueIsPaused() public {
        _fundAndApprove(REQUESTED);
        queue.setPaused(true);

        vm.expectRevert(LidoWithdrawalClaimAdapter.WithdrawalsPaused.selector);
        _acquire(REQUESTED, 0, 1);

        assertEq(stETH.balanceOf(seller), REQUESTED);
        assertEq(queue.lastRequestId(), 0);
    }

    function testRevertsWhenStatusReadFails() public {
        _fundAndApprove(REQUESTED);
        queue.setFailure(false, true);

        vm.expectRevert(MockLidoWithdrawalQueue.StatusFailed.selector);
        _acquire(REQUESTED, 0, 1);
    }

    function testRevertsUnlessExactlyOneRequestIdIsReturned() public {
        _fundAndApprove(REQUESTED);
        queue.setResponseLengths(0, 1);

        vm.expectRevert(abi.encodeWithSelector(LidoWithdrawalClaimAdapter.InvalidRequestIdCount.selector, 0));
        _acquire(REQUESTED, 0, 1);

        queue.setResponseLengths(2, 1);
        vm.expectRevert(abi.encodeWithSelector(LidoWithdrawalClaimAdapter.InvalidRequestIdCount.selector, 2));
        _acquire(REQUESTED, 0, 1);
    }

    function testRevertsWhenQueueReturnsZeroRequestId() public {
        _fundAndApprove(REQUESTED);
        queue.setReturnZeroRequestId(true);

        vm.expectRevert(LidoWithdrawalClaimAdapter.InvalidRequestId.selector);
        _acquire(REQUESTED, 0, 1);
    }

    function testRevertsUnlessExactlyOneStatusIsReturned() public {
        _fundAndApprove(REQUESTED);
        queue.setResponseLengths(1, 0);

        vm.expectRevert(abi.encodeWithSelector(LidoWithdrawalClaimAdapter.InvalidStatusCount.selector, 0));
        _acquire(REQUESTED, 0, 1);

        queue.setResponseLengths(1, 2);
        vm.expectRevert(abi.encodeWithSelector(LidoWithdrawalClaimAdapter.InvalidStatusCount.selector, 2));
        _acquire(REQUESTED, 0, 1);
    }

    function testRevertsWhenStatusOwnerDoesNotMatchReceiver() public {
        _fundAndApprove(REQUESTED);
        address wrongOwner = makeAddr("wrongOwner");
        queue.setStatusOwner(wrongOwner, true);

        vm.expectRevert(
            abi.encodeWithSelector(LidoWithdrawalClaimAdapter.InvalidRequestOwner.selector, wrongOwner, receiver)
        );
        _acquire(REQUESTED, 0, 1);
    }

    function testRevertsWhenStatusAmountDoesNotMatchMeasuredReceipt() public {
        _fundAndApprove(REQUESTED);
        queue.setStatusAmount(REQUESTED - 1, true);

        vm.expectRevert(
            abi.encodeWithSelector(LidoWithdrawalClaimAdapter.InvalidRequestAmount.selector, REQUESTED - 1, REQUESTED)
        );
        _acquire(REQUESTED, 0, 1);
    }

    function testRevertsWhenRequestSharesAreBelowSignedFloor() public {
        _fundAndApprove(REQUESTED);
        queue.setStatusShares(REQUESTED - 1, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoWithdrawalClaimAdapter.InsufficientRequestShares.selector, REQUESTED - 1, REQUESTED
            )
        );
        _acquire(REQUESTED, 0, REQUESTED);
    }

    function testRevertsWhenRequestSharesAreZeroEvenWithZeroFloor() public {
        _fundAndApprove(REQUESTED);
        queue.setStatusShares(0, true);

        vm.expectRevert(abi.encodeWithSelector(LidoWithdrawalClaimAdapter.InsufficientRequestShares.selector, 0, 0));
        _acquire(REQUESTED, 0, 0);
    }

    function testRevertsWhenReturnedRequestIsAlreadyClaimed() public {
        _fundAndApprove(REQUESTED);
        queue.setStatusClaimed(true);

        vm.expectRevert(abi.encodeWithSelector(LidoWithdrawalClaimAdapter.RequestAlreadyClaimed.selector, 1));
        _acquire(REQUESTED, 0, 1);
    }

    function testQueueSideRoundingResidualSharesAreRefundedToSeller() public {
        _fundAndApprove(REQUESTED);
        queue.setPullShortfall(1);

        ClaimTypes.Acquisition memory acquired = _acquire(REQUESTED, 0, 1);

        assertEq(acquired.pendingUnits, REQUESTED - 1);
        assertEq(acquired.pendingReceived, REQUESTED - 1);
        assertEq(stETH.balanceOf(seller), 1);
        assertEq(stETH.balanceOf(address(queue)), REQUESTED - 1);
        assertEq(stETH.sharesOf(address(adapter)), 0);
        assertEq(stETH.balanceOf(address(adapter)), 0);
    }

    function testPreexistingSharesArePreservedWithoutDonationDoS() public {
        stETH.mint(address(adapter), 1);
        _fundAndApprove(REQUESTED);

        ClaimTypes.Acquisition memory acquired = _acquire(REQUESTED, 0, 1);

        assertEq(stETH.sharesOf(address(adapter)), 1);
        assertEq(stETH.balanceOf(seller), 0);
        assertEq(queue.lastRequestId(), 1);
        assertEq(acquired.pendingReceived, REQUESTED);
    }

    function testRevertsForWrongImmutableEndpoints() public {
        _fundAndApprove(REQUESTED);

        LidoWithdrawalClaimAdapter.LidoOriginateData memory wrongQueueData = LidoWithdrawalClaimAdapter.LidoOriginateData({
            queue: makeAddr("wrongQueue"), stETH: address(stETH), requestedStETH: REQUESTED
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                LidoWithdrawalClaimAdapter.QueueMismatch.selector, wrongQueueData.queue, address(queue)
            )
        );
        adapter.acquire(_context(), abi.encode(wrongQueueData), _bounds(0, 1));

        LidoWithdrawalClaimAdapter.LidoOriginateData memory wrongStETHData = LidoWithdrawalClaimAdapter.LidoOriginateData({
            queue: address(queue), stETH: makeAddr("wrongStETH"), requestedStETH: REQUESTED
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                LidoWithdrawalClaimAdapter.StETHMismatch.selector, wrongStETHData.stETH, address(stETH)
            )
        );
        adapter.acquire(_context(), abi.encode(wrongStETHData), _bounds(0, 1));
    }

    function testOnlyImmutableSettlementCanAcquire() public {
        address caller = makeAddr("notSettlement");
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(LidoWithdrawalClaimAdapter.OnlySettlement.selector, caller));
        adapter.acquire(_context(), _claimData(REQUESTED), _bounds(0, 1));
    }

    function testAdapterCannotReceiveOriginatedNFTCustody() public {
        _fundAndApprove(REQUESTED);
        uint256 sellerBefore = stETH.balanceOf(seller);
        ClaimTypes.ClaimContext memory wrongContext = _context();
        wrongContext.claimReceiver = address(adapter);

        vm.expectRevert(LidoWithdrawalClaimAdapter.AdapterAsClaimReceiver.selector);
        adapter.acquire(wrongContext, _claimData(REQUESTED), _bounds(0, 1));

        assertEq(queue.lastRequestId(), 0);
        assertEq(stETH.balanceOf(seller), sellerBefore);
        assertEq(stETH.balanceOf(address(queue)), 0);
        assertEq(stETH.balanceOf(address(adapter)), 0);
        assertEq(stETH.allowance(address(adapter), address(queue)), 0);
    }

    function testLaterFailureRollsBackOriginationAndAdapterCustody() public {
        _fundAndApprove(REQUESTED);
        uint256 sellerBefore = stETH.balanceOf(seller);

        vm.expectRevert(ForcedLaterFailure.selector);
        this.acquireThenRevert(_context(), _claimData(REQUESTED), _bounds(0, 1));

        assertEq(queue.lastRequestId(), 0);
        assertEq(stETH.balanceOf(seller), sellerBefore);
        assertEq(stETH.balanceOf(address(queue)), 0);
        assertEq(stETH.balanceOf(address(adapter)), 0);
        assertEq(stETH.allowance(address(adapter), address(queue)), 0);
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

    function _fundAndApprove(uint256 amount) private {
        stETH.mint(seller, amount);
        vm.prank(seller);
        stETH.approve(address(adapter), amount);
    }

    function _acquire(
        uint256 requested,
        uint256 maxShortfall,
        uint256 minShares
    )
        private
        returns (ClaimTypes.Acquisition memory)
    {
        return adapter.acquire(_context(), _claimData(requested), _bounds(maxShortfall, minShares));
    }

    function _context() private view returns (ClaimTypes.ClaimContext memory) {
        return ClaimTypes.ClaimContext({ seller: seller, claimController: receiver, claimReceiver: receiver });
    }

    function _claimData(uint256 requested) private view returns (bytes memory) {
        return abi.encode(
            LidoWithdrawalClaimAdapter.LidoOriginateData({
                queue: address(queue), stETH: address(stETH), requestedStETH: requested
            })
        );
    }

    function _bounds(uint256 maxShortfall, uint256 minShares) private pure returns (bytes memory) {
        return abi.encode(
            LidoWithdrawalClaimAdapter.LidoOriginateBounds({
                maxStETHShortfall: maxShortfall, minAmountOfShares: minShares
            })
        );
    }
}
