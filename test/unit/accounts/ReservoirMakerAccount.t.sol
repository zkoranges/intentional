// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { IMakerHooks } from "@1inch/swap-vm/src/interfaces/IMakerHooks.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { ReservoirMakerAccount } from "../../../src/accounts/ReservoirMakerAccount.sol";
import { ERC4626ReserveAdapter } from "../../../src/adapters/ERC4626ReserveAdapter.sol";
import { IAquaReserveResolver } from "../../../src/interfaces/IAquaReserveResolver.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockERC4626 } from "../../mocks/MockERC4626.sol";
import { MockReservoirRouter } from "../../mocks/MockReservoirRouter.sol";

contract ReservoirMakerAccountTest is Test {
    event ReinvestSucceeded(address indexed asset, address indexed adapter);
    event ReinvestFailed(address indexed asset, ReservoirMakerAccount.FailureReason reason);

    uint32 internal constant REINVEST_GAS_LIMIT = 500_000;
    bytes internal constant PROGRAM = hex"0192";

    address internal taker = makeAddr("taker");
    address internal stranger = makeAddr("stranger");

    Aqua internal aqua;
    ReservoirMakerAccount internal account;
    MockReservoirRouter internal router;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC4626 internal vaultA;
    MockERC4626 internal vaultB;
    ERC4626ReserveAdapter internal adapterA;
    ERC4626ReserveAdapter internal adapterB;

    function setUp() public {
        aqua = new Aqua();
        account = new ReservoirMakerAccount(address(this), IAqua(address(aqua)));
        router = new MockReservoirRouter(IAqua(address(aqua)));

        MockERC20 first = new MockERC20("First", "FIRST", 18);
        MockERC20 second = new MockERC20("Second", "SECOND", 18);
        (tokenA, tokenB) = address(first) < address(second) ? (first, second) : (second, first);

        vaultA = new MockERC4626(IERC20(address(tokenA)), "Vault A", "vA");
        vaultB = new MockERC4626(IERC20(address(tokenB)), "Vault B", "vB");
        adapterA = new ERC4626ReserveAdapter(address(account), vaultA, 0, 0);
        adapterB = new ERC4626ReserveAdapter(address(account), vaultB, 0, 0);

        account.configureRouter(router);
        account.configureReserve(address(tokenB), adapterB, REINVEST_GAS_LIMIT);
        account.configureReserve(address(tokenA), adapterA, REINVEST_GAS_LIMIT);
    }

    function test_ConfigurationSortsPairAndSetsUnlimitedImmutableAllowances() public view {
        assertEq(account.tokenA(), address(tokenA));
        assertEq(account.tokenB(), address(tokenB));
        assertEq(address(account.adapterOf(address(tokenA))), address(adapterA));
        assertEq(address(account.adapterOf(address(tokenB))), address(adapterB));

        assertEq(tokenA.allowance(address(account), address(aqua)), type(uint256).max);
        assertEq(tokenA.allowance(address(account), address(adapterA)), type(uint256).max);
        assertEq(vaultA.allowance(address(account), address(adapterA)), type(uint256).max);
        assertEq(tokenB.allowance(address(account), address(aqua)), type(uint256).max);
        assertEq(tokenB.allowance(address(account), address(adapterB)), type(uint256).max);
        assertEq(vaultB.allowance(address(account), address(adapterB)), type(uint256).max);
    }

    function test_SetupIsControllerOnlyAndSingleAssignment() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ReservoirMakerAccount.OnlyController.selector, stranger));
        account.prepareInventory(address(tokenA));

        vm.expectRevert(ReservoirMakerAccount.AlreadyConfigured.selector);
        account.configureRouter(router);

        vm.expectRevert(ReservoirMakerAccount.AlreadyConfigured.selector);
        account.configureReserve(address(tokenA), adapterA, REINVEST_GAS_LIMIT);
    }

    function test_ConfigureRejectsAdapterBoundToAnotherMaker() public {
        ReservoirMakerAccount other = new ReservoirMakerAccount(address(this), IAqua(address(aqua)));
        MockERC20 third = new MockERC20("Third", "THIRD", 18);
        MockERC4626 thirdVault = new MockERC4626(IERC20(address(third)), "Third Vault", "vTHIRD");
        ERC4626ReserveAdapter wrong = new ERC4626ReserveAdapter(stranger, thirdVault, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                ReservoirMakerAccount.AdapterBindingMismatch.selector, address(third), address(wrong)
            )
        );
        other.configureReserve(address(third), wrong, REINVEST_GAS_LIMIT);
    }

    function test_PrepareInventoryDepositsToMakerOwnedShares() public {
        _fund(1000, 2000);
        account.prepareInventory(address(tokenA));
        account.prepareInventory(address(tokenB));

        assertEq(tokenA.balanceOf(address(account)), 0);
        assertEq(tokenB.balanceOf(address(account)), 0);
        assertEq(vaultA.balanceOf(address(account)), 1000);
        assertEq(vaultB.balanceOf(address(account)), 2000);
        assertEq(tokenA.balanceOf(address(adapterA)), 0);
        assertEq(tokenB.balanceOf(address(adapterB)), 0);
    }

    function test_SealAndShipBuildsExactOrderAndAlignedAquaBalances() public {
        _fundAndPrepare(1000, 2000);

        (ISwapVM.Order memory order, bytes32 shippedHash) = account.sealAndShip(PROGRAM, 1000, 2000);

        assertTrue(account.isSealed());
        assertEq(shippedHash, keccak256(abi.encode(order)));
        assertEq(account.strategyHash(), shippedHash);
        assertEq(keccak256(abi.encode(account.shippedOrder())), keccak256(abi.encode(order)));
        assertEq(account.strategyProgram(), PROGRAM);

        (uint248 balanceA, uint8 countA) =
            aqua.rawBalances(address(account), address(router), shippedHash, address(tokenA));
        (uint248 balanceB, uint8 countB) =
            aqua.rawBalances(address(account), address(router), shippedHash, address(tokenB));
        assertEq(balanceA, 1000);
        assertEq(balanceB, 2000);
        assertEq(countA, 2);
        assertEq(countB, 2);
    }

    function test_SealRejectsUnbackedBalanceAndHashMismatchAtomically() public {
        _fundAndPrepare(1000, 2000);
        vm.expectRevert(
            abi.encodeWithSelector(ReservoirMakerAccount.InvalidVirtualBalance.selector, address(tokenA), 1001, 1000)
        );
        account.sealAndShip(PROGRAM, 1001, 2000);
        assertFalse(account.isSealed());

        router.setReturnBadHash(true);
        ISwapVM.Order memory order = account.buildOrder(PROGRAM);
        bytes32 aquaHash = keccak256(abi.encode(order));
        bytes32 routerHash = bytes32(uint256(aquaHash) ^ 1);
        vm.expectRevert(
            abi.encodeWithSelector(ReservoirMakerAccount.StrategyHashMismatch.selector, routerHash, aquaHash)
        );
        account.sealAndShip(PROGRAM, 1000, 2000);
        assertFalse(account.isSealed());
        assertEq(account.strategyHash(), bytes32(0));
    }

    function test_ConfigurationAndPreparationCannotChangeAfterShipping() public {
        _fundAndPrepare(1000, 2000);
        account.sealAndShip(PROGRAM, 1000, 2000);

        vm.expectRevert(ReservoirMakerAccount.ConfigurationSealed.selector);
        account.prepareInventory(address(tokenA));
        MockReservoirRouter replacement = new MockReservoirRouter(IAqua(address(aqua)));
        vm.expectRevert(ReservoirMakerAccount.ConfigurationSealed.selector);
        account.configureRouter(replacement);
    }

    function test_ResolverFacadeReturnsZeroForUnsupportedAndAdapterFailure() public {
        (uint256 unsupported, uint256 unsupportedCost) = account.availableFor(makeAddr("unsupported"), 100);
        assertEq(unsupported, 0);
        assertEq(unsupportedCost, 0);

        bytes memory callData = abi.encodeCall(IAquaReserveResolver.availableFor, (address(tokenA), 100));
        vm.mockCallRevert(address(adapterA), callData, bytes("forced"));
        (uint256 failed, uint256 failedCost) = account.availableFor(address(tokenA), 100);
        assertEq(failed, 0);
        assertEq(failedCost, 0);
        vm.clearMockedCalls();
    }

    function test_HooksMaterializeOutputThenReinvestInputAndClearPhase() public {
        bytes32 orderHash = _fundPrepareAndSeal(1000, 2000);
        uint256 inputSharesBefore = vaultA.balanceOf(address(account));

        _preOut(address(tokenA), address(tokenB), 100, 200, orderHash);
        assertEq(tokenB.balanceOf(address(account)), 200);
        assertEq(account.settlementPhase(orderHash), 1);

        vm.prank(address(account));
        assertTrue(tokenB.transfer(taker, 200));
        _preIn(address(tokenA), address(tokenB), 100, 200, orderHash);
        assertEq(account.settlementPhase(orderHash), 2);

        tokenA.mint(address(account), 100);
        vm.expectEmit(true, true, false, false, address(account));
        emit ReinvestSucceeded(address(tokenA), address(adapterA));
        _postIn(address(tokenA), address(tokenB), 100, 200, orderHash);

        assertEq(account.settlementPhase(orderHash), 0);
        assertEq(tokenA.balanceOf(address(account)), 0);
        assertEq(vaultA.balanceOf(address(account)) - inputSharesBefore, 100);
        assertEq(tokenA.balanceOf(address(adapterA)), 0);
    }

    function test_InputFirstAndPostWithoutPreInFailOrderingGuard() public {
        bytes32 orderHash = _fundPrepareAndSeal(1000, 2000);

        vm.expectRevert(abi.encodeWithSelector(ReservoirMakerAccount.InvalidSettlementPhase.selector, 1, 0));
        _preIn(address(tokenA), address(tokenB), 100, 100, orderHash);

        _preOut(address(tokenA), address(tokenB), 100, 100, orderHash);
        vm.expectRevert(abi.encodeWithSelector(ReservoirMakerAccount.InvalidSettlementPhase.selector, 2, 1));
        _postIn(address(tokenA), address(tokenB), 100, 100, orderHash);
    }

    function test_HookAuthenticationRejectsCallerMakerHashAndPair() public {
        bytes32 orderHash = _fundPrepareAndSeal(1000, 2000);

        vm.expectRevert(abi.encodeWithSelector(ReservoirMakerAccount.OnlyRouter.selector, address(this)));
        account.preTransferOut(address(account), taker, address(tokenA), address(tokenB), 1, 1, orderHash, "", "");

        vm.expectRevert(abi.encodeWithSelector(ReservoirMakerAccount.InvalidHookMaker.selector, stranger));
        router.forwardPreTransferOut(account, stranger, taker, address(tokenA), address(tokenB), 1, 1, orderHash);

        bytes32 wrongHash = bytes32(uint256(orderHash) + 1);
        vm.expectRevert(abi.encodeWithSelector(ReservoirMakerAccount.InvalidOrderHash.selector, wrongHash));
        router.forwardPreTransferOut(
            account, address(account), taker, address(tokenA), address(tokenB), 1, 1, wrongHash
        );

        address wrongToken = makeAddr("wrong");
        vm.expectRevert(
            abi.encodeWithSelector(ReservoirMakerAccount.InvalidTokenPair.selector, address(tokenA), wrongToken)
        );
        router.forwardPreTransferOut(account, address(account), taker, address(tokenA), wrongToken, 1, 1, orderHash);
    }

    function test_PreWithdrawFailureIsAtomicAndDoesNotSetPhase() public {
        bytes32 orderHash = _fundPrepareAndSeal(1000, 2000);
        uint256 sharesBefore = vaultB.balanceOf(address(account));
        bytes memory withdrawCall = abi.encodeCall(IERC4626.withdraw, (100, address(account), address(account)));
        vm.mockCallRevert(address(vaultB), withdrawCall, bytes("forced withdraw"));

        vm.expectRevert();
        _preOut(address(tokenA), address(tokenB), 100, 100, orderHash);

        assertEq(account.settlementPhase(orderHash), 0);
        assertEq(tokenB.balanceOf(address(account)), 0);
        assertEq(vaultB.balanceOf(address(account)), sharesBefore);
        vm.clearMockedCalls();
    }

    function test_PostDepositFailureEmitsFailureLeavesInputIdleAndClearsPhase() public {
        bytes32 orderHash = _fundPrepareAndSeal(1000, 2000);
        _preOut(address(tokenA), address(tokenB), 100, 100, orderHash);
        _preIn(address(tokenA), address(tokenB), 100, 100, orderHash);
        tokenA.mint(address(account), 100);

        bytes memory depositCall = abi.encodeCall(IERC4626.deposit, (100, address(account)));
        vm.mockCallRevert(address(vaultA), depositCall, bytes("forced deposit"));
        vm.expectEmit(true, false, false, true, address(account));
        emit ReinvestFailed(address(tokenA), ReservoirMakerAccount.FailureReason.CallFailed);
        _postIn(address(tokenA), address(tokenB), 100, 100, orderHash);

        assertEq(account.settlementPhase(orderHash), 0);
        assertEq(tokenA.balanceOf(address(account)), 100);
        assertEq(tokenA.balanceOf(address(adapterA)), 0);
        vm.clearMockedCalls();
    }

    function test_PostTransferOutIsDisabled() public {
        bytes32 orderHash = _fundPrepareAndSeal(1000, 2000);
        vm.expectRevert(ReservoirMakerAccount.HookDisabled.selector);
        router.forwardPostTransferOut(
            account, address(account), taker, address(tokenA), address(tokenB), 1, 1, orderHash
        );
    }

    function _fund(uint256 amountA, uint256 amountB) private {
        tokenA.mint(address(account), amountA);
        tokenB.mint(address(account), amountB);
    }

    function _fundAndPrepare(uint256 amountA, uint256 amountB) private {
        _fund(amountA, amountB);
        account.prepareInventory(address(tokenA));
        account.prepareInventory(address(tokenB));
    }

    function _fundPrepareAndSeal(uint256 amountA, uint256 amountB) private returns (bytes32 orderHash) {
        _fundAndPrepare(amountA, amountB);
        (, orderHash) = account.sealAndShip(PROGRAM, amountA, amountB);
    }

    function _preOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash
    )
        private
    {
        router.forwardPreTransferOut(
            account, address(account), taker, tokenIn, tokenOut, amountIn, amountOut, orderHash
        );
    }

    function _preIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, bytes32 orderHash) private {
        router.forwardPreTransferIn(account, address(account), taker, tokenIn, tokenOut, amountIn, amountOut, orderHash);
    }

    function _postIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash
    )
        private
    {
        router.forwardPostTransferIn(
            account, address(account), taker, tokenIn, tokenOut, amountIn, amountOut, orderHash
        );
    }
}
