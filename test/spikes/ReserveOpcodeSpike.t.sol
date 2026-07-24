// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import { Context, ContextLib } from "@1inch/swap-vm/src/libs/VM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { Opcode } from "@1inch/swap-vm/src/libs/OpcodeList.sol";

import { IAquaReserveResolver } from "../../src/interfaces/IAquaReserveResolver.sol";

contract ReserveOpcodeSpikeRouter is AquaSwapVMRouter {
    using ContextLib for Context;

    uint256 private constant RESERVE_CLAMP_OPCODE = 0x92;

    error ReserveClampArgsNotEmpty();
    error ReserveClampExitCostUnsupported(uint256 exitCostWad);
    error ReserveClampContextChanged();

    constructor(address aqua) AquaSwapVMRouter(aqua, address(0), msg.sender, "ReservoirSpike", "1") { }

    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
        if (opcode == RESERVE_CLAMP_OPCODE) {
            _reserveClamp(ctx, args);
        } else {
            super._runOpcode(ctx, opcode, args);
        }
    }

    function _reserveClamp(Context memory ctx, bytes calldata args) private {
        if (args.length != 0) {
            revert ReserveClampArgsNotEmpty();
        }

        bool exactInBefore = ctx.query.isExactIn;
        bytes32 contextBefore = _stableContextHash(ctx);

        uint256 tailPC = ctx.vm.nextPC;
        uint256 curveMaxOut = ctx.swap.balanceOut == 0 ? 0 : ctx.swap.balanceOut - 1;

        if (exactInBefore) {
            uint256 requestedInput = ctx.swap.amountIn;
            ctx.runLoop();
            uint256 candidateOutput = ctx.swap.amountOut;
            (uint256 availableOutput, uint256 exitCostWad) =
                IAquaReserveResolver(ctx.query.maker).availableFor(ctx.query.tokenOut, candidateOutput);
            if (exitCostWad != 0) {
                revert ReserveClampExitCostUnsupported(exitCostWad);
            }

            if (availableOutput < candidateOutput) {
                ctx.setNextPC(tailPC);
                ctx.query.isExactIn = false;
                ctx.swap.amountOut = Math.min(availableOutput, curveMaxOut);
                ctx.swap.amountIn = 0;
                ctx.runLoop();
                ctx.query.isExactIn = exactInBefore;
            } else {
                ctx.swap.amountIn = requestedInput;
            }
        } else {
            (uint256 availableOutput, uint256 exitCostWad) =
                IAquaReserveResolver(ctx.query.maker).availableFor(ctx.query.tokenOut, ctx.swap.amountOut);
            if (exitCostWad != 0) {
                revert ReserveClampExitCostUnsupported(exitCostWad);
            }
            ctx.swap.amountOut = Math.min(Math.min(ctx.swap.amountOut, availableOutput), curveMaxOut);
            ctx.runLoop();
        }

        if (
            ctx.query.isExactIn != exactInBefore || _stableContextHash(ctx) != contextBefore
                || ctx.vm.nextPC != ctx.program().length
        ) {
            revert ReserveClampContextChanged();
        }
    }

    function _stableContextHash(Context memory ctx) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ctx.vm.isStaticContext,
                keccak256(ctx.program()),
                keccak256(ctx.takerArgs()),
                ctx.query.orderHash,
                ctx.query.maker,
                ctx.query.taker,
                ctx.query.tokenIn,
                ctx.query.tokenOut,
                ctx.swap.balanceIn,
                ctx.swap.balanceOut,
                ctx.swap.amountNetPulled
            )
        );
    }
}

contract SpikeResolverMaker is IAquaReserveResolver {
    mapping(address asset => uint256 capacity) public capacityOf;

    function setCapacity(address asset, uint256 capacity) external {
        capacityOf[asset] = capacity;
    }

    function availableFor(
        address asset,
        uint256 wanted
    )
        external
        view
        returns (uint256 canDeliver, uint256 exitCostWad)
    {
        return (Math.min(wanted, capacityOf[asset]), 0);
    }

    function ship(
        IAqua aqua,
        address app,
        ISwapVM.Order calldata order,
        address[] calldata tokens,
        uint256[] calldata balances
    )
        external
        returns (bytes32 strategyHash)
    {
        return aqua.ship(app, abi.encode(order), tokens, balances);
    }
}

contract ReserveOpcodeSpikeTest is Test {
    using Math for uint256;

    uint256 private constant BALANCE_IN = 1000e18;
    uint256 private constant BALANCE_OUT = 1000e18;
    uint256 private constant REQUESTED_INPUT = 1000e18;
    uint256 private constant SAFE_CAPACITY = 100e18;

    Aqua private aqua;
    ReserveOpcodeSpikeRouter private router;
    SpikeResolverMaker private maker;
    TokenMock private tokenA;
    TokenMock private tokenB;

    function setUp() public {
        aqua = new Aqua();
        router = new ReserveOpcodeSpikeRouter(address(aqua));
        maker = new SpikeResolverMaker();
        tokenA = new TokenMock("Token A", "A");
        tokenB = new TokenMock("Token B", "B");
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        maker.setCapacity(address(tokenB), SAFE_CAPACITY);
    }

    function test_ReserveOpcodeSpike() public {
        ISwapVM.Order memory order = _order();
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory balances = new uint256[](2);
        balances[0] = BALANCE_IN;
        balances[1] = BALANCE_OUT;

        bytes32 shippedHash = maker.ship(aqua, address(router), order, tokens, balances);
        assertEq(shippedHash, router.hash(order), "Aqua and router hashes differ");

        uint256 candidateOutput = REQUESTED_INPUT * BALANCE_OUT / (BALANCE_IN + REQUESTED_INPUT);
        bytes memory takerTraits = _takerTraits();
        (uint256 actualInput, uint256 actualOutput, bytes32 quotedHash) =
            router.asView().quote(order, REQUESTED_INPUT, takerTraits);

        uint256 expectedInput = Math.ceilDiv(SAFE_CAPACITY * BALANCE_IN, BALANCE_OUT - SAFE_CAPACITY);
        assertEq(candidateOutput, 500e18, "fixture must bind");
        assertEq(actualOutput, SAFE_CAPACITY, "output must saturate at capacity");
        assertEq(actualInput, expectedInput, "second XYC pass must inverse-recompute input");
        assertLt(actualInput, REQUESTED_INPUT, "partial-fill validation requires a smaller actual input");
        assertEq(quotedHash, shippedHash, "quote must use the shipped order");
    }

    function _order() private view returns (ISwapVM.Order memory) {
        bytes memory program =
            abi.encodePacked(bytes1(uint8(0x92)), bytes1(uint8(0)), bytes1(uint8(Opcode.XYCSwap)), bytes1(uint8(0)));
        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: address(maker),
                receiver: address(0),
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: true,
                allowZeroAmountIn: false,
                hasPreTransferInHook: false,
                hasPostTransferInHook: false,
                hasPreTransferOutHook: false,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(0),
                postTransferInData: "",
                preTransferOutTarget: address(0),
                preTransferOutData: "",
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: program
            })
        );
    }

    function _takerTraits() private view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(this),
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                isAToB: true,
                threshold: "",
                to: address(0),
                deadline: 0,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
    }
}
