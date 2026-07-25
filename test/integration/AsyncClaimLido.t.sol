// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626ReserveAdapter } from "../../src/adapters/ERC4626ReserveAdapter.sol";
import { AsyncClaimSettlement } from "../../src/claims/AsyncClaimSettlement.sol";
import { ProductiveFundingAccount } from "../../src/claims/ProductiveFundingAccount.sol";
import { LidoWithdrawalClaimAdapter } from "../../src/claims/adapters/LidoWithdrawalClaimAdapter.sol";
import { ClaimTypes } from "../../src/claims/types/ClaimTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { MockLidoWithdrawalQueue } from "../mocks/claims/MockLidoWithdrawalQueue.sol";
import { MockStETH } from "../mocks/claims/MockStETH.sol";

contract AcquisitionOrderedWETH is MockERC20 {
    error PaymentBeforeAcquisition();

    MockLidoWithdrawalQueue public immutable queue;
    address public immutable paymentRecipient;

    bool public enforcePaymentOrder;
    bool public paymentAfterAcquisition;

    constructor(MockLidoWithdrawalQueue queue_, address paymentRecipient_) MockERC20("Wrapped Ether", "WETH", 18) {
        queue = queue_;
        paymentRecipient = paymentRecipient_;
    }

    function setEnforcePaymentOrder(bool enabled) external {
        enforcePaymentOrder = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (enforcePaymentOrder && from != address(0) && to == paymentRecipient) {
            if (queue.lastRequestId() == 0) {
                revert PaymentBeforeAcquisition();
            }
            paymentAfterAcquisition = true;
        }
        super._update(from, to, value);
    }
}

contract OriginationAwareERC4626 is MockERC4626 {
    error FundingAttemptedBeforeOrigination();
    error ForcedFundingFailureAfterOrigination(uint256 requestId);

    MockLidoWithdrawalQueue public immutable queue;
    bool public failFundingAfterOrigination;

    constructor(IERC20 asset_, MockLidoWithdrawalQueue queue_) MockERC4626(asset_, "Productive WETH Vault", "pvWETH") {
        queue = queue_;
    }

    function setFailFundingAfterOrigination(bool enabled) external {
        failFundingAfterOrigination = enabled;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        if (failFundingAfterOrigination) {
            uint256 requestId = queue.lastRequestId();
            if (requestId == 0) {
                revert FundingAttemptedBeforeOrigination();
            }
            revert ForcedFundingFailureAfterOrigination(requestId);
        }
        return super.withdraw(assets, receiver, owner);
    }
}

contract AsyncClaimLidoIntegrationTest is Test {
    uint256 private constant FACTOR_KEY = 0xA11CE;
    uint256 private constant FUNDING = 100 ether;
    uint256 private constant REQUESTED_STETH = 10 ether;
    uint256 private constant PAYMENT = 4 ether;

    address private factor;
    address private seller;

    MockStETH private stETH;
    MockLidoWithdrawalQueue private queue;
    AcquisitionOrderedWETH private weth;
    OriginationAwareERC4626 private vault;
    ProductiveFundingAccount private fundingAccount;
    ERC4626ReserveAdapter private reserveAdapter;
    AsyncClaimSettlement private settlement;
    LidoWithdrawalClaimAdapter private lidoAdapter;

    bytes private claimData;
    bytes private boundsData;

    function setUp() public {
        factor = vm.addr(FACTOR_KEY);
        seller = makeAddr("seller");

        stETH = new MockStETH();
        queue = new MockLidoWithdrawalQueue(IERC20(address(stETH)));
        weth = new AcquisitionOrderedWETH(queue, seller);
        vault = new OriginationAwareERC4626(IERC20(address(weth)), queue);

        fundingAccount = new ProductiveFundingAccount(factor);
        reserveAdapter = new ERC4626ReserveAdapter(address(fundingAccount), vault, 0, 0);

        vm.prank(factor);
        fundingAccount.configureReserve(reserveAdapter);

        settlement = new AsyncClaimSettlement(factor, fundingAccount);
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
        settlement.seal();
        vm.stopPrank();

        weth.setEnforcePaymentOrder(true);
        claimData = abi.encode(
            LidoWithdrawalClaimAdapter.LidoOriginateData({
                queue: address(queue), stETH: address(stETH), requestedStETH: REQUESTED_STETH
            })
        );
        boundsData = abi.encode(
            LidoWithdrawalClaimAdapter.LidoOriginateBounds({ maxStETHShortfall: 0, minAmountOfShares: REQUESTED_STETH })
        );
    }

    function test_SellerFactorsLidoWithdrawalAgainstProductiveWETH() public {
        _assertFundingEntirelyInShares();

        ClaimTypes.Quote memory quote = _quote(1);
        bytes memory signature = _sign(quote);
        uint256 sharesBefore = vault.balanceOf(address(fundingAccount));
        uint256 expectedSharesBurned = vault.previewWithdraw(PAYMENT);

        vm.prank(seller);
        ClaimTypes.Acquisition memory acquisition = settlement.fill(quote, claimData, boundsData, signature);

        assertEq(acquisition.positionKey, keccak256(abi.encode(address(queue), uint256(1))));
        assertEq(acquisition.claimId, 1);
        assertEq(acquisition.pendingUnits, REQUESTED_STETH);
        assertEq(acquisition.pendingReceived, REQUESTED_STETH);
        assertEq(acquisition.claimableUnits, 0);
        assertEq(acquisition.assetsReceived, 0);

        MockLidoWithdrawalQueue.WithdrawalRequestStatus memory status = queue.statusOf(1);
        assertEq(status.owner, factor, "the factor receives the withdrawal claim");
        assertEq(status.amountOfStETH, REQUESTED_STETH);
        assertEq(status.amountOfShares, REQUESTED_STETH);
        assertFalse(status.isFinalized);
        assertFalse(status.isClaimed);

        assertTrue(weth.paymentAfterAcquisition(), "payment must observe the originated request");
        assertEq(weth.balanceOf(seller), PAYMENT, "seller receives the exact signed payment");
        assertEq(sharesBefore - vault.balanceOf(address(fundingAccount)), expectedSharesBurned);
        assertEq(weth.balanceOf(address(fundingAccount)), 0, "no payment asset remains idle");

        assertEq(stETH.balanceOf(seller), 0);
        assertEq(stETH.balanceOf(address(queue)), REQUESTED_STETH);
        assertEq(stETH.balanceOf(address(lidoAdapter)), 0);
        assertEq(stETH.sharesOf(address(lidoAdapter)), 0);
        assertEq(stETH.allowance(address(lidoAdapter), address(queue)), 0);
        assertTrue(settlement.nonceUsed(quote.nonce));
    }

    function test_FundingFailureAfterOriginationRollsBackRequestAndTokens() public {
        _assertFundingEntirelyInShares();

        ClaimTypes.Quote memory quote = _quote(2);
        bytes memory signature = _sign(quote);
        uint256 fundingSharesBefore = vault.balanceOf(address(fundingAccount));
        vault.setFailFundingAfterOrigination(true);

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(OriginationAwareERC4626.ForcedFundingFailureAfterOrigination.selector, 1)
        );
        settlement.fill(quote, claimData, boundsData, signature);

        assertFalse(settlement.nonceUsed(quote.nonce));
        assertEq(queue.lastRequestId(), 0, "request counter rolls back");

        MockLidoWithdrawalQueue.WithdrawalRequestStatus memory status = queue.statusOf(1);
        assertEq(status.owner, address(0), "request ownership rolls back");
        assertEq(status.amountOfStETH, 0);
        assertEq(status.amountOfShares, 0);

        assertEq(stETH.balanceOf(seller), REQUESTED_STETH);
        assertEq(stETH.balanceOf(address(queue)), 0);
        assertEq(stETH.balanceOf(address(lidoAdapter)), 0);
        assertEq(stETH.sharesOf(address(lidoAdapter)), 0);
        assertEq(stETH.allowance(address(lidoAdapter), address(queue)), 0);

        assertFalse(weth.paymentAfterAcquisition());
        assertEq(weth.balanceOf(seller), 0);
        assertEq(weth.balanceOf(address(fundingAccount)), 0);
        assertEq(vault.balanceOf(address(fundingAccount)), fundingSharesBefore);
        assertEq(weth.balanceOf(address(vault)), FUNDING);
    }

    function _assertFundingEntirelyInShares() private view {
        assertEq(weth.balanceOf(address(fundingAccount)), 0);
        assertEq(weth.balanceOf(address(reserveAdapter)), 0);
        assertEq(vault.balanceOf(address(fundingAccount)), FUNDING);
        assertEq(weth.balanceOf(address(vault)), FUNDING);
        assertEq(vault.maxWithdraw(address(fundingAccount)), FUNDING);
    }

    function _quote(uint256 nonce) private view returns (ClaimTypes.Quote memory) {
        return ClaimTypes.Quote({
            factor: factor,
            seller: seller,
            adapter: address(lidoAdapter),
            claimController: seller,
            claimReceiver: factor,
            paymentAsset: address(weth),
            paymentAmount: PAYMENT,
            claimDataHash: keccak256(claimData),
            boundsHash: keccak256(boundsData),
            nonce: nonce,
            deadline: block.timestamp + 10 minutes
        });
    }

    function _sign(ClaimTypes.Quote memory quote) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FACTOR_KEY, settlement.hashQuote(quote));
        return abi.encodePacked(r, s, v);
    }
}
