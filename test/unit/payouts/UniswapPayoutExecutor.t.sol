// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { UniswapPayoutExecutor } from "../../../src/payouts/UniswapPayoutExecutor.sol";
import { PayoutTypes } from "../../../src/payouts/types/PayoutTypes.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockUniswapProxy } from "../../mocks/payouts/MockUniswapProxy.sol";

contract UniswapPayoutExecutorTest is Test {
    bytes4 private constant SELECTOR = 0x2894adf9;
    uint256 private constant FUNDING = 0.005 ether;
    uint256 private constant RATE = 1874e6; // payout units per 1e18 funding

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

    function test_EntryPayoutDustFailsClosed() public {
        _fund(FUNDING);
        usdc.mint(address(executor), 1);
        vm.expectRevert(abi.encodeWithSelector(UniswapPayoutExecutor.UnexpectedEntryPayout.selector, 1));
        executor.payout(recipient, IERC20(address(usdc)), FUNDING, 1, _payoutData(recipient, FUNDING));
    }

    function test_EntryFundingShortfallFailsClosed() public {
        _fund(FUNDING - 1);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapPayoutExecutor.UnexpectedEntryFunding.selector, FUNDING - 1, FUNDING)
        );
        executor.payout(recipient, IERC20(address(usdc)), FUNDING, 1, _payoutData(recipient, FUNDING));
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

    function test_NoPayableEntryPoint() public {
        vm.deal(address(this), 1);
        (bool ok,) = address(executor).call{ value: 1 }("");
        assertFalse(ok, "executor accepted native value");
        assertEq(address(executor).balance, 0, "executor holds native dust");
    }
}
