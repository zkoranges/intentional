// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "@1inch/swap-vm/src/libs/VM.sol";
import { Opcode } from "@1inch/swap-vm/src/libs/OpcodeList.sol";

import { ReserveClamp } from "../instructions/ReserveClamp.sol";

/// @notice Canonical builder for the v1 Reservoir wrapper and its exact XYC tail.
library ReservoirProgramLib {
    function build() internal pure returns (bytes memory) {
        return build("");
    }

    /// @param prefix Optional complete instructions such as Deadline and Salt.
    function build(bytes memory prefix) internal pure returns (bytes memory) {
        return bytes.concat(prefix, abi.encodePacked(Opcode._92, uint8(0)), abi.encodePacked(Opcode.XYCSwap, uint8(0)));
    }
}

/// @notice Dispatch helper for Reservoir-specific opcodes.
abstract contract ReservoirOpcodes is ReserveClamp {
    uint256 public constant RESERVE_CLAMP_OPCODE = uint256(Opcode._92);

    function _runReservoirOpcode(
        Context memory ctx,
        uint256 opcode,
        bytes calldata args
    )
        internal
        returns (bool handled)
    {
        if (opcode == RESERVE_CLAMP_OPCODE) {
            _reserveClampXD(ctx, args);
            return true;
        }
        return false;
    }
}
