// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Vm } from "forge-std/Vm.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { Opcode } from "@1inch/swap-vm/src/libs/OpcodeList.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";

import { ReserveClamp } from "../../../src/instructions/ReserveClamp.sol";
import { ReservoirProgramLib } from "../../../src/opcodes/ReservoirOpcodes.sol";
import { ReserveClampTestBase } from "./ReserveClampTestBase.sol";

contract ReserveClampTest is ReserveClampTestBase {
    bytes32 private constant RESERVE_CLAMPED_TOPIC =
        keccak256("ReserveClamped(bytes32,address,uint256,uint256,uint256,uint256,uint256)");

    function test_ProgramBuilderUsesCanonicalZeroArgumentTail() public pure {
        assertEq(ReservoirProgramLib.build(), abi.encodePacked(Opcode._92, uint8(0), Opcode.XYCSwap, uint8(0)));

        bytes memory prefix = abi.encodePacked(Opcode.Salt, uint8(2), bytes2(0xbeef));
        assertEq(
            ReservoirProgramLib.build(prefix),
            bytes.concat(prefix, abi.encodePacked(Opcode._92, uint8(0), Opcode.XYCSwap, uint8(0)))
        );
    }

    function test_RawOpcodeIsFrozenAt92() public view {
        assertEq(router.RESERVE_CLAMP_OPCODE(), 0x92);
    }

    function test_ExactInNonBindingRetainsRequestedInput() public {
        uint256 requestedInput = 100e18;
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT);

        (uint256 actualInput, uint256 actualOutput,) = _quote(order, requestedInput, true);
        uint256 expectedOutput = requestedInput * DEFAULT_BALANCE_OUT / (DEFAULT_BALANCE_IN + requestedInput);

        assertEq(actualInput, requestedInput);
        assertEq(actualOutput, expectedOutput);
    }

    function test_ExactInBindingInverseRecomputesInputAndRestoresContext() public {
        uint256 requestedInput = 1000e18;
        uint256 safeCapacity = 100e18;
        maker.setCapacity(address(tokenB), safeCapacity);
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT);

        (uint256 actualInput, uint256 actualOutput,) = _quote(order, requestedInput, true);
        uint256 expectedInput = Math.ceilDiv(safeCapacity * DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT - safeCapacity);

        assertEq(actualOutput, safeCapacity);
        assertEq(actualInput, expectedInput);
        assertLt(actualInput, requestedInput);
    }

    function test_ExactInBindingMayRetainFullInputOnIntegerPlateau() public {
        maker.setCapacity(address(tokenB), 49);
        (ISwapVM.Order memory order,) = _ship(1, 100);

        (uint256 actualInput, uint256 actualOutput,) = _quote(order, 1, true);

        assertEq(actualOutput, 49);
        assertEq(actualInput, 1);
    }

    function test_ExactOutNonBindingCeilsRequiredInput() public {
        uint256 requestedOutput = 100e18;
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT);

        (uint256 actualInput, uint256 actualOutput,) = _quote(order, requestedOutput, false);
        uint256 expectedInput =
            Math.ceilDiv(requestedOutput * DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT - requestedOutput);

        assertEq(actualOutput, requestedOutput);
        assertEq(actualInput, expectedInput);
    }

    function test_ExactOutBindingPublicQuoteCoversPartialFillValidator() public {
        uint256 requestedOutput = 500e18;
        uint256 safeCapacity = 100e18;
        maker.setCapacity(address(tokenB), safeCapacity);
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT);

        (uint256 actualInput, uint256 actualOutput,) = _quote(order, requestedOutput, false);

        assertEq(actualOutput, safeCapacity);
        assertLt(actualOutput, requestedOutput);
        assertEq(actualInput, Math.ceilDiv(safeCapacity * DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT - safeCapacity));
    }

    function test_ExactOutAtFullVirtualReserveCapsBelowSingularity() public {
        (ISwapVM.Order memory order,) = _ship(1000, 1000);

        (uint256 actualInput, uint256 actualOutput,) = _quote(order, 1000, false);

        assertEq(actualOutput, 999);
        assertEq(actualInput, 999_000);
    }

    function test_ExactOutAboveFullVirtualReserveCapsBelowSingularity() public {
        (ISwapVM.Order memory order,) = _ship(1000, 1000);

        (uint256 actualInput, uint256 actualOutput,) = _quote(order, 10_000, false);

        assertEq(actualOutput, 999);
        assertEq(actualInput, 999_000);
    }

    function test_ZeroCapacityDeterministicallyRejectsZeroOutput() public {
        maker.setCapacity(address(tokenB), 0);
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT);
        ISwapVM routerView = router.asView();

        vm.expectRevert(MakerTraitsLib.MakerTraitsZeroAmountInNotAllowed.selector);
        routerView.quote(order, 100e18, _takerTraits(true));
    }

    function test_ZeroBalanceOutFailsXYCDomainGuard() public {
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, 0);
        ISwapVM routerView = router.asView();

        vm.expectRevert(
            abi.encodeWithSelector(XYCSwap.XYCSwapRequiresBothBalancesNonZero.selector, DEFAULT_BALANCE_IN, 0)
        );
        routerView.quote(order, 100e18, _takerTraits(true));
    }

    function test_OneUnitBalanceOutDeterministicallyRejectsZeroExactInOutput() public {
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, 1);
        ISwapVM routerView = router.asView();

        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector, 0));
        routerView.quote(order, 100e18, _takerTraits(true));
    }

    function test_OneUnitBalanceOutDeterministicallyRejectsExactOut() public {
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, 1);
        ISwapVM routerView = router.asView();

        vm.expectRevert(MakerTraitsLib.MakerTraitsZeroAmountInNotAllowed.selector);
        routerView.quote(order, 1, _takerTraits(false));
    }

    function test_RejectsNonzeroExitCostExactIn() public {
        maker.setExitCost(address(tokenB), 1);
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT);
        ISwapVM routerView = router.asView();

        vm.expectRevert(abi.encodeWithSelector(ReserveClamp.ReserveClampExitCostUnsupported.selector, 1));
        routerView.quote(order, 100e18, _takerTraits(true));
    }

    function test_RejectsNonzeroExitCostExactOut() public {
        maker.setExitCost(address(tokenB), 1e18);
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT);
        ISwapVM routerView = router.asView();

        vm.expectRevert(abi.encodeWithSelector(ReserveClamp.ReserveClampExitCostUnsupported.selector, 1e18));
        routerView.quote(order, 100e18, _takerTraits(false));
    }

    function test_RejectsNonemptyReserveArgs() public {
        bytes memory program = abi.encodePacked(Opcode._92, uint8(1), bytes1(0xff), Opcode.XYCSwap, uint8(0));
        (ISwapVM.Order memory order,) = _shipProgram(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT, program);
        ISwapVM routerView = router.asView();

        vm.expectRevert(ReserveClamp.ReserveClampArgsNotEmpty.selector);
        routerView.quote(order, 100e18, _takerTraits(true));
    }

    function test_RejectsMissingXYCTail() public {
        bytes memory program = abi.encodePacked(Opcode._92, uint8(0));
        (ISwapVM.Order memory order,) = _shipProgram(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT, program);
        ISwapVM routerView = router.asView();

        vm.expectRevert(ReserveClamp.ReserveClampInvalidTail.selector);
        routerView.quote(order, 100e18, _takerTraits(true));
    }

    function test_RejectsAdditionalTailInstruction() public {
        bytes memory program = bytes.concat(ReservoirProgramLib.build(), abi.encodePacked(Opcode.Salt, uint8(0)));
        (ISwapVM.Order memory order,) = _shipProgram(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT, program);
        ISwapVM routerView = router.asView();

        vm.expectRevert(ReserveClamp.ReserveClampInvalidTail.selector);
        routerView.quote(order, 100e18, _takerTraits(true));
    }

    function test_RejectsXYCTailArguments() public {
        bytes memory program = abi.encodePacked(Opcode._92, uint8(0), Opcode.XYCSwap, uint8(1), bytes1(0));
        (ISwapVM.Order memory order,) = _shipProgram(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT, program);
        ISwapVM routerView = router.asView();

        vm.expectRevert(ReserveClamp.ReserveClampInvalidTail.selector);
        routerView.quote(order, 100e18, _takerTraits(true));
    }

    function test_PrefixDelegatesUpstreamDeadlineOpcode() public {
        uint40 deadline = uint40(block.timestamp + 1 hours);
        bytes memory prefix = abi.encodePacked(Opcode.Deadline, uint8(5), deadline);
        (ISwapVM.Order memory order,) =
            _shipProgram(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT, ReservoirProgramLib.build(prefix));

        (uint256 actualInput, uint256 actualOutput,) = _quote(order, 100e18, true);

        assertEq(actualInput, 100e18);
        assertGt(actualOutput, 0);
    }

    function test_StaticBindingQuoteDoesNotAttemptTelemetryLog() public {
        maker.setCapacity(address(tokenB), 100e18);
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT);

        (uint256 actualInput, uint256 actualOutput,) = _quote(order, 1000e18, true);

        assertEq(actualOutput, 100e18);
        assertLt(actualInput, 1000e18);
    }

    function test_BindingSwapEmitsExactClampTelemetry() public {
        uint256 requestedInput = 1000e18;
        uint256 safeCapacity = 100e18;
        maker.setCapacity(address(tokenB), safeCapacity);
        (ISwapVM.Order memory order, bytes32 strategyHash) = _ship(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT);
        _fundSwap(requestedInput, DEFAULT_BALANCE_OUT);

        uint256 candidateOutput = requestedInput * DEFAULT_BALANCE_OUT / (DEFAULT_BALANCE_IN + requestedInput);
        uint256 expectedInput = Math.ceilDiv(safeCapacity * DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT - safeCapacity);

        vm.recordLogs();
        (uint256 actualInput, uint256 actualOutput, bytes32 returnedHash) =
            router.swap(order, requestedInput, _takerTraits(true));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(returnedHash, strategyHash);
        assertEq(actualInput, expectedInput);
        assertEq(actualOutput, safeCapacity);
        _assertClampLog(logs, strategyHash, requestedInput, candidateOutput, safeCapacity, expectedInput);
    }

    function test_NonBindingSwapEmitsNoClampTelemetry() public {
        uint256 requestedInput = 100e18;
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT);
        _fundSwap(requestedInput, DEFAULT_BALANCE_OUT);

        vm.recordLogs();
        router.swap(order, requestedInput, _takerTraits(true));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countClampLogs(logs), 0);
    }

    function test_BindingExactOutSwapEmitsNoClampTelemetry() public {
        uint256 requestedOutput = 500e18;
        maker.setCapacity(address(tokenB), 100e18);
        (ISwapVM.Order memory order,) = _ship(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT);
        _fundSwap(DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT);

        vm.recordLogs();
        (uint256 actualInput, uint256 actualOutput,) = router.swap(order, requestedOutput, _takerTraits(false));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(actualOutput, 100e18);
        assertEq(actualInput, Math.ceilDiv(100e18 * DEFAULT_BALANCE_IN, DEFAULT_BALANCE_OUT - 100e18));
        assertEq(_countClampLogs(logs), 0);
    }

    function _assertClampLog(
        Vm.Log[] memory logs,
        bytes32 strategyHash,
        uint256 requestedInput,
        uint256 candidateOutput,
        uint256 safeCapacity,
        uint256 expectedInput
    )
        private
        view
    {
        assertEq(_countClampLogs(logs), 1);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == RESERVE_CLAMPED_TOPIC) {
                assertEq(logs[i].topics[1], strategyHash);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(tokenB));
                (
                    uint256 loggedRequestedInput,
                    uint256 loggedCandidateOutput,
                    uint256 loggedSafeCapacity,
                    uint256 loggedActualInput,
                    uint256 loggedActualOutput
                ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                assertEq(loggedRequestedInput, requestedInput);
                assertEq(loggedCandidateOutput, candidateOutput);
                assertEq(loggedSafeCapacity, safeCapacity);
                assertEq(loggedActualInput, expectedInput);
                assertEq(loggedActualOutput, safeCapacity);
            }
        }
    }

    function _countClampLogs(Vm.Log[] memory logs) private view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(router) && logs[i].topics.length == 3
                    && logs[i].topics[0] == RESERVE_CLAMPED_TOPIC
            ) {
                ++count;
            }
        }
    }
}
