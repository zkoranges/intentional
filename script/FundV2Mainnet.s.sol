// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { console2 } from "forge-std/console2.sol";

import { ILidoWithdrawalQueue } from "../src/claims/interfaces/ILidoWithdrawalQueue.sol";
import { V2MainnetOpsBase } from "./V2MainnetOpsBase.sol";

/// @notice Funds an exact reviewed deployment while settlement remains paused.
contract FundV2Mainnet is V2MainnetOpsBase {
    using SafeERC20 for IERC20;

    bytes32 private constant ACK_HASH = keccak256("FUND_PAUSED_RESERVOIR_V2");
    uint256 public constant MIN_JURY_FUNDING = 0.002 ether;
    uint256 public constant MAX_JURY_FUNDING = 5 ether;

    function run() external {
        require(keccak256(bytes(vm.envString("RESERVOIR_MAINNET_ACK"))) == ACK_HASH, "funding acknowledgement mismatch");
        uint256 fundingAmount = vm.envUint("FUNDING_WETH_WEI");
        uint256 minimumCapacity = vm.envUint("MIN_CAPACITY_WEI");
        require(fundingAmount >= MIN_JURY_FUNDING && fundingAmount <= MAX_JURY_FUNDING, "funding outside jury bounds");
        require(minimumCapacity != 0 && minimumCapacity <= fundingAmount, "invalid capacity floor");

        LiveDeployment memory deployed = _loadDeployment();
        _requireReviewedBindings(deployed);
        require(deployed.fundingAccount.isPaused() && deployed.settlement.isPaused(), "deployment must begin paused");
        require(IERC20(WETH).balanceOf(address(deployed.fundingAccount)) == 0, "funding account has idle WETH");
        require(
            IERC20(STATA_WETH).balanceOf(address(deployed.fundingAccount)) == 0, "funding account already has shares"
        );
        require(IERC20(WETH).balanceOf(deployed.factor) >= fundingAmount, "factor has insufficient WETH");
        require(
            IERC4626(STATA_WETH).maxDeposit(address(deployed.fundingAccount)) >= fundingAmount,
            "vault deposit constrained"
        );
        require(!ILidoWithdrawalQueue(QUEUE).isPaused(), "canonical Lido withdrawals paused");

        vm.startBroadcast();
        IERC20(WETH).safeTransfer(address(deployed.fundingAccount), fundingAmount);
        deployed.fundingAccount.setPaused(false);
        deployed.fundingAccount.reinvestInventory();
        vm.stopBroadcast();

        uint256 shares = IERC20(STATA_WETH).balanceOf(address(deployed.fundingAccount));
        uint256 nav = IERC4626(STATA_WETH).convertToAssets(shares);
        require(!deployed.fundingAccount.isPaused(), "funding remained paused");
        require(deployed.settlement.isPaused(), "settlement activated during funding");
        require(IERC20(WETH).balanceOf(address(deployed.fundingAccount)) == 0, "funding retained idle WETH");
        require(shares != 0, "funding minted no vault shares");
        require(
            deployed.fundingAccount.availableFor(minimumCapacity) == minimumCapacity,
            "minimum funding capacity unavailable"
        );

        console2.log("RESERVOIR_MAINNET_FUNDING_BEGIN");
        console2.log(
            string.concat(
                '{"chainId":1,"releaseState":"funded-paused","factor":"',
                vm.toString(deployed.factor),
                '","fundingAccount":"',
                vm.toString(address(deployed.fundingAccount)),
                '","kernel":"',
                vm.toString(address(deployed.settlement)),
                '","fundingWei":"',
                vm.toString(fundingAmount),
                '","minimumCapacityWei":"',
                vm.toString(minimumCapacity),
                '","vaultShares":"',
                vm.toString(shares),
                '","reserveNavWei":"',
                vm.toString(nav),
                '"}'
            )
        );
        console2.log("RESERVOIR_MAINNET_FUNDING_END");
    }
}
