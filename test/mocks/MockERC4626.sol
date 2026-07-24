// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockERC4626 is ERC4626 {
    uint256 public withdrawLimit = type(uint256).max;
    uint256 public depositLimit = type(uint256).max;
    bool public previewDepositZero;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) { }

    function setWithdrawLimit(uint256 limit) external {
        withdrawLimit = limit;
    }

    function setDepositLimit(uint256 limit) external {
        depositLimit = limit;
    }

    function setPreviewDepositZero(bool enabled) external {
        previewDepositZero = enabled;
    }

    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), withdrawLimit);
    }

    function maxDeposit(address) public view virtual override returns (uint256) {
        return depositLimit;
    }

    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        return previewDepositZero ? 0 : super.previewDeposit(assets);
    }
}

contract HeroERC4626 is MockERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockERC4626(asset_, name_, symbol_) { }

    function accrueYield(uint256 assets) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
    }
}
