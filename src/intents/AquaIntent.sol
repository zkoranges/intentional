// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

/// @notice Transaction-native exact-input intent accepted against an
///         Aqua-authorized SwapVM strategy.
/// @dev The maker authorizes the reusable order by shipping its hash and
///      balances to Aqua. The transaction sender is the taker and authorizes
///      this fill by submitting it; `recipient`, `amountIn`, `minAmountOut`,
///      and `deadline` define the execution requested by the caller.
struct ExactInAquaIntent {
    address recipient;
    uint256 amountIn;
    uint256 minAmountOut;
    uint40 deadline;
    bool isAToB;
}

library AquaIntentLib {
    error InvalidIntentRecipient();
    error InvalidIntentAmount();
    error InvalidIntentMinimum();
    error InvalidIntentDeadline();

    function buildTakerTraits(ExactInAquaIntent memory intent) internal pure returns (bytes memory) {
        if (intent.recipient == address(0)) {
            revert InvalidIntentRecipient();
        }
        if (intent.amountIn == 0) {
            revert InvalidIntentAmount();
        }
        if (intent.minAmountOut == 0) {
            revert InvalidIntentMinimum();
        }
        if (intent.deadline == 0) {
            revert InvalidIntentDeadline();
        }

        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                // SwapVM derives the taker from msg.sender. Supplying zero here
                // ensures every nonzero recipient is encoded explicitly.
                taker: address(0),
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                isAToB: intent.isAToB,
                threshold: abi.encode(intent.minAmountOut),
                to: intent.recipient,
                deadline: intent.deadline,
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
