// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { UniswapPayoutExecutor } from "../../../src/payouts/UniswapPayoutExecutor.sol";
import { PayoutTypes } from "../../../src/payouts/types/PayoutTypes.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockUniswapProxy } from "../../mocks/payouts/MockUniswapProxy.sol";

/// @notice Route double that attempts to pull more of the funding asset than
///         the fill funded — the executor's exact approval must block it.
contract GreedyUniswapProxy {
    MockERC20 public immutable fundingAsset;
    MockERC20 public immutable payoutAsset;

    constructor(MockERC20 fundingAsset_, MockERC20 payoutAsset_) {
        fundingAsset = fundingAsset_;
        payoutAsset = payoutAsset_;
    }

    fallback() external {
        (address recipient, uint256 amountIn) = abi.decode(msg.data[4:], (address, uint256));
        fundingAsset.transferFrom(msg.sender, address(this), amountIn + 1);
        payoutAsset.mint(recipient, 1);
    }
}

contract UniswapPayoutExecutorTest is Test {
    bytes4 private constant SELECTOR = 0x2894adf9;
    uint256 private constant FUNDING = 0.005 ether;
    uint256 private constant RATE = 1874e6; // payout units per 1e18 funding
    uint256 private constant WETH_DONATION = 0.7 ether;
    uint256 private constant USDC_DONATION = 123e6;

    address private recipient = makeAddr("payout-recipient");

    MockERC20 private weth;
    MockERC20 private usdc;
    MockUniswapProxy private proxy;
    UniswapPayoutExecutor private executor;

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        proxy = new MockUniswapProxy(weth, usdc, RATE);
        // The test contract itself plays the settlement.
        executor = new UniswapPayoutExecutor(address(this), IERC20(address(weth)), address(proxy), SELECTOR);
    }

    function _payoutData(address recipient_, uint256 amountIn) private pure returns (bytes memory) {
        return abi.encode(
            PayoutTypes.UniswapPayoutData({
                callData: abi.encodePacked(SELECTOR, abi.encode(recipient_, amountIn)),
                apiQuoteHash: keccak256("retained /quote json")
            })
        );
    }

    function _fund(uint256 amount) private {
        weth.mint(address(executor), amount);
    }

    function test_OnlySettlementMayCall() public {
        _fund(FUNDING);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(UniswapPayoutExecutor.OnlySettlement.selector, makeAddr("stranger")));
        executor.payout(recipient, IERC20(address(usdc)), FUNDING, 1, _payoutData(recipient, FUNDING));
    }

    function test_PayoutAssetMayNotBeZeroOrFundingAsset() public {
        _fund(FUNDING);
        vm.expectRevert(abi.encodeWithSelector(UniswapPayoutExecutor.InvalidPayoutAsset.selector, address(0)));
        executor.payout(recipient, IERC20(address(0)), FUNDING, 1, _payoutData(recipient, FUNDING));

        vm.expectRevert(abi.encodeWithSelector(UniswapPayoutExecutor.InvalidPayoutAsset.selector, address(weth)));
        executor.payout(recipient, IERC20(address(weth)), FUNDING, 1, _payoutData(recipient, FUNDING));
    }

    function test_EntryPayoutDustDoesNotBlockOrEnrichTheFill() public {
        _fund(FUNDING);
        usdc.mint(address(executor), 1);
        uint256 expectedOut = (FUNDING * RATE) / 1e18;

        uint256 delivered =
            executor.payout(recipient, IERC20(address(usdc)), FUNDING, expectedOut, _payoutData(recipient, FUNDING));

        assertEq(delivered, expectedOut, "dust leaked into the measured delta");
        assertEq(usdc.balanceOf(recipient), expectedOut, "recipient did not receive the payout");
        assertEq(usdc.balanceOf(address(executor)), 1, "dust was captured by the fill");
        assertEq(weth.balanceOf(address(executor)), 0, "funding residue");
    }

    function test_EntryFundingShortfallFailsClosed() public {
        _fund(FUNDING - 1);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapPayoutExecutor.InsufficientEntryFunding.selector, FUNDING - 1, FUNDING)
        );
        executor.payout(recipient, IERC20(address(usdc)), FUNDING, 1, _payoutData(recipient, FUNDING));
    }

    function test_DonatedFundingAssetBeforeFillIsInert() public {
        _fund(FUNDING);
        weth.mint(address(executor), WETH_DONATION);
        uint256 expectedOut = (FUNDING * RATE) / 1e18;

        uint256 delivered =
            executor.payout(recipient, IERC20(address(usdc)), FUNDING, expectedOut, _payoutData(recipient, FUNDING));

        assertEq(delivered, expectedOut, "donation leaked into the measured delta");
        assertEq(usdc.balanceOf(recipient), expectedOut, "recipient did not receive the payout");
        assertEq(weth.balanceOf(address(executor)), WETH_DONATION, "funding donation not carried through");
        assertEq(usdc.balanceOf(address(executor)), 0, "payout residue");
        assertEq(weth.allowance(address(executor), address(proxy)), 0, "allowance not cleared");
    }

    function test_DonatedPayoutAssetBeforeFillIsInert() public {
        _fund(FUNDING);
        usdc.mint(address(executor), USDC_DONATION);
        uint256 expectedOut = (FUNDING * RATE) / 1e18;

        uint256 delivered =
            executor.payout(recipient, IERC20(address(usdc)), FUNDING, expectedOut, _payoutData(recipient, FUNDING));

        assertEq(delivered, expectedOut, "donation leaked into the measured delta");
        assertEq(usdc.balanceOf(recipient), expectedOut, "recipient did not receive the payout");
        assertEq(usdc.balanceOf(address(executor)), USDC_DONATION, "payout donation not carried through");
        assertEq(weth.balanceOf(address(executor)), 0, "funding residue");
    }

    function test_DonatedBothAssetsBeforeFillAreInert() public {
        _fund(FUNDING);
        weth.mint(address(executor), WETH_DONATION);
        usdc.mint(address(executor), USDC_DONATION);
        uint256 expectedOut = (FUNDING * RATE) / 1e18;

        uint256 delivered =
            executor.payout(recipient, IERC20(address(usdc)), FUNDING, expectedOut, _payoutData(recipient, FUNDING));

        assertEq(delivered, expectedOut, "donations leaked into the measured delta");
        assertEq(usdc.balanceOf(recipient), expectedOut, "recipient did not receive the payout");
        assertEq(weth.balanceOf(address(executor)), WETH_DONATION, "funding donation not carried through");
        assertEq(usdc.balanceOf(address(executor)), USDC_DONATION, "payout donation not carried through");
    }

    function test_RepeatedFillsAfterDonationKeepDustInert() public {
        weth.mint(address(executor), WETH_DONATION);
        usdc.mint(address(executor), USDC_DONATION);
        uint256 expectedOut = (FUNDING * RATE) / 1e18;

        for (uint256 i = 0; i < 3; ++i) {
            _fund(FUNDING);
            uint256 delivered = executor.payout(
                recipient, IERC20(address(usdc)), FUNDING, expectedOut, _payoutData(recipient, FUNDING)
            );
            assertEq(delivered, expectedOut, "measured delta drifted across fills");
            assertEq(weth.balanceOf(address(executor)), WETH_DONATION, "funding donation drifted across fills");
            assertEq(usdc.balanceOf(address(executor)), USDC_DONATION, "payout donation drifted across fills");
        }
        assertEq(usdc.balanceOf(recipient), 3 * expectedOut, "recipient total across fills mismatch");
    }

    function test_ExcessivePullCannotReachDonatedFunding() public {
        GreedyUniswapProxy greedy = new GreedyUniswapProxy(weth, usdc);
        UniswapPayoutExecutor greedyBound =
            new UniswapPayoutExecutor(address(this), IERC20(address(weth)), address(greedy), SELECTOR);
        weth.mint(address(greedyBound), FUNDING + WETH_DONATION);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(greedy), FUNDING, FUNDING + 1
            )
        );
        greedyBound.payout(recipient, IERC20(address(usdc)), FUNDING, 1, _payoutData(recipient, FUNDING));

        assertEq(weth.balanceOf(address(greedyBound)), FUNDING + WETH_DONATION, "greedy route reached the donation");
        assertEq(weth.allowance(address(greedyBound), address(greedy)), 0, "allowance survived the revert");
    }

    function test_BaselinesSurviveARevertedFill() public {
        weth.mint(address(executor), WETH_DONATION);
        usdc.mint(address(executor), USDC_DONATION);
        _fund(FUNDING);
        proxy.setMode(MockUniswapProxy.Mode.RevertAfterPull);
        vm.expectRevert(bytes("MOCK: revert after pull"));
        executor.payout(recipient, IERC20(address(usdc)), FUNDING, 1, _payoutData(recipient, FUNDING));

        assertEq(weth.balanceOf(address(executor)), FUNDING + WETH_DONATION, "funding moved despite the revert");
        assertEq(usdc.balanceOf(address(executor)), USDC_DONATION, "payout donation moved despite the revert");
        assertEq(weth.allowance(address(executor), address(proxy)), 0, "allowance survived the revert");

        // The same executor still fills once the route behaves again.
        proxy.setMode(MockUniswapProxy.Mode.Normal);
        uint256 expectedOut = (FUNDING * RATE) / 1e18;
        uint256 delivered =
            executor.payout(recipient, IERC20(address(usdc)), FUNDING, expectedOut, _payoutData(recipient, FUNDING));
        assertEq(delivered, expectedOut, "post-revert fill delta mismatch");
        assertEq(weth.balanceOf(address(executor)), WETH_DONATION, "funding baseline not preserved");
        assertEq(usdc.balanceOf(address(executor)), USDC_DONATION, "payout baseline not preserved");
    }

    function test_SelectorMismatchRevertsBeforeAnyApproval() public {
        _fund(FUNDING);
        bytes memory wrongSelector = abi.encode(
            PayoutTypes.UniswapPayoutData({
                callData: abi.encodePacked(bytes4(0xdeadbeef), abi.encode(recipient, FUNDING)), apiQuoteHash: bytes32(0)
            })
        );
        vm.expectRevert(
            abi.encodeWithSelector(UniswapPayoutExecutor.PayoutSelectorMismatch.selector, bytes4(0xdeadbeef), SELECTOR)
        );
        executor.payout(recipient, IERC20(address(usdc)), FUNDING, 1, wrongSelector);
        assertEq(weth.allowance(address(executor), address(proxy)), 0, "approval was granted before the check");
    }

    function test_SuccessIsExactAndDustlessWithClearedAllowance() public {
        _fund(FUNDING);
        uint256 expectedOut = (FUNDING * RATE) / 1e18;

        uint256 delivered =
            executor.payout(recipient, IERC20(address(usdc)), FUNDING, expectedOut, _payoutData(recipient, FUNDING));

        assertEq(delivered, expectedOut, "measured delta mismatch");
        assertEq(usdc.balanceOf(recipient), expectedOut, "recipient did not receive the payout");
        assertEq(weth.balanceOf(address(executor)), 0, "funding residue");
        assertEq(usdc.balanceOf(address(executor)), 0, "payout residue");
        assertEq(weth.allowance(address(executor), address(proxy)), 0, "allowance not cleared");
    }

    function test_RevertingProxyBubblesAndRollsBackAllowance() public {
        _fund(FUNDING);
        proxy.setMode(MockUniswapProxy.Mode.RevertAfterPull);
        vm.expectRevert(bytes("MOCK: revert after pull"));
        executor.payout(recipient, IERC20(address(usdc)), FUNDING, 1, _payoutData(recipient, FUNDING));
        assertEq(weth.allowance(address(executor), address(proxy)), 0, "allowance survived the revert");
    }

    function test_BelowMinimumDeliveryReverts() public {
        _fund(FUNDING);
        proxy.setMode(MockUniswapProxy.Mode.PayLess);
        uint256 expectedOut = (FUNDING * RATE) / 1e18;
        vm.expectRevert(
            abi.encodeWithSelector(UniswapPayoutExecutor.InsufficientDelivery.selector, expectedOut / 2, expectedOut)
        );
        executor.payout(recipient, IERC20(address(usdc)), FUNDING, expectedOut, _payoutData(recipient, FUNDING));
    }

    function test_RecipientMeasuredByDeltaNotProxyBehavior() public {
        _fund(FUNDING);
        proxy.setMode(MockUniswapProxy.Mode.PayCallerInstead);
        // The proxy "pays" — but to the executor, not the recipient. The
        // measured recipient delta is zero, so the minimum check reverts.
        vm.expectRevert(abi.encodeWithSelector(UniswapPayoutExecutor.InsufficientDelivery.selector, 0, 1));
        executor.payout(recipient, IERC20(address(usdc)), FUNDING, 1, _payoutData(recipient, FUNDING));
    }

    function test_ExitFundingResidueReverts() public {
        _fund(FUNDING);
        proxy.setMode(MockUniswapProxy.Mode.PullLess);
        vm.expectRevert(abi.encodeWithSelector(UniswapPayoutExecutor.ExitResidue.selector, 1, 0));
        executor.payout(recipient, IERC20(address(usdc)), FUNDING, 1, _payoutData(recipient, FUNDING));
    }

    function test_PartialPullStillRevertsWithDonationPresent() public {
        _fund(FUNDING);
        weth.mint(address(executor), WETH_DONATION);
        proxy.setMode(MockUniswapProxy.Mode.PullLess);
        // The under-pulled wei is measured against the donation-inclusive
        // baseline, so the residue check still fails closed.
        vm.expectRevert(abi.encodeWithSelector(UniswapPayoutExecutor.ExitResidue.selector, WETH_DONATION + 1, 0));
        executor.payout(recipient, IERC20(address(usdc)), FUNDING, 1, _payoutData(recipient, FUNDING));
    }

    function test_NoPayableEntryPoint() public {
        vm.deal(address(this), 1);
        (bool ok,) = address(executor).call{ value: 1 }("");
        assertFalse(ok, "executor accepted native value");
        assertEq(address(executor).balance, 0, "executor holds native dust");
    }
}
