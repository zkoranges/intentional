// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice External ERC-7575 share token controlled by one test vault.
contract MockERC7575Share is ERC20 {
    error InvalidVault(address supplied);
    error OnlyVault(address caller);

    address public immutable vault;

    modifier onlyVault() {
        if (msg.sender != vault) {
            revert OnlyVault(msg.sender);
        }
        _;
    }

    constructor(address vault_) ERC20("Mock ERC-7575 Share", "m7540") {
        if (vault_ == address(0)) {
            revert InvalidVault(vault_);
        }
        vault = vault_;
    }

    function mint(address receiver, uint256 shares) external onlyVault {
        _mint(receiver, shares);
    }

    function burnForRequest(address owner, address spender, uint256 shares, bool spendAllowance) external onlyVault {
        if (spendAllowance) {
            _spendAllowance(owner, spender, shares);
        }
        _burn(owner, shares);
    }
}
