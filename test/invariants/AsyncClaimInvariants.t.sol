// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626ReserveAdapter } from "../../src/adapters/ERC4626ReserveAdapter.sol";
import { AsyncClaimSettlement } from "../../src/claims/AsyncClaimSettlement.sol";
import { ProductiveFundingAccount } from "../../src/claims/ProductiveFundingAccount.sol";
import { ERC8161RedeemClaimAdapter } from "../../src/claims/adapters/ERC8161RedeemClaimAdapter.sol";
import { IERC7540RedeemTransferable } from "../../src/claims/interfaces/IERC7540RedeemTransferable.sol";
import { ClaimTypes } from "../../src/claims/types/ClaimTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { MockERC7540ERC8161Vault } from "../mocks/claims/MockERC7540ERC8161Vault.sol";

/// @dev Stateful phase-transition driver. It has only two actions: advance any
///      portion from Pending to Claimable, or atomically fill the fixed quote.
contract AsyncClaimInvariantHandler is Test {
    MockERC7540ERC8161Vault public immutable claimVault;
    AsyncClaimSettlement public immutable settlement;
    address public immutable seller;
    uint256 public immutable requestId;

    bool public filled;
    uint256 public acquiredPendingUnits;
    uint256 public acquiredPendingReceived;
    uint256 public acquiredClaimableUnits;
    uint256 public acquiredAssetsReceived;

    ClaimTypes.Quote private _quote;
    bytes private _claimData;
    bytes private _boundsData;
    bytes private _signature;

    constructor(
        MockERC7540ERC8161Vault claimVault_,
        AsyncClaimSettlement settlement_,
        address seller_,
        uint256 requestId_,
        ClaimTypes.Quote memory quote_,
        bytes memory claimData_,
        bytes memory boundsData_,
        bytes memory signature_
    ) {
        claimVault = claimVault_;
        settlement = settlement_;
        seller = seller_;
        requestId = requestId_;
        _quote = quote_;
        _claimData = claimData_;
        _boundsData = boundsData_;
        _signature = signature_;
    }

    function process(uint256 rawShares) external {
        if (filled) {
            return;
        }

        uint256 pending = claimVault.pendingRedeemRequest(requestId, seller);
        uint256 shares = rawShares % (pending + 1);
        claimVault.process(requestId, seller, shares);
    }

    function fill() external {
        if (filled) {
            return;
        }

        vm.prank(seller);
        ClaimTypes.Acquisition memory acquisition = settlement.fill(_quote, _claimData, _boundsData, _signature);

        acquiredPendingUnits = acquisition.pendingUnits;
        acquiredPendingReceived = acquisition.pendingReceived;
        acquiredClaimableUnits = acquisition.claimableUnits;
        acquiredAssetsReceived = acquisition.assetsReceived;
        filled = true;
    }
}

/// @notice Cross-contract release properties for Reservoir v2's one active
///         nonzero-ID ERC-7540 cohort.
contract AsyncClaimInvariantsTest is StdInvariant, Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant FACTOR_KEY = 0xA11CE;
    uint256 private constant TOTAL_SHARES = 100 ether;
    uint256 private constant PAYMENT = 97 ether;
    uint256 private constant FUNDING = 1000 ether;
    uint256 private constant NONCE = 42;

    address private factor;
    address private seller;

    MockERC20 private claimAsset;
    MockERC7540ERC8161Vault private claimVault;
    ERC8161RedeemClaimAdapter private claimAdapter;

    MockERC20 private weth;
    MockERC4626 private fundingVault;
    ProductiveFundingAccount private fundingAccount;
    ERC4626ReserveAdapter private reserveAdapter;
    AsyncClaimSettlement private settlement;

    AsyncClaimInvariantHandler private handler;
    uint256 private requestId;
    uint256 private initialFundingShares;

    function setUp() public {
        factor = vm.addr(FACTOR_KEY);
        seller = makeAddr("invariant-seller");

        claimAsset = new MockERC20("Invariant Claim Asset", "iCLAIM", 18);
        claimVault = new MockERC7540ERC8161Vault(claimAsset);
        claimAsset.mint(address(claimVault), 10_000 ether);

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        fundingVault = new MockERC4626(IERC20(address(weth)), "Invariant Productive WETH", "ipvWETH");
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
        initialFundingShares = fundingVault.balanceOf(address(fundingAccount));

        claimVault.mintShares(seller, TOTAL_SHARES);
        vm.prank(seller);
        requestId = claimVault.requestRedeem(TOTAL_SHARES, seller, seller);
        vm.prank(seller);
        claimVault.setOperator(address(claimAdapter), true);

        bytes memory claimData = abi.encode(
            ERC8161RedeemClaimAdapter.ERC8161ClaimData({
                vault: address(claimVault),
                share: claimVault.share(),
                asset: address(claimAsset),
                requestId: requestId,
                sellerController: seller
            })
        );
        bytes memory boundsData = abi.encode(
            ERC8161RedeemClaimAdapter.ERC8161Bounds({
                expectedTotalShares: TOTAL_SHARES, minPendingTransferRateWad: WAD, minAssetsPerClaimableShareWad: WAD
            })
        );
        ClaimTypes.Quote memory quote = ClaimTypes.Quote({
            factor: factor,
            seller: seller,
            adapter: address(claimAdapter),
            claimController: factor,
            claimReceiver: factor,
            paymentAsset: address(weth),
            paymentAmount: PAYMENT,
            claimDataHash: keccak256(claimData),
            boundsHash: keccak256(boundsData),
            nonce: NONCE,
            deadline: block.timestamp + 10 minutes
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FACTOR_KEY, settlement.hashQuote(quote));
        bytes memory signature = abi.encodePacked(r, s, v);

        handler = new AsyncClaimInvariantHandler(
            claimVault, settlement, seller, requestId, quote, claimData, boundsData, signature
        );

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = AsyncClaimInvariantHandler.process.selector;
        selectors[1] = AsyncClaimInvariantHandler.fill.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @dev This full-stack fuzz complements the adapter unit test: the same
    ///      signed quote must settle through funding and payment at every split.
    function testFuzz_AllConstantTotalSplitsSettleThroughKernel(uint256 claimableShares) public {
        claimableShares = bound(claimableShares, 0, TOTAL_SHARES);
        claimVault.process(requestId, seller, claimableShares);

        handler.fill();

        assertTrue(handler.filled());
        assertEq(handler.acquiredPendingUnits(), TOTAL_SHARES - claimableShares);
        assertEq(handler.acquiredPendingReceived(), TOTAL_SHARES - claimableShares);
        assertEq(handler.acquiredClaimableUnits(), claimableShares);
        assertEq(handler.acquiredAssetsReceived(), claimableShares);
        assertEq(weth.balanceOf(seller), PAYMENT);
    }

    function invariant_ConstantTotalSurvivesAnyPhaseDriftUntilCompleteAcquisition() public view {
        uint256 sellerPending = claimVault.pendingRedeemRequest(requestId, seller);
        uint256 sellerClaimable = claimVault.claimableRedeemRequest(requestId, seller);
        uint256 factorPending = claimVault.pendingRedeemRequest(requestId, factor);
        uint256 factorAssets = claimAsset.balanceOf(factor);

        if (!handler.filled()) {
            assertEq(sellerPending + sellerClaimable, TOTAL_SHARES);
            assertEq(factorPending + factorAssets, 0);
        } else {
            assertEq(sellerPending + sellerClaimable, 0);
            assertEq(factorPending + factorAssets, TOTAL_SHARES);
            assertEq(handler.acquiredPendingUnits() + handler.acquiredClaimableUnits(), TOTAL_SHARES);
        }
    }

    function invariant_PaymentIffCompleteMeasuredAcquisition() public view {
        uint256 sellerRemaining =
            claimVault.pendingRedeemRequest(requestId, seller) + claimVault.claimableRedeemRequest(requestId, seller);
        uint256 factorAcquired = claimVault.pendingRedeemRequest(requestId, factor) + claimAsset.balanceOf(factor);

        bool fullyAcquired = sellerRemaining == 0 && factorAcquired == TOTAL_SHARES;
        bool exactlyPaid = weth.balanceOf(seller) == PAYMENT;

        assertEq(exactlyPaid, fullyAcquired);
        assertEq(settlement.nonceUsed(NONCE), fullyAcquired);
        assertEq(weth.balanceOf(address(fundingAccount)), 0);
        assertEq(claimAsset.balanceOf(address(claimAdapter)), 0);
        assertEq(IERC20(claimVault.share()).balanceOf(address(claimAdapter)), 0);

        if (fullyAcquired) {
            assertLt(fundingVault.balanceOf(address(fundingAccount)), initialFundingShares);
        } else {
            assertEq(fundingVault.balanceOf(address(fundingAccount)), initialFundingShares);
        }
    }
}
