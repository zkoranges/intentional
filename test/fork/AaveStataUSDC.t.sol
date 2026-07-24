// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { ReservoirMakerAccount } from "../../src/accounts/ReservoirMakerAccount.sol";
import { ERC4626ReserveAdapter } from "../../src/adapters/ERC4626ReserveAdapter.sol";
import { ReservoirProgramLib } from "../../src/opcodes/ReservoirOpcodes.sol";
import { ReservoirSwapVMRouter } from "../../src/routers/ReservoirSwapVMRouter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";

interface IStataTokenV2Integration {
    function aToken() external view returns (address);
}

interface IAaveATokenIntegration {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

    function POOL() external view returns (address);
}

/// @notice Gate 2: real StataTokenV2 USDC custody and settlement on a pinned mainnet fork.
contract AaveStataUSDCForkTest is Test {
    using SafeERC20 for IERC20;

    uint256 private constant PINNED_BLOCK = 25_604_561;
    bytes32 private constant PINNED_BLOCK_HASH = 0x95ca77908413d71bd01cada1ece52b6c2f35467dbbb8f2367144cd0ffbe7888d;

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant STATA_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address private constant A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address private constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    uint256 private constant ONE_USDC = 1_000_000;
    uint256 private constant STARTING_ASSETS = 10_000 * ONE_USDC;
    uint256 private constant REQUESTED_INPUT = 100 * ONE_USDC;
    uint256 private constant CALIBRATION_DEPOSIT = 1000 * ONE_USDC;

    // Sealed only for USDC after the calibration test below. The mock reserve
    // keeps its independently exercised local-test limit.
    uint32 private constant AAVE_REINVEST_GAS_LIMIT = 500_000;
    uint32 private constant MOCK_REINVEST_GAS_LIMIT = 1_000_000;
    string private constant ARCHIVE_FAILURE = "archive RPC required for block 25,604,561";

    bytes32 private constant RESERVE_CLAMPED_TOPIC =
        keccak256("ReserveClamped(bytes32,address,uint256,uint256,uint256,uint256,uint256)");
    bytes32 private constant REINVEST_SUCCEEDED_TOPIC = keccak256("ReinvestSucceeded(address,address)");
    bytes32 private constant REINVEST_FAILED_TOPIC = keccak256("ReinvestFailed(address,uint8)");
    bytes32 private constant ASSETS_REINVESTED_TOPIC = keccak256("AssetsReinvested(address,uint256,uint256)");
    bytes32 private constant DEPOSIT_TOPIC = keccak256("Deposit(address,address,uint256,uint256)");
    bytes32 private constant WITHDRAW_TOPIC = keccak256("Withdraw(address,address,address,uint256,uint256)");

    IERC20 private constant UNDERLYING = IERC20(USDC);
    IERC4626 private constant STATA = IERC4626(STATA_USDC);

    Aqua private aqua;
    ReservoirSwapVMRouter private router;
    ReservoirMakerAccount private maker;
    ERC4626ReserveAdapter private aaveAdapter;
    MockERC20 private mockAsset;
    MockERC4626 private mockVault;
    ERC4626ReserveAdapter private mockAdapter;
    ISwapVM.Order private order;
    bytes32 private orderHash;

    function setUp() public {
        _pinAndValidateFork();

        aqua = new Aqua();
        router = new ReservoirSwapVMRouter(address(aqua), address(0), address(this), "Reservoir", "1");
        maker = new ReservoirMakerAccount(address(this), aqua);
        mockAsset = new MockERC20("Fork Mock USD", "fmUSD", 6);
        mockVault = new MockERC4626(IERC20(address(mockAsset)), "Fork Mock Vault", "vfmUSD");

        aaveAdapter = new ERC4626ReserveAdapter(address(maker), STATA, 0, 0);
        mockAdapter = new ERC4626ReserveAdapter(address(maker), IERC4626(address(mockVault)), 0, 0);

        maker.configureRouter(ISwapVM(address(router)));
        maker.configureReserve(USDC, aaveAdapter, AAVE_REINVEST_GAS_LIMIT);
        maker.configureReserve(address(mockAsset), mockAdapter, MOCK_REINVEST_GAS_LIMIT);

        deal(USDC, address(maker), STARTING_ASSETS);
        mockAsset.mint(address(maker), STARTING_ASSETS);
        maker.prepareInventory(USDC);
        maker.prepareInventory(address(mockAsset));

        assertEq(UNDERLYING.balanceOf(address(maker)), 0, "Aave inventory must start entirely in shares");
        assertEq(mockAsset.balanceOf(address(maker)), 0, "mock inventory must start entirely in shares");
        assertGt(STATA.balanceOf(address(maker)), 0, "maker received no Stata shares");
        assertGt(mockVault.balanceOf(address(maker)), 0, "maker received no mock shares");

        uint256 balanceA = maker.navOf(maker.tokenA());
        uint256 balanceB = maker.navOf(maker.tokenB());
        (ISwapVM.Order memory shippedOrder, bytes32 shippedHash) =
            maker.sealAndShip(ReservoirProgramLib.build(), balanceA, balanceB);
        order = shippedOrder;
        orderHash = shippedHash;
    }

    function test_AaveStataUSDCNonBindingSwapAndTimestampYield() public {
        address tokenIn = address(mockAsset);
        address tokenOut = USDC;
        bool aToB = _isAToB(tokenIn, tokenOut);

        uint256 postShipSnapshot = vm.snapshotState();
        uint256 fixedShares = STATA.balanceOf(address(maker));
        uint256 navBefore = STATA.convertToAssets(fixedShares);
        (uint256 aquaInBeforeYield, uint256 aquaOutBeforeYield) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);

        vm.warp(block.timestamp + 30 days);

        uint256 navAfter = STATA.convertToAssets(fixedShares);
        (uint256 aquaInAfterYield, uint256 aquaOutAfterYield) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);
        assertEq(STATA.balanceOf(address(maker)), fixedShares, "yield warp changed maker shares");
        assertGt(navAfter, navBefore, "yield warp did not increase fixed-share NAV");
        assertEq(aquaInAfterYield, aquaInBeforeYield, "yield warp changed Aqua input balance");
        assertEq(aquaOutAfterYield, aquaOutBeforeYield, "yield warp changed Aqua output balance");

        assertTrue(vm.revertToStateAndDelete(postShipSnapshot), "could not restore post-ship snapshot");

        (uint256 aquaInBefore, uint256 aquaOutBefore) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);
        uint256 candidateOutput = REQUESTED_INPUT * aquaOutBefore / (aquaInBefore + REQUESTED_INPUT);
        (uint256 safeCapacity, uint256 exitCostWad) = maker.availableFor(tokenOut, candidateOutput);
        assertEq(exitCostWad, 0, "v1 Aave exit cost must be zero");
        assertEq(safeCapacity, candidateOutput, "Aave path unexpectedly binds at demo size");
        assertGe(STATA.maxWithdraw(address(maker)), safeCapacity, "Stata cannot cover quoted output");

        bytes memory quoteTraits = _takerTraits(true, aToB, "");
        (uint256 quotedInput, uint256 quotedOutput, bytes32 quotedHash) =
            router.asView().quote(order, REQUESTED_INPUT, quoteTraits);
        assertEq(quotedHash, orderHash, "quote returned wrong order hash");
        assertEq(quotedInput, REQUESTED_INPUT, "non-binding quote changed exact input");
        assertEq(quotedOutput, candidateOutput, "non-binding quote changed XYC output");

        mockAsset.mint(address(this), REQUESTED_INPUT);
        IERC20(address(mockAsset)).forceApprove(address(router), type(uint256).max);

        uint256 takerInputBefore = mockAsset.balanceOf(address(this));
        uint256 takerOutputBefore = UNDERLYING.balanceOf(address(this));
        uint256 inputSharesBefore = mockVault.balanceOf(address(maker));
        uint256 outputSharesBefore = STATA.balanceOf(address(maker));
        uint256 expectedInputShares = mockVault.previewDeposit(quotedInput);
        uint256 expectedOutputShares = STATA.previewWithdraw(quotedOutput);
        assertEq(UNDERLYING.balanceOf(address(maker)), 0, "USDC became idle before settlement");

        vm.recordLogs();
        (uint256 actualInput, uint256 actualOutput, bytes32 actualHash) =
            router.swap(order, REQUESTED_INPUT, _takerTraits(true, aToB, abi.encode(quotedOutput)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(actualHash, orderHash, "swap returned wrong order hash");
        assertEq(actualInput, quotedInput, "same-state quote/swap input mismatch");
        assertEq(actualOutput, quotedOutput, "same-state quote/swap output mismatch");
        assertEq(takerInputBefore - mockAsset.balanceOf(address(this)), actualInput, "taker input delta");
        assertEq(UNDERLYING.balanceOf(address(this)) - takerOutputBefore, actualOutput, "recipient output delta");
        assertEq(
            mockVault.balanceOf(address(maker)) - inputSharesBefore,
            expectedInputShares,
            "mock input share mint rounding"
        );
        assertEq(
            outputSharesBefore - STATA.balanceOf(address(maker)),
            expectedOutputShares,
            "Stata output share burn rounding"
        );
        assertEq(mockAsset.balanceOf(address(maker)), 0, "successful input reinvest left idle mock asset");
        assertEq(UNDERLYING.balanceOf(address(maker)), 0, "materialized USDC was not fully pulled");
        assertEq(mockAsset.balanceOf(address(mockAdapter)), 0, "mock adapter retained dust");
        assertEq(UNDERLYING.balanceOf(address(aaveAdapter)), 0, "Aave adapter retained dust");
        assertTrue(_hasEvent(logs, address(maker), REINVEST_SUCCEEDED_TOPIC), "missing mock ReinvestSucceeded");
        assertTrue(_hasEvent(logs, STATA_USDC, WITHDRAW_TOPIC), "missing real Stata withdrawal");
        assertFalse(_hasEvent(logs, address(router), RESERVE_CLAMPED_TOPIC), "non-binding path emitted clamp");

        (uint256 aquaInAfter, uint256 aquaOutAfter) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);
        assertEq(aquaInAfter, aquaInBefore + actualInput, "Aqua input delta");
        assertEq(aquaOutAfter, aquaOutBefore - actualOutput, "Aqua output delta");
    }

    function test_AaveInputReinvestSucceedsUnderSealedLimit() public {
        address tokenIn = USDC;
        address tokenOut = address(mockAsset);
        bool aToB = _isAToB(tokenIn, tokenOut);

        (uint256 quotedInput, uint256 quotedOutput,) =
            router.asView().quote(order, REQUESTED_INPUT, _takerTraits(true, aToB, ""));
        assertEq(quotedInput, REQUESTED_INPUT, "Aave-input quote changed exact input");

        deal(USDC, address(this), REQUESTED_INPUT);
        UNDERLYING.forceApprove(address(router), type(uint256).max);

        uint256 takerInputBefore = UNDERLYING.balanceOf(address(this));
        uint256 takerOutputBefore = mockAsset.balanceOf(address(this));
        uint256 aaveSharesBefore = STATA.balanceOf(address(maker));
        uint256 expectedAaveShares = STATA.previewDeposit(quotedInput);
        assertEq(UNDERLYING.balanceOf(address(maker)), 0, "Aave input must not be idle before swap");

        vm.recordLogs();
        (uint256 actualInput, uint256 actualOutput,) =
            router.swap(order, REQUESTED_INPUT, _takerTraits(true, aToB, abi.encode(quotedOutput)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(actualInput, quotedInput, "Aave-input quote/swap mismatch");
        assertEq(actualOutput, quotedOutput, "Aave-input output mismatch");
        assertEq(takerInputBefore - UNDERLYING.balanceOf(address(this)), actualInput, "USDC taker delta");
        assertEq(mockAsset.balanceOf(address(this)) - takerOutputBefore, actualOutput, "mock output delta");
        assertEq(
            STATA.balanceOf(address(maker)) - aaveSharesBefore, expectedAaveShares, "Aave input share mint rounding"
        );
        assertEq(UNDERLYING.balanceOf(address(maker)), 0, "Aave reinvest left maker USDC idle");
        assertEq(UNDERLYING.balanceOf(address(aaveAdapter)), 0, "Aave adapter retained USDC");
        assertTrue(_hasEvent(logs, address(maker), REINVEST_SUCCEEDED_TOPIC), "missing Aave ReinvestSucceeded");
        assertFalse(_hasEvent(logs, address(maker), REINVEST_FAILED_TOPIC), "Aave reinvest hit sealed limit");
        assertTrue(_hasEvent(logs, address(aaveAdapter), ASSETS_REINVESTED_TOPIC), "missing adapter reinvest event");
        assertTrue(_hasEvent(logs, STATA_USDC, DEPOSIT_TOPIC), "missing real Stata deposit");
    }

    function test_AaveAdapterFullReinvestGasCalibration() public {
        ReservoirMakerAccount calibrationMaker = new ReservoirMakerAccount(address(this), aqua);
        ERC4626ReserveAdapter calibrationAdapter = new ERC4626ReserveAdapter(address(calibrationMaker), STATA, 0, 0);
        calibrationMaker.configureReserve(USDC, calibrationAdapter, AAVE_REINVEST_GAS_LIMIT);

        deal(USDC, address(calibrationMaker), CALIBRATION_DEPOSIT);
        vm.cool(address(calibrationMaker));
        vm.cool(address(calibrationAdapter));
        vm.cool(USDC);
        vm.cool(STATA_USDC);
        vm.cool(A_USDC);
        vm.cool(AAVE_V3_POOL);

        uint256 firstSharesBefore = STATA.balanceOf(address(calibrationMaker));
        uint256 gasBeforeFirst = gasleft();
        calibrationMaker.prepareInventory(USDC);
        uint256 firstFullPathGas = gasBeforeFirst - gasleft();
        uint256 firstShares = STATA.balanceOf(address(calibrationMaker)) - firstSharesBefore;

        deal(USDC, address(calibrationMaker), CALIBRATION_DEPOSIT);
        uint256 repeatSharesBefore = STATA.balanceOf(address(calibrationMaker));
        uint256 gasBeforeRepeat = gasleft();
        calibrationMaker.prepareInventory(USDC);
        uint256 repeatFullPathGas = gasBeforeRepeat - gasleft();
        uint256 repeatShares = STATA.balanceOf(address(calibrationMaker)) - repeatSharesBefore;

        assertGt(firstShares, 0, "first full reinvest minted no shares");
        assertGt(repeatShares, 0, "repeat full reinvest minted no shares");
        assertEq(UNDERLYING.balanceOf(address(calibrationMaker)), 0, "calibration maker retained USDC");
        assertEq(UNDERLYING.balanceOf(address(calibrationAdapter)), 0, "calibration adapter retained USDC");
        assertLt(firstFullPathGas, AAVE_REINVEST_GAS_LIMIT, "sealed limit lacks first-path margin");
        assertLt(repeatFullPathGas, AAVE_REINVEST_GAS_LIMIT, "sealed limit lacks repeat-path margin");

        emit log_named_uint("full adapter first reinvest gas (cold named accounts)", firstFullPathGas);
        emit log_named_uint("full adapter repeat reinvest gas (same tx warm)", repeatFullPathGas);
        emit log_named_uint("sealed Aave reinvest gas limit", AAVE_REINVEST_GAS_LIMIT);
        emit log_named_uint("first full-path shares", firstShares);
        emit log_named_uint("repeat full-path shares", repeatShares);
    }

    function __rollAaveFork(uint256 blockNumber) external {
        require(msg.sender == address(this), "self only");
        vm.rollFork(blockNumber);
    }

    function __historicalAaveStateProbe() external returns (bool) {
        require(msg.sender == address(this), "self only");
        bytes memory historicalCode =
            vm.rpc("eth_getCode", "[\"0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E\",\"0x186b1d1\"]");
        return historicalCode.length != 0;
    }

    function _pinAndValidateFork() private {
        try this.__historicalAaveStateProbe() returns (bool hasHistoricalState) {
            if (!hasHistoricalState) {
                revert(ARCHIVE_FAILURE);
            }
        } catch {
            revert(ARCHIVE_FAILURE);
        }

        try this.__rollAaveFork(PINNED_BLOCK + 1) { }
        catch {
            revert(ARCHIVE_FAILURE);
        }
        assertEq(block.number, PINNED_BLOCK + 1, "fork did not roll to hash preflight block");
        assertEq(blockhash(PINNED_BLOCK), PINNED_BLOCK_HASH, "unexpected pinned block hash");

        try this.__rollAaveFork(PINNED_BLOCK) { }
        catch {
            revert(ARCHIVE_FAILURE);
        }
        assertEq(block.number, PINNED_BLOCK, "fork did not restore pinned state");

        assertGt(USDC.code.length, 0, "USDC code missing");
        assertGt(STATA_USDC.code.length, 0, "Stata code missing");
        assertGt(A_USDC.code.length, 0, "aUSDC code missing");
        assertGt(AAVE_V3_POOL.code.length, 0, "Aave Pool code missing");
        assertEq(STATA.asset(), USDC, "unexpected Stata asset");
        assertEq(IStataTokenV2Integration(STATA_USDC).aToken(), A_USDC, "unexpected Stata aToken");
        assertEq(IAaveATokenIntegration(A_USDC).UNDERLYING_ASSET_ADDRESS(), USDC, "unexpected aUSDC underlying");
        assertEq(IAaveATokenIntegration(A_USDC).POOL(), AAVE_V3_POOL, "unexpected aUSDC Pool");
    }

    function _isAToB(address tokenIn, address tokenOut) private view returns (bool aToB) {
        assertTrue(
            (tokenIn == maker.tokenA() && tokenOut == maker.tokenB())
                || (tokenIn == maker.tokenB() && tokenOut == maker.tokenA()),
            "tokens are not the shipped pair"
        );
        return tokenIn == maker.tokenA();
    }

    function _takerTraits(bool exactIn, bool aToB, bytes memory threshold) private view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(this),
                isExactIn: exactIn,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                isAToB: aToB,
                threshold: threshold,
                to: address(0),
                deadline: uint40(block.timestamp + 1 hours),
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

    function _hasEvent(Vm.Log[] memory logs, address emitter, bytes32 topic) private pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                return true;
            }
        }
        return false;
    }
}
