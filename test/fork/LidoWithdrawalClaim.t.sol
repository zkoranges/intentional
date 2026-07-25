// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { ERC4626ReserveAdapter } from "../../src/adapters/ERC4626ReserveAdapter.sol";
import { AsyncClaimSettlement } from "../../src/claims/AsyncClaimSettlement.sol";
import { ProductiveFundingAccount } from "../../src/claims/ProductiveFundingAccount.sol";
import { LidoWithdrawalClaimAdapter } from "../../src/claims/adapters/LidoWithdrawalClaimAdapter.sol";
import { ILidoWithdrawalQueue } from "../../src/claims/interfaces/ILidoWithdrawalQueue.sol";
import { ClaimTypes } from "../../src/claims/types/ClaimTypes.sol";

interface IMainnetStETH is IERC20 {
    function submit(address referral) external payable returns (uint256 shares);

    function getSharesByPooledEth(uint256 amount) external view returns (uint256 shares);

    function sharesOf(address account) external view returns (uint256 shares);
}

interface IMainnetLidoWithdrawalQueue is ILidoWithdrawalQueue {
    function STETH() external view returns (address);

    function getLastRequestId() external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);
}

interface IMainnetWETH is IERC20 {
    function deposit() external payable;
}

interface IStataTokenV2Integration {
    function aToken() external view returns (address);
}

interface IAaveATokenIntegration {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

    function POOL() external view returns (address);
}

/// @notice Full signed Reservoir v2 fill against canonical Lido at a pinned
///         block, funded by canonical WETH held in canonical Aave StataWETH.
/// @dev Requires an archive-capable ETH_RPC_URL. It never impersonates a Lido
///      oracle or finalizer and never touches a persistent deployment.
contract LidoWithdrawalClaimForkTest is Test {
    uint256 private constant PINNED_BLOCK = 25_604_561;
    bytes32 private constant PINNED_BLOCK_HASH = 0x95ca77908413d71bd01cada1ece52b6c2f35467dbbb8f2367144cd0ffbe7888d;

    address private constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private constant QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant STATA_WETH = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;
    address private constant A_WETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address private constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    uint256 private constant FACTOR_KEY = 0xA11CE;
    uint256 private constant SUBMITTED_ETH = 1 ether;
    uint256 private constant FUNDING_WETH = 5 ether;
    uint256 private constant PAYMENT_WETH = 0.9975 ether;
    uint256 private constant QUOTE_NONCE = 1;
    uint256 private constant MAX_STETH_SHORTFALL = 2;
    string private constant ARCHIVE_FAILURE = "archive RPC required for block 25,604,561";

    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant WITHDRAW_TOPIC = keccak256("Withdraw(address,address,address,uint256,uint256)");

    IMainnetStETH private constant LIDO = IMainnetStETH(STETH);
    IMainnetLidoWithdrawalQueue private constant WITHDRAWAL_QUEUE = IMainnetLidoWithdrawalQueue(QUEUE);
    IMainnetWETH private constant MAINNET_WETH = IMainnetWETH(WETH);
    IERC4626 private constant STATA = IERC4626(STATA_WETH);

    ProductiveFundingAccount private fundingAccount;
    ERC4626ReserveAdapter private reserveAdapter;
    AsyncClaimSettlement private settlement;
    LidoWithdrawalClaimAdapter private lidoAdapter;

    address private seller;
    address private factor;
    uint256 private reserveAdapterNativeBaseline;
    uint256 private lidoAdapterNativeBaseline;

    function setUp() public {
        _pinAndValidateFork();

        seller = makeAddr("disposableLidoSeller");
        factor = vm.addr(FACTOR_KEY);

        fundingAccount = new ProductiveFundingAccount(factor);
        reserveAdapter = new ERC4626ReserveAdapter(address(fundingAccount), STATA, 0, 0);

        vm.prank(factor);
        fundingAccount.configureReserve(reserveAdapter);

        settlement = new AsyncClaimSettlement(factor, fundingAccount);
        lidoAdapter = new LidoWithdrawalClaimAdapter(address(settlement), IERC20(STETH), WITHDRAWAL_QUEUE);
        // Fork tests deploy at well-known deterministic Foundry addresses. Those
        // addresses can already have forced native dust in historical mainnet
        // state, so the meaningful invariant is that this flow does not change it.
        reserveAdapterNativeBaseline = address(reserveAdapter).balance;
        lidoAdapterNativeBaseline = address(lidoAdapter).balance;

        vm.deal(factor, FUNDING_WETH);
        vm.startPrank(factor);
        MAINNET_WETH.deposit{ value: FUNDING_WETH }();
        assertTrue(MAINNET_WETH.transfer(address(fundingAccount), FUNDING_WETH));

        fundingAccount.prepareInventory();
        fundingAccount.configureSettlement(address(settlement));
        fundingAccount.seal();
        settlement.allowAdapter(address(lidoAdapter));
        settlement.seal();
        vm.stopPrank();
    }

    function test_JuryDemo_RealLidoClaimBeforeRealAavePayment() public {
        _assertFundingEntirelyInShares();
        (uint256 navBefore, uint256 navAfter, uint256 fixedShares) = _assertRealStataWETHAccruesAtFixedShares();

        vm.deal(seller, SUBMITTED_ETH);
        vm.prank(seller);
        LIDO.submit{ value: SUBMITTED_ETH }(address(0));

        uint256 requestedStETH = LIDO.balanceOf(seller);
        assertGe(requestedStETH, lidoAdapter.MIN_STETH_WITHDRAWAL_AMOUNT());
        assertLe(requestedStETH, lidoAdapter.MAX_STETH_WITHDRAWAL_AMOUNT());
        assertGt(requestedStETH, MAX_STETH_SHORTFALL);

        uint256 minShares = LIDO.getSharesByPooledEth(requestedStETH - MAX_STETH_SHORTFALL);
        assertGt(minShares, 0);

        bytes memory claimData = abi.encode(
            LidoWithdrawalClaimAdapter.LidoOriginateData({ queue: QUEUE, stETH: STETH, requestedStETH: requestedStETH })
        );
        bytes memory boundsData = abi.encode(
            LidoWithdrawalClaimAdapter.LidoOriginateBounds({
                maxStETHShortfall: MAX_STETH_SHORTFALL, minAmountOfShares: minShares
            })
        );
        ClaimTypes.Quote memory quote = ClaimTypes.Quote({
            factor: factor,
            seller: seller,
            adapter: address(lidoAdapter),
            claimController: factor,
            claimReceiver: factor,
            paymentAsset: WETH,
            paymentAmount: PAYMENT_WETH,
            claimDataHash: keccak256(claimData),
            boundsHash: keccak256(boundsData),
            nonce: QUOTE_NONCE,
            deadline: block.timestamp + 10 minutes
        });
        bytes memory signature = _sign(quote);

        vm.prank(seller);
        assertTrue(LIDO.approve(address(lidoAdapter), requestedStETH));

        uint256 lastRequestBefore = WITHDRAWAL_QUEUE.getLastRequestId();

        uint256 sellerWETHBefore = MAINNET_WETH.balanceOf(seller);
        uint256 fundingSharesBefore = STATA.balanceOf(address(fundingAccount));
        uint256 expectedFundingSharesBurned = STATA.previewWithdraw(PAYMENT_WETH);

        vm.recordLogs();
        vm.prank(seller);
        ClaimTypes.Acquisition memory acquired = settlement.fill(quote, claimData, boundsData, signature);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(acquired.claimId, lastRequestBefore + 1);
        assertEq(WITHDRAWAL_QUEUE.getLastRequestId(), acquired.claimId);
        assertEq(acquired.positionKey, keccak256(abi.encode(QUEUE, acquired.claimId)));
        assertEq(acquired.pendingUnits, acquired.pendingReceived);
        assertGe(acquired.pendingUnits, minShares);
        assertEq(acquired.claimableUnits, 0);
        assertEq(acquired.assetsReceived, 0);

        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = acquired.claimId;
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses =
            WITHDRAWAL_QUEUE.getWithdrawalStatus(requestIds);
        assertEq(statuses.length, 1);
        assertEq(statuses[0].owner, factor);
        assertEq(statuses[0].amountOfShares, acquired.pendingReceived);
        assertFalse(statuses[0].isFinalized);
        assertFalse(statuses[0].isClaimed);
        assertLe(requestedStETH - statuses[0].amountOfStETH, MAX_STETH_SHORTFALL);
        assertEq(WITHDRAWAL_QUEUE.balanceOf(factor), 1);
        assertEq(WITHDRAWAL_QUEUE.balanceOf(address(lidoAdapter)), 0);

        _assertRealProtocolEventOrder(logs, acquired.claimId);
        assertEq(fundingSharesBefore - STATA.balanceOf(address(fundingAccount)), expectedFundingSharesBurned);
        assertEq(MAINNET_WETH.balanceOf(seller) - sellerWETHBefore, PAYMENT_WETH);
        assertEq(MAINNET_WETH.balanceOf(address(fundingAccount)), 0);
        assertTrue(settlement.nonceUsed(QUOTE_NONCE));

        _assertAdapterDustFree();
        _emitJuryProof(navBefore, navAfter, fixedShares, requestedStETH, acquired.pendingReceived);
    }

    function test_ProductionLidoPathRejectsSellerAsClaimReceiverBeforeMovement() public {
        bytes memory claimData = abi.encode(
            LidoWithdrawalClaimAdapter.LidoOriginateData({
                queue: QUEUE, stETH: STETH, requestedStETH: lidoAdapter.MIN_STETH_WITHDRAWAL_AMOUNT()
            })
        );
        bytes memory boundsData = abi.encode(
            LidoWithdrawalClaimAdapter.LidoOriginateBounds({ maxStETHShortfall: 0, minAmountOfShares: 1 })
        );
        ClaimTypes.Quote memory quote = ClaimTypes.Quote({
            factor: factor,
            seller: seller,
            adapter: address(lidoAdapter),
            claimController: factor,
            claimReceiver: seller,
            paymentAsset: WETH,
            paymentAmount: PAYMENT_WETH,
            claimDataHash: keccak256(claimData),
            boundsHash: keccak256(boundsData),
            nonce: QUOTE_NONCE,
            deadline: block.timestamp + 10 minutes
        });

        uint256 lastRequestBefore = WITHDRAWAL_QUEUE.getLastRequestId();
        uint256 sellerWethBefore = MAINNET_WETH.balanceOf(seller);
        bytes memory signature = _sign(quote);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AsyncClaimSettlement.ClaimReceiverIsSeller.selector, seller));
        settlement.fill(quote, claimData, boundsData, signature);

        assertEq(WITHDRAWAL_QUEUE.getLastRequestId(), lastRequestBefore);
        assertEq(MAINNET_WETH.balanceOf(seller), sellerWethBefore);
        assertFalse(settlement.nonceUsed(quote.nonce));
    }

    function _assertFundingEntirelyInShares() private view {
        assertEq(MAINNET_WETH.balanceOf(address(fundingAccount)), 0);
        assertEq(MAINNET_WETH.balanceOf(address(reserveAdapter)), 0);
        assertGt(STATA.balanceOf(address(fundingAccount)), 0);
        assertGe(STATA.maxWithdraw(address(fundingAccount)), FUNDING_WETH - 1);
        assertLe(STATA.maxWithdraw(address(fundingAccount)), FUNDING_WETH);
        assertEq(fundingAccount.availableFor(PAYMENT_WETH), PAYMENT_WETH);
    }

    function _assertRealStataWETHAccruesAtFixedShares()
        private
        returns (uint256 navBefore, uint256 navAfter, uint256 fixedShares)
    {
        uint256 snapshot = vm.snapshotState();
        fixedShares = STATA.balanceOf(address(fundingAccount));
        navBefore = STATA.convertToAssets(fixedShares);
        uint256 blockBefore = block.number;

        vm.warp(block.timestamp + 30 days);

        navAfter = STATA.convertToAssets(fixedShares);
        assertEq(STATA.balanceOf(address(fundingAccount)), fixedShares, "yield warp changed StataWETH shares");
        assertEq(block.number, blockBefore, "yield proof must not roll the fork");
        assertGt(navAfter, navBefore, "real StataWETH fixed-share NAV did not accrue");
        assertTrue(vm.revertToStateAndDelete(snapshot), "could not restore pinned pre-fill state");
    }

    function _emitJuryProof(
        uint256 navBefore,
        uint256 navAfter,
        uint256 fixedShares,
        uint256 requestedStETH,
        uint256 acquiredLidoShares
    )
        private
    {
        emit log_string("JURY 1 | REAL CONTRACTS | Lido WithdrawalQueue + Aave StataWETH");
        emit log_named_decimal_uint("JURY 2 | Reserve NAV before (WETH)", navBefore, 18);
        emit log_named_decimal_uint("JURY 3 | Reserve NAV after 30 days (WETH)", navAfter, 18);
        emit log_named_decimal_uint("JURY 4 | Seller stETH submitted", requestedStETH, 18);
        emit log_named_decimal_uint("JURY 5 | Lido claim shares acquired", acquiredLidoShares, 18);
        emit log_named_decimal_uint("JURY 6 | Exact WETH paid after acquisition", PAYMENT_WETH, 18);

        assertGt(fixedShares, 0, "jury reserve had no StataWETH shares");
    }

    function _assertRealProtocolEventOrder(Vm.Log[] memory logs, uint256 requestId) private view {
        uint256 lidoMintIndex = type(uint256).max;
        uint256 aaveWithdrawIndex = type(uint256).max;
        bytes32 factorTopic = bytes32(uint256(uint160(factor)));

        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter == QUEUE && entry.topics.length == 4 && entry.topics[0] == TRANSFER_TOPIC
                    && entry.topics[1] == bytes32(0) && entry.topics[2] == factorTopic
                    && entry.topics[3] == bytes32(requestId)
            ) {
                lidoMintIndex = i;
            }
            if (
                aaveWithdrawIndex == type(uint256).max && entry.emitter == STATA_WETH && entry.topics.length != 0
                    && entry.topics[0] == WITHDRAW_TOPIC
            ) {
                aaveWithdrawIndex = i;
            }
        }

        assertTrue(lidoMintIndex != type(uint256).max, "missing real Lido ERC-721 mint");
        assertTrue(aaveWithdrawIndex != type(uint256).max, "missing real StataWETH withdrawal");
        assertLt(lidoMintIndex, aaveWithdrawIndex, "payment reserve exited before Lido claim acquisition");
    }

    function _assertAdapterDustFree() private view {
        assertEq(LIDO.balanceOf(address(lidoAdapter)), 0);
        assertEq(LIDO.sharesOf(address(lidoAdapter)), 0);
        assertEq(LIDO.allowance(address(lidoAdapter), QUEUE), 0);
        assertEq(MAINNET_WETH.balanceOf(address(lidoAdapter)), 0);
        assertEq(MAINNET_WETH.balanceOf(address(reserveAdapter)), 0);
        assertEq(STATA.balanceOf(address(reserveAdapter)), 0);
        assertEq(MAINNET_WETH.balanceOf(address(settlement)), 0);
        assertEq(address(lidoAdapter).balance, lidoAdapterNativeBaseline, "Lido flow changed native ETH balance");
        assertEq(
            address(reserveAdapter).balance, reserveAdapterNativeBaseline, "reserve flow changed native ETH balance"
        );
    }

    function _sign(ClaimTypes.Quote memory quote) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FACTOR_KEY, settlement.hashQuote(quote));
        return abi.encodePacked(r, s, v);
    }

    function _pinAndValidateFork() private {
        try this.__historicalStateProbe() returns (bool hasHistoricalState) {
            if (!hasHistoricalState) {
                revert(ARCHIVE_FAILURE);
            }
        } catch {
            revert(ARCHIVE_FAILURE);
        }

        try this.__rollFork(PINNED_BLOCK + 1) { }
        catch {
            revert(ARCHIVE_FAILURE);
        }
        assertEq(block.number, PINNED_BLOCK + 1, "fork did not roll to block after pin");
        assertEq(blockhash(PINNED_BLOCK), PINNED_BLOCK_HASH, "unexpected pinned block hash");

        try this.__rollFork(PINNED_BLOCK) { }
        catch {
            revert(ARCHIVE_FAILURE);
        }
        assertEq(block.number, PINNED_BLOCK, "fork did not restore pinned state");

        assertGt(STETH.code.length, 0, "canonical stETH has no code");
        assertGt(QUEUE.code.length, 0, "canonical withdrawal queue has no code");
        assertGt(WETH.code.length, 0, "canonical WETH has no code");
        assertGt(STATA_WETH.code.length, 0, "canonical StataWETH has no code");
        assertGt(A_WETH.code.length, 0, "canonical aWETH has no code");
        assertGt(AAVE_V3_POOL.code.length, 0, "canonical Aave Pool has no code");
        assertEq(WITHDRAWAL_QUEUE.STETH(), STETH, "queue/stETH wiring mismatch");
        assertEq(STATA.asset(), WETH, "unexpected StataWETH asset");
        assertEq(IStataTokenV2Integration(STATA_WETH).aToken(), A_WETH, "unexpected StataWETH aToken");
        assertEq(IAaveATokenIntegration(A_WETH).UNDERLYING_ASSET_ADDRESS(), WETH, "unexpected aWETH underlying");
        assertEq(IAaveATokenIntegration(A_WETH).POOL(), AAVE_V3_POOL, "unexpected aWETH Pool");
    }

    function __rollFork(uint256 blockNumber) external {
        require(msg.sender == address(this), "self only");
        vm.rollFork(blockNumber);
    }

    /// @dev Probe historical state before the fork backend lazily loads an old
    ///      account, so a non-archive endpoint fails with the documented error.
    function __historicalStateProbe() external returns (bool) {
        require(msg.sender == address(this), "self only");
        bytes memory historicalCode =
            vm.rpc("eth_getCode", "[\"0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1\",\"0x186b1d1\"]");
        return historicalCode.length != 0;
    }
}
