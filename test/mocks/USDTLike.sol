// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MockERC20 } from "./MockERC20.sol";

contract USDTLike is MockERC20 {
    error NonzeroAllowanceMustBeCleared(address owner, address spender, uint256 currentAllowance);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) { }

    function approve(address spender, uint256 value) public override returns (bool) {
        uint256 currentAllowance = allowance(msg.sender, spender);
        if (value != 0 && currentAllowance != 0) {
            revert NonzeroAllowanceMustBeCleared(msg.sender, spender, currentAllowance);
        }
        return super.approve(spender, value);
    }
}
