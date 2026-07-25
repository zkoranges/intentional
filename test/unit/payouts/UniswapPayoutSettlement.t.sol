// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626ReserveAdapter } from "../../../src/adapters/ERC4626ReserveAdapter.sol";
import { ProductiveFundingAccount } from "../../../src/claims/ProductiveFundingAccount.sol";
import { ClaimTypes } from "../../../src/claims/types/ClaimTypes.sol";
import { UniswapPayoutExecutor } from "../../../src/payouts/UniswapPayoutExecutor.sol";
import { UniswapPayoutSettlement } from "../../../src/payouts/UniswapPayoutSettlement.sol";
import { IPayoutExecutor } from "../../../src/payouts/interfaces/IPayoutExecutor.sol";
import { PayoutTypes } from "../../../src/payouts/types/PayoutTypes.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockERC4626 } from "../../mocks/MockERC4626.sol";
import { KernelClaimAdapter } from "../../mocks/claims/KernelClaimAdapter.sol";
import { MockUniswapProxy } from "../../mocks/payouts/MockUniswapProxy.sol";

contract UniswapPayoutSettlementTest is Test {
    bytes4 private constant SELECTOR = 0x2894adf9;
    uint256 private constant FACTOR_KEY = 0xA11CE;
    uint256 private constant WRONG_KEY = 0xB0B;
    uint256 private constant FUNDING = 1000e18;
    uint256 private constant PAYMENT = 100e18;
    uint256 private constant RATE = 1874e6;
    bytes32 private constant POSITION_KEY = keccak256("payout.position");

    address private factor;
    address private seller = makeAddr("seller");
    address private claimController = makeAddr("claim-controller");
    address private claimReceiver = makeAddr("claim-receiver");

    MockERC20 private weth;
    MockERC20 private usdc;
    MockERC4626 private vault;
    MockUniswapProxy private proxy;
    ProductiveFundingAccount private fundingAccount;
    ERC4626ReserveAdapter private reserveAdapter;
    UniswapPayoutExecutor private executor;
    UniswapPayoutSettlement private settlement;
    KernelClaimAdapter private claimAdapter;

    bytes private claimData;
    bytes private boundsData;
    bytes private payoutData;
    uint256 private expectedOut;

    function setUp() public {
        factor = vm.addr(FACTOR_KEY);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockERC4626(IERC20(address(weth)), "Funding Vault", "fWETH");
        proxy = new MockUniswapProxy(weth, usdc, RATE);
        fundingAccount = new ProductiveFundingAccount(factor);
        reserveAdapter = new ERC4626ReserveAdapter(address(fundingAccount), vault, 0, 0);

        vm.prank(factor);
        fundingAccount.configureReserve(reserveAdapter);

        // Mutually referential immutables: predict the settlement address one
        // nonce ahead, exactly as the mainnet deployment sequence does.
        address predictedSettlement = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        executor = new UniswapPayoutExecutor(predictedSettlement, IERC20(address(weth)), address(proxy), SELECTOR);
        settlement = new UniswapPayoutSettlement(factor, fundingAccount, IPayoutExecutor(address(executor)));
        assertEq(address(settlement), predictedSettlement, "settlement address prediction failed");

        claimAdapter = new KernelClaimAdapter(address(settlement));

        weth.mint(address(fundingAccount), FUNDING);
        vm.startPrank(factor);
        fundingAccount.prepareInventory();
        fundingAccount.configureSettlement(address(settlement));
        fundingAccount.seal();
        settlement.allowAdapter(address(claimAdapter));
        settlement.allowPayoutAsset(address(usdc));
        settlement.seal();
        vm.stopPrank();

        claimData = abi.encode(POSITION_KEY, uint256(7), uint256(60e18), uint256(40e18));
        boundsData = abi.encode(uint256(100e18), uint256(1e18), uint256(1e18));
        payoutData = abi.encode(
            PayoutTypes.UniswapPayoutData({
                callData: abi.encodePacked(SELECTOR, abi.encode(seller, PAYMENT)),
                apiQuoteHash: keccak256("retained /quote json")
            })
        );
        expectedOut = (PAYMENT * RATE) / 1e18;
    }

    function _quote(uint256 nonce) private view returns (PayoutTypes.Quote memory) {
        return PayoutTypes.Quote({
            factor: factor,
            seller: seller,
            adapter: address(claimAdapter),
            claimController: claimController,
            claimReceiver: claimReceiver,
            paymentAsset: address(weth),
            paymentAmount: PAYMENT,
            claimDataHash: keccak256(claimData),
            boundsHash: keccak256(boundsData),
            payoutAsset: address(usdc),
            minimumPayoutAmount: expectedOut,
            payoutDataHash: keccak256(payoutData),
            nonce: nonce,
            deadline: block.timestamp + 10 minutes
        });
    }

    function _sign(
        PayoutTypes.Quote memory quote,
        uint256 key,
        UniswapPayoutSettlement domain
    )
        private
        view
        returns (bytes memory)
    {
        PayoutTypes.Quote memory copied = quote;
        bytes32 digest = domain.hashQuote(_asCalldata(copied));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    // hashQuote takes calldata; route the struct through this external helper.
    function _asCalldata(PayoutTypes.Quote memory quote) private pure returns (PayoutTypes.Quote memory) {
        return quote;
    }

    function test_ValidFillAcquiresThenPaysAtLeastMinimumInPayoutAsset() public {
        PayoutTypes.Quote memory quote = _quote(1);
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        claimAdapter.configureNonceCheck(quote.nonce, true);

        vm.prank(seller);
        ClaimTypes.Acquisition memory acquisition = settlement.fill(quote, claimData, boundsData, payoutData, signature);

        assertEq(acquisition.positionKey, POSITION_KEY);
        assertTrue(claimAdapter.acquired(), "claim not acquired");
        assertTrue(settlement.nonceUsed(quote.nonce), "nonce not consumed");
        assertEq(usdc.balanceOf(seller), expectedOut, "seller payout delta mismatch");
        assertEq(weth.balanceOf(seller), 0, "seller should not receive the funding asset");
        assertEq(weth.balanceOf(address(executor)), 0, "executor funding residue");
        assertEq(usdc.balanceOf(address(executor)), 0, "executor payout residue");
        assertEq(weth.balanceOf(address(fundingAccount)), 0, "funding account idle residue");
    }

    function test_MutatingPayoutFieldsInvalidatesTheSignature() public {
        PayoutTypes.Quote memory quote = _quote(2);
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);

        PayoutTypes.Quote memory mutatedMinimum = quote;
        mutatedMinimum.minimumPayoutAmount = expectedOut - 1;
        vm.prank(seller);
        vm.expectPartialRevert(UniswapPayoutSettlement.InvalidFactorSignature.selector);
        settlement.fill(mutatedMinimum, claimData, boundsData, payoutData, signature);

        PayoutTypes.Quote memory mutatedAsset = quote;
        mutatedAsset.payoutAsset = address(weth);
        vm.prank(seller);
        vm.expectPartialRevert(UniswapPayoutSettlement.PayoutAssetNotAllowed.selector);
        settlement.fill(mutatedAsset, claimData, boundsData, payoutData, signature);
    }

    function test_PayoutDataMustMatchItsSignedHash() public {
        PayoutTypes.Quote memory quote = _quote(3);
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        bytes memory altered = bytes.concat(payoutData, hex"00");
        vm.prank(seller);
        vm.expectPartialRevert(UniswapPayoutSettlement.PayoutDataHashMismatch.selector);
        settlement.fill(quote, claimData, boundsData, altered, signature);
    }

    function test_ZeroMinimumPayoutReverts() public {
        PayoutTypes.Quote memory quote = _quote(4);
        quote.minimumPayoutAmount = 0;
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectRevert(UniswapPayoutSettlement.InvalidMinimumPayout.selector);
        settlement.fill(quote, claimData, boundsData, payoutData, signature);
    }

    function test_UnallowedPayoutAssetReverts() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        PayoutTypes.Quote memory quote = _quote(5);
        quote.payoutAsset = address(dai);
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(UniswapPayoutSettlement.PayoutAssetNotAllowed.selector, address(dai)));
        settlement.fill(quote, claimData, boundsData, payoutData, signature);

        // The factor can allow it later — the rail is factor-controlled.
        vm.prank(factor);
        settlement.allowPayoutAsset(address(dai));
        assertTrue(settlement.isPayoutAssetAllowed(address(dai)));
    }

    function test_WrongKeyAndWrongDomainSignaturesRejected() public {
        PayoutTypes.Quote memory quote = _quote(6);
        bytes memory wrongKey = _sign(quote, WRONG_KEY, settlement);
        vm.prank(seller);
        vm.expectPartialRevert(UniswapPayoutSettlement.InvalidFactorSignature.selector);
        settlement.fill(quote, claimData, boundsData, payoutData, wrongKey);

        address otherPredicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        UniswapPayoutExecutor otherExecutor =
            new UniswapPayoutExecutor(otherPredicted, IERC20(address(weth)), address(proxy), SELECTOR);
        UniswapPayoutSettlement otherDomain =
            new UniswapPayoutSettlement(factor, fundingAccount, IPayoutExecutor(address(otherExecutor)));
        bytes memory wrongDomain = _sign(quote, FACTOR_KEY, otherDomain);
        vm.prank(seller);
        vm.expectPartialRevert(UniswapPayoutSettlement.InvalidFactorSignature.selector);
        settlement.fill(quote, claimData, boundsData, payoutData, wrongDomain);
    }

    function test_ConstructorRejectsForeignOrMisassetedExecutor() public {
        UniswapPayoutExecutor foreign =
            new UniswapPayoutExecutor(makeAddr("someone-else"), IERC20(address(weth)), address(proxy), SELECTOR);
        vm.expectRevert(UniswapPayoutSettlement.InvalidExecutor.selector);
        new UniswapPayoutSettlement(factor, fundingAccount, IPayoutExecutor(address(foreign)));

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        UniswapPayoutExecutor wrongAsset =
            new UniswapPayoutExecutor(predicted, IERC20(address(usdc)), address(proxy), SELECTOR);
        vm.expectRevert(UniswapPayoutSettlement.InvalidExecutor.selector);
        new UniswapPayoutSettlement(factor, fundingAccount, IPayoutExecutor(address(wrongAsset)));
    }

    function test_PayoutFailureRollsBackClaimAndNonce() public {
        PayoutTypes.Quote memory quote = _quote(7);
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        proxy.setMode(MockUniswapProxy.Mode.PayLess);

        uint256 sharesBefore = vault.balanceOf(address(fundingAccount));
        vm.prank(seller);
        vm.expectPartialRevert(UniswapPayoutExecutor.InsufficientDelivery.selector);
        settlement.fill(quote, claimData, boundsData, payoutData, signature);

        assertFalse(settlement.nonceUsed(quote.nonce), "nonce survived the rollback");
        assertFalse(claimAdapter.acquired(), "claim acquisition survived the rollback");
        assertEq(usdc.balanceOf(seller), 0, "seller received payout despite rollback");
        assertEq(vault.balanceOf(address(fundingAccount)), sharesBefore, "reserve shares moved despite rollback");
    }

    function test_ExecutorDonationsAreInertThroughASettlementFill() public {
        weth.mint(address(executor), 0.7 ether);
        usdc.mint(address(executor), 123e6);

        PayoutTypes.Quote memory quote = _quote(30);
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);

        vm.prank(seller);
        settlement.fill(quote, claimData, boundsData, payoutData, signature);

        assertEq(usdc.balanceOf(seller), expectedOut, "seller payout delta mismatch");
        assertEq(weth.balanceOf(address(executor)), 0.7 ether, "funding donation not carried through");
        assertEq(usdc.balanceOf(address(executor)), 123e6, "payout donation not carried through");
        assertEq(weth.balanceOf(address(fundingAccount)), 0, "funding account idle residue");
    }

    function test_ExecutorDonationsSurviveARevertedSettlementFill() public {
        weth.mint(address(executor), 0.7 ether);
        usdc.mint(address(executor), 123e6);
        proxy.setMode(MockUniswapProxy.Mode.PayLess);

        PayoutTypes.Quote memory quote = _quote(31);
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectPartialRevert(UniswapPayoutExecutor.InsufficientDelivery.selector);
        settlement.fill(quote, claimData, boundsData, payoutData, signature);

        assertEq(weth.balanceOf(address(executor)), 0.7 ether, "funding donation moved despite the rollback");
        assertEq(usdc.balanceOf(address(executor)), 123e6, "payout donation moved despite the rollback");
        assertFalse(settlement.nonceUsed(quote.nonce), "nonce survived the rollback");

        // The identical quote fills once the route behaves again, and the
        // donations stay inert across the retry.
        proxy.setMode(MockUniswapProxy.Mode.Normal);
        vm.prank(seller);
        settlement.fill(quote, claimData, boundsData, payoutData, signature);
        assertEq(usdc.balanceOf(seller), expectedOut, "seller payout delta mismatch");
        assertEq(weth.balanceOf(address(executor)), 0.7 ether, "funding donation not carried through");
        assertEq(usdc.balanceOf(address(executor)), 123e6, "payout donation not carried through");
    }

    function test_ReplayPauseFloorCancellationAndLifetimePortedFromV2() public {
        PayoutTypes.Quote memory quote = _quote(8);
        bytes memory signature = _sign(quote, FACTOR_KEY, settlement);

        vm.prank(seller);
        settlement.fill(quote, claimData, boundsData, payoutData, signature);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(UniswapPayoutSettlement.NonceAlreadyUsed.selector, quote.nonce));
        settlement.fill(quote, claimData, boundsData, payoutData, signature);

        PayoutTypes.Quote memory farDeadline = _quote(9);
        farDeadline.deadline = block.timestamp + 16 minutes;
        bytes memory farSignature = _sign(farDeadline, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectPartialRevert(UniswapPayoutSettlement.QuoteDeadlineTooFar.selector);
        settlement.fill(farDeadline, claimData, boundsData, payoutData, farSignature);

        vm.prank(factor);
        settlement.cancelNonce(10);
        PayoutTypes.Quote memory cancelled = _quote(10);
        bytes memory cancelledSignature = _sign(cancelled, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(UniswapPayoutSettlement.NonceAlreadyUsed.selector, uint256(10)));
        settlement.fill(cancelled, claimData, boundsData, payoutData, cancelledSignature);

        vm.prank(factor);
        settlement.advanceNonceFloor(100);
        PayoutTypes.Quote memory belowFloor = _quote(11);
        bytes memory belowFloorSignature = _sign(belowFloor, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapPayoutSettlement.NonceBelowFloor.selector, uint256(11), uint256(100))
        );
        settlement.fill(belowFloor, claimData, boundsData, payoutData, belowFloorSignature);

        vm.prank(factor);
        settlement.setPaused(true);
        PayoutTypes.Quote memory paused = _quote(120);
        bytes memory pausedSignature = _sign(paused, FACTOR_KEY, settlement);
        vm.prank(seller);
        vm.expectRevert(UniswapPayoutSettlement.SettlementPaused.selector);
        settlement.fill(paused, claimData, boundsData, payoutData, pausedSignature);
    }
}
