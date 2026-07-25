// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626ReserveAdapter } from "../../src/adapters/ERC4626ReserveAdapter.sol";
import { AsyncClaimSettlement } from "../../src/claims/AsyncClaimSettlement.sol";
import { ProductiveFundingAccount } from "../../src/claims/ProductiveFundingAccount.sol";
import { ERC8161RedeemClaimAdapter } from "../../src/claims/adapters/ERC8161RedeemClaimAdapter.sol";
import { IERC7540RedeemTransferable } from "../../src/claims/interfaces/IERC7540RedeemTransferable.sol";
import { ClaimTypes } from "../../src/claims/types/ClaimTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { RevertingERC4626 } from "../mocks/RevertingERC4626.sol";
import { MockERC7540ERC8161Vault } from "../mocks/claims/MockERC7540ERC8161Vault.sol";

/// @notice Complete deterministic Reservoir v2 proof through the real kernel,
///         productive reserve account, and both ERC-8161 acquisition legs.
contract AsyncClaimERC8161IntegrationTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant FACTOR_KEY = 0xA11CE;
    uint256 private constant TOTAL_SHARES = 100 ether;
    uint256 private constant CLAIMABLE_AT_FILL = 40 ether;
    uint256 private constant PAYMENT = 97 ether;
    uint256 private constant FUNDING = 1000 ether;
    uint256 private constant YIELD = 100 ether;

    address private factor;
    address private seller;

    MockERC20 private claimAsset;
    MockERC7540ERC8161Vault private claimVault;
    ERC8161RedeemClaimAdapter private claimAdapter;

    MockERC20 private weth;
    RevertingERC4626 private fundingVault;
    ProductiveFundingAccount private fundingAccount;
    ERC4626ReserveAdapter private reserveAdapter;
    AsyncClaimSettlement private settlement;

    uint256 private requestId;
    bytes private claimData;
    bytes private boundsData;

    function setUp() public {
        factor = vm.addr(FACTOR_KEY);
        seller = makeAddr("seller");

        claimAsset = new MockERC20("Async Claim Asset", "ACA", 18);
        claimVault = new MockERC7540ERC8161Vault(claimAsset);
        claimAsset.mint(address(claimVault), 10_000 ether);

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        fundingVault = new RevertingERC4626(IERC20(address(weth)), "Productive WETH", "pvWETH");
        fundingAccount = new ProductiveFundingAccount(factor);
        reserveAdapter = new ERC4626ReserveAdapter(address(fundingAccount), fundingVault, 0, 0);

        vm.prank(factor);
        fundingAccount.configureReserve(reserveAdapter);

        settlement = new AsyncClaimSettlement(factor, fundingAccount);
        claimAdapter =
            new ERC8161RedeemClaimAdapter(IERC7540RedeemTransferable(address(claimVault)), address(settlement));

        weth.mint(address(fundingAccount), FUNDING);
        vm.startPrank(factor);
        fundingAccount.prepareInventory();
        fundingAccount.configureSettlement(address(settlement));
        fundingAccount.seal();
        settlement.allowAdapter(address(claimAdapter));
        settlement.seal();
        vm.stopPrank();

        requestId = _newRequest(TOTAL_SHARES);
        claimData = _claimData(requestId);
        boundsData = _bounds(TOTAL_SHARES);
    }

    /// @dev Kept public so the terminal demo can target this exact proof.
    function test_Hero_Quote100PendingSettles60Pending40ClaimableAndPaysExactly() public {
        uint256 fixedFundingShares = fundingVault.balanceOf(address(fundingAccount));
        uint256 navBefore = fundingVault.convertToAssets(fixedFundingShares);
        assertEq(weth.balanceOf(address(fundingAccount)), 0, "standby WETH must rest in vault shares");
        assertEq(fixedFundingShares, FUNDING);

        // The account holds the same shares while their NAV grows.
        weth.mint(address(fundingVault), YIELD);
        uint256 navAfter = fundingVault.convertToAssets(fixedFundingShares);
        assertEq(fundingVault.balanceOf(address(fundingAccount)), fixedFundingShares);
        assertGt(navAfter, navBefore, "productive reserve did not earn");
        assertEq(fundingAccount.availableFor(PAYMENT), PAYMENT);

        ClaimTypes.ClaimFacts memory atQuote = claimAdapter.inspect(claimData);
        assertEq(atQuote.pendingUnits, TOTAL_SHARES);
        assertEq(atQuote.claimableUnits, 0);
        assertEq(atQuote.pendingUnits + atQuote.claimableUnits, TOTAL_SHARES);

        ClaimTypes.Quote memory quote = _quote(claimData, boundsData, 1);
        bytes memory signature = _sign(quote);

        // This is the load-bearing race: the signed economics stay fixed while
        // the protocol advances 40 shares from Pending to Claimable.
        claimVault.process(requestId, seller, CLAIMABLE_AT_FILL);
        ClaimTypes.ClaimFacts memory atFill = claimAdapter.inspect(claimData);
        assertEq(atFill.pendingUnits, TOTAL_SHARES - CLAIMABLE_AT_FILL);
        assertEq(atFill.claimableUnits, CLAIMABLE_AT_FILL);
        assertEq(atFill.pendingUnits + atFill.claimableUnits, TOTAL_SHARES);

        vm.prank(seller);
        claimVault.setOperator(address(claimAdapter), true);
        assertTrue(claimVault.isOperator(seller, address(claimAdapter)));

        uint256 sellerPaymentBefore = weth.balanceOf(seller);
        uint256 fundingSharesBefore = fundingVault.balanceOf(address(fundingAccount));
        uint256 expectedFundingSharesBurned = fundingVault.previewWithdraw(PAYMENT);

        vm.prank(seller);
        ClaimTypes.Acquisition memory acquisition = settlement.fill(quote, claimData, boundsData, signature);

        assertEq(acquisition.positionKey, keccak256(abi.encode(address(claimVault), requestId, seller)));
        assertEq(acquisition.claimId, requestId);
        assertEq(acquisition.pendingUnits, 60 ether);
        assertEq(acquisition.pendingReceived, 60 ether, "measured Pending delta must meet the signed WAD floor");
        assertEq(acquisition.claimableUnits, 40 ether);
        assertEq(acquisition.assetsReceived, 40 ether, "measured asset delta must meet the signed WAD floor");
        assertEq(claimVault.transferCallCount(), 1, "Pending leg was not executed");
        assertEq(claimVault.redeemCallCount(), 1, "Claimable leg was not executed");

        assertEq(claimVault.pendingRedeemRequest(requestId, seller), 0);
        assertEq(claimVault.claimableRedeemRequest(requestId, seller), 0);
        assertEq(claimVault.pendingRedeemRequest(requestId, factor), 60 ether);
        assertEq(claimAsset.balanceOf(factor), 40 ether);

        assertEq(weth.balanceOf(seller) - sellerPaymentBefore, PAYMENT, "payment must be exact");
        assertEq(fundingSharesBefore - fundingVault.balanceOf(address(fundingAccount)), expectedFundingSharesBurned);
        assertEq(weth.balanceOf(address(fundingAccount)), 0, "materialized WETH must not remain idle");
        assertTrue(settlement.nonceUsed(quote.nonce));
        _assertAdapterDustFree();

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AsyncClaimSettlement.NonceAlreadyUsed.selector, quote.nonce));
        settlement.fill(quote, claimData, boundsData, signature);

        vm.prank(seller);
        claimVault.setOperator(address(claimAdapter), false);
        assertFalse(claimVault.isOperator(seller, address(claimAdapter)));

        // A new valid factor quote cannot exercise the old vault-wide approval
        // after the seller revokes it.
        uint256 freshShares = 10 ether;
        uint256 freshRequestId = _newRequest(freshShares);
        bytes memory freshClaimData = _claimData(freshRequestId);
        bytes memory freshBoundsData = _bounds(freshShares);
        ClaimTypes.Quote memory freshQuote = _quote(freshClaimData, freshBoundsData, 2);
        bytes memory freshSignature = _sign(freshQuote);
        uint256 paymentAfterFirstFill = weth.balanceOf(seller);

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC8161RedeemClaimAdapter.OperatorNotApproved.selector, seller, address(claimAdapter)
            )
        );
        settlement.fill(freshQuote, freshClaimData, freshBoundsData, freshSignature);

        assertFalse(settlement.nonceUsed(freshQuote.nonce));
        assertEq(claimVault.pendingRedeemRequest(freshRequestId, seller), freshShares);
        assertEq(claimVault.pendingRedeemRequest(freshRequestId, factor), 0);
        assertEq(weth.balanceOf(seller), paymentAfterFirstFill);
    }

    function test_FundingFailureAfterMixedAcquisitionRollsBackClaimNonceReserveAndPayment() public {
        ClaimTypes.Quote memory quote = _quote(claimData, boundsData, 3);
        bytes memory signature = _sign(quote);
        claimVault.process(requestId, seller, CLAIMABLE_AT_FILL);
        vm.prank(seller);
        claimVault.setOperator(address(claimAdapter), true);

        uint256 fundingSharesBefore = fundingVault.balanceOf(address(fundingAccount));
        uint256 fundingAssetsBefore = weth.balanceOf(address(fundingVault));
        fundingVault.setRevertWithdraw(true);

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(RevertingERC4626.ForcedVaultRevert.selector, fundingVault.withdraw.selector)
        );
        settlement.fill(quote, claimData, boundsData, signature);

        assertFalse(settlement.nonceUsed(quote.nonce), "nonce write must roll back");
        assertEq(claimVault.pendingRedeemRequest(requestId, seller), 60 ether, "Pending transfer must roll back");
        assertEq(claimVault.claimableRedeemRequest(requestId, seller), 40 ether, "redemption must roll back");
        assertEq(claimVault.pendingRedeemRequest(requestId, factor), 0);
        assertEq(claimAsset.balanceOf(factor), 0);
        assertEq(claimVault.transferCallCount(), 0);
        assertEq(claimVault.redeemCallCount(), 0);
        assertEq(weth.balanceOf(seller), 0, "seller cannot be paid without acquisition");
        assertEq(fundingVault.balanceOf(address(fundingAccount)), fundingSharesBefore);
        assertEq(weth.balanceOf(address(fundingVault)), fundingAssetsBefore);
        assertEq(weth.balanceOf(address(fundingAccount)), 0);
        _assertAdapterDustFree();
    }

    function _newRequest(uint256 shares) private returns (uint256 id) {
        claimVault.mintShares(seller, shares);
        vm.prank(seller);
        id = claimVault.requestRedeem(shares, seller, seller);
    }

    function _claimData(uint256 id) private view returns (bytes memory) {
        return abi.encode(
            ERC8161RedeemClaimAdapter.ERC8161ClaimData({
                vault: address(claimVault),
                share: claimVault.share(),
                asset: address(claimAsset),
                requestId: id,
                sellerController: seller
            })
        );
    }

    function _bounds(uint256 expectedTotal) private pure returns (bytes memory) {
        return abi.encode(
            ERC8161RedeemClaimAdapter.ERC8161Bounds({
                expectedTotalShares: expectedTotal, minPendingTransferRateWad: WAD, minAssetsPerClaimableShareWad: WAD
            })
        );
    }

    function _quote(
        bytes memory quotedClaimData,
        bytes memory quotedBoundsData,
        uint256 nonce
    )
        private
        view
        returns (ClaimTypes.Quote memory)
    {
        return ClaimTypes.Quote({
            factor: factor,
            seller: seller,
            adapter: address(claimAdapter),
            claimController: factor,
            claimReceiver: factor,
            paymentAsset: address(weth),
            paymentAmount: PAYMENT,
            claimDataHash: keccak256(quotedClaimData),
            boundsHash: keccak256(quotedBoundsData),
            nonce: nonce,
            deadline: block.timestamp + 10 minutes
        });
    }

    function _sign(ClaimTypes.Quote memory quote) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FACTOR_KEY, settlement.hashQuote(quote));
        return abi.encodePacked(r, s, v);
    }

    function _assertAdapterDustFree() private view {
        assertEq(claimAsset.balanceOf(address(claimAdapter)), 0);
        assertEq(IERC20(claimVault.share()).balanceOf(address(claimAdapter)), 0);
        assertEq(address(claimAdapter).balance, 0);
        assertEq(weth.balanceOf(address(reserveAdapter)), 0);
    }
}
