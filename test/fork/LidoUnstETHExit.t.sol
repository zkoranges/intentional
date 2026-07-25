// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { ERC4626ReserveAdapter } from "../../src/adapters/ERC4626ReserveAdapter.sol";
import { AsyncClaimSettlement } from "../../src/claims/AsyncClaimSettlement.sol";
import { ProductiveFundingAccount } from "../../src/claims/ProductiveFundingAccount.sol";
import { LidoUnstETHExitAdapter } from "../../src/claims/adapters/LidoUnstETHExitAdapter.sol";
import { ILidoWithdrawalQueue } from "../../src/claims/interfaces/ILidoWithdrawalQueue.sol";
import { ClaimTypes } from "../../src/claims/types/ClaimTypes.sol";

interface IMainnetWETHExit is IERC20 {
    function deposit() external payable;
}

/// @notice Primary existing-claim proof: real, already-created unstETH NFTs
///         move through the new adapter on a pinned Ethereum mainnet fork,
///         while exact WETH payment is materialized from canonical Aave
///         StataWETH. No queue, token, vault, or route mock participates.
/// @dev The two fixtures were independently observed at PINNED_BLOCK:
///      #130880 pending/unclaimed and #130850 finalized/unclaimed. A claimed
///      historical request (#130851) exercises the burned-position failure.
contract LidoUnstETHExitForkTest is Test {
    uint256 private constant PINNED_BLOCK = 25_612_678;
    bytes32 private constant PINNED_BLOCK_HASH = 0x63bf233aa081b518347b3d046b944cd28da003cc44906834e0c5d5647bc14a32;

    address private constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private constant QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant STATA_WETH = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;

    uint256 private constant PENDING_REQUEST_ID = 130_880;
    uint256 private constant FINALIZED_REQUEST_ID = 130_850;
    uint256 private constant CLAIMED_REQUEST_ID = 130_851;
    uint256 private constant FACTOR_KEY = 0xB10001;
    uint256 private constant FUNDING_WETH = 0.02 ether;
    uint256 private constant PAYMENT_WETH = 0.004 ether;

    ILidoWithdrawalQueue private constant WITHDRAWAL_QUEUE = ILidoWithdrawalQueue(QUEUE);
    IMainnetWETHExit private constant MAINNET_WETH = IMainnetWETHExit(WETH);
    IERC4626 private constant STATA = IERC4626(STATA_WETH);

    address private factor;
    ProductiveFundingAccount private fundingAccount;
    ERC4626ReserveAdapter private reserveAdapter;
    AsyncClaimSettlement private settlement;
    LidoUnstETHExitAdapter private exitAdapter;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), PINNED_BLOCK);
        vm.rollFork(PINNED_BLOCK + 1);
        assertEq(blockhash(PINNED_BLOCK), PINNED_BLOCK_HASH, "unexpected mainnet fork block");
        vm.rollFork(PINNED_BLOCK);
        assertGt(STETH.code.length, 0, "canonical stETH missing");
        assertGt(QUEUE.code.length, 0, "canonical Lido queue missing");
        assertGt(WETH.code.length, 0, "canonical WETH missing");
        assertEq(STATA.asset(), WETH, "canonical StataWETH asset mismatch");

        factor = vm.addr(FACTOR_KEY);
        fundingAccount = new ProductiveFundingAccount(factor);
        reserveAdapter = new ERC4626ReserveAdapter(address(fundingAccount), STATA, 0, 0);

        vm.prank(factor);
        fundingAccount.configureReserve(reserveAdapter);

        settlement = new AsyncClaimSettlement(factor, fundingAccount);
        exitAdapter = new LidoUnstETHExitAdapter(address(settlement), IERC20(STETH), WITHDRAWAL_QUEUE);

        vm.deal(factor, FUNDING_WETH);
        vm.startPrank(factor);
        MAINNET_WETH.deposit{ value: FUNDING_WETH }();
        assertTrue(MAINNET_WETH.transfer(address(fundingAccount), FUNDING_WETH));
        fundingAccount.prepareInventory();
        fundingAccount.configureSettlement(address(settlement));
        fundingAccount.seal();
        settlement.allowAdapter(address(exitAdapter));
        settlement.seal();
        vm.stopPrank();

        assertEq(MAINNET_WETH.balanceOf(address(fundingAccount)), 0, "reserve is not fully productive");
        assertGt(STATA.balanceOf(address(fundingAccount)), 0, "funding account has no StataWETH shares");
    }

    function test_ExistingPendingUnstETHSettlesAtomicallyAgainstProductiveReserve() public {
        _settleExisting(PENDING_REQUEST_ID, 1, false);
    }

    function test_ExistingFinalizedUnstETHSettlesAtomicallyAgainstProductiveReserve() public {
        _settleExisting(FINALIZED_REQUEST_ID, 2, true);
    }

    function test_SellerTransferRaceFailsBeforePaymentOnCanonicalQueue() public {
        uint256 requestId = PENDING_REQUEST_ID;
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory status = _status(requestId);
        address seller = status.owner;
        address thirdParty = makeAddr("canonical-race-winner");
        (bytes memory claimData, bytes memory boundsData) = _boundPosition(requestId, status);
        ClaimTypes.Quote memory quote = _quote(seller, requestId, claimData, boundsData, 3);
        bytes memory signature = _sign(quote);

        vm.prank(seller);
        WITHDRAWAL_QUEUE.approve(address(exitAdapter), requestId);
        vm.prank(seller);
        WITHDRAWAL_QUEUE.transferFrom(seller, thirdParty, requestId);

        uint256 sellerWethBefore = MAINNET_WETH.balanceOf(seller);
        uint256 sharesBefore = STATA.balanceOf(address(fundingAccount));
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(LidoUnstETHExitAdapter.InvalidRequestOwner.selector, thirdParty, seller));
        settlement.fill(quote, claimData, boundsData, signature);

        assertEq(WITHDRAWAL_QUEUE.ownerOf(requestId), thirdParty, "race winner lost the NFT");
        assertEq(MAINNET_WETH.balanceOf(seller), sellerWethBefore, "seller was paid after losing the claim");
        assertEq(STATA.balanceOf(address(fundingAccount)), sharesBefore, "reserve moved on failed acquisition");
        assertFalse(settlement.nonceUsed(quote.nonce), "failed fill consumed nonce");
    }

    function test_ClaimedHistoricalRequestFailsBeforePayment() public {
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory status = _status(CLAIMED_REQUEST_ID);
        assertTrue(status.isClaimed, "fixture is not claimed");
        (bytes memory claimData, bytes memory boundsData) = _boundPosition(CLAIMED_REQUEST_ID, status);
        ClaimTypes.Quote memory quote = _quote(status.owner, CLAIMED_REQUEST_ID, claimData, boundsData, 4);
        bytes memory signature = _sign(quote);
        uint256 sharesBefore = STATA.balanceOf(address(fundingAccount));

        vm.prank(status.owner);
        vm.expectRevert(
            abi.encodeWithSelector(LidoUnstETHExitAdapter.RequestAlreadyClaimed.selector, CLAIMED_REQUEST_ID)
        );
        settlement.fill(quote, claimData, boundsData, signature);

        assertEq(STATA.balanceOf(address(fundingAccount)), sharesBefore, "reserve moved for a burned claim");
        assertFalse(settlement.nonceUsed(quote.nonce), "failed fill consumed nonce");
    }

    function _settleExisting(uint256 requestId, uint256 nonce, bool expectedFinalized) private {
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory beforeStatus = _status(requestId);
        address seller = beforeStatus.owner;
        assertFalse(beforeStatus.isClaimed, "fixture already claimed");
        assertEq(beforeStatus.isFinalized, expectedFinalized, "fixture finalization state changed");
        assertEq(WITHDRAWAL_QUEUE.ownerOf(requestId), seller, "status/ERC-721 owner mismatch");
        assertTrue(seller != factor, "seller and factor must differ");

        (bytes memory claimData, bytes memory boundsData) = _boundPosition(requestId, beforeStatus);
        ClaimTypes.Quote memory quote = _quote(seller, requestId, claimData, boundsData, nonce);
        bytes memory signature = _sign(quote);

        vm.prank(seller);
        WITHDRAWAL_QUEUE.approve(address(exitAdapter), requestId);

        uint256 sellerWethBefore = MAINNET_WETH.balanceOf(seller);
        uint256 fundingSharesBefore = STATA.balanceOf(address(fundingAccount));
        vm.prank(seller);
        ClaimTypes.Acquisition memory acquired = settlement.fill(quote, claimData, boundsData, signature);

        ILidoWithdrawalQueue.WithdrawalRequestStatus memory afterStatus = _status(requestId);
        assertEq(WITHDRAWAL_QUEUE.ownerOf(requestId), factor, "factor did not acquire the canonical NFT");
        assertEq(afterStatus.owner, factor, "queue status owner did not follow ERC-721 ownership");
        assertEq(afterStatus.amountOfStETH, beforeStatus.amountOfStETH, "stETH amount changed");
        assertEq(afterStatus.amountOfShares, beforeStatus.amountOfShares, "share amount changed");
        assertEq(acquired.positionKey, keccak256(abi.encode(QUEUE, requestId)), "position key mismatch");
        assertEq(acquired.claimId, requestId, "request id mismatch");
        assertEq(acquired.assetsReceived, 0, "existing NFT acquisition received assets");
        if (afterStatus.isFinalized) {
            assertEq(acquired.pendingUnits, 0, "finalized request reported pending units");
            assertEq(acquired.pendingReceived, 0, "finalized request reported pending receipt");
            assertEq(acquired.claimableUnits, afterStatus.amountOfShares, "claimable units mismatch");
        } else {
            assertEq(acquired.pendingUnits, afterStatus.amountOfShares, "pending units mismatch");
            assertEq(acquired.pendingReceived, afterStatus.amountOfShares, "pending receipt mismatch");
            assertEq(acquired.claimableUnits, 0, "pending request reported claimable units");
        }

        assertEq(MAINNET_WETH.balanceOf(seller) - sellerWethBefore, PAYMENT_WETH, "seller payment mismatch");
        assertLt(STATA.balanceOf(address(fundingAccount)), fundingSharesBefore, "reserve shares were not materialized");
        assertEq(MAINNET_WETH.balanceOf(address(fundingAccount)), 0, "funding account left idle WETH");
        assertEq(WITHDRAWAL_QUEUE.balanceOf(address(exitAdapter)), 0, "adapter took NFT custody");
        assertTrue(settlement.nonceUsed(nonce), "nonce not consumed");
    }

    function _boundPosition(
        uint256 requestId,
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory status
    )
        private
        pure
        returns (bytes memory claimData, bytes memory boundsData)
    {
        claimData =
            abi.encode(LidoUnstETHExitAdapter.LidoExitData({ queue: QUEUE, stETH: STETH, requestId: requestId }));
        boundsData = abi.encode(
            LidoUnstETHExitAdapter.LidoExitBounds({
                minAmountOfStETH: status.amountOfStETH,
                maxAmountOfStETH: status.amountOfStETH,
                minAmountOfShares: status.amountOfShares,
                maxAmountOfShares: status.amountOfShares
            })
        );
    }

    function _quote(
        address seller,
        uint256,
        bytes memory claimData,
        bytes memory boundsData,
        uint256 nonce
    )
        private
        view
        returns (ClaimTypes.Quote memory)
    {
        return ClaimTypes.Quote({
            factor: factor,
            seller: seller,
            adapter: address(exitAdapter),
            claimController: factor,
            claimReceiver: factor,
            paymentAsset: WETH,
            paymentAmount: PAYMENT_WETH,
            claimDataHash: keccak256(claimData),
            boundsHash: keccak256(boundsData),
            nonce: nonce,
            deadline: block.timestamp + 10 minutes
        });
    }

    function _status(uint256 requestId)
        private
        view
        returns (ILidoWithdrawalQueue.WithdrawalRequestStatus memory status)
    {
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses =
            WITHDRAWAL_QUEUE.getWithdrawalStatus(requestIds);
        assertEq(statuses.length, 1, "canonical queue returned wrong status count");
        return statuses[0];
    }

    function _sign(ClaimTypes.Quote memory quote) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FACTOR_KEY, settlement.hashQuote(quote));
        return abi.encodePacked(r, s, v);
    }
}
