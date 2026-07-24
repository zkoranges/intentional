// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { Context, ContextLib } from "@1inch/swap-vm/src/libs/VM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { IAquaReserveResolver } from "../../../src/interfaces/IAquaReserveResolver.sol";
import { ReservoirOpcodes, ReservoirProgramLib } from "../../../src/opcodes/ReservoirOpcodes.sol";
import { ReservoirSwapVMRouter } from "../../../src/routers/ReservoirSwapVMRouter.sol";

contract InstructionResolverMaker is IAquaReserveResolver {
    mapping(address asset => uint256 capacity) public capacityOf;
    mapping(address asset => uint256 exitCost) public exitCostOf;

    function setCapacity(address asset, uint256 capacity) external {
        capacityOf[asset] = capacity;
    }

    function setExitCost(address asset, uint256 exitCostWad) external {
        exitCostOf[asset] = exitCostWad;
    }

    function availableFor(
        address asset,
        uint256 wanted
    )
        external
        view
        returns (uint256 canDeliver, uint256 exitCostWad)
    {
        return (Math.min(wanted, capacityOf[asset]), exitCostOf[asset]);
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

    function approveToken(address token, address spender, uint256 amount) external {
        require(IERC20(token).approve(spender, amount));
    }
}

/// @dev Asserts the SPEC §6.4 context transition inside the production dispatch path.
contract ContextCheckingReservoirRouter is ReservoirSwapVMRouter {
    using ContextLib for Context;

    error ReserveClampContextChanged();

    constructor(address aqua) ReservoirSwapVMRouter(aqua, address(0), msg.sender, "ReservoirTest", "1") { }

    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
        if (opcode != ReservoirOpcodes.RESERVE_CLAMP_OPCODE) {
            super._runOpcode(ctx, opcode, args);
            return;
        }

        bool exactInBefore = ctx.query.isExactIn;
        bytes32 stableContextBefore = _stableContextHash(ctx);
        super._runOpcode(ctx, opcode, args);

        if (
            ctx.query.isExactIn != exactInBefore || _stableContextHash(ctx) != stableContextBefore
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

abstract contract ReserveClampTestBase is Test {
    uint256 internal constant DEFAULT_BALANCE_IN = 1000e18;
    uint256 internal constant DEFAULT_BALANCE_OUT = 1000e18;

    Aqua internal aqua;
    ContextCheckingReservoirRouter internal router;
    InstructionResolverMaker internal maker;
    TokenMock internal tokenA;
    TokenMock internal tokenB;

    function setUp() public virtual {
        aqua = new Aqua();
        router = new ContextCheckingReservoirRouter(address(aqua));
        maker = new InstructionResolverMaker();
        tokenA = new TokenMock("Token A", "A");
        tokenB = new TokenMock("Token B", "B");
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        maker.setCapacity(address(tokenA), type(uint256).max);
        maker.setCapacity(address(tokenB), type(uint256).max);
    }

    function _ship(
        uint256 balanceIn,
        uint256 balanceOut
    )
        internal
        returns (ISwapVM.Order memory order, bytes32 strategyHash)
    {
        return _shipProgram(balanceIn, balanceOut, ReservoirProgramLib.build());
    }

    function _shipProgram(
        uint256 balanceIn,
        uint256 balanceOut,
        bytes memory program
    )
        internal
        returns (ISwapVM.Order memory order, bytes32 strategyHash)
    {
        order = _order(program);

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        uint256[] memory balances = new uint256[](2);
        balances[0] = balanceIn;
        balances[1] = balanceOut;

        strategyHash = maker.ship(aqua, address(router), order, tokens, balances);
        assertEq(strategyHash, router.hash(order), "Aqua and router order hashes differ");
    }

    function _order(bytes memory program) internal view returns (ISwapVM.Order memory) {
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

    function _quote(
        ISwapVM.Order memory order,
        uint256 requestedAmount,
        bool isExactIn
    )
        internal
        view
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash)
    {
        return router.asView().quote(order, requestedAmount, _takerTraits(isExactIn));
    }

    function _takerTraits(bool isExactIn) internal view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(this),
                isExactIn: isExactIn,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                isAToB: true,
                threshold: "",
                to: address(0),
                deadline: uint40(block.timestamp + 1 days),
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

    function _fundSwap(uint256 inputAmount, uint256 outputAmount) internal {
        tokenA.mint(address(this), inputAmount);
        tokenA.approve(address(router), type(uint256).max);

        tokenB.mint(address(maker), outputAmount);
        maker.approveToken(address(tokenB), address(aqua), type(uint256).max);
    }
}
