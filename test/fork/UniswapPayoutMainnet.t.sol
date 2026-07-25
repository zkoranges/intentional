// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { ERC4626ReserveAdapter } from "../../src/adapters/ERC4626ReserveAdapter.sol";
import { ProductiveFundingAccount } from "../../src/claims/ProductiveFundingAccount.sol";
import { LidoWithdrawalClaimAdapter } from "../../src/claims/adapters/LidoWithdrawalClaimAdapter.sol";
import { ILidoWithdrawalQueue } from "../../src/claims/interfaces/ILidoWithdrawalQueue.sol";
import { UniswapPayoutExecutor } from "../../src/payouts/UniswapPayoutExecutor.sol";
import { UniswapPayoutSettlement } from "../../src/payouts/UniswapPayoutSettlement.sol";
import { IPayoutExecutor } from "../../src/payouts/interfaces/IPayoutExecutor.sol";
import { PayoutTypes } from "../../src/payouts/types/PayoutTypes.sol";

interface ILidoStETHPayout is IERC20 {
    function submit(address referral) external payable returns (uint256 sharesAmount);
    function getSharesByPooledEth(uint256 amount) external view returns (uint256);
}

/// @notice The canonical payout proof (uniswap_payouts_idea.md §10.4): on a
///         current-head chain-1 fork pinned to the route-fetch block, a seller
///         factors a canonical Lido claim and is paid in USDC through the
///         live Uniswap Trading API route — funding materialized from
///         canonical Aave StataWETH, executor dustless, failure atomic.
/// @dev This suite lives under `test/fork/`, which every deterministic
///      invocation excludes (`Makefile`, `ci.yml`). So an explicit fork run
///      always intends to execute it: a missing RPC or fixture is an operator
///      error and must fail loudly. The fixture is produced by
///      `MODE=payout frontend/scripts/fetch-uniswap-route.mjs`, which derives
///      this test's deterministic executor address as swapper.
contract UniswapPayoutMainnetForkTest is Test {
    using stdJson for string;

    address private constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant STATA_WETH = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;
    address private constant QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    string private constant FIXTURE_PATH = "test/fork/fixtures/uniswap-payout-route.json";

    uint256 private factorKey;
    address private factor;
    address private seller;

    uint256 private amountIn;
    uint256 private apiQuotedOut;
    address private swapTo;
    bytes private swapData;
    bytes32 private apiQuoteHash;
    uint256 private fetchedAtBlock;
    bool private fixtureLoaded;

    ProductiveFundingAccount private fundingAccount;
    ERC4626ReserveAdapter private reserveAdapter;
    UniswapPayoutExecutor private executor;
    UniswapPayoutSettlement private settlement;
    LidoWithdrawalClaimAdapter private lidoAdapter;

    uint256 private constant REQUESTED_STETH = 0.005 ether;
    uint256 private constant FUNDING_WETH = 0.01 ether;

    bytes private claimData;
    bytes private boundsData;
    bytes private payoutData;

    function setUp() public {
        string memory fixture = vm.readFile(FIXTURE_PATH);
        require(
            bytes(fixture).length != 0,
            "fork payout: fixture is empty; run `MODE=payout node frontend/scripts/fetch-uniswap-route.mjs`"
        );
        amountIn = vm.parseUint(fixture.readString(".amountInWei"));
        apiQuotedOut = vm.parseUint(fixture.readString(".apiQuotedOut"));
        swapTo = fixture.readAddress(".swapTo");
        swapData = fixture.readBytes(".swapData");
        apiQuoteHash = fixture.readBytes32(".apiQuoteHash");
        fetchedAtBlock = fixture.readUint(".fetchedAtBlock");
        seller = fixture.readAddress(".recipient");
        fixtureLoaded = true;

        factorKey = uint256(keccak256("reservoir.payout.fork.factor"));
        factor = vm.addr(factorKey);
        assertEq(seller, makeAddr("payoutForkSeller"), "fixture recipient mismatch");

        vm.createSelectFork(vm.envString("ETH_RPC_URL"), fetchedAtBlock);
        assertEq(vm.getNonce(factor), 0, "fork factor address must be fresh");

        vm.deal(factor, 1 ether);
        vm.deal(seller, 1 ether);

        // Deterministic deployment order — the fetch script derived the
        // executor address as CREATE(factor, nonce 2). Pranked CALLS consume
        // no EOA nonce (only creations do), so configureReserve — which must
        // precede the settlement constructor because it sets paymentAsset —
        // sits nonce-free between the creations.
        vm.startPrank(factor);
        fundingAccount = new ProductiveFundingAccount(factor); // nonce 0
        reserveAdapter = new ERC4626ReserveAdapter(address(fundingAccount), IERC4626(STATA_WETH), 0, 0); // 1
        address predictedSettlement = vm.computeCreateAddress(factor, 3);
        executor = new UniswapPayoutExecutor(predictedSettlement, IERC20(WETH), swapTo, bytes4(swapData)); // 2
        fundingAccount.configureReserve(reserveAdapter); // call: no nonce consumed
        settlement = new UniswapPayoutSettlement(factor, fundingAccount, IPayoutExecutor(address(executor))); // 3
        lidoAdapter = new LidoWithdrawalClaimAdapter(address(settlement), IERC20(STETH), ILidoWithdrawalQueue(QUEUE)); // 4
        vm.stopPrank();
        assertEq(address(settlement), predictedSettlement, "settlement prediction failed");

        deal(WETH, address(fundingAccount), FUNDING_WETH);
        vm.startPrank(factor);
        fundingAccount.prepareInventory();
        fundingAccount.configureSettlement(address(settlement));
        fundingAccount.seal();
        settlement.allowAdapter(address(lidoAdapter));
        settlement.allowPayoutAsset(USDC);
        settlement.seal();
        vm.stopPrank();

        // Factor starts with zero idle WETH: everything is StataWETH shares.
        assertEq(IERC20(WETH).balanceOf(address(fundingAccount)), 0, "funding not fully productive");
        assertGt(IERC20(STATA_WETH).balanceOf(address(fundingAccount)), 0, "no StataWETH shares");

        vm.prank(seller);
        ILidoStETHPayout(STETH).submit{ value: 0.0055 ether }(address(0));
        vm.prank(seller);
        IERC20(STETH).approve(address(lidoAdapter), REQUESTED_STETH);

        claimData = abi.encode(
            LidoWithdrawalClaimAdapter.LidoOriginateData({
                queue: QUEUE, stETH: STETH, requestedStETH: REQUESTED_STETH
            })
        );
        boundsData = abi.encode(
            LidoWithdrawalClaimAdapter.LidoOriginateBounds({
                maxStETHShortfall: 2,
                minAmountOfShares: ILidoStETHPayout(STETH).getSharesByPooledEth(REQUESTED_STETH - 2)
            })
        );
        payoutData = abi.encode(PayoutTypes.UniswapPayoutData({ callData: swapData, apiQuoteHash: apiQuoteHash }));
    }

    modifier requiresFixture() {
        require(fixtureLoaded, "fork payout: fixture not loaded");
        _;
    }

    function _quote(uint256 nonce, uint256 minimumOut) private view returns (PayoutTypes.Quote memory) {
        return PayoutTypes.Quote({
            factor: factor,
            seller: seller,
            adapter: address(lidoAdapter),
            claimController: factor,
            claimReceiver: factor,
            paymentAsset: WETH,
            paymentAmount: amountIn,
            claimDataHash: keccak256(claimData),
            boundsHash: keccak256(boundsData),
            payoutAsset: USDC,
            minimumPayoutAmount: minimumOut,
            payoutDataHash: keccak256(payoutData),
            nonce: nonce,
            deadline: block.timestamp + 10 minutes
        });
    }

    function _sign(PayoutTypes.Quote memory quote) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(factorKey, settlement.hashQuote(quote));
        return abi.encodePacked(r, s, v);
    }

    function test_CanonicalLidoClaimFactoredAndPaidInUSDCThroughLiveRoute() public requiresFixture {
        // Signed minimum: 99% of the API-quoted output (route slippage 0.5%).
        uint256 minimumOut = (apiQuotedOut * 99) / 100;
        PayoutTypes.Quote memory quote = _quote(1, minimumOut);
        bytes memory signature = _sign(quote);

        uint256 sellerUsdcBefore = IERC20(USDC).balanceOf(seller);
        uint256 sharesBefore = IERC20(STATA_WETH).balanceOf(address(fundingAccount));

        vm.prank(seller);
        settlement.fill(quote, claimData, boundsData, payoutData, signature);

        uint256 delivered = IERC20(USDC).balanceOf(seller) - sellerUsdcBefore;
        assertGe(delivered, minimumOut, "seller received less than the signed minimum USDC");

        uint256[] memory ids =
            ILidoWithdrawalQueue(QUEUE).getWithdrawalStatus(_ownedIds()).length > 0 ? _ownedIds() : new uint256[](0);
        assertEq(ids.length, 1, "factor does not own exactly one canonical request");

        assertEq(IERC20(WETH).balanceOf(address(executor)), 0, "executor funding residue");
        assertEq(IERC20(USDC).balanceOf(address(executor)), 0, "executor payout residue");
        assertLt(IERC20(STATA_WETH).balanceOf(address(fundingAccount)), sharesBefore, "no shares were materialized");
        assertEq(IERC20(WETH).balanceOf(address(fundingAccount)), 0, "funding account idle residue");
        assertTrue(settlement.nonceUsed(quote.nonce), "nonce not consumed");

        emit log_named_uint("PAYOUT FORK | api quoted USDC", apiQuotedOut);
        emit log_named_uint("PAYOUT FORK | signed minimum USDC", minimumOut);
        emit log_named_uint("PAYOUT FORK | delivered USDC", delivered);
    }

    function test_UnmeetableMinimumRevertsEverythingAtomically() public requiresFixture {
        PayoutTypes.Quote memory quote = _quote(2, type(uint256).max);
        bytes memory signature = _sign(quote);

        uint256 sellerStETHBefore = IERC20(STETH).balanceOf(seller);
        uint256 sharesBefore = IERC20(STATA_WETH).balanceOf(address(fundingAccount));

        vm.prank(seller);
        vm.expectPartialRevert(UniswapPayoutExecutor.InsufficientDelivery.selector);
        settlement.fill(quote, claimData, boundsData, payoutData, signature);

        assertEq(_ownedIds().length, 0, "Lido request survived the rollback");
        assertApproxEqAbs(IERC20(STETH).balanceOf(seller), sellerStETHBefore, 2, "seller stETH moved");
        assertEq(IERC20(STATA_WETH).balanceOf(address(fundingAccount)), sharesBefore, "reserve shares moved");
        assertEq(IERC20(USDC).balanceOf(seller), 0, "partial payout escaped");
        assertFalse(settlement.nonceUsed(quote.nonce), "nonce survived the rollback");
    }

    /// @notice Real-chain regression for the original public griefing defect:
    ///         arbitrary WETH/USDC dust at the immutable executor must neither
    ///         block the canonical route nor leak into the seller's measured
    ///         payout. `deal` changes only fork fixture balances; every
    ///         protocol interaction still executes against production Lido,
    ///         Aave StataWETH, WETH, USDC, and the archived Uniswap route.
    function test_DonationsCannotBrickCanonicalMainnetRoute() public requiresFixture {
        uint256 donatedWeth = 1;
        uint256 donatedUsdc = 1;
        deal(WETH, address(executor), donatedWeth);
        deal(USDC, address(executor), donatedUsdc);

        uint256 minimumOut = (apiQuotedOut * 99) / 100;
        PayoutTypes.Quote memory quote = _quote(3, minimumOut);
        bytes memory signature = _sign(quote);
        uint256 sellerUsdcBefore = IERC20(USDC).balanceOf(seller);

        vm.prank(seller);
        settlement.fill(quote, claimData, boundsData, payoutData, signature);

        uint256 delivered = IERC20(USDC).balanceOf(seller) - sellerUsdcBefore;
        assertGe(delivered, minimumOut, "seller received less than the signed minimum USDC");
        assertEq(IERC20(WETH).balanceOf(address(executor)), donatedWeth, "donated WETH was spent or trapped");
        assertEq(IERC20(USDC).balanceOf(address(executor)), donatedUsdc, "donated USDC leaked into the payout");
        assertEq(IERC20(WETH).allowance(address(executor), swapTo), 0, "route allowance survived");
        assertTrue(settlement.nonceUsed(quote.nonce), "nonce not consumed");
        assertEq(_ownedIds().length, 1, "canonical Lido claim was not originated");
    }

    function _ownedIds() private view returns (uint256[] memory ids) {
        return IWithdrawalQueueIds(QUEUE).getWithdrawalRequests(factor);
    }
}

interface IWithdrawalQueueIds {
    function getWithdrawalRequests(address owner) external view returns (uint256[] memory);
}
