// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC4626 } from "./MockERC4626.sol";

contract GasBurningERC4626 is MockERC4626 {
    bool public burnOnDeposit;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockERC4626(asset_, name_, symbol_) { }

    function setBurnOnDeposit(bool enabled) external {
        burnOnDeposit = enabled;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (burnOnDeposit) {
            assembly ("memory-safe") {
                for { } 1 { } { pop(gas()) }
            }
        }
        return super.deposit(assets, receiver);
    }
}
