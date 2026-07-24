// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context, ContextLib } from "@1inch/swap-vm/src/libs/VM.sol";
import { Opcode } from "@1inch/swap-vm/src/libs/OpcodeList.sol";

import { IAquaReserveResolver } from "../interfaces/IAquaReserveResolver.sol";

/// @notice Clamps SwapVM output to the maker reserve's currently deliverable inventory.
/// @dev The instruction is a wrapper and requires the remaining program to be exactly one
///      argument-free XYCSwap. Binding exact-in evaluation reruns that tail as exact-out
///      to obtain the least input required for the clamped output.
abstract contract ReserveClamp {
    using ContextLib for Context;

    error ReserveClampArgsNotEmpty();
    error ReserveClampExitCostUnsupported(uint256 exitCostWad);
    error ReserveClampInvalidTail();

    event ReserveClamped(
        bytes32 indexed orderHash,
        address indexed tokenOut,
        uint256 requestedInput,
        uint256 candidateOutput,
        uint256 safeCapacity,
        uint256 actualInput,
        uint256 actualOutput
    );

    function _reserveClampXD(Context memory ctx, bytes calldata args) internal {
        if (args.length != 0) {
            revert ReserveClampArgsNotEmpty();
        }

        uint256 tailPC = ctx.vm.nextPC;
        _requireSingleXYCTail(ctx, tailPC);

        uint256 curveMaxOut = ctx.swap.balanceOut == 0 ? 0 : ctx.swap.balanceOut - 1;
        if (ctx.query.isExactIn) {
            _reserveClampExactIn(ctx, tailPC, curveMaxOut);
        } else {
            _reserveClampExactOut(ctx, curveMaxOut);
        }
    }

    function _reserveClampExactIn(Context memory ctx, uint256 tailPC, uint256 curveMaxOut) private {
        uint256 requestedInput = ctx.swap.amountIn;
        ctx.runLoop();
        uint256 candidateOutput = ctx.swap.amountOut;

        (uint256 safeCapacity, uint256 exitCostWad) =
            IAquaReserveResolver(ctx.query.maker).availableFor(ctx.query.tokenOut, candidateOutput);
        _requireZeroExitCost(exitCostWad);

        if (safeCapacity < candidateOutput) {
            ctx.setNextPC(tailPC);
            ctx.query.isExactIn = false;
            ctx.swap.amountOut = Math.min(safeCapacity, curveMaxOut);
            ctx.swap.amountIn = 0;
            ctx.runLoop();
            ctx.query.isExactIn = true;

            if (!ctx.vm.isStaticContext) {
                emit ReserveClamped(
                    ctx.query.orderHash,
                    ctx.query.tokenOut,
                    requestedInput,
                    candidateOutput,
                    safeCapacity,
                    ctx.swap.amountIn,
                    ctx.swap.amountOut
                );
            }
        } else {
            ctx.swap.amountIn = requestedInput;
        }
    }

    function _reserveClampExactOut(Context memory ctx, uint256 curveMaxOut) private {
        uint256 requestedOutput = ctx.swap.amountOut;
        (uint256 safeCapacity, uint256 exitCostWad) =
            IAquaReserveResolver(ctx.query.maker).availableFor(ctx.query.tokenOut, requestedOutput);
        _requireZeroExitCost(exitCostWad);

        ctx.swap.amountOut = Math.min(Math.min(requestedOutput, safeCapacity), curveMaxOut);
        ctx.runLoop();
    }

    function _requireSingleXYCTail(Context memory ctx, uint256 tailPC) private pure {
        bytes calldata program = ctx.program();
        if (
            tailPC > program.length || program.length - tailPC != 2 || uint8(program[tailPC]) != uint8(Opcode.XYCSwap)
                || uint8(program[tailPC + 1]) != 0
        ) {
            revert ReserveClampInvalidTail();
        }
    }

    function _requireZeroExitCost(uint256 exitCostWad) private pure {
        if (exitCostWad != 0) {
            revert ReserveClampExitCostUnsupported(exitCostWad);
        }
    }
}
