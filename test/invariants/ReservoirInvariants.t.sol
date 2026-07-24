// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { ReserveClampTestBase } from "../unit/instructions/ReserveClampTestBase.sol";

/// @notice Exact integer properties of the pinned XYC formulas.
contract ReservoirXYCMathInvariants is Test {
    uint256 private constant MAX_TERM = 1e24;

    function testFuzz_ExactDiscreteInverse(uint256 xSeed, uint256 ySeed, uint256 extraInputSeed) public pure {
        uint256 x = _bounded(xSeed, 1, MAX_TERM);
        uint256 y = _bounded(ySeed, 2, MAX_TERM);
        uint256 minimumPositiveInput = Math.ceilDiv(x, y - 1);
        uint256 a = minimumPositiveInput + (extraInputSeed % MAX_TERM);
        uint256 b = _f(x, y, a);
        uint256 inverse = _g(x, y, b);

        assertGt(b, 0);
        assertLe(inverse, a);
        assertEq(_f(x, y, inverse), b);
        assertLt(_f(x, y, inverse - 1), b);
    }

    function testFuzz_ExactInRoundingFavorsMaker(uint256 xSeed, uint256 ySeed, uint256 aSeed) public pure {
        uint256 x = _bounded(xSeed, 1, MAX_TERM);
        uint256 y = _bounded(ySeed, 1, MAX_TERM);
        uint256 a = _bounded(aSeed, 1, MAX_TERM);
        uint256 b = _f(x, y, a);
        uint256 denominator = x + a;
        uint256 numerator = a * y;

        assertLe(b * denominator, numerator);
        assertGt((b + 1) * denominator, numerator);
    }

    function testFuzz_ExactOutRoundingFavorsMaker(uint256 xSeed, uint256 ySeed, uint256 bSeed) public pure {
        uint256 x = _bounded(xSeed, 1, MAX_TERM);
        uint256 y = _bounded(ySeed, 2, MAX_TERM);
        uint256 b = 1 + (bSeed % (y - 1));
        uint256 requiredInput = _g(x, y, b);
        uint256 denominator = y - b;
        uint256 numerator = b * x;

        assertGe(requiredInput * denominator, numerator);
        assertLt((requiredInput - 1) * denominator, numerator);
    }

    function testFuzz_ExactInOutputIsMonotonic(
        uint256 xSeed,
        uint256 ySeed,
        uint256 firstInputSeed,
        uint256 additionalInputSeed
    )
        public
        pure
    {
        uint256 x = _bounded(xSeed, 1, MAX_TERM);
        uint256 y = _bounded(ySeed, 1, MAX_TERM);
        uint256 firstInput = _bounded(firstInputSeed, 1, MAX_TERM);
        uint256 secondInput = firstInput + (additionalInputSeed % MAX_TERM);

        assertLe(_f(x, y, firstInput), _f(x, y, secondInput));
    }

    function _f(uint256 x, uint256 y, uint256 input) private pure returns (uint256) {
        return input * y / (x + input);
    }

    function _g(uint256 x, uint256 y, uint256 output) private pure returns (uint256) {
        return Math.ceilDiv(output * x, y - output);
    }

    function _bounded(uint256 value, uint256 minimum, uint256 maximum) private pure returns (uint256) {
        return minimum + (value % (maximum - minimum + 1));
    }
}

/// @notice Bounded quote-level invariants through the production opcode/router.
/// @dev SPEC §9 deliberately excludes additivity (capacity is state-dependent),
///      global symmetry while binding (the cap is non-injective), and cross-block
///      quote equality. The tests below cover their required replacements:
///      exact non-binding inversion, same-state monotonicity, and binding saturation.
contract ReservoirQuoteInvariants is ReserveClampTestBase {
    uint256 private constant BALANCE = 1_000_000e18;

    ISwapVM.Order private order;

    function setUp() public override {
        super.setUp();
        (order,) = _ship(BALANCE, BALANCE);
    }

    function test_NonBindingCoreSmokeMatrixHasZeroRoundTripError() public view {
        uint256[3] memory amounts = [uint256(1e18), uint256(10e18), uint256(50e18)];

        for (uint256 i = 0; i < amounts.length; ++i) {
            (, uint256 output,) = _quote(order, amounts[i], true);
            (uint256 inputBack, uint256 exactOutput,) = _quote(order, output, false);

            assertEq(inputBack, amounts[i]);
            assertEq(exactOutput, output);
        }
    }

    function test_NonBindingEffectivePriceIsMonotonic() public view {
        uint256[3] memory amounts = [uint256(1e18), uint256(10e18), uint256(50e18)];
        uint256 previousRate = type(uint256).max;

        for (uint256 i = 0; i < amounts.length; ++i) {
            (, uint256 output,) = _quote(order, amounts[i], true);
            uint256 rate = output * 1e18 / amounts[i];
            assertLe(rate, previousRate);
            previousRate = rate;
        }
    }

    function test_HeroFixtureStrictlyReducesInput() public {
        uint256 safeCapacity = 100e18;
        uint256 requestedInput = 1000e18;
        maker.setCapacity(address(tokenB), safeCapacity);

        (uint256 actualInput, uint256 actualOutput,) = _quote(order, requestedInput, true);

        assertEq(actualOutput, safeCapacity);
        assertLt(actualInput, requestedInput);
    }

    function testFuzz_BindingExactInSaturatesAndNeverOvercharges(uint128 capacitySeed, uint128 extraInputSeed) public {
        uint256 safeCapacity = _bounded(uint256(capacitySeed), 1e6, BALANCE / 4);
        uint256 firstClippedOutput = safeCapacity + 1;
        uint256 minimumBindingInput = Math.ceilDiv(firstClippedOutput * BALANCE, BALANCE - firstClippedOutput);
        uint256 requestedInput = minimumBindingInput + (uint256(extraInputSeed) % BALANCE);
        maker.setCapacity(address(tokenB), safeCapacity);

        (uint256 actualInput, uint256 actualOutput,) = _quote(order, requestedInput, true);
        uint256 expectedInput = Math.ceilDiv(safeCapacity * BALANCE, BALANCE - safeCapacity);

        assertEq(actualOutput, safeCapacity);
        assertEq(actualInput, expectedInput);
        assertLe(actualInput, requestedInput);
    }

    function testFuzz_BindingSaturationIsConstantForLargerRequests(
        uint128 capacitySeed,
        uint128 extraInputSeed
    )
        public
    {
        uint256 safeCapacity = _bounded(uint256(capacitySeed), 1e6, BALANCE / 4);
        uint256 firstClippedOutput = safeCapacity + 1;
        uint256 firstRequest = Math.ceilDiv(firstClippedOutput * BALANCE, BALANCE - firstClippedOutput);
        uint256 secondRequest = firstRequest + 1 + (uint256(extraInputSeed) % BALANCE);
        maker.setCapacity(address(tokenB), safeCapacity);

        (uint256 firstInput, uint256 firstOutput,) = _quote(order, firstRequest, true);
        (uint256 secondInput, uint256 secondOutput,) = _quote(order, secondRequest, true);

        assertEq(firstOutput, safeCapacity);
        assertEq(secondOutput, safeCapacity);
        assertEq(firstInput, secondInput);
    }

    function testFuzz_ExactOutNeverExceedsCapacity(uint128 capacitySeed, uint128 additionalOutputSeed) public {
        uint256 safeCapacity = _bounded(uint256(capacitySeed), 1, BALANCE / 2);
        uint256 requestedOutput = safeCapacity + 1 + (uint256(additionalOutputSeed) % (BALANCE - safeCapacity - 1));
        maker.setCapacity(address(tokenB), safeCapacity);

        (uint256 actualInput, uint256 actualOutput,) = _quote(order, requestedOutput, false);

        assertEq(actualOutput, safeCapacity);
        assertLt(actualOutput, requestedOutput);
        assertEq(actualInput, Math.ceilDiv(safeCapacity * BALANCE, BALANCE - safeCapacity));
    }

    function _bounded(uint256 value, uint256 minimum, uint256 maximum) private pure returns (uint256) {
        return minimum + (value % (maximum - minimum + 1));
    }
}
