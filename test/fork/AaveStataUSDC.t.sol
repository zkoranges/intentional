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

interface IStataTokenV2Integration {
    function aToken() external view returns (address);
}

interface IAaveATokenIntegration {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

    function POOL() external view returns (address);
}

interface IMainnetWETH is IERC20 {
    function deposit() external payable;
}

/// @notice Production-contract-only Aqua swap between canonical Aave
///         StataUSDC and StataWETH custody on a pinned mainnet fork.
/// @dev Disposable contracts/users and test-funded token balances are local to
///      the fork. Every external protocol call targets canonical production
///      code; no protocol or privileged actor is substituted.
contract AaveStataUSDCForkTest is Test {
    using SafeERC20 for IERC20;

    uint256 private constant PINNED_BLOCK = 25_604_561;
    bytes32 private constant PINNED_BLOCK_HASH = 0x95ca77908413d71bd01cada1ece52b6c2f35467dbbb8f2367144cd0ffbe7888d;

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant STATA_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address private constant STATA_WETH = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;
    address private constant A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address private constant A_WETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address private constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address private constant CANONICAL_AQUA = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;

    uint256 private constant ONE_USDC = 1_000_000;
    uint256 private constant STARTING_USDC = 10_000 * ONE_USDC;
    uint256 private constant STARTING_WETH = 5 ether;
    uint256 private constant REQUESTED_USDC_INPUT = 100 * ONE_USDC;
    uint256 private constant REQUESTED_WETH_INPUT = 0.05 ether;
    uint256 private constant USDC_CALIBRATION_DEPOSIT = 1000 * ONE_USDC;
    uint256 private constant WETH_CALIBRATION_DEPOSIT = 1 ether;

    uint32 private constant AAVE_REINVEST_GAS_LIMIT = 500_000;
    string private constant ARCHIVE_FAILURE = "archive RPC required for block 25,604,561";

    bytes32 private constant RESERVE_CLAMPED_TOPIC =
        keccak256("ReserveClamped(bytes32,address,uint256,uint256,uint256,uint256,uint256)");
    bytes32 private constant REINVEST_SUCCEEDED_TOPIC = keccak256("ReinvestSucceeded(address,address)");
    bytes32 private constant REINVEST_FAILED_TOPIC = keccak256("ReinvestFailed(address,uint8)");
    bytes32 private constant ASSETS_REINVESTED_TOPIC = keccak256("AssetsReinvested(address,uint256,uint256)");
    bytes32 private constant DEPOSIT_TOPIC = keccak256("Deposit(address,address,uint256,uint256)");
    bytes32 private constant WITHDRAW_TOPIC = keccak256("Withdraw(address,address,address,uint256,uint256)");

    IERC20 private constant USDC_TOKEN = IERC20(USDC);
    IMainnetWETH private constant WETH_TOKEN = IMainnetWETH(WETH);
    IERC4626 private constant USDC_VAULT = IERC4626(STATA_USDC);
    IERC4626 private constant WETH_VAULT = IERC4626(STATA_WETH);

    Aqua private aqua;
    ReservoirSwapVMRouter private router;
    ReservoirMakerAccount private maker;
    ERC4626ReserveAdapter private usdcAdapter;
    ERC4626ReserveAdapter private wethAdapter;
    ISwapVM.Order private order;
    bytes32 private orderHash;

    function setUp() public {
        _pinAndValidateFork();

        assertGt(CANONICAL_AQUA.code.length, 0, "canonical Aqua code missing");
        aqua = Aqua(CANONICAL_AQUA);
        router = new ReservoirSwapVMRouter(address(aqua), address(0), address(this), "Reservoir", "1");
        maker = new ReservoirMakerAccount(address(this), aqua);
        usdcAdapter = new ERC4626ReserveAdapter(address(maker), USDC_VAULT, 0, 0);
        wethAdapter = new ERC4626ReserveAdapter(address(maker), WETH_VAULT, 0, 0);

        maker.configureRouter(ISwapVM(address(router)));
        maker.configureReserve(USDC, usdcAdapter, AAVE_REINVEST_GAS_LIMIT);
        maker.configureReserve(WETH, wethAdapter, AAVE_REINVEST_GAS_LIMIT);

        deal(USDC, address(maker), STARTING_USDC);
        vm.deal(address(this), STARTING_WETH);
        WETH_TOKEN.deposit{ value: STARTING_WETH }();
        assertTrue(WETH_TOKEN.transfer(address(maker), STARTING_WETH));

        maker.prepareInventory(USDC);
        maker.prepareInventory(WETH);

        assertEq(USDC_TOKEN.balanceOf(address(maker)), 0, "USDC inventory must start entirely in shares");
        assertEq(WETH_TOKEN.balanceOf(address(maker)), 0, "WETH inventory must start entirely in shares");
        assertGt(USDC_VAULT.balanceOf(address(maker)), 0, "maker received no StataUSDC shares");
        assertGt(WETH_VAULT.balanceOf(address(maker)), 0, "maker received no StataWETH shares");

        uint256 balanceA = maker.navOf(maker.tokenA());
        uint256 balanceB = maker.navOf(maker.tokenB());
        (ISwapVM.Order memory shippedOrder, bytes32 shippedHash) =
            maker.sealAndShip(ReservoirProgramLib.build(), balanceA, balanceB);
        order = shippedOrder;
        orderHash = shippedHash;
    }

    function test_ProductionAaveWETHToUSDCSwapAndTimestampYield() public {
        address tokenIn = WETH;
        address tokenOut = USDC;
        bool aToB = _isAToB(tokenIn, tokenOut);

        uint256 postShipSnapshot = vm.snapshotState();
        uint256 fixedShares = USDC_VAULT.balanceOf(address(maker));
        uint256 navBefore = USDC_VAULT.convertToAssets(fixedShares);
        (uint256 aquaInBeforeYield, uint256 aquaOutBeforeYield) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);

        vm.warp(block.timestamp + 30 days);

        uint256 navAfter = USDC_VAULT.convertToAssets(fixedShares);
        (uint256 aquaInAfterYield, uint256 aquaOutAfterYield) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);
        assertEq(USDC_VAULT.balanceOf(address(maker)), fixedShares, "yield warp changed maker shares");
        assertGt(navAfter, navBefore, "yield warp did not increase fixed-share NAV");
        assertEq(aquaInAfterYield, aquaInBeforeYield, "yield warp changed Aqua input balance");
        assertEq(aquaOutAfterYield, aquaOutBeforeYield, "yield warp changed Aqua output balance");

        assertTrue(vm.revertToStateAndDelete(postShipSnapshot), "could not restore post-ship snapshot");

        (uint256 aquaInBefore, uint256 aquaOutBefore) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);
        uint256 candidateOutput = REQUESTED_WETH_INPUT * aquaOutBefore / (aquaInBefore + REQUESTED_WETH_INPUT);
        (uint256 safeCapacity, uint256 exitCostWad) = maker.availableFor(tokenOut, candidateOutput);
        assertEq(exitCostWad, 0, "v1 Aave exit cost must be zero");
        assertEq(safeCapacity, candidateOutput, "StataUSDC path unexpectedly binds");
        assertGe(USDC_VAULT.maxWithdraw(address(maker)), safeCapacity, "StataUSDC cannot cover quoted output");

        (uint256 quotedInput, uint256 quotedOutput, bytes32 quotedHash) =
            router.asView().quote(order, REQUESTED_WETH_INPUT, _takerTraits(true, aToB, ""));
        assertEq(quotedHash, orderHash, "quote returned wrong order hash");
        assertEq(quotedInput, REQUESTED_WETH_INPUT, "quote changed exact WETH input");
        assertEq(quotedOutput, candidateOutput, "quote changed XYC output");

        vm.deal(address(this), REQUESTED_WETH_INPUT);
        WETH_TOKEN.deposit{ value: REQUESTED_WETH_INPUT }();
        IERC20(WETH).forceApprove(address(router), type(uint256).max);

        uint256 takerInputBefore = WETH_TOKEN.balanceOf(address(this));
        uint256 takerOutputBefore = USDC_TOKEN.balanceOf(address(this));
        uint256 inputSharesBefore = WETH_VAULT.balanceOf(address(maker));
        uint256 outputSharesBefore = USDC_VAULT.balanceOf(address(maker));
        uint256 expectedInputShares = WETH_VAULT.previewDeposit(quotedInput);
        uint256 expectedOutputShares = USDC_VAULT.previewWithdraw(quotedOutput);

        vm.recordLogs();
        (uint256 actualInput, uint256 actualOutput, bytes32 actualHash) =
            router.swap(order, REQUESTED_WETH_INPUT, _takerTraits(true, aToB, abi.encode(quotedOutput)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(actualHash, orderHash, "swap returned wrong order hash");
        assertEq(actualInput, quotedInput, "same-state quote/swap input mismatch");
        assertEq(actualOutput, quotedOutput, "same-state quote/swap output mismatch");
        assertEq(takerInputBefore - WETH_TOKEN.balanceOf(address(this)), actualInput, "WETH taker delta");
        assertEq(USDC_TOKEN.balanceOf(address(this)) - takerOutputBefore, actualOutput, "USDC recipient delta");
        assertEq(
            WETH_VAULT.balanceOf(address(maker)) - inputSharesBefore,
            expectedInputShares,
            "StataWETH input share mint rounding"
        );
        assertEq(
            outputSharesBefore - USDC_VAULT.balanceOf(address(maker)),
            expectedOutputShares,
            "StataUSDC output share burn rounding"
        );
        _assertNoIdleOrAdapterDust();
        assertTrue(_hasEvent(logs, address(maker), REINVEST_SUCCEEDED_TOPIC), "missing ReinvestSucceeded");
        assertFalse(_hasEvent(logs, address(maker), REINVEST_FAILED_TOPIC), "reinvest hit sealed limit");
        assertTrue(_hasEvent(logs, address(wethAdapter), ASSETS_REINVESTED_TOPIC), "missing WETH reinvest event");
        assertTrue(_hasEvent(logs, STATA_WETH, DEPOSIT_TOPIC), "missing real StataWETH deposit");
        assertTrue(_hasEvent(logs, STATA_USDC, WITHDRAW_TOPIC), "missing real StataUSDC withdrawal");
        assertFalse(_hasEvent(logs, address(router), RESERVE_CLAMPED_TOPIC), "non-binding path emitted clamp");

        (uint256 aquaInAfter, uint256 aquaOutAfter) =
            aqua.safeBalances(address(maker), address(router), orderHash, tokenIn, tokenOut);
        assertEq(aquaInAfter, aquaInBefore + actualInput, "Aqua input delta");
        assertEq(aquaOutAfter, aquaOutBefore - actualOutput, "Aqua output delta");
    }

    function test_ProductionAaveUSDCToWETHSwapAndReinvest() public {
        address tokenIn = USDC;
        address tokenOut = WETH;
        bool aToB = _isAToB(tokenIn, tokenOut);

        (uint256 quotedInput, uint256 quotedOutput,) =
            router.asView().quote(order, REQUESTED_USDC_INPUT, _takerTraits(true, aToB, ""));
        assertEq(quotedInput, REQUESTED_USDC_INPUT, "quote changed exact USDC input");
        assertGe(WETH_VAULT.maxWithdraw(address(maker)), quotedOutput, "StataWETH cannot cover quoted output");

        deal(USDC, address(this), REQUESTED_USDC_INPUT);
        USDC_TOKEN.forceApprove(address(router), type(uint256).max);

        uint256 takerInputBefore = USDC_TOKEN.balanceOf(address(this));
        uint256 takerOutputBefore = WETH_TOKEN.balanceOf(address(this));
        uint256 inputSharesBefore = USDC_VAULT.balanceOf(address(maker));
        uint256 outputSharesBefore = WETH_VAULT.balanceOf(address(maker));
        uint256 expectedInputShares = USDC_VAULT.previewDeposit(quotedInput);
        uint256 expectedOutputShares = WETH_VAULT.previewWithdraw(quotedOutput);

        vm.recordLogs();
        (uint256 actualInput, uint256 actualOutput,) =
            router.swap(order, REQUESTED_USDC_INPUT, _takerTraits(true, aToB, abi.encode(quotedOutput)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(actualInput, quotedInput, "USDC quote/swap mismatch");
        assertEq(actualOutput, quotedOutput, "WETH output mismatch");
        assertEq(takerInputBefore - USDC_TOKEN.balanceOf(address(this)), actualInput, "USDC taker delta");
        assertEq(WETH_TOKEN.balanceOf(address(this)) - takerOutputBefore, actualOutput, "WETH recipient delta");
        assertEq(
            USDC_VAULT.balanceOf(address(maker)) - inputSharesBefore,
            expectedInputShares,
            "StataUSDC input share mint rounding"
        );
        assertEq(
            outputSharesBefore - WETH_VAULT.balanceOf(address(maker)),
            expectedOutputShares,
            "StataWETH output share burn rounding"
        );
        _assertNoIdleOrAdapterDust();
        assertTrue(_hasEvent(logs, address(maker), REINVEST_SUCCEEDED_TOPIC), "missing ReinvestSucceeded");
        assertFalse(_hasEvent(logs, address(maker), REINVEST_FAILED_TOPIC), "reinvest hit sealed limit");
        assertTrue(_hasEvent(logs, address(usdcAdapter), ASSETS_REINVESTED_TOPIC), "missing USDC reinvest event");
        assertTrue(_hasEvent(logs, STATA_USDC, DEPOSIT_TOPIC), "missing real StataUSDC deposit");
        assertTrue(_hasEvent(logs, STATA_WETH, WITHDRAW_TOPIC), "missing real StataWETH withdrawal");
    }

    function test_ProductionAaveAdaptersFullReinvestGasCalibration() public {
        _calibrateReinvest(USDC_TOKEN, USDC_VAULT, A_USDC, USDC_CALIBRATION_DEPOSIT, "USDC");
        _calibrateReinvest(IERC20(WETH), WETH_VAULT, A_WETH, WETH_CALIBRATION_DEPOSIT, "WETH");
    }

    function _calibrateReinvest(
        IERC20 asset,
        IERC4626 vault,
        address aToken,
        uint256 depositAssets,
        string memory symbol
    )
        private
    {
        ReservoirMakerAccount calibrationMaker = new ReservoirMakerAccount(address(this), aqua);
        ERC4626ReserveAdapter calibrationAdapter = new ERC4626ReserveAdapter(address(calibrationMaker), vault, 0, 0);
        calibrationMaker.configureReserve(address(asset), calibrationAdapter, AAVE_REINVEST_GAS_LIMIT);

        deal(address(asset), address(calibrationMaker), depositAssets);
        vm.cool(address(calibrationMaker));
        vm.cool(address(calibrationAdapter));
        vm.cool(address(asset));
        vm.cool(address(vault));
        vm.cool(aToken);
        vm.cool(AAVE_V3_POOL);

        uint256 firstSharesBefore = vault.balanceOf(address(calibrationMaker));
        uint256 gasBeforeFirst = gasleft();
        calibrationMaker.prepareInventory(address(asset));
        uint256 firstFullPathGas = gasBeforeFirst - gasleft();
        uint256 firstShares = vault.balanceOf(address(calibrationMaker)) - firstSharesBefore;

        deal(address(asset), address(calibrationMaker), depositAssets);
        uint256 repeatSharesBefore = vault.balanceOf(address(calibrationMaker));
        uint256 gasBeforeRepeat = gasleft();
        calibrationMaker.prepareInventory(address(asset));
        uint256 repeatFullPathGas = gasBeforeRepeat - gasleft();
        uint256 repeatShares = vault.balanceOf(address(calibrationMaker)) - repeatSharesBefore;

        assertGt(firstShares, 0, string.concat(symbol, " first reinvest minted no shares"));
        assertGt(repeatShares, 0, string.concat(symbol, " repeat reinvest minted no shares"));
        assertEq(asset.balanceOf(address(calibrationMaker)), 0, string.concat(symbol, " maker retained underlying"));
        assertEq(asset.balanceOf(address(calibrationAdapter)), 0, string.concat(symbol, " adapter retained underlying"));
        assertLt(firstFullPathGas, AAVE_REINVEST_GAS_LIMIT, string.concat(symbol, " first path exceeds limit"));
        assertLt(repeatFullPathGas, AAVE_REINVEST_GAS_LIMIT, string.concat(symbol, " repeat path exceeds limit"));

        emit log_named_string("production reserve", symbol);
        emit log_named_uint("full adapter first reinvest gas", firstFullPathGas);
        emit log_named_uint("full adapter repeat reinvest gas", repeatFullPathGas);
    }

    function _assertNoIdleOrAdapterDust() private view {
        assertEq(USDC_TOKEN.balanceOf(address(maker)), 0, "maker retained idle USDC");
        assertEq(WETH_TOKEN.balanceOf(address(maker)), 0, "maker retained idle WETH");
        assertEq(USDC_TOKEN.balanceOf(address(usdcAdapter)), 0, "USDC adapter retained dust");
        assertEq(WETH_TOKEN.balanceOf(address(wethAdapter)), 0, "WETH adapter retained dust");
        assertEq(USDC_VAULT.balanceOf(address(usdcAdapter)), 0, "USDC adapter retained vault shares");
        assertEq(WETH_VAULT.balanceOf(address(wethAdapter)), 0, "WETH adapter retained vault shares");
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

        _assertVaultBinding(USDC, STATA_USDC, A_USDC);
        _assertVaultBinding(WETH, STATA_WETH, A_WETH);
        assertGt(AAVE_V3_POOL.code.length, 0, "Aave Pool code missing");
    }

    function _assertVaultBinding(address asset, address vault, address aToken) private view {
        assertGt(asset.code.length, 0, "underlying code missing");
        assertGt(vault.code.length, 0, "Stata code missing");
        assertGt(aToken.code.length, 0, "aToken code missing");
        assertEq(IERC4626(vault).asset(), asset, "unexpected Stata asset");
        assertEq(IStataTokenV2Integration(vault).aToken(), aToken, "unexpected Stata aToken");
        assertEq(IAaveATokenIntegration(aToken).UNDERLYING_ASSET_ADDRESS(), asset, "unexpected aToken underlying");
        assertEq(IAaveATokenIntegration(aToken).POOL(), AAVE_V3_POOL, "unexpected aToken Pool");
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
