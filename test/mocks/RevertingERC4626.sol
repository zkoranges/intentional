// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC4626 } from "./MockERC4626.sol";

contract RevertingERC4626 is MockERC4626 {
    error ForcedVaultRevert(bytes4 selector);

    bool public revertMaxWithdraw;
    bool public revertMaxDeposit;
    bool public revertPreviewDeposit;
    bool public revertDeposit;
    bool public revertWithdraw;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockERC4626(asset_, name_, symbol_) { }

    function setRevertMaxWithdraw(bool enabled) external {
        revertMaxWithdraw = enabled;
    }

    function setRevertMaxDeposit(bool enabled) external {
        revertMaxDeposit = enabled;
    }

    function setRevertPreviewDeposit(bool enabled) external {
        revertPreviewDeposit = enabled;
    }

    function setRevertDeposit(bool enabled) external {
        revertDeposit = enabled;
    }

    function setRevertWithdraw(bool enabled) external {
        revertWithdraw = enabled;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (revertMaxWithdraw) {
            revert ForcedVaultRevert(this.maxWithdraw.selector);
        }
        return super.maxWithdraw(owner);
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (revertMaxDeposit) {
            revert ForcedVaultRevert(this.maxDeposit.selector);
        }
        return super.maxDeposit(receiver);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        if (revertPreviewDeposit) {
            revert ForcedVaultRevert(this.previewDeposit.selector);
        }
        return super.previewDeposit(assets);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (revertDeposit) {
            revert ForcedVaultRevert(this.deposit.selector);
        }
        return super.deposit(assets, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (revertWithdraw) {
            revert ForcedVaultRevert(this.withdraw.selector);
        }
        return super.withdraw(assets, receiver, owner);
    }
}
