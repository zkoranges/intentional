// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626ReserveAdapter } from "../../src/adapters/ERC4626ReserveAdapter.sol";
import { ProductiveFundingAccount } from "../../src/claims/ProductiveFundingAccount.sol";
import { LidoWithdrawalClaimAdapter } from "../../src/claims/adapters/LidoWithdrawalClaimAdapter.sol";
import { ClaimTypes } from "../../src/claims/types/ClaimTypes.sol";
import { UniswapPayoutExecutor } from "../../src/payouts/UniswapPayoutExecutor.sol";
import { UniswapPayoutSettlement } from "../../src/payouts/UniswapPayoutSettlement.sol";
import { IPayoutExecutor } from "../../src/payouts/interfaces/IPayoutExecutor.sol";
import { PayoutTypes } from "../../src/payouts/types/PayoutTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { MockLidoWithdrawalQueue } from "../mocks/claims/MockLidoWithdrawalQueue.sol";
import { MockStETH } from "../mocks/claims/MockStETH.sol";

/// @notice Proxy double that additionally proves the settlement ORDER: the
///         swap must observe the already-originated Lido request.
contract OrderingAwareProxy {
    MockERC20 public immutable fundingAsset;
    MockERC20 public immutable payoutAsset;
    MockLidoWithdrawalQueue public immutable queue;
    uint256 public rate;
    bool public payLess;
    bool public swapObservedOrigination;

    constructor(MockERC20 fundingAsset_, MockERC20 payoutAsset_, MockLidoWithdrawalQueue queue_, uint256 rate_) {
        fundingAsset = fundingAsset_;
        payoutAsset = payoutAsset_;
        queue = queue_;
        rate = rate_;
    }

    function setPayLess(bool enabled) external {
        payLess = enabled;
    }

    fallback() external {
        (address recipient, uint256 amountIn) = abi.decode(msg.data[4:], (address, uint256));
        swapObservedOrigination = queue.lastRequestId() != 0;
        fundingAsset.transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rate) / 1e18;
        if (payLess) {
            out /= 2;
        }
        payoutAsset.mint(recipient, out);
    }
}

contract UniswapPayoutLidoIntegrationTest is Test {
    bytes4 private constant SELECTOR = 0x2894adf9;
    uint256 private constant FACTOR_KEY = 0xA11CE;
    uint256 private constant FUNDING = 100 ether;
    uint256 private constant REQUESTED_STETH = 10 ether;
    uint256 private constant PAYMENT = 4 ether;
    uint256 private constant RATE = 1874e6;

    address private factor;
    address private seller;

    MockStETH private stETH;
    MockLidoWithdrawalQueue private queue;
    MockERC20 private weth;
    MockERC20 private usdc;
    MockERC4626 private vault;
    OrderingAwareProxy private proxy;
    ProductiveFundingAccount private fundingAccount;
    ERC4626ReserveAdapter private reserveAdapter;
    UniswapPayoutExecutor private executor;
    UniswapPayoutSettlement private settlement;
    LidoWithdrawalClaimAdapter private lidoAdapter;

    bytes private claimData;
    bytes private boundsData;
    bytes private payoutData;
    uint256 private expectedOut;

    function setUp() public {
        factor = vm.addr(FACTOR_KEY);
        seller = makeAddr("seller");

        stETH = new MockStETH();
        queue = new MockLidoWithdrawalQueue(IERC20(address(stETH)));
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockERC4626(IERC20(address(weth)), "Productive WETH Vault", "pvWETH");
        proxy = new OrderingAwareProxy(weth, usdc, queue, RATE);

        fundingAccount = new ProductiveFundingAccount(factor);
        reserveAdapter = new ERC4626ReserveAdapter(address(fundingAccount), vault, 0, 0);
        vm.prank(factor);
        fundingAccount.configureReserve(reserveAdapter);

        address predictedSettlement = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        executor = new UniswapPayoutExecutor(predictedSettlement, IERC20(address(weth)), address(proxy), SELECTOR);
        settlement = new UniswapPayoutSettlement(factor, fundingAccount, IPayoutExecutor(address(executor)));
        lidoAdapter = new LidoWithdrawalClaimAdapter(address(settlement), IERC20(address(stETH)), queue);

        weth.mint(address(fundingAccount), FUNDING);
        stETH.mint(seller, REQUESTED_STETH);
        vm.prank(seller);
        stETH.approve(address(lidoAdapter), REQUESTED_STETH);

        vm.startPrank(factor);
        fundingAccount.prepareInventory();
        fundingAccount.configureSettlement(address(settlement));
        fundingAccount.seal();
        settlement.allowAdapter(address(lidoAdapter));
        settlement.allowPayoutAsset(address(usdc));
        settlement.seal();
        vm.stopPrank();

        claimData = abi.encode(
            LidoWithdrawalClaimAdapter.LidoOriginateData({
                queue: address(queue), stETH: address(stETH), requestedStETH: REQUESTED_STETH
            })
        );
        boundsData = abi.encode(
            LidoWithdrawalClaimAdapter.LidoOriginateBounds({ maxStETHShortfall: 0, minAmountOfShares: REQUESTED_STETH })
        );
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
            adapter: address(lidoAdapter),
            claimController: factor,
            claimReceiver: factor,
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

    function _sign(PayoutTypes.Quote memory quote) private view returns (bytes memory) {
        bytes32 digest = settlement.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FACTOR_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_SellerFactorsLidoClaimAndIsPaidInUSDC() public {
        PayoutTypes.Quote memory quote = _quote(1);
        bytes memory signature = _sign(quote);
        uint256 sharesBefore = vault.balanceOf(address(fundingAccount));
        uint256 expectedSharesBurned = vault.previewWithdraw(PAYMENT);

        vm.prank(seller);
        ClaimTypes.Acquisition memory acquisition = settlement.fill(quote, claimData, boundsData, payoutData, signature);

        assertEq(acquisition.claimId, 1);
        assertEq(acquisition.pendingUnits, REQUESTED_STETH);

        MockLidoWithdrawalQueue.WithdrawalRequestStatus memory status = queue.statusOf(1);
        assertEq(status.owner, factor, "the factor receives the withdrawal claim");
        assertEq(status.amountOfStETH, REQUESTED_STETH);

        assertTrue(proxy.swapObservedOrigination(), "the swap must run after claim origination");
        assertEq(usdc.balanceOf(seller), expectedOut, "seller receives the USDC payout");
        assertEq(weth.balanceOf(seller), 0, "seller must not receive the funding asset");
        assertEq(sharesBefore - vault.balanceOf(address(fundingAccount)), expectedSharesBurned);
        assertEq(weth.balanceOf(address(executor)), 0, "executor funding residue");
        assertEq(usdc.balanceOf(address(executor)), 0, "executor payout residue");
        assertEq(stETH.balanceOf(seller), 0);
        assertEq(stETH.balanceOf(address(queue)), REQUESTED_STETH);
        assertTrue(settlement.nonceUsed(quote.nonce));
    }

    function test_SwapFailureRollsBackOriginationTokensAndNonce() public {
        PayoutTypes.Quote memory quote = _quote(2);
        bytes memory signature = _sign(quote);
        proxy.setPayLess(true);
        uint256 sharesBefore = vault.balanceOf(address(fundingAccount));

        vm.prank(seller);
        vm.expectPartialRevert(UniswapPayoutExecutor.InsufficientDelivery.selector);
        settlement.fill(quote, claimData, boundsData, payoutData, signature);

        assertEq(queue.lastRequestId(), 0, "origination survived the rollback");
        assertEq(stETH.balanceOf(seller), REQUESTED_STETH, "seller stETH not returned");
        assertEq(usdc.balanceOf(seller), 0, "partial payout escaped the rollback");
        assertEq(vault.balanceOf(address(fundingAccount)), sharesBefore, "reserve shares moved");
        assertFalse(settlement.nonceUsed(quote.nonce), "nonce survived the rollback");
    }

    function test_AcquisitionFailureMovesNothing() public {
        vm.prank(seller);
        stETH.approve(address(lidoAdapter), 0); // break the acquisition stage

        PayoutTypes.Quote memory quote = _quote(3);
        bytes memory signature = _sign(quote);
        uint256 sharesBefore = vault.balanceOf(address(fundingAccount));

        vm.prank(seller);
        vm.expectRevert();
        settlement.fill(quote, claimData, boundsData, payoutData, signature);

        assertEq(queue.lastRequestId(), 0);
        assertEq(usdc.balanceOf(seller), 0);
        assertEq(vault.balanceOf(address(fundingAccount)), sharesBefore);
        assertFalse(settlement.nonceUsed(quote.nonce));
    }
}
