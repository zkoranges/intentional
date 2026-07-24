// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { Opcode } from "@1inch/swap-vm/src/libs/OpcodeList.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { TransientLockUnsafeLib } from "@1inch/solidity-utils/contracts/libraries/TransientLockUnsafe.sol";

import { ReservoirMakerAccount } from "../../src/accounts/ReservoirMakerAccount.sol";
import { ERC4626ReserveAdapter } from "../../src/adapters/ERC4626ReserveAdapter.sol";
import { ReservoirProgramLib } from "../../src/opcodes/ReservoirOpcodes.sol";
import { ReservoirSwapVMRouter } from "../../src/routers/ReservoirSwapVMRouter.sol";
import { GasBurningERC4626 } from "../mocks/GasBurningERC4626.sol";
import { HugeRevertDataERC4626 } from "../mocks/HugeRevertDataERC4626.sol";
import { MaliciousTaker } from "../mocks/MaliciousTaker.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { RevertingERC4626 } from "../mocks/RevertingERC4626.sol";

interface IReservoirRouterView {
    function asView() external view returns (ISwapVM);
}

contract StaticQuoteProbe {
    function quote(
        IReservoirRouterView router,
        ISwapVM.Order calldata order,
        uint256 amount,
        bytes calldata traits
    )
        external
        view
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash)
    {
        return router.asView().quote(order, amount, traits);
    }
}

contract ReservoirAquaIntegrationTest is Test {
    struct HeroResult {
        uint256 navBefore;
        uint256 navAfter;
        uint256 requestedInput;
        uint256 candidateOutput;
        uint256 safeCapacity;
        uint256 actualInput;
        uint256 actualOutput;
        bool reinvestSucceeded;
    }

    event ReserveClamped(
        bytes32 indexed orderHash,
        address indexed tokenOut,
        uint256 requestedInput,
        uint256 candidateOutput,
        uint256 safeCapacity,
        uint256 actualInput,
        uint256 actualOutput
    );

    uint256 private constant STARTING_ASSETS = 1000e18;
    uint256 private constant REQUESTED_INPUT = 1000e18;
    uint256 private constant SAFE_CAPACITY = 100e18;
    uint32 private constant LOCAL_REINVEST_GAS_LIMIT = 1_000_000;

    bytes32 private constant REINVEST_SUCCEEDED_TOPIC = keccak256("ReinvestSucceeded(address,address)");
    bytes32 private constant REINVEST_FAILED_TOPIC = keccak256("ReinvestFailed(address,uint8)");

    Aqua private aqua;
    ReservoirSwapVMRouter private router;
    ReservoirMakerAccount private maker;
    MockERC20 private tokenX;
    MockERC20 private tokenY;
    RevertingERC4626 private vaultX;
    RevertingERC4626 private vaultY;
    ERC4626ReserveAdapter private adapterX;
    ERC4626ReserveAdapter private adapterY;
    ISwapVM.Order private order;
    bytes32 private orderHash;

    function setUp() public {
        aqua = new Aqua();
        router = new ReservoirSwapVMRouter(address(aqua), address(0), address(this), "Reservoir", "1");
        maker = new ReservoirMakerAccount(address(this), aqua);

        tokenX = new MockERC20("Token X", "X", 18);
        tokenY = new MockERC20("Token Y", "Y", 18);
        vaultX = new RevertingERC4626(IERC20(address(tokenX)), "Vault X", "vX");
        vaultY = new RevertingERC4626(IERC20(address(tokenY)), "Vault Y", "vY");
        adapterX = new ERC4626ReserveAdapter(address(maker), IERC4626(address(vaultX)), 0, 0);
        adapterY = new ERC4626ReserveAdapter(address(maker), IERC4626(address(vaultY)), 0, 0);

        maker.configureRouter(ISwapVM(address(router)));
        maker.configureReserve(address(tokenX), adapterX, LOCAL_REINVEST_GAS_LIMIT);
        maker.configureReserve(address(tokenY), adapterY, LOCAL_REINVEST_GAS_LIMIT);

        tokenX.mint(address(maker), STARTING_ASSETS);
        tokenY.mint(address(maker), STARTING_ASSETS);
        maker.prepareInventory(address(tokenX));
        maker.prepareInventory(address(tokenY));

        assertEq(tokenX.balanceOf(address(maker)), 0, "rest: token X must be entirely in shares");
        assertEq(tokenY.balanceOf(address(maker)), 0, "rest: token Y must be entirely in shares");

        (ISwapVM.Order memory shippedOrder, bytes32 shippedHash) =
            maker.sealAndShip(ReservoirProgramLib.build(), maker.navOf(maker.tokenA()), maker.navOf(maker.tokenB()));
        order = shippedOrder;
        orderHash = shippedHash;
    }

    function test_HeroExactInSettlesAndReinvests() public {
        runHeroScenario();
    }

    /// @notice Runs the exact scenario used by both this integration suite and the local demo script.
    function runHeroScenario() public returns (HeroResult memory result) {
        address tokenIn = maker.tokenA();
        address tokenOut = maker.tokenB();
        RevertingERC4626 outputVault = _vault(tokenOut);
        RevertingERC4626 inputVault = _vault(tokenIn);

        uint256 fixedShares = outputVault.balanceOf(address(maker));
        uint256 navBefore = outputVault.convertToAssets(fixedShares);
        (uint256 aquaInBefore, uint256 aquaOutBefore) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);

        _token(tokenOut).mint(address(outputVault), 100e18);
        _token(tokenIn).mint(address(inputVault), 50e18);
        uint256 navAfter = outputVault.convertToAssets(fixedShares);
        (uint256 aquaInAfterYield, uint256 aquaOutAfterYield) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);
        assertEq(outputVault.balanceOf(address(maker)), fixedShares, "earn: share count changed");
        assertGt(navAfter, navBefore, "earn: fixed shares did not gain NAV");
        assertEq(aquaInAfterYield, aquaInBefore, "earn: Aqua input balance changed");
        assertEq(aquaOutAfterYield, aquaOutBefore, "earn: Aqua output balance changed");

        outputVault.setWithdrawLimit(SAFE_CAPACITY);
        uint256 candidateOutput = REQUESTED_INPUT * aquaOutBefore / (aquaInBefore + REQUESTED_INPUT);
        (uint256 safeCapacity,) = maker.availableFor(tokenOut, candidateOutput);
        assertGt(candidateOutput, safeCapacity, "challenge: fixture does not bind");
        assertEq(safeCapacity, SAFE_CAPACITY, "challenge: unexpected capacity");

        bytes memory quoteTraits = _takerTraits(true, true, "");
        (uint256 quotedInput, uint256 quotedOutput,) = router.asView().quote(order, REQUESTED_INPUT, quoteTraits);
        assertEq(quotedOutput, safeCapacity, "adapt: quote did not clamp");
        assertLe(quotedInput, REQUESTED_INPUT, "adapt: quote overcharged input");
        assertLt(quotedInput, REQUESTED_INPUT, "adapt: hero fixture must visibly reduce input");

        MockERC20 input = _token(tokenIn);
        MockERC20 output = _token(tokenOut);
        input.mint(address(this), REQUESTED_INPUT);
        input.approve(address(router), type(uint256).max);

        uint256 takerInputBefore = input.balanceOf(address(this));
        uint256 takerOutputBefore = output.balanceOf(address(this));
        uint256 inputSharesBefore = inputVault.balanceOf(address(maker));
        uint256 outputSharesBefore = outputVault.balanceOf(address(maker));
        uint256 expectedInputShares = inputVault.previewDeposit(quotedInput);
        uint256 expectedOutputShares = outputVault.previewWithdraw(quotedOutput);
        uint256 inputVaultAssetsBefore = inputVault.totalAssets();
        uint256 outputVaultAssetsBefore = outputVault.totalAssets();

        vm.recordLogs();
        vm.expectEmit(true, true, false, true, address(router));
        emit ReserveClamped(
            orderHash, tokenOut, REQUESTED_INPUT, candidateOutput, safeCapacity, quotedInput, quotedOutput
        );
        bytes memory swapTraits = _takerTraits(true, true, abi.encode(quotedOutput));
        (uint256 actualInput, uint256 actualOutput,) = router.swap(order, REQUESTED_INPUT, swapTraits);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(actualInput, quotedInput, "same-state quote/swap input mismatch");
        assertEq(actualOutput, quotedOutput, "same-state quote/swap output mismatch");
        assertEq(takerInputBefore - input.balanceOf(address(this)), actualInput, "taker input delta");
        assertEq(output.balanceOf(address(this)) - takerOutputBefore, actualOutput, "recipient output delta");
        assertEq(
            inputVault.balanceOf(address(maker)) - inputSharesBefore,
            expectedInputShares,
            "settle: input share mint rounding"
        );
        assertEq(
            outputSharesBefore - outputVault.balanceOf(address(maker)),
            expectedOutputShares,
            "settle: output share burn rounding"
        );
        assertEq(inputVault.totalAssets() - inputVaultAssetsBefore, actualInput, "settle: input vault asset delta");
        assertEq(outputVaultAssetsBefore - outputVault.totalAssets(), actualOutput, "settle: output vault asset delta");
        assertEq(input.balanceOf(address(maker)), 0, "settle: successful reinvest left maker input idle");
        assertEq(output.balanceOf(address(maker)), 0, "settle: materialized output was not fully pulled");
        assertEq(input.balanceOf(address(_adapter(tokenIn))), 0, "settle: input adapter dust");
        assertEq(output.balanceOf(address(_adapter(tokenOut))), 0, "settle: output adapter dust");
        assertTrue(_hasEvent(logs, address(maker), REINVEST_SUCCEEDED_TOPIC), "missing ReinvestSucceeded");

        (uint256 aquaInAfter, uint256 aquaOutAfter) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);
        assertEq(aquaInAfter, aquaInBefore + actualInput, "Aqua input delta");
        assertEq(aquaOutAfter, aquaOutBefore - actualOutput, "Aqua output delta");

        result = HeroResult({
            navBefore: navBefore,
            navAfter: navAfter,
            requestedInput: REQUESTED_INPUT,
            candidateOutput: candidateOutput,
            safeCapacity: safeCapacity,
            actualInput: actualInput,
            actualOutput: actualOutput,
            reinvestSucceeded: true
        });
    }

    function test_BrokenReinvestDoesNotRevertSettlement() public {
        assertTrue(runBrokenReinvestScenario());
    }

    /// @notice Repeats settlement with a deliberately broken input vault.
    /// @return survived True only after output settled and input remained safely idle.
    function runBrokenReinvestScenario() public returns (bool survived) {
        address tokenIn = maker.tokenA();
        address tokenOut = maker.tokenB();
        RevertingERC4626 inputVault = _vault(tokenIn);
        RevertingERC4626 outputVault = _vault(tokenOut);
        outputVault.setWithdrawLimit(SAFE_CAPACITY);
        inputVault.setRevertDeposit(true);

        (uint256 quotedInput, uint256 quotedOutput,) =
            router.asView().quote(order, REQUESTED_INPUT, _takerTraits(true, true, ""));
        MockERC20 input = _token(tokenIn);
        MockERC20 output = _token(tokenOut);
        input.mint(address(this), REQUESTED_INPUT);
        input.approve(address(router), type(uint256).max);

        uint256 inputSharesBefore = inputVault.balanceOf(address(maker));
        uint256 takerOutputBefore = output.balanceOf(address(this));
        vm.recordLogs();
        (uint256 actualInput, uint256 actualOutput,) =
            router.swap(order, REQUESTED_INPUT, _takerTraits(true, true, abi.encode(quotedOutput)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(actualInput, quotedInput);
        assertEq(actualOutput, quotedOutput);
        assertEq(output.balanceOf(address(this)) - takerOutputBefore, actualOutput, "survive: output not settled");
        assertEq(inputVault.balanceOf(address(maker)), inputSharesBefore, "survive: broken deposit minted shares");
        assertEq(input.balanceOf(address(maker)), actualInput, "survive: input was not left idle");
        assertEq(input.balanceOf(address(_adapter(tokenIn))), 0, "survive: adapter retained input");
        assertTrue(_hasEvent(logs, address(maker), REINVEST_FAILED_TOPIC), "missing ReinvestFailed");
        return true;
    }

    function test_ConstrainedExactOutUsesBestEffortPartialFill() public {
        address tokenIn = maker.tokenA();
        address tokenOut = maker.tokenB();
        _vault(tokenOut).setWithdrawLimit(SAFE_CAPACITY);
        uint256 requestedOutput = 500e18;

        (uint256 quotedInput, uint256 quotedOutput,) =
            router.asView().quote(order, requestedOutput, _takerTraits(false, true, abi.encode(type(uint256).max)));
        assertEq(quotedOutput, SAFE_CAPACITY);
        assertLt(quotedOutput, requestedOutput);

        MockERC20 input = _token(tokenIn);
        input.mint(address(this), quotedInput);
        input.approve(address(router), type(uint256).max);
        (uint256 actualInput, uint256 actualOutput,) =
            router.swap(order, requestedOutput, _takerTraits(false, true, abi.encode(quotedInput)));
        assertEq(actualInput, quotedInput);
        assertEq(actualOutput, quotedOutput);
    }

    function test_NormalExactOutSettles() public {
        address tokenIn = maker.tokenA();
        address tokenOut = maker.tokenB();
        uint256 requestedOutput = 10e18;
        (uint256 quotedInput, uint256 quotedOutput,) =
            router.asView().quote(order, requestedOutput, _takerTraits(false, true, abi.encode(type(uint256).max)));
        assertEq(quotedOutput, requestedOutput);

        MockERC20 input = _token(tokenIn);
        MockERC20 output = _token(tokenOut);
        input.mint(address(this), quotedInput);
        input.approve(address(router), type(uint256).max);
        uint256 outputBefore = output.balanceOf(address(this));
        (uint256 actualInput, uint256 actualOutput,) =
            router.swap(order, requestedOutput, _takerTraits(false, true, abi.encode(quotedInput)));

        assertEq(actualInput, quotedInput);
        assertEq(actualOutput, requestedOutput);
        assertEq(output.balanceOf(address(this)) - outputBefore, requestedOutput);
    }

    function test_ReverseDirectionResolvesCorrectAdapters() public {
        address tokenIn = maker.tokenB();
        address tokenOut = maker.tokenA();
        _vault(tokenOut).setWithdrawLimit(SAFE_CAPACITY);
        (uint256 quotedInput, uint256 quotedOutput,) =
            router.asView().quote(order, REQUESTED_INPUT, _takerTraits(true, false, ""));

        MockERC20 input = _token(tokenIn);
        MockERC20 output = _token(tokenOut);
        input.mint(address(this), REQUESTED_INPUT);
        input.approve(address(router), type(uint256).max);
        uint256 outputBefore = output.balanceOf(address(this));
        uint256 inputSharesBefore = _vault(tokenIn).balanceOf(address(maker));
        uint256 outputSharesBefore = _vault(tokenOut).balanceOf(address(maker));

        (uint256 actualInput, uint256 actualOutput,) =
            router.swap(order, REQUESTED_INPUT, _takerTraits(true, false, abi.encode(quotedOutput)));

        assertEq(actualInput, quotedInput);
        assertEq(actualOutput, quotedOutput);
        assertEq(output.balanceOf(address(this)) - outputBefore, actualOutput);
        assertGt(_vault(tokenIn).balanceOf(address(maker)), inputSharesBefore, "reverse input adapter");
        assertLt(_vault(tokenOut).balanceOf(address(maker)), outputSharesBefore, "reverse output adapter");
    }

    function test_PreWithdrawFailureIsAtomic() public {
        address tokenIn = maker.tokenA();
        address tokenOut = maker.tokenB();
        RevertingERC4626 outputVault = _vault(tokenOut);
        outputVault.setWithdrawLimit(SAFE_CAPACITY);
        (, uint256 quotedOutput,) = router.asView().quote(order, REQUESTED_INPUT, _takerTraits(true, true, ""));
        outputVault.setRevertWithdraw(true);

        MockERC20 input = _token(tokenIn);
        MockERC20 output = _token(tokenOut);
        input.mint(address(this), REQUESTED_INPUT);
        input.approve(address(router), type(uint256).max);
        uint256 takerInputBefore = input.balanceOf(address(this));
        uint256 takerOutputBefore = output.balanceOf(address(this));
        uint256 makerSharesBefore = outputVault.balanceOf(address(maker));
        (uint256 aquaInBefore, uint256 aquaOutBefore) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);

        vm.expectPartialRevert(RevertingERC4626.ForcedVaultRevert.selector);
        router.swap(order, REQUESTED_INPUT, _takerTraits(true, true, abi.encode(quotedOutput)));

        assertEq(input.balanceOf(address(this)), takerInputBefore);
        assertEq(output.balanceOf(address(this)), takerOutputBefore);
        assertEq(outputVault.balanceOf(address(maker)), makerSharesBefore);
        (uint256 aquaInAfter, uint256 aquaOutAfter) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);
        assertEq(aquaInAfter, aquaInBefore);
        assertEq(aquaOutAfter, aquaOutBefore);
    }

    function test_StaleExactInCapacityIsStoppedByMinOut() public {
        address tokenIn = maker.tokenA();
        address tokenOut = maker.tokenB();
        RevertingERC4626 outputVault = _vault(tokenOut);
        outputVault.setWithdrawLimit(500e18);
        (, uint256 quotedOutput,) = router.asView().quote(order, REQUESTED_INPUT, _takerTraits(true, true, ""));
        outputVault.setWithdrawLimit(SAFE_CAPACITY);

        MockERC20 input = _token(tokenIn);
        input.mint(address(this), REQUESTED_INPUT);
        input.approve(address(router), type(uint256).max);
        uint256 takerInputBefore = input.balanceOf(address(this));
        uint256 takerOutputBefore = _token(tokenOut).balanceOf(address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                TakerTraitsLib.TakerTraitsInsufficientMinOutputAmount.selector, SAFE_CAPACITY, quotedOutput
            )
        );
        router.swap(order, REQUESTED_INPUT, _takerTraits(true, true, abi.encode(quotedOutput)));

        assertEq(input.balanceOf(address(this)), takerInputBefore);
        assertEq(_token(tokenOut).balanceOf(address(this)), takerOutputBefore);
    }

    function test_StaleExactOutMaySettleSmallerFillUnderMaxIn() public {
        address tokenIn = maker.tokenA();
        address tokenOut = maker.tokenB();
        RevertingERC4626 outputVault = _vault(tokenOut);
        uint256 requestedOutput = 500e18;
        outputVault.setWithdrawLimit(requestedOutput);
        (uint256 quotedInput, uint256 quotedOutput,) =
            router.asView().quote(order, requestedOutput, _takerTraits(false, true, abi.encode(type(uint256).max)));
        assertEq(quotedOutput, requestedOutput);

        outputVault.setWithdrawLimit(SAFE_CAPACITY);
        MockERC20 input = _token(tokenIn);
        MockERC20 output = _token(tokenOut);
        input.mint(address(this), quotedInput);
        input.approve(address(router), type(uint256).max);
        uint256 outputBefore = output.balanceOf(address(this));

        (uint256 actualInput, uint256 actualOutput,) =
            router.swap(order, requestedOutput, _takerTraits(false, true, abi.encode(quotedInput)));

        assertEq(actualOutput, SAFE_CAPACITY);
        assertLt(actualOutput, quotedOutput, "stale exact-out did not shrink");
        assertLe(actualInput, quotedInput, "stale exact-out exceeded maxIn");
        assertEq(output.balanceOf(address(this)) - outputBefore, actualOutput);
    }

    function test_InputFirstTraitsRevertBeforeTokenDelta() public {
        address tokenIn = maker.tokenA();
        address tokenOut = maker.tokenB();
        uint256 requestedInput = 10e18;
        (, uint256 quotedOutput,) = router.asView().quote(order, requestedInput, _takerTraits(true, true, ""));

        MockERC20 input = _token(tokenIn);
        MockERC20 output = _token(tokenOut);
        input.mint(address(this), requestedInput);
        input.approve(address(router), type(uint256).max);
        uint256 takerInputBefore = input.balanceOf(address(this));
        uint256 takerOutputBefore = output.balanceOf(address(this));
        (uint256 aquaInBefore, uint256 aquaOutBefore) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);

        vm.expectPartialRevert(ReservoirMakerAccount.InvalidSettlementPhase.selector);
        router.swap(order, requestedInput, _takerTraitsAdvanced(true, true, true, abi.encode(quotedOutput)));

        assertEq(input.balanceOf(address(this)), takerInputBefore);
        assertEq(output.balanceOf(address(this)), takerOutputBefore);
        (uint256 aquaInAfter, uint256 aquaOutAfter) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);
        assertEq(aquaInAfter, aquaInBefore);
        assertEq(aquaOutAfter, aquaOutBefore);
    }

    function test_TwoSequentialSwapsRetainAllowances() public {
        address tokenIn = maker.tokenA();
        address tokenOut = maker.tokenB();
        MockERC20 input = _token(tokenIn);
        input.mint(address(this), 20e18);
        input.approve(address(router), type(uint256).max);

        for (uint256 i = 0; i < 2; ++i) {
            (, uint256 quotedOutput,) = router.asView().quote(order, 10e18, _takerTraits(true, true, ""));
            router.swap(order, 10e18, _takerTraits(true, true, abi.encode(quotedOutput)));
        }

        assertEq(input.allowance(address(maker), address(aqua)), type(uint256).max, "Aqua allowance decayed");
        assertEq(
            input.allowance(address(maker), address(_adapter(tokenIn))),
            type(uint256).max,
            "input adapter allowance decayed"
        );
        assertEq(
            IERC20(address(_vault(tokenOut))).allowance(address(maker), address(_adapter(tokenOut))),
            type(uint256).max,
            "share allowance decayed"
        );
        assertEq(input.balanceOf(address(maker)), 0, "second reinvest left input idle");
    }

    function test_CallbackSameOrderNestedSwapCaughtAtPreTransferOut() public {
        _assertCaughtSameOrderNestedSwap(MaliciousTaker.AttackPoint.PreTransferOut);
    }

    function test_CallbackSameOrderNestedSwapCaughtAtPreTransferIn() public {
        _assertCaughtSameOrderNestedSwap(MaliciousTaker.AttackPoint.PreTransferIn);
    }

    function test_CallbackSameOrderNestedSwapPropagatedIsAtomic() public {
        address tokenIn = maker.tokenA();
        address tokenOut = maker.tokenB();
        MaliciousTaker attacker = new MaliciousTaker();
        uint256 requestedInput = 10e18;
        bytes memory traits = _takerTraitsFor(
            address(attacker),
            true,
            true,
            false,
            false,
            true,
            abi.encode(_quoteOutputFor(address(attacker), requestedInput))
        );
        bytes memory swapCall = abi.encodeCall(ISwapVM.swap, (order, requestedInput, traits));
        attacker.configureAttack(address(router), swapCall, MaliciousTaker.AttackPoint.PreTransferOut, true);

        MockERC20 input = _token(tokenIn);
        MockERC20 output = _token(tokenOut);
        input.mint(address(attacker), requestedInput);
        attacker.approveToken(input, address(router), type(uint256).max);

        uint256 takerInputBefore = input.balanceOf(address(attacker));
        uint256 takerOutputBefore = output.balanceOf(address(attacker));
        uint256 outputSharesBefore = _vault(tokenOut).balanceOf(address(maker));
        (uint256 aquaInBefore, uint256 aquaOutBefore) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);

        vm.expectRevert(TransientLockUnsafeLib.UnexpectedLock.selector);
        attacker.execute(address(router), swapCall);

        assertEq(input.balanceOf(address(attacker)), takerInputBefore, "propagated callback charged input");
        assertEq(output.balanceOf(address(attacker)), takerOutputBefore, "propagated callback delivered output");
        assertEq(_vault(tokenOut).balanceOf(address(maker)), outputSharesBefore, "materialization was not atomic");
        (uint256 aquaInAfter, uint256 aquaOutAfter) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);
        assertEq(aquaInAfter, aquaInBefore, "propagated callback changed Aqua input");
        assertEq(aquaOutAfter, aquaOutBefore, "propagated callback changed Aqua output");
    }

    function test_CallbackStaticQuoteCannotMaterializeInventory() public {
        address tokenIn = maker.tokenA();
        address tokenOut = maker.tokenB();
        MaliciousTaker attacker = new MaliciousTaker();
        StaticQuoteProbe probe = new StaticQuoteProbe();
        uint256 requestedInput = 10e18;
        bytes memory emptyTraits = _takerTraitsFor(address(attacker), true, true, false, false, false, "");
        bytes memory quoteCall = abi.encodeCall(
            StaticQuoteProbe.quote, (IReservoirRouterView(address(router)), order, requestedInput, emptyTraits)
        );
        uint256 quotedOutput = _quoteOutputFor(address(attacker), requestedInput);
        bytes memory outerTraits =
            _takerTraitsFor(address(attacker), true, true, false, false, true, abi.encode(quotedOutput));
        bytes memory swapCall = abi.encodeCall(ISwapVM.swap, (order, requestedInput, outerTraits));
        attacker.configureAttack(address(probe), quoteCall, MaliciousTaker.AttackPoint.PreTransferOut, true);

        MockERC20 input = _token(tokenIn);
        input.mint(address(attacker), requestedInput);
        attacker.approveToken(input, address(router), type(uint256).max);
        uint256 sharesBefore = _vault(tokenOut).balanceOf(address(maker));

        bytes memory result = attacker.execute(address(router), swapCall);
        (, uint256 actualOutput,) = abi.decode(result, (uint256, uint256, bytes32));

        assertEq(attacker.attempts(), 1, "static quote callback not attempted");
        assertTrue(attacker.lastSuccess(), "static quote callback failed");
        assertEq(
            _vault(tokenOut).balanceOf(address(maker)),
            sharesBefore - actualOutput,
            "callback quote materialized additional output"
        );
    }

    function test_CallbackDifferentOrderCannotReachMakerHooks() public {
        MaliciousTaker attacker = new MaliciousTaker();
        uint256 requestedInput = 10e18;
        bytes memory salt = abi.encodePacked(uint8(Opcode.Salt), uint8(8), uint64(1));
        ISwapVM.Order memory inactiveOrder = maker.buildOrder(ReservoirProgramLib.build(salt));
        bytes memory inactiveTraits = _takerTraitsFor(address(attacker), true, true, false, false, true, "");
        bytes memory inactiveSwap = abi.encodeCall(ISwapVM.swap, (inactiveOrder, requestedInput, inactiveTraits));

        uint256 quotedOutput = _quoteOutputFor(address(attacker), requestedInput);
        bytes memory outerTraits =
            _takerTraitsFor(address(attacker), true, true, false, false, true, abi.encode(quotedOutput));
        bytes memory outerSwap = abi.encodeCall(ISwapVM.swap, (order, requestedInput, outerTraits));
        attacker.configureAttack(address(router), inactiveSwap, MaliciousTaker.AttackPoint.PreTransferOut, false);

        MockERC20 input = _token(maker.tokenA());
        input.mint(address(attacker), requestedInput);
        attacker.approveToken(input, address(router), type(uint256).max);
        bytes memory result = attacker.execute(address(router), outerSwap);
        (uint256 actualInput, uint256 actualOutput,) = abi.decode(result, (uint256, uint256, bytes32));

        assertEq(attacker.attempts(), 1, "different-order callback not attempted");
        assertFalse(attacker.lastSuccess(), "inactive order unexpectedly settled");
        assertGt(actualInput, 0, "outer input missing");
        assertGt(actualOutput, 0, "outer output missing");
        assertEq(maker.settlementPhase(orderHash), 0, "outer settlement phase not cleared");
    }

    function test_GasBurningReinvestCannotConsumeSettlementReserve() public {
        MockERC20 input = new MockERC20("Gas Input", "GIN", 18);
        GasBurningERC4626 inputVault = new GasBurningERC4626(input, "Gas Vault", "vGIN");
        _assertBombedReinvestSettlement(input, inputVault, abi.encodeCall(GasBurningERC4626.setBurnOnDeposit, (true)));
    }

    function test_HugeRevertDataCannotConsumeSettlementReserve() public {
        MockERC20 input = new MockERC20("Revert Input", "RIN", 18);
        HugeRevertDataERC4626 inputVault = new HugeRevertDataERC4626(input, "Revert Vault", "vRIN");
        _assertBombedReinvestSettlement(
            input, inputVault, abi.encodeCall(HugeRevertDataERC4626.setHugeRevertOnDeposit, (true))
        );
    }

    function _takerTraits(bool exactIn, bool aToB, bytes memory threshold) private view returns (bytes memory) {
        return _takerTraitsAdvanced(exactIn, aToB, false, threshold);
    }

    function _takerTraitsAdvanced(
        bool exactIn,
        bool aToB,
        bool firstTransferFromTaker,
        bytes memory threshold
    )
        private
        view
        returns (bytes memory)
    {
        return _takerTraitsFor(address(this), exactIn, aToB, firstTransferFromTaker, false, false, threshold);
    }

    function _takerTraitsFor(
        address taker,
        bool exactIn,
        bool aToB,
        bool firstTransferFromTaker,
        bool preTransferInCallback,
        bool preTransferOutCallback,
        bytes memory threshold
    )
        private
        view
        returns (bytes memory)
    {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: taker,
                isExactIn: exactIn,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: firstTransferFromTaker,
                useTransferFromAndAquaPush: true,
                isAToB: aToB,
                threshold: threshold,
                to: address(0),
                deadline: uint40(block.timestamp + 1 hours),
                hasPreTransferInCallback: preTransferInCallback,
                hasPreTransferOutCallback: preTransferOutCallback,
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

    function _assertCaughtSameOrderNestedSwap(MaliciousTaker.AttackPoint point) private {
        address tokenIn = maker.tokenA();
        address tokenOut = maker.tokenB();
        MaliciousTaker attacker = new MaliciousTaker();
        uint256 requestedInput = 10e18;
        bool atPreIn = point == MaliciousTaker.AttackPoint.PreTransferIn;
        bool atPreOut = point == MaliciousTaker.AttackPoint.PreTransferOut;
        uint256 quotedOutput = _quoteOutputFor(address(attacker), requestedInput);
        bytes memory traits =
            _takerTraitsFor(address(attacker), true, true, false, atPreIn, atPreOut, abi.encode(quotedOutput));
        bytes memory swapCall = abi.encodeCall(ISwapVM.swap, (order, requestedInput, traits));
        attacker.configureAttack(address(router), swapCall, point, false);

        MockERC20 input = _token(tokenIn);
        MockERC20 output = _token(tokenOut);
        input.mint(address(attacker), requestedInput);
        attacker.approveToken(input, address(router), type(uint256).max);
        uint256 outputBefore = output.balanceOf(address(attacker));

        bytes memory result = attacker.execute(address(router), swapCall);
        (uint256 actualInput, uint256 actualOutput,) = abi.decode(result, (uint256, uint256, bytes32));

        assertEq(attacker.attempts(), 1, "same-order callback not attempted");
        assertFalse(attacker.lastSuccess(), "same-order lock did not reject nested swap");
        assertEq(input.balanceOf(address(attacker)), requestedInput - actualInput, "outer callback input delta");
        assertEq(output.balanceOf(address(attacker)) - outputBefore, actualOutput, "outer callback output delta");
        assertEq(maker.settlementPhase(orderHash), 0, "outer callback phase not cleared");
    }

    function _quoteOutputFor(address taker, uint256 requestedInput) private view returns (uint256 output) {
        (, output,) =
            router.asView().quote(order, requestedInput, _takerTraitsFor(taker, true, true, false, false, false, ""));
    }

    function _assertBombedReinvestSettlement(MockERC20 input, IERC4626 inputVault, bytes memory enableBomb) private {
        Aqua localAqua = new Aqua();
        ReservoirSwapVMRouter localRouter =
            new ReservoirSwapVMRouter(address(localAqua), address(0), address(this), "Reservoir", "1");
        ReservoirMakerAccount localMaker = new ReservoirMakerAccount(address(this), localAqua);
        MockERC20 output = new MockERC20("Output", "OUT", 18);
        MockERC4626 outputVault = new MockERC4626(output, "Output Vault", "vOUT");
        ERC4626ReserveAdapter inputAdapter = new ERC4626ReserveAdapter(address(localMaker), inputVault, 0, 0);
        ERC4626ReserveAdapter outputAdapter = new ERC4626ReserveAdapter(address(localMaker), outputVault, 0, 0);

        localMaker.configureRouter(ISwapVM(address(localRouter)));
        localMaker.configureReserve(address(input), inputAdapter, LOCAL_REINVEST_GAS_LIMIT);
        localMaker.configureReserve(address(output), outputAdapter, LOCAL_REINVEST_GAS_LIMIT);
        input.mint(address(localMaker), STARTING_ASSETS);
        output.mint(address(localMaker), STARTING_ASSETS);
        localMaker.prepareInventory(address(input));
        localMaker.prepareInventory(address(output));
        (ISwapVM.Order memory localOrder, bytes32 localOrderHash) = localMaker.sealAndShip(
            ReservoirProgramLib.build(), localMaker.navOf(localMaker.tokenA()), localMaker.navOf(localMaker.tokenB())
        );

        (bool enabled,) = address(inputVault).call(enableBomb);
        assertTrue(enabled, "bomb fixture did not arm");
        bool aToB = localMaker.tokenA() == address(input);
        uint256 requestedInput = 10e18;
        bytes memory quoteTraits = _takerTraitsFor(address(this), true, aToB, false, false, false, "");
        (uint256 quotedInput, uint256 quotedOutput,) =
            localRouter.asView().quote(localOrder, requestedInput, quoteTraits);
        input.mint(address(this), requestedInput);
        input.approve(address(localRouter), type(uint256).max);
        uint256 recipientOutputBefore = output.balanceOf(address(this));

        vm.recordLogs();
        (uint256 actualInput, uint256 actualOutput,) = localRouter.swap(
            localOrder,
            requestedInput,
            _takerTraitsFor(address(this), true, aToB, false, false, false, abi.encode(quotedOutput))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(actualInput, quotedInput, "bombed reinvest input mismatch");
        assertEq(actualOutput, quotedOutput, "bombed reinvest output mismatch");
        assertEq(output.balanceOf(address(this)) - recipientOutputBefore, actualOutput, "bombed output did not settle");
        assertEq(input.balanceOf(address(localMaker)), actualInput, "failed reinvest did not leave input idle");
        assertEq(input.balanceOf(address(inputAdapter)), 0, "failed reinvest left adapter dust");
        assertTrue(_hasEvent(logs, address(localMaker), REINVEST_FAILED_TOPIC), "missing bomb ReinvestFailed");
        assertFalse(_hasEvent(logs, address(localMaker), REINVEST_SUCCEEDED_TOPIC), "bomb emitted success");
        assertEq(localMaker.settlementPhase(localOrderHash), 0, "bombed post-hook did not clear phase");
    }

    function _vault(address asset) private view returns (RevertingERC4626) {
        if (asset == address(tokenX)) {
            return vaultX;
        }
        if (asset == address(tokenY)) {
            return vaultY;
        }
        revert("unknown asset");
    }

    function _adapter(address asset) private view returns (ERC4626ReserveAdapter) {
        if (asset == address(tokenX)) {
            return adapterX;
        }
        if (asset == address(tokenY)) {
            return adapterY;
        }
        revert("unknown asset");
    }

    function _token(address asset) private view returns (MockERC20) {
        if (asset == address(tokenX)) {
            return tokenX;
        }
        if (asset == address(tokenY)) {
            return tokenY;
        }
        revert("unknown asset");
    }

    function _hasEvent(Vm.Log[] memory logs, address emitter, bytes32 topic) private pure returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                return true;
            }
        }
        return false;
    }
}
