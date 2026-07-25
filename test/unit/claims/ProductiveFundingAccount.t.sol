// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { ProductiveFundingAccount } from "../../../src/claims/ProductiveFundingAccount.sol";
import { ERC4626ReserveAdapter } from "../../../src/adapters/ERC4626ReserveAdapter.sol";
import { IAquaReserveResolver } from "../../../src/interfaces/IAquaReserveResolver.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { HeroERC4626, MockERC4626 } from "../../mocks/MockERC4626.sol";
import { RevertingERC4626 } from "../../mocks/RevertingERC4626.sol";
import { KernelFeeOnTransferToken, KernelSettlementCaller } from "../../mocks/claims/KernelClaimAdapter.sol";

contract ProductiveFundingAccountTest is Test {
    address private factor = makeAddr("factor");
    address private seller = makeAddr("seller");
    address private stranger = makeAddr("stranger");

    MockERC20 private asset;
    HeroERC4626 private vault;
    ProductiveFundingAccount private account;
    ERC4626ReserveAdapter private adapter;
    KernelSettlementCaller private settlement;

    function setUp() public {
        asset = new MockERC20("Payment", "PAY", 18);
        vault = new HeroERC4626(IERC20(address(asset)), "Productive Payment", "pPAY");
        account = new ProductiveFundingAccount(factor);
        adapter = new ERC4626ReserveAdapter(address(account), IERC4626(address(vault)), 0, 0);
        settlement = new KernelSettlementCaller();
    }

    function test_ConstructorAndConfigurationAuthorization() public {
        vm.expectRevert(ProductiveFundingAccount.InvalidFactor.selector);
        new ProductiveFundingAccount(address(0));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ProductiveFundingAccount.OnlyFactor.selector, stranger));
        account.configureReserve(adapter);

        vm.startPrank(factor);
        account.configureReserve(adapter);
        account.configureSettlement(address(settlement));

        vm.expectRevert(ProductiveFundingAccount.AlreadyConfigured.selector);
        account.configureReserve(adapter);
        vm.expectRevert(ProductiveFundingAccount.AlreadyConfigured.selector);
        account.configureSettlement(address(settlement));
        vm.stopPrank();

        assertEq(address(account.paymentAsset()), address(asset));
        assertEq(address(account.vault()), address(vault));
        assertEq(address(account.reserveAdapter()), address(adapter));
        assertEq(account.settlement(), address(settlement));
        assertEq(asset.allowance(address(account), address(adapter)), type(uint256).max);
        assertEq(vault.allowance(address(account), address(adapter)), type(uint256).max);
    }

    function test_ConfigurationRejectsWrongBindingParametersAndSettlementCode() public {
        ERC4626ReserveAdapter wrongMaker = new ERC4626ReserveAdapter(stranger, vault, 0, 0);
        vm.prank(factor);
        vm.expectRevert(
            abi.encodeWithSelector(ProductiveFundingAccount.AdapterBindingMismatch.selector, address(wrongMaker))
        );
        account.configureReserve(wrongMaker);

        ERC4626ReserveAdapter thresholded = new ERC4626ReserveAdapter(address(account), vault, 1, 0);
        vm.prank(factor);
        vm.expectRevert(ProductiveFundingAccount.NonZeroReserveParameter.selector);
        account.configureReserve(thresholded);

        ERC4626ReserveAdapter buffered = new ERC4626ReserveAdapter(address(account), vault, 0, 1);
        vm.prank(factor);
        vm.expectRevert(ProductiveFundingAccount.NonZeroReserveParameter.selector);
        account.configureReserve(buffered);

        vm.prank(factor);
        vm.expectRevert(ProductiveFundingAccount.InvalidSettlement.selector);
        account.configureSettlement(makeAddr("no-code"));
    }

    function test_SealRequiresCompleteConfigurationAndFreezesPreparation() public {
        vm.prank(factor);
        vm.expectRevert(ProductiveFundingAccount.ConfigurationIncomplete.selector);
        account.seal();

        vm.startPrank(factor);
        account.configureReserve(adapter);
        account.configureSettlement(address(settlement));
        account.seal();
        vm.expectRevert(ProductiveFundingAccount.ConfigurationSealed.selector);
        account.prepareInventory();
        vm.stopPrank();

        assertTrue(account.isSealed());
    }

    function test_AvailableForIsViewSafeAndRejectsExitCost() public {
        _configureAndSeal();
        asset.mint(address(account), 100);

        assertEq(account.availableFor(60), 60);

        bytes memory callData = abi.encodeCall(IAquaReserveResolver.availableFor, (address(asset), 60));
        vm.mockCallRevert(address(adapter), callData, bytes("forced"));
        assertEq(account.availableFor(60), 0);
        vm.clearMockedCalls();

        vm.mockCall(address(adapter), callData, abi.encode(uint256(60), uint256(1)));
        assertEq(account.availableFor(60), 0);
        vm.clearMockedCalls();

        vm.mockCall(address(adapter), callData, abi.encode(uint256(61), uint256(0)));
        assertEq(account.availableFor(60), 0);
        vm.clearMockedCalls();
    }

    function test_RestEarnThenExactMaterializeAndPay() public {
        vm.startPrank(factor);
        account.configureReserve(adapter);
        account.configureSettlement(address(settlement));
        vm.stopPrank();

        asset.mint(address(account), 1000e18);
        vm.prank(factor);
        account.prepareInventory();
        assertEq(asset.balanceOf(address(account)), 0, "standby capital must be in shares");

        uint256 fixedShares = vault.balanceOf(address(account));
        uint256 navBefore = vault.convertToAssets(fixedShares);
        asset.mint(address(this), 100e18);
        asset.approve(address(vault), 100e18);
        vault.accrueYield(100e18);
        uint256 navAfter = vault.convertToAssets(fixedShares);
        assertGt(navAfter, navBefore, "fixed shares did not earn");

        vm.prank(factor);
        account.seal();

        uint256 payment = 100e18;
        uint256 expectedBurn = vault.previewWithdraw(payment);
        uint256 sharesBefore = vault.balanceOf(address(account));
        uint256 sellerBefore = asset.balanceOf(seller);

        uint256 paid = settlement.materializeAndPay(account, seller, payment);

        assertEq(paid, payment);
        assertEq(asset.balanceOf(seller) - sellerBefore, payment);
        assertEq(sharesBefore - vault.balanceOf(address(account)), expectedBurn);
        assertEq(asset.balanceOf(address(account)), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
    }

    function test_MaterializeAndPayIsSettlementOnly() public {
        _configureAndSeal();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ProductiveFundingAccount.OnlySettlement.selector, stranger));
        account.materializeAndPay(seller, 1);
    }

    function test_FeeOnTransferPaymentRevertsAndRestoresReserve() public {
        KernelFeeOnTransferToken feeAsset = new KernelFeeOnTransferToken();
        MockERC4626 feeVault = new MockERC4626(IERC20(address(feeAsset)), "Fee Vault", "fVAULT");
        ProductiveFundingAccount feeAccount = new ProductiveFundingAccount(factor);
        ERC4626ReserveAdapter feeAdapter = new ERC4626ReserveAdapter(address(feeAccount), feeVault, 0, 0);
        KernelSettlementCaller feeSettlement = new KernelSettlementCaller();

        vm.startPrank(factor);
        feeAccount.configureReserve(feeAdapter);
        feeAccount.configureSettlement(address(feeSettlement));
        vm.stopPrank();
        feeAsset.mint(address(feeAccount), 1000);
        vm.prank(factor);
        feeAccount.prepareInventory();
        vm.prank(factor);
        feeAccount.seal();

        feeAsset.configureFee(seller, true);
        uint256 sharesBefore = feeVault.balanceOf(address(feeAccount));
        vm.expectRevert(abi.encodeWithSelector(ProductiveFundingAccount.InexactPayment.selector, 100, 99));
        feeSettlement.materializeAndPay(feeAccount, seller, 100);

        assertEq(feeVault.balanceOf(address(feeAccount)), sharesBefore);
        assertEq(feeAsset.balanceOf(seller), 0);
        assertEq(feeAsset.balanceOf(address(feeAccount)), 0);
    }

    function test_WithdrawFailureRestoresReserve() public {
        RevertingERC4626 brokenVault = new RevertingERC4626(IERC20(address(asset)), "Broken Funding", "bFUND");
        ProductiveFundingAccount brokenAccount = new ProductiveFundingAccount(factor);
        ERC4626ReserveAdapter brokenAdapter = new ERC4626ReserveAdapter(address(brokenAccount), brokenVault, 0, 0);
        KernelSettlementCaller brokenSettlement = new KernelSettlementCaller();

        vm.startPrank(factor);
        brokenAccount.configureReserve(brokenAdapter);
        brokenAccount.configureSettlement(address(brokenSettlement));
        vm.stopPrank();
        asset.mint(address(brokenAccount), 1000);
        vm.prank(factor);
        brokenAccount.prepareInventory();
        vm.prank(factor);
        brokenAccount.seal();

        uint256 sharesBefore = brokenVault.balanceOf(address(brokenAccount));
        brokenVault.setRevertWithdraw(true);
        vm.expectRevert(
            abi.encodeWithSelector(RevertingERC4626.ForcedVaultRevert.selector, brokenVault.withdraw.selector)
        );
        brokenSettlement.materializeAndPay(brokenAccount, seller, 100);

        assertEq(brokenVault.balanceOf(address(brokenAccount)), sharesBefore);
        assertEq(asset.balanceOf(seller), 0);
    }

    function test_LiveLifecycleTopUpPauseAndRecoverAssets() public {
        _configureAndSeal();
        asset.mint(address(account), 1000);

        vm.prank(factor);
        account.reinvestInventory();
        assertEq(asset.balanceOf(address(account)), 0);
        assertGt(vault.balanceOf(address(account)), 0);
        assertEq(account.availableFor(600), 600);

        vm.prank(factor);
        account.setPaused(true);
        assertTrue(account.isPaused());
        assertEq(account.availableFor(600), 0);
        vm.expectRevert(ProductiveFundingAccount.FundingPaused.selector);
        settlement.materializeAndPay(account, seller, 1);

        uint256 factorBefore = asset.balanceOf(factor);
        vm.prank(factor);
        assertEq(account.withdrawAssets(factor, 600), 600);
        assertEq(asset.balanceOf(factor) - factorBefore, 600);

        vm.prank(factor);
        account.setPaused(false);
        assertFalse(account.isPaused());
        assertEq(account.availableFor(400), 400);
    }

    function test_LiveLifecycleCanRecoverSharesOnlyWhilePaused() public {
        _configureAndSeal();
        asset.mint(address(account), 1000);
        vm.prank(factor);
        account.reinvestInventory();
        uint256 shares = vault.balanceOf(address(account));

        vm.prank(factor);
        vm.expectRevert(ProductiveFundingAccount.FundingNotPaused.selector);
        account.withdrawShares(factor, shares);

        vm.startPrank(factor);
        account.setPaused(true);
        assertEq(account.withdrawShares(factor, shares), shares);
        vm.stopPrank();

        assertEq(vault.balanceOf(address(account)), 0);
        assertEq(vault.balanceOf(factor), shares);
    }

    function _configureAndSeal() private {
        vm.startPrank(factor);
        account.configureReserve(adapter);
        account.configureSettlement(address(settlement));
        account.seal();
        vm.stopPrank();
    }
}
