// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { AquaSwapVMRouter } from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import { Context } from "@1inch/swap-vm/src/libs/VM.sol";

import { ReservoirOpcodes } from "../opcodes/ReservoirOpcodes.sol";

/// @notice Aqua SwapVM router extended with Reservoir's reserve-capacity wrapper.
contract ReservoirSwapVMRouter is AquaSwapVMRouter, ReservoirOpcodes {
    constructor(
        address aqua,
        address weth,
        address owner,
        string memory name,
        string memory version
    )
        AquaSwapVMRouter(aqua, weth, owner, name, version)
    { }

    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual override {
        if (!_runReservoirOpcode(ctx, opcode, args)) {
            super._runOpcode(ctx, opcode, args);
        }
    }
}
