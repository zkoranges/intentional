// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { ReservoirMakerAccount } from "../../src/accounts/ReservoirMakerAccount.sol";
import { ERC4626ReserveAdapter } from "../../src/adapters/ERC4626ReserveAdapter.sol";
import { AquaIntentLib, ExactInAquaIntent } from "../../src/intents/AquaIntent.sol";
import { ReservoirProgramLib } from "../../src/opcodes/ReservoirOpcodes.sol";
import { ReservoirSwapVMRouter } from "../../src/routers/ReservoirSwapVMRouter.sol";

interface ILidoStETH is IERC20 {
    function submit(address referral) external payable returns (uint256 sharesAmount);
}

interface ILidoWstETH is IERC20 {
    function wrap(uint256 stETHAmount) external returns (uint256 wstETHAmount);

    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256 stETHAmount);
}

interface IMainnetWETH is IERC20 {
    function deposit() external payable;
}

interface IStataTokenMetadata {
    function aToken() external view returns (address);
}

/// @notice A portable exact-input intent filled through a freshly deployed
///         Reservoir router and maker against canonical mainnet Aqua, Lido,
///         WETH, and Aave StataTokenV2 contracts.
/// @dev No external protocol is mocked or replaced. Only the Reservoir release
///      contracts and user accounts are disposable fork fixtures.
contract AquaIntentWstETHForkTest is Test {
    using AquaIntentLib for ExactInAquaIntent;
    using SafeERC20 for IERC20;

    uint256 private constant PINNED_BLOCK = 25_604_561;
    bytes32 private constant PINNED_BLOCK_HASH = 0x95ca77908413d71bd01cada1ece52b6c2f35467dbbb8f2367144cd0ffbe7888d;

    address private constant CANONICAL_AQUA = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;
    address private constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant STATA_WSTETH = 0x322AA5F5Be95644d6c36544B6c5061F072D16DF5;
    address private constant STATA_WETH = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;
    address private constant A_WSTETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address private constant A_WETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;

    uint32 private constant REINVEST_GAS_LIMIT = 500_000;
    uint256 private constant TAKER_INPUT = 0.01 ether;
    string private constant ARCHIVE_FAILURE = "archive RPC required for block 25,604,561";

    ILidoStETH private constant STETH_TOKEN = ILidoStETH(STETH);
    ILidoWstETH private constant WSTETH_TOKEN = ILidoWstETH(WSTETH);
    IMainnetWETH private constant WETH_TOKEN = IMainnetWETH(WETH);
    IERC4626 private constant WSTETH_VAULT = IERC4626(STATA_WSTETH);
    IERC4626 private constant WETH_VAULT = IERC4626(STATA_WETH);

    Aqua private aqua;
    ReservoirSwapVMRouter private router;
    ReservoirMakerAccount private maker;
    ERC4626ReserveAdapter private wstETHAdapter;
    ERC4626ReserveAdapter private wethAdapter;
    ISwapVM.Order private order;
    bytes32 private strategyHash;
    address private taker;
    address private recipient;

    function setUp() public {
        _pinAndValidateFork();

        aqua = Aqua(CANONICAL_AQUA);
        router = new ReservoirSwapVMRouter(CANONICAL_AQUA, WETH, address(this), "Reservoir Aqua Intent", "1");
        maker = new ReservoirMakerAccount(address(this), aqua);
        wstETHAdapter = new ERC4626ReserveAdapter(address(maker), WSTETH_VAULT, 0, 0);
        wethAdapter = new ERC4626ReserveAdapter(address(maker), WETH_VAULT, 0, 0);

        maker.configureRouter(ISwapVM(address(router)));
        maker.configureReserve(WSTETH, wstETHAdapter, REINVEST_GAS_LIMIT);
        maker.configureReserve(WETH, wethAdapter, REINVEST_GAS_LIMIT);

        vm.deal(address(this), 10 ether);
        _mintWstETH(address(maker), 2 ether);
        WETH_TOKEN.deposit{ value: 3 ether }();
        IERC20(WETH).safeTransfer(address(maker), 3 ether);

        maker.prepareInventory(WSTETH);
        maker.prepareInventory(WETH);
        assertEq(IERC20(WSTETH).balanceOf(address(maker)), 0, "maker retained idle wstETH");
        assertEq(IERC20(WETH).balanceOf(address(maker)), 0, "maker retained idle WETH");

        uint256 virtualWstETH = 1 ether;
        uint256 virtualWeth = WSTETH_TOKEN.getStETHByWstETH(virtualWstETH);
        assertGe(maker.navOf(WSTETH), virtualWstETH, "wstETH NAV does not back intent");
        assertGe(maker.navOf(WETH), virtualWeth, "WETH NAV does not back intent");

        (order, strategyHash) = maker.sealAndShip(ReservoirProgramLib.build(), virtualWstETH, virtualWeth);
        assertEq(order.maker, address(maker));
        assertEq(router.hash(order), strategyHash);

        taker = makeAddr("aquaIntentTaker");
        recipient = makeAddr("aquaIntentRecipient");
        _mintWstETH(taker, 0.1 ether);
    }

    function test_ProductionAquaIntentQuotesAndFillsWstETHForWETH() public {
        ExactInAquaIntent memory intent = _intent(1);
        bytes memory previewTraits = intent.buildTakerTraits();

        uint256 makerWethSharesBefore = WETH_VAULT.balanceOf(address(maker));
        uint256 makerWstETHSharesBefore = WSTETH_VAULT.balanceOf(address(maker));
        vm.prank(taker);
        (uint256 quotedInput, uint256 quotedOutput, bytes32 quotedHash) =
            router.quote(order, intent.amountIn, previewTraits);

        assertEq(quotedHash, strategyHash, "quote is not the Aqua-shipped strategy");
        assertEq(quotedInput, intent.amountIn, "non-binding exact-in quote changed input");
        assertGt(quotedOutput, quotedInput, "wstETH intent ignored live wstETH/stETH value");
        assertEq(WETH_VAULT.balanceOf(address(maker)), makerWethSharesBefore, "quote burned WETH shares");
        assertEq(WSTETH_VAULT.balanceOf(address(maker)), makerWstETHSharesBefore, "quote minted wstETH shares");

        intent.minAmountOut = quotedOutput;
        bytes memory fillTraits = intent.buildTakerTraits();
        uint256 takerInputBefore = IERC20(WSTETH).balanceOf(taker);
        uint256 recipientOutputBefore = IERC20(WETH).balanceOf(recipient);
        (uint256 aquaInputBefore, uint256 aquaOutputBefore) =
            aqua.safeBalances(address(maker), address(router), strategyHash, WSTETH, WETH);

        vm.prank(taker);
        IERC20(WSTETH).approve(address(router), intent.amountIn);
        vm.prank(taker);
        (uint256 actualInput, uint256 actualOutput, bytes32 filledHash) =
            router.swap(order, intent.amountIn, fillTraits);

        assertEq(filledHash, strategyHash, "filled strategy hash changed");
        assertEq(actualInput, intent.amountIn, "intent charged an unexpected input");
        assertGe(actualOutput, intent.minAmountOut, "intent minimum output was not honored");
        assertEq(takerInputBefore - IERC20(WSTETH).balanceOf(taker), actualInput, "taker input debit mismatch");
        assertEq(IERC20(WETH).balanceOf(recipient) - recipientOutputBefore, actualOutput, "recipient output mismatch");

        (uint256 aquaInputAfter, uint256 aquaOutputAfter) =
            aqua.safeBalances(address(maker), address(router), strategyHash, WSTETH, WETH);
        assertEq(aquaInputAfter, aquaInputBefore + actualInput, "Aqua input balance mismatch");
        assertEq(aquaOutputAfter, aquaOutputBefore - actualOutput, "Aqua output balance mismatch");
        assertLt(WETH_VAULT.balanceOf(address(maker)), makerWethSharesBefore, "WETH was not materialized");
        assertGt(WSTETH_VAULT.balanceOf(address(maker)), makerWstETHSharesBefore, "received wstETH was not reinvested");
        _assertNoIdleOrAdapterDust();

        emit log_named_address("AQUA INTENT | canonical Aqua", CANONICAL_AQUA);
        emit log_named_bytes32("AQUA INTENT | canonical strategy hash", strategyHash);
        emit log_named_uint("AQUA INTENT | mainnet block", block.number);
        emit log_named_address("AQUA INTENT | output recipient", recipient);
        emit log_named_decimal_uint("AQUA INTENT | exact wstETH input", actualInput, 18);
        emit log_named_decimal_uint("AQUA INTENT | minimum WETH output", intent.minAmountOut, 18);
        emit log_named_decimal_uint("AQUA INTENT | actual WETH output", actualOutput, 18);
    }

    function test_IntentMinimumDeadlineAndAquaAuthorizationFailClosed() public {
        ExactInAquaIntent memory intent = _intent(1);
        vm.prank(taker);
        (, uint256 quotedOutput,) = router.quote(order, intent.amountIn, intent.buildTakerTraits());

        intent.minAmountOut = quotedOutput + 1;
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                TakerTraitsLib.TakerTraitsInsufficientMinOutputAmount.selector, quotedOutput, quotedOutput + 1
            )
        );
        router.quote(order, intent.amountIn, intent.buildTakerTraits());

        intent.minAmountOut = 1;
        intent.deadline = uint40(block.timestamp - 1);
        vm.prank(taker);
        vm.expectRevert(TakerTraitsLib.TakerTraitsDeadlineExpired.selector);
        router.quote(order, intent.amountIn, intent.buildTakerTraits());

        ISwapVM.Order memory alteredOrder = order;
        alteredOrder.data = bytes.concat(alteredOrder.data, hex"00");
        bytes32 alteredHash = router.hash(alteredOrder);
        assertNotEq(alteredHash, strategyHash, "altered order retained strategy hash");
        vm.expectPartialRevert(IAqua.SafeBalancesForTokenNotInActiveStrategy.selector);
        aqua.safeBalances(address(maker), address(router), alteredHash, WSTETH, WETH);

        vm.prank(taker);
        vm.expectPartialRevert(IAqua.SafeBalancesForTokenNotInActiveStrategy.selector);
        router.quote(alteredOrder, intent.amountIn, intent.buildTakerTraits());
    }

    function _intent(uint256 minAmountOut) private view returns (ExactInAquaIntent memory) {
        assertEq(maker.tokenA(), WSTETH, "unexpected sorted input token");
        assertEq(maker.tokenB(), WETH, "unexpected sorted output token");
        return ExactInAquaIntent({
            recipient: recipient,
            amountIn: TAKER_INPUT,
            minAmountOut: minAmountOut,
            deadline: uint40(block.timestamp + 10 minutes),
            isAToB: true
        });
    }

    function _mintWstETH(address recipient_, uint256 ethAmount) private returns (uint256 received) {
        uint256 stETHBefore = IERC20(STETH).balanceOf(address(this));
        STETH_TOKEN.submit{ value: ethAmount }(address(0));
        uint256 stETHReceived = IERC20(STETH).balanceOf(address(this)) - stETHBefore;
        IERC20(STETH).forceApprove(WSTETH, stETHReceived);
        received = WSTETH_TOKEN.wrap(stETHReceived);
        assertGt(received, 0, "canonical Lido wrap minted no wstETH");
        IERC20(WSTETH).safeTransfer(recipient_, received);
    }

    function _assertNoIdleOrAdapterDust() private view {
        assertEq(IERC20(WSTETH).balanceOf(address(maker)), 0, "maker retained idle wstETH");
        assertEq(IERC20(WETH).balanceOf(address(maker)), 0, "maker retained idle WETH");
        assertEq(IERC20(WSTETH).balanceOf(address(wstETHAdapter)), 0, "wstETH adapter retained underlying");
        assertEq(IERC20(WETH).balanceOf(address(wethAdapter)), 0, "WETH adapter retained underlying");
        assertEq(WSTETH_VAULT.balanceOf(address(wstETHAdapter)), 0, "wstETH adapter retained shares");
        assertEq(WETH_VAULT.balanceOf(address(wethAdapter)), 0, "WETH adapter retained shares");
    }

    function __rollFork(uint256 blockNumber) external {
        require(msg.sender == address(this), "self only");
        vm.rollFork(blockNumber);
    }

    function __historicalStateProbe() external returns (bool) {
        require(msg.sender == address(this), "self only");
        bytes memory historicalCode =
            vm.rpc("eth_getCode", "[\"0x322AA5F5Be95644d6c36544B6c5061F072D16DF5\",\"0x186b1d1\"]");
        return historicalCode.length != 0;
    }

    function _pinAndValidateFork() private {
        assertEq(block.chainid, 1, "Ethereum mainnet fork required");
        if (vm.envOr("AQUA_INTENT_CURRENT_MAINNET", false)) {
            _validateCanonicalContracts();
            return;
        }

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
        assertEq(blockhash(PINNED_BLOCK), PINNED_BLOCK_HASH, "unexpected pinned block hash");
        try this.__rollFork(PINNED_BLOCK) { }
        catch {
            revert(ARCHIVE_FAILURE);
        }

        _validateCanonicalContracts();
    }

    function _validateCanonicalContracts() private view {
        assertGt(CANONICAL_AQUA.code.length, 0, "canonical Aqua code missing");
        assertGt(STETH.code.length, 0, "canonical stETH code missing");
        assertGt(WSTETH.code.length, 0, "canonical wstETH code missing");
        assertGt(WETH.code.length, 0, "canonical WETH code missing");
        assertEq(WSTETH_VAULT.asset(), WSTETH, "StatawstETH asset mismatch");
        assertEq(WETH_VAULT.asset(), WETH, "StataWETH asset mismatch");
        assertEq(IStataTokenMetadata(STATA_WSTETH).aToken(), A_WSTETH, "StatawstETH aToken mismatch");
        assertEq(IStataTokenMetadata(STATA_WETH).aToken(), A_WETH, "StataWETH aToken mismatch");
    }
}
