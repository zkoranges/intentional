// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { AquaIntentLib, ExactInAquaIntent } from "../src/intents/AquaIntent.sol";
import { ReservoirMakerAccount } from "../src/accounts/ReservoirMakerAccount.sol";
import { ReservoirSwapVMRouter } from "../src/routers/ReservoirSwapVMRouter.sol";

interface ILidoWstETHFill is IERC20 {
    function wrap(uint256 stETHAmount) external returns (uint256 wstETHAmount);

    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256 stETHAmount);
}

/// @notice Fills one exact-input wstETH -> WETH intent on Ethereum mainnet
///         through the shipped Reservoir strategy on canonical Aqua.
contract FillAquaIntentMainnet is Script {
    using SafeERC20 for IERC20;
    using AquaIntentLib for ExactInAquaIntent;

    bytes32 private constant ACK_HASH = keccak256("FILL_AQUA_INTENT_RESERVOIR_V1");

    address private constant CANONICAL_AQUA = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;
    address private constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 private constant MIN_TAKER_WEI = 0.000_01 ether;
    uint256 private constant MAX_TAKER_WEI = 0.001 ether;
    uint256 private constant BPS = 10_000;

    function run() external {
        require(
            keccak256(bytes(vm.envString("RESERVOIR_MAINNET_ACK"))) == ACK_HASH,
            "aqua intent fill acknowledgement mismatch"
        );
        require(block.chainid == 1, "Ethereum mainnet required");

        address operator = vm.envAddress("FACTOR_ADDRESS");
        ReservoirMakerAccount maker = ReservoirMakerAccount(vm.envAddress("AQUA_MAKER_ADDRESS"));
        ReservoirSwapVMRouter router = ReservoirSwapVMRouter(payable(vm.envAddress("AQUA_ROUTER_ADDRESS")));
        uint256 minOutBpsOfFair = vm.envOr("MIN_OUT_BPS_OF_FAIR", uint256(9000));
        uint256 driftBufferBps = vm.envOr("QUOTE_DRIFT_BUFFER_BPS", uint256(30));
        require(minOutBpsOfFair != 0 && minOutBpsOfFair <= BPS, "invalid minimum-output floor");
        require(driftBufferBps < BPS, "invalid drift buffer");

        uint256 takerWstETH = vm.envUint("TAKER_WSTETH_WEI");
        require(takerWstETH >= MIN_TAKER_WEI && takerWstETH <= MAX_TAKER_WEI, "recorded taker amount outside bounds");
        require(IERC20(WSTETH).balanceOf(operator) >= takerWstETH, "operator holds less than the recorded amount");

        require(maker.isSealed(), "maker strategy not shipped");
        require(address(maker.router()) == address(router), "router does not match maker");
        require(maker.tokenA() == WSTETH && maker.tokenB() == WETH, "unexpected maker token pair");
        bytes32 strategyHash = maker.strategyHash();
        ISwapVM.Order memory order = maker.shippedOrder();
        require(router.hash(order) == strategyHash, "reconstructed order hash mismatch");

        (uint256 aquaWstETHBefore, uint256 aquaWethBefore) =
            Aqua(CANONICAL_AQUA).safeBalances(address(maker), address(router), strategyHash, WSTETH, WETH);
        require(aquaWstETHBefore != 0 && aquaWethBefore != 0, "strategy has no active virtual balances");

        ExactInAquaIntent memory previewIntent = ExactInAquaIntent({
            recipient: operator,
            amountIn: takerWstETH,
            minAmountOut: 1,
            deadline: uint40(block.timestamp + 15 minutes),
            isAToB: true
        });
        vm.prank(operator);
        (uint256 quotedInput, uint256 quotedOutput, bytes32 quotedHash) =
            router.quote(order, takerWstETH, previewIntent.buildTakerTraits());
        require(quotedHash == strategyHash, "quote is not the shipped strategy");
        require(quotedInput == takerWstETH, "quote changed the exact input");
        uint256 fairWeth = ILidoWstETHFill(WSTETH).getStETHByWstETH(takerWstETH);
        require(quotedOutput >= (fairWeth * minOutBpsOfFair) / BPS, "quoted output below the rate circuit breaker");
        uint256 minAmountOut = (quotedOutput * (BPS - driftBufferBps)) / BPS;
        require(minAmountOut != 0, "minimum output rounded to zero");

        vm.startBroadcast();

        IERC20(WSTETH).forceApprove(address(router), takerWstETH);

        ExactInAquaIntent memory intent = ExactInAquaIntent({
            recipient: operator,
            amountIn: takerWstETH,
            minAmountOut: minAmountOut,
            deadline: uint40(block.timestamp + 15 minutes),
            isAToB: true
        });

        uint256 recipientWethBefore = IERC20(WETH).balanceOf(operator);
        (uint256 actualInput, uint256 actualOutput, bytes32 filledHash) =
            router.swap(order, takerWstETH, intent.buildTakerTraits());

        vm.stopBroadcast();

        require(filledHash == strategyHash, "filled strategy hash mismatch");
        require(actualInput == takerWstETH, "unexpected input amount charged");
        require(actualOutput >= minAmountOut, "minimum output not honored");
        require(IERC20(WETH).balanceOf(operator) - recipientWethBefore == actualOutput, "recipient WETH delta mismatch");
        (uint256 aquaWstETHAfter, uint256 aquaWethAfter) =
            Aqua(CANONICAL_AQUA).safeBalances(address(maker), address(router), strategyHash, WSTETH, WETH);
        require(aquaWstETHAfter == aquaWstETHBefore + actualInput, "Aqua input balance mismatch");
        require(aquaWethAfter == aquaWethBefore - actualOutput, "Aqua output balance mismatch");

        console2.log("AQUA INTENT MAINNET | strategy hash");
        console2.logBytes32(strategyHash);
        console2.log("AQUA INTENT MAINNET | exact wstETH input wei", actualInput);
        console2.log("AQUA INTENT MAINNET | router-quoted WETH output wei", quotedOutput);
        console2.log("AQUA INTENT MAINNET | minimum WETH output wei", minAmountOut);
        console2.log("AQUA INTENT MAINNET | actual WETH output wei", actualOutput);
        string memory fillHead = string.concat(
            '{"chainId":1,"strategyHash":"',
            vm.toString(strategyHash),
            '","wstETHInWei":"',
            vm.toString(actualInput),
            '","quotedWethOutWei":"',
            vm.toString(quotedOutput)
        );
        string memory fillTail = string.concat(
            '","wethOutWei":"', vm.toString(actualOutput), '","recipient":"', vm.toString(operator), '"}'
        );
        console2.log("RESERVOIR_AQUA_INTENT_FILL_BEGIN");
        console2.log(string.concat(fillHead, fillTail));
        console2.log("RESERVOIR_AQUA_INTENT_FILL_END");
    }
}
