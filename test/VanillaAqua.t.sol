// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { AquaSwapVMTest } from "@1inch/swap-vm/test/base/AquaSwapVMTest.sol";

/// @notice Smallest upstream XYC/Aqua balance test, preserved in behavior.
contract VanillaAquaTest is AquaSwapVMTest {
    function test_VanillaAqua() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: INITIAL_BALANCE_A,
            balanceB: INITIAL_BALANCE_B,
            priceMin: 0,
            priceMax: 0,
            protocolFeeBps: 0,
            feeInBps: 0,
            protocolFeeRecipient: address(0),
            swapType: SwapType.XYC
        });
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = SwapProgram({
            amount: 100e18, taker: taker, tokenA: tokenA, tokenB: tokenB, zeroForOne: true, isExactIn: true
        });

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);
        mintTokenInToTaker(swapProgram);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);
        mintTokenOutToMaker(swapProgram, 200e18);

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);
        uint256 amountOutExpected = setup.balanceB * amountIn / (setup.balanceA + amountIn);

        assertEq(takerBalanceBAfter - takerBalanceBBefore, amountOutExpected);
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn);
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut);
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn);
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut);
    }
}

