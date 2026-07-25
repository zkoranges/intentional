// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console2 } from "forge-std/console2.sol";

import { V2MainnetOpsBase } from "./V2MainnetOpsBase.sol";

/// @notice Unpauses only a separately funded and independently verified release.
/// @dev This script cannot deploy, transfer, approve, or reinvest capital.
contract ActivateV2Mainnet is V2MainnetOpsBase {
    bytes32 private constant ACK_HASH = keccak256("ACTIVATE_VERIFIED_RESERVOIR_V2");

    function run() external {
        require(
            keccak256(bytes(vm.envString("RESERVOIR_MAINNET_ACK"))) == ACK_HASH, "activation acknowledgement mismatch"
        );
        uint256 minimumCapacity = vm.envUint("MIN_CAPACITY_WEI");
        require(minimumCapacity != 0, "invalid capacity floor");

        LiveDeployment memory deployed = _loadDeployment();
        _requireReviewedBindings(deployed);
        require(!deployed.fundingAccount.isPaused(), "funding must be active");
        require(deployed.settlement.isPaused(), "settlement must begin paused");
        require(IERC20(WETH).balanceOf(address(deployed.fundingAccount)) == 0, "funding retained idle WETH");
        require(IERC20(STATA_WETH).balanceOf(address(deployed.fundingAccount)) != 0, "funding has no shares");
        require(
            deployed.fundingAccount.availableFor(minimumCapacity) == minimumCapacity,
            "minimum funding capacity unavailable"
        );

        vm.startBroadcast();
        deployed.settlement.setPaused(false);
        vm.stopBroadcast();

        require(!deployed.settlement.isPaused(), "settlement remained paused");
        require(
            deployed.fundingAccount.availableFor(minimumCapacity) == minimumCapacity,
            "post-activation capacity unavailable"
        );

        console2.log("RESERVOIR_MAINNET_ACTIVATION_BEGIN");
        console2.log(
            string.concat(
                '{"chainId":1,"releaseState":"active","factor":"',
                vm.toString(deployed.factor),
                '","fundingAccount":"',
                vm.toString(address(deployed.fundingAccount)),
                '","kernel":"',
                vm.toString(address(deployed.settlement)),
                '","minimumCapacityWei":"',
                vm.toString(minimumCapacity),
                '"}'
            )
        );
        console2.log("RESERVOIR_MAINNET_ACTIVATION_END");
    }
}
