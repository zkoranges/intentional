// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC4626 } from "./MockERC4626.sol";

contract HugeRevertDataERC4626 is MockERC4626 {
    bool public hugeRevertOnDeposit;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockERC4626(asset_, name_, symbol_) { }

    function setHugeRevertOnDeposit(bool enabled) external {
        hugeRevertOnDeposit = enabled;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (hugeRevertOnDeposit) {
            assembly ("memory-safe") {
                let ptr := mload(0x40)
                mstore(ptr, 0x485547455f5245564552545f44415441)
                revert(ptr, 0x10000)
            }
        }
        return super.deposit(assets, receiver);
    }
}
