// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { ReservoirMakerAccount } from "../../../src/accounts/ReservoirMakerAccount.sol";
import { ERC4626ReserveAdapter } from "../../../src/adapters/ERC4626ReserveAdapter.sol";
import { GasBurningERC4626 } from "../../mocks/GasBurningERC4626.sol";
import { HugeRevertDataERC4626 } from "../../mocks/HugeRevertDataERC4626.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockERC4626 } from "../../mocks/MockERC4626.sol";
import { MockReservoirRouter } from "../../mocks/MockReservoirRouter.sol";

contract ReservoirMakerGasIsolationTest is Test {
    event ReinvestSucceeded(address indexed asset, address indexed adapter);
    event ReinvestFailed(address indexed asset, ReservoirMakerAccount.FailureReason reason);

    enum VaultMode {
        Normal,
        GasBurning,
        HugeRevert
    }

    struct Fixture {
        ReservoirMakerAccount account;
        MockReservoirRouter router;
        MockERC20 input;
        MockERC20 output;
        MockERC4626 inputVault;
        MockERC4626 outputVault;
        ERC4626ReserveAdapter inputAdapter;
        ERC4626ReserveAdapter outputAdapter;
        bytes32 orderHash;
    }

    address internal taker = makeAddr("taker");

    function test_GasBurningVaultCannotRevertSettledPostHook() public {
        Fixture memory f = _fixture(VaultMode.GasBurning, 80_000);
        GasBurningERC4626(address(f.inputVault)).setBurnOnDeposit(true);
        _armPostInput(f, 100);

        vm.expectEmit(true, false, false, true, address(f.account));
        emit ReinvestFailed(address(f.input), ReservoirMakerAccount.FailureReason.CallFailed);
        _postInput(f, 100);

        assertEq(f.account.settlementPhase(f.orderHash), 0);
        assertEq(f.input.balanceOf(address(f.account)), 100);
        assertEq(f.input.balanceOf(address(f.inputAdapter)), 0);
    }

    function test_HugeRevertDataIsNotCopiedAndCannotRevertSettledPostHook() public {
        Fixture memory f = _fixture(VaultMode.HugeRevert, 300_000);
        HugeRevertDataERC4626(address(f.inputVault)).setHugeRevertOnDeposit(true);
        _armPostInput(f, 100);

        uint256 gasBefore = gasleft();
        vm.expectEmit(true, false, false, true, address(f.account));
        emit ReinvestFailed(address(f.input), ReservoirMakerAccount.FailureReason.CallFailed);
        _postInput(f, 100);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 500_000);
        assertEq(f.account.settlementPhase(f.orderHash), 0);
        assertEq(f.input.balanceOf(address(f.account)), 100);
        assertEq(f.input.balanceOf(address(f.inputAdapter)), 0);
    }

    function test_ForwardedGasJustBelowRetainedBoundarySkipsAndCompletes() public {
        Fixture memory f = _fixture(VaultMode.Normal, 500_000);
        uint256 boundary = f.account.POST_HOOK_GAS_RESERVE() + f.account.CALL_OVERHEAD();
        _assertLowGasSkipCompletes(f, boundary - 1);
    }

    function test_ForwardedGasAtRetainedBoundarySkipsAndCompletes() public {
        Fixture memory f = _fixture(VaultMode.Normal, 500_000);
        uint256 boundary = f.account.POST_HOOK_GAS_RESERVE() + f.account.CALL_OVERHEAD();
        _assertLowGasSkipCompletes(f, boundary);
    }

    function test_ForwardedGasWellBelowRetainedBoundarySkipsAndCompletes() public {
        Fixture memory f = _fixture(VaultMode.Normal, 500_000);
        _assertLowGasSkipCompletes(f, 35_000);
    }

    function test_SufficientGasAboveBoundaryRunsBoundedReinvestSuccessfully() public {
        Fixture memory f = _fixture(VaultMode.Normal, 500_000);
        _armPostInput(f, 100);

        vm.expectEmit(true, true, false, false, address(f.account));
        emit ReinvestSucceeded(address(f.input), address(f.inputAdapter));
        bool success = f.router
            .forwardPostTransferInWithGas(
                f.account, address(f.account), taker, address(f.input), address(f.output), 100, 10, f.orderHash, 350_000
            );

        assertTrue(success);
        assertEq(f.account.settlementPhase(f.orderHash), 0);
        assertEq(f.input.balanceOf(address(f.account)), 0);
        assertEq(f.input.balanceOf(address(f.inputAdapter)), 0);
    }

    function test_CallerLevelGasBelowCompletionBoundaryIsExplicitlyOutsideGuarantee() public {
        Fixture memory f = _fixture(VaultMode.Normal, 500_000);
        _armPostInput(f, 100);

        bool success = f.router
            .forwardPostTransferInWithGas(
                f.account, address(f.account), taker, address(f.input), address(f.output), 100, 10, f.orderHash, 3000
            );

        assertFalse(success);
        assertEq(f.account.settlementPhase(f.orderHash), 2);
        assertEq(f.input.balanceOf(address(f.account)), 100);
    }

    function _fixture(VaultMode mode, uint32 inputGasLimit) private returns (Fixture memory f) {
        Aqua aqua = new Aqua();
        f.account = new ReservoirMakerAccount(address(this), IAqua(address(aqua)));
        f.router = new MockReservoirRouter(IAqua(address(aqua)));
        f.input = new MockERC20("Input", "IN", 18);
        f.output = new MockERC20("Output", "OUT", 18);

        if (mode == VaultMode.GasBurning) {
            f.inputVault =
                MockERC4626(address(new GasBurningERC4626(IERC20(address(f.input)), "Gas Burning Vault", "gbvIN")));
        } else if (mode == VaultMode.HugeRevert) {
            f.inputVault = MockERC4626(
                address(new HugeRevertDataERC4626(IERC20(address(f.input)), "Huge Revert Vault", "hrvIN"))
            );
        } else {
            f.inputVault = new MockERC4626(IERC20(address(f.input)), "Input Vault", "vIN");
        }
        f.outputVault = new MockERC4626(IERC20(address(f.output)), "Output Vault", "vOUT");
        f.inputAdapter = new ERC4626ReserveAdapter(address(f.account), f.inputVault, 0, 0);
        f.outputAdapter = new ERC4626ReserveAdapter(address(f.account), f.outputVault, 0, 0);

        f.account.configureRouter(f.router);
        f.account.configureReserve(address(f.input), f.inputAdapter, inputGasLimit);
        f.account.configureReserve(address(f.output), f.outputAdapter, 500_000);

        f.input.mint(address(f.account), 1000);
        f.output.mint(address(f.account), 1000);
        f.account.prepareInventory(address(f.input));
        f.account.prepareInventory(address(f.output));
        (, f.orderHash) = f.account.sealAndShip(hex"0192", 1000, 1000);
    }

    function _armPostInput(Fixture memory f, uint256 amountIn) private {
        f.router
            .forwardPreTransferOut(
                f.account, address(f.account), taker, address(f.input), address(f.output), amountIn, 10, f.orderHash
            );
        f.router
            .forwardPreTransferIn(
                f.account, address(f.account), taker, address(f.input), address(f.output), amountIn, 10, f.orderHash
            );
        f.input.mint(address(f.account), amountIn);
    }

    function _postInput(Fixture memory f, uint256 amountIn) private {
        f.router
            .forwardPostTransferIn(
                f.account, address(f.account), taker, address(f.input), address(f.output), amountIn, 10, f.orderHash
            );
    }

    function _assertLowGasSkipCompletes(Fixture memory f, uint256 hookGas) private {
        _armPostInput(f, 100);

        vm.expectEmit(true, false, false, true, address(f.account));
        emit ReinvestFailed(address(f.input), ReservoirMakerAccount.FailureReason.LowGas);
        bool success = f.router
            .forwardPostTransferInWithGas(
                f.account, address(f.account), taker, address(f.input), address(f.output), 100, 10, f.orderHash, hookGas
            );

        assertTrue(success);
        assertEq(f.account.settlementPhase(f.orderHash), 0);
        assertEq(f.input.balanceOf(address(f.account)), 100);
    }
}
