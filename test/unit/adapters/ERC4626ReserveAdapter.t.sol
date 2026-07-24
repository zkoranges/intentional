// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626ReserveAdapter } from "../../../src/adapters/ERC4626ReserveAdapter.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { HeroERC4626, MockERC4626 } from "../../mocks/MockERC4626.sol";
import { RevertingERC4626 } from "../../mocks/RevertingERC4626.sol";
import { USDTLike } from "../../mocks/USDTLike.sol";

contract ERC4626ReserveAdapterTest is Test {
    event AssetsReinvested(address indexed asset, uint256 assets, uint256 shares);

    address internal maker = makeAddr("maker");
    address internal sink = makeAddr("sink");

    MockERC20 internal asset;
    MockERC4626 internal vault;
    ERC4626ReserveAdapter internal adapter;

    function setUp() public {
        asset = new MockERC20("Mock Asset", "MA", 18);
        vault = new MockERC4626(IERC20(address(asset)), "Mock Vault", "mvMA");
        adapter = new ERC4626ReserveAdapter(maker, vault, 5, 10);

        asset.mint(maker, 2000);
        vm.startPrank(maker);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1000, maker);
        asset.approve(address(adapter), type(uint256).max);
        vault.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    function test_AvailableForIncludesIdleAndBufferedWithdrawable() public view {
        vault.maxWithdraw(maker);
        (uint256 deliverable, uint256 cost) = adapter.availableFor(address(asset), 3000);
        assertEq(deliverable, 1990);
        assertEq(cost, 0);
    }

    function test_AvailableForClampsExactlyAtBufferedCapacityBoundary() public view {
        (uint256 below,) = adapter.availableFor(address(asset), 1989);
        (uint256 atCapacity,) = adapter.availableFor(address(asset), 1990);
        (uint256 above,) = adapter.availableFor(address(asset), 1991);

        assertEq(below, 1989);
        assertEq(atCapacity, 1990);
        assertEq(above, 1990);
    }

    function test_AvailableForClampsWantedAtZeroAndOne() public view {
        (uint256 zero,) = adapter.availableFor(address(asset), 0);
        (uint256 one,) = adapter.availableFor(address(asset), 1);
        assertEq(zero, 0);
        assertEq(one, 1);
    }

    function test_AvailableForUsesVaultLimitAndSaturatingBuffer() public {
        vault.setWithdrawLimit(400);
        (uint256 deliverable,) = adapter.availableFor(address(asset), type(uint256).max);
        assertEq(deliverable, 1390);

        vm.prank(maker);
        assertTrue(asset.transfer(sink, 1000));
        vault.setWithdrawLimit(5);
        (deliverable,) = adapter.availableFor(address(asset), type(uint256).max);
        assertEq(deliverable, 0);
    }

    function test_AvailableForWrongAssetReturnsZero() public {
        (uint256 deliverable, uint256 cost) = adapter.availableFor(makeAddr("wrong"), 100);
        assertEq(deliverable, 0);
        assertEq(cost, 0);
        assertEq(adapter.idleThreshold(makeAddr("wrong")), 0);
    }

    function test_AvailableForTreatsRevertingMaxWithdrawAsZeroButKeepsIdle() public {
        RevertingERC4626 brokenVault = new RevertingERC4626(IERC20(address(asset)), "Broken Vault", "bvMA");
        ERC4626ReserveAdapter brokenAdapter = new ERC4626ReserveAdapter(maker, brokenVault, 0, 10);
        brokenVault.setRevertMaxWithdraw(true);

        (uint256 deliverable,) = brokenAdapter.availableFor(address(asset), 2000);
        assertEq(deliverable, 990);
    }

    function test_MaterializeUsesIdleWithoutBurningShares() public {
        uint256 sharesBefore = vault.balanceOf(maker);
        vm.prank(maker);
        uint256 delivered = adapter.materialize(address(asset), 400);

        assertEq(delivered, 400);
        assertEq(asset.balanceOf(maker), 1000);
        assertEq(vault.balanceOf(maker), sharesBefore);
    }

    function test_MaterializeWithdrawsOnlyShortfallAndReturnsAssetsNotShares() public {
        uint256 sharesBefore = vault.balanceOf(maker);
        vm.prank(maker);
        uint256 delivered = adapter.materialize(address(asset), 1250);

        assertEq(delivered, 1250);
        assertEq(asset.balanceOf(maker), 1250);
        assertEq(sharesBefore - vault.balanceOf(maker), 250);
    }

    function test_NonUnitSharePriceUsesERC4626CeilBurnAndFloorMint() public {
        MockERC20 yieldAsset = new MockERC20("Yield Asset", "YA", 18);
        HeroERC4626 yieldVault = new HeroERC4626(IERC20(address(yieldAsset)), "Yield Vault", "yvYA");
        ERC4626ReserveAdapter yieldAdapter = new ERC4626ReserveAdapter(maker, yieldVault, 0, 0);

        yieldAsset.mint(maker, 1000);
        vm.startPrank(maker);
        yieldAsset.approve(address(yieldVault), type(uint256).max);
        yieldVault.deposit(1000, maker);
        yieldAsset.approve(address(yieldAdapter), type(uint256).max);
        yieldVault.approve(address(yieldAdapter), type(uint256).max);
        vm.stopPrank();

        yieldAsset.mint(address(this), 333);
        yieldAsset.approve(address(yieldVault), 333);
        yieldVault.accrueYield(333);

        uint256 requestedAssets = 100;
        uint256 expectedBurn = yieldVault.previewWithdraw(requestedAssets);
        uint256 sharesBeforeWithdraw = yieldVault.balanceOf(maker);
        vm.prank(maker);
        assertEq(yieldAdapter.materialize(address(yieldAsset), requestedAssets), requestedAssets);
        assertEq(
            sharesBeforeWithdraw - yieldVault.balanceOf(maker),
            expectedBurn,
            "withdraw did not use ERC-4626 ceil rounding"
        );
        assertEq(yieldAsset.balanceOf(maker), requestedAssets, "withdraw asset delta");

        uint256 expectedMint = yieldVault.previewDeposit(requestedAssets);
        uint256 sharesBeforeDeposit = yieldVault.balanceOf(maker);
        vm.prank(maker);
        yieldAdapter.reinvest(address(yieldAsset));
        assertEq(
            yieldVault.balanceOf(maker) - sharesBeforeDeposit,
            expectedMint,
            "deposit did not use ERC-4626 floor rounding"
        );
        assertEq(yieldAsset.balanceOf(maker), 0, "reinvest left maker idle");
        assertEq(yieldAsset.balanceOf(address(yieldAdapter)), 0, "reinvest left adapter dust");
    }

    function test_MaterializeRejectsInsufficientAndLeavesBalancesAtomic() public {
        vault.setWithdrawLimit(100);
        uint256 idleBefore = asset.balanceOf(maker);
        uint256 sharesBefore = vault.balanceOf(maker);

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(ERC4626ReserveAdapter.InsufficientWithdrawable.selector, 500, 100));
        adapter.materialize(address(asset), 1500);

        assertEq(asset.balanceOf(maker), idleBefore);
        assertEq(vault.balanceOf(maker), sharesBefore);
    }

    function test_MaterializeRequiresMakerAndConfiguredAsset() public {
        vm.expectRevert(abi.encodeWithSelector(ERC4626ReserveAdapter.OnlyMakerAccount.selector, address(this)));
        adapter.materialize(address(asset), 1);

        address wrong = makeAddr("wrong");
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(ERC4626ReserveAdapter.UnsupportedAsset.selector, wrong));
        adapter.materialize(wrong, 1);
    }

    function test_TwoSequentialMaterializationsRetainShareAllowance() public {
        vm.startPrank(maker);
        adapter.materialize(address(asset), 1200);
        assertTrue(asset.transfer(sink, 1200));
        adapter.materialize(address(asset), 300);
        vm.stopPrank();

        assertEq(asset.balanceOf(maker), 300);
        assertEq(vault.allowance(maker, address(adapter)), type(uint256).max);
    }

    function test_ReinvestBelowThresholdIsNoOp() public {
        vm.prank(maker);
        assertTrue(asset.transfer(sink, 996));
        uint256 sharesBefore = vault.balanceOf(maker);

        vm.prank(maker);
        adapter.reinvest(address(asset));

        assertEq(asset.balanceOf(maker), 4);
        assertEq(vault.balanceOf(maker), sharesBefore);
    }

    function test_ReinvestCapsAtMaxDepositEmitsAmountsAndLeavesNoDust() public {
        vault.setDepositLimit(100);
        uint256 sharesBefore = vault.balanceOf(maker);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit AssetsReinvested(address(asset), 100, 100);
        vm.prank(maker);
        adapter.reinvest(address(asset));

        assertEq(asset.balanceOf(maker), 900);
        assertEq(vault.balanceOf(maker) - sharesBefore, 100);
        assertEq(asset.balanceOf(address(adapter)), 0);
    }

    function test_ReinvestSweepsUnsolicitedAdapterUnderlyingBeforeDeposit() public {
        asset.mint(address(adapter), 7);
        uint256 sharesBefore = vault.balanceOf(maker);

        vm.prank(maker);
        adapter.reinvest(address(asset));

        assertEq(asset.balanceOf(address(adapter)), 0, "donation remained on adapter");
        assertEq(asset.balanceOf(maker), 5, "idle threshold was not preserved");
        assertEq(vault.balanceOf(maker) - sharesBefore, 1002, "donation did not benefit maker");
    }

    function test_ReinvestZeroMaxDepositAndZeroPreviewAreNoOps() public {
        uint256 idleBefore = asset.balanceOf(maker);
        uint256 sharesBefore = vault.balanceOf(maker);

        vault.setDepositLimit(0);
        vm.prank(maker);
        adapter.reinvest(address(asset));
        assertEq(asset.balanceOf(maker), idleBefore);
        assertEq(vault.balanceOf(maker), sharesBefore);

        vault.setDepositLimit(type(uint256).max);
        vault.setPreviewDepositZero(true);
        vm.prank(maker);
        adapter.reinvest(address(asset));
        assertEq(asset.balanceOf(maker), idleBefore);
        assertEq(vault.balanceOf(maker), sharesBefore);
    }

    function test_RevertingDepositViewsAndDepositLeaveMakerFundsUntouched() public {
        RevertingERC4626 brokenVault = new RevertingERC4626(IERC20(address(asset)), "Broken Vault", "bvMA");
        ERC4626ReserveAdapter brokenAdapter = new ERC4626ReserveAdapter(maker, brokenVault, 0, 0);
        vm.prank(maker);
        asset.approve(address(brokenAdapter), type(uint256).max);

        uint256 idleBefore = asset.balanceOf(maker);
        brokenVault.setRevertMaxDeposit(true);
        vm.prank(maker);
        vm.expectRevert();
        brokenAdapter.reinvest(address(asset));
        assertEq(asset.balanceOf(maker), idleBefore);

        brokenVault.setRevertMaxDeposit(false);
        brokenVault.setRevertPreviewDeposit(true);
        vm.prank(maker);
        vm.expectRevert();
        brokenAdapter.reinvest(address(asset));
        assertEq(asset.balanceOf(maker), idleBefore);

        brokenVault.setRevertPreviewDeposit(false);
        brokenVault.setRevertDeposit(true);
        vm.prank(maker);
        vm.expectRevert();
        brokenAdapter.reinvest(address(asset));
        assertEq(asset.balanceOf(maker), idleBefore);
        assertEq(asset.balanceOf(address(brokenAdapter)), 0);

        (uint256 deliverable,) = brokenAdapter.availableFor(address(asset), idleBefore);
        assertEq(deliverable, idleBefore);
    }

    function test_RepeatedReinvestUsesZeroFirstApprovalForUSDTLikeAsset() public {
        USDTLike usdt = new USDTLike("USDT-like", "USDTL", 6);
        MockERC4626 usdtVault = new MockERC4626(IERC20(address(usdt)), "USDT Vault", "vUSDTL");
        ERC4626ReserveAdapter usdtAdapter = new ERC4626ReserveAdapter(maker, usdtVault, 0, 0);

        usdt.mint(maker, 200_000_000);
        vm.prank(maker);
        usdt.approve(address(usdtAdapter), type(uint256).max);

        vm.prank(maker);
        usdtAdapter.reinvest(address(usdt));
        assertEq(usdtVault.balanceOf(maker), 200_000_000);

        usdt.mint(maker, 100_000_000);
        vm.prank(address(usdtAdapter));
        usdt.approve(address(usdtVault), 1);

        vm.prank(maker);
        usdtAdapter.reinvest(address(usdt));
        assertEq(usdtVault.balanceOf(maker), 300_000_000);
        assertEq(usdt.balanceOf(address(usdtAdapter)), 0);
    }

    function test_SixDecimalCapacityUsesRawAssetUnits() public {
        MockERC20 six = new MockERC20("Six", "SIX", 6);
        MockERC4626 sixVault = new MockERC4626(IERC20(address(six)), "Six Vault", "vSIX");
        ERC4626ReserveAdapter sixAdapter = new ERC4626ReserveAdapter(maker, sixVault, 0, 100_000);

        six.mint(maker, 2_000_000);
        vm.startPrank(maker);
        six.approve(address(sixVault), type(uint256).max);
        sixVault.deposit(1_000_000, maker);
        six.approve(address(sixAdapter), type(uint256).max);
        sixVault.approve(address(sixAdapter), type(uint256).max);
        vm.stopPrank();

        (uint256 deliverable,) = sixAdapter.availableFor(address(six), type(uint256).max);
        assertEq(deliverable, 1_900_000);
    }
}
