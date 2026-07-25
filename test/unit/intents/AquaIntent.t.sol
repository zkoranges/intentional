// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";

import { TakerTraits, TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { AquaIntentLib, ExactInAquaIntent } from "../../../src/intents/AquaIntent.sol";

contract AquaIntentHarness {
    using AquaIntentLib for ExactInAquaIntent;
    using TakerTraitsLib for TakerTraits;

    function build(ExactInAquaIntent memory intent) external pure returns (bytes memory) {
        return intent.buildTakerTraits();
    }

    function decode(bytes calldata packed)
        external
        pure
        returns (bool exactIn, bool pushToAqua, bool aToB, address recipient, uint40 deadline, uint256 minimum)
    {
        (TakerTraits traits, bytes calldata data) = TakerTraitsLib.parse(packed);
        (bool hasMinimum, uint256 decodedMinimum) = traits.threshold(data);
        require(hasMinimum, "missing minimum");
        return (
            traits.isExactIn(),
            traits.useTransferFromAndAquaPush(),
            traits.isAToB(),
            traits.to(data, address(0xdead)),
            traits.deadline(data),
            decodedMinimum
        );
    }
}

contract AquaIntentTest is Test {
    AquaIntentHarness private harness;

    function setUp() public {
        harness = new AquaIntentHarness();
    }

    function test_BuildsExplicitProductionTraits() public {
        address recipient = makeAddr("recipient");
        ExactInAquaIntent memory intent = _validIntent(recipient);
        (bool exactIn, bool pushToAqua, bool aToB, address decodedRecipient, uint40 deadline, uint256 minimum) =
            harness.decode(harness.build(intent));

        assertTrue(exactIn, "intent is not exact input");
        assertTrue(pushToAqua, "input is not pushed to Aqua");
        assertTrue(aToB, "direction changed");
        assertEq(decodedRecipient, recipient, "recipient is not explicit");
        assertEq(deadline, intent.deadline, "deadline changed");
        assertEq(minimum, intent.minAmountOut, "minimum changed");
    }

    function test_RevertsForZeroRecipient() public {
        ExactInAquaIntent memory intent = _validIntent(address(0));
        vm.expectRevert(AquaIntentLib.InvalidIntentRecipient.selector);
        harness.build(intent);
    }

    function test_RevertsForZeroAmount() public {
        ExactInAquaIntent memory intent = _validIntent(makeAddr("recipient"));
        intent.amountIn = 0;
        vm.expectRevert(AquaIntentLib.InvalidIntentAmount.selector);
        harness.build(intent);
    }

    function test_RevertsForZeroMinimum() public {
        ExactInAquaIntent memory intent = _validIntent(makeAddr("recipient"));
        intent.minAmountOut = 0;
        vm.expectRevert(AquaIntentLib.InvalidIntentMinimum.selector);
        harness.build(intent);
    }

    function test_RevertsForZeroDeadline() public {
        ExactInAquaIntent memory intent = _validIntent(makeAddr("recipient"));
        intent.deadline = 0;
        vm.expectRevert(AquaIntentLib.InvalidIntentDeadline.selector);
        harness.build(intent);
    }

    function _validIntent(address recipient) private pure returns (ExactInAquaIntent memory) {
        return ExactInAquaIntent({
            recipient: recipient, amountIn: 0.01 ether, minAmountOut: 0.009 ether, deadline: 1_800_000_000, isAToB: true
        });
    }
}
