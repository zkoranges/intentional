// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice stETH-shaped test token with a one-shot transfer-rounding shortfall.
contract MockStETH is ERC20 {
    error ShortfallExceedsTransfer(uint256 shortfall, uint256 amount);
    error NonzeroAllowanceMustBeCleared(address owner, address spender, uint256 currentAllowance);

    uint256 public nextTransferShortfall;
    bool public requireZeroFirstApproval;

    constructor() ERC20("Mock staked Ether", "mstETH") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function submit(address) external payable returns (uint256 shares) {
        shares = msg.value;
        _mint(msg.sender, shares);
    }

    function sharesOf(address account) external view returns (uint256 shares) {
        return balanceOf(account);
    }

    function transferShares(address recipient, uint256 sharesAmount) external returns (uint256 tokensAmount) {
        _transfer(msg.sender, recipient, sharesAmount);
        return sharesAmount;
    }

    function setNextTransferShortfall(uint256 shortfall) external {
        nextTransferShortfall = shortfall;
    }

    function setRequireZeroFirstApproval(bool required) external {
        requireZeroFirstApproval = required;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        uint256 currentAllowance = allowance(msg.sender, spender);
        if (requireZeroFirstApproval && value != 0 && currentAllowance != 0) {
            revert NonzeroAllowanceMustBeCleared(msg.sender, spender, currentAllowance);
        }
        return super.approve(spender, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 shortfall = nextTransferShortfall;
        if (from == address(0) || to == address(0) || shortfall == 0) {
            super._update(from, to, value);
            return;
        }
        if (shortfall > value) {
            revert ShortfallExceedsTransfer(shortfall, value);
        }

        nextTransferShortfall = 0;
        unchecked {
            super._update(from, to, value - shortfall);
        }
    }
}
