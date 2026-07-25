// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { console2 } from "forge-std/console2.sol";

import { ERC4626ReserveAdapter } from "../src/adapters/ERC4626ReserveAdapter.sol";
import { AsyncClaimSettlement } from "../src/claims/AsyncClaimSettlement.sol";
import { ProductiveFundingAccount } from "../src/claims/ProductiveFundingAccount.sol";
import { LidoWithdrawalClaimAdapter } from "../src/claims/adapters/LidoWithdrawalClaimAdapter.sol";
import { ILidoWithdrawalQueue } from "../src/claims/interfaces/ILidoWithdrawalQueue.sol";
import { V2MainnetOpsBase } from "./V2MainnetOpsBase.sol";

/// @notice Deploys the reviewed Reservoir v2 release paused and unfunded.
/// @dev Nothing is broadcast unless the operator separately passes Foundry's
///      `--broadcast` flag. Funding and activation use different scripts and
///      acknowledgements so deployment cannot silently move reserve capital.
contract DeployV2Mainnet is V2MainnetOpsBase {
    bytes32 private constant ACK_HASH = keccak256("DEPLOY_PAUSED_UNFUNDED_RESERVOIR_V2");

    function run() external {
        require(block.chainid == 1, "Ethereum mainnet required");
        require(
            keccak256(bytes(vm.envString("RESERVOIR_MAINNET_ACK"))) == ACK_HASH, "deployment acknowledgement mismatch"
        );
        _requireCanonicalCode();

        address factor = vm.envAddress("FACTOR_ADDRESS");
        require(factor != address(0) && factor.code.length == 0, "code-free factor EOA required");

        vm.startBroadcast();
        ProductiveFundingAccount fundingAccount = new ProductiveFundingAccount(factor);
        ERC4626ReserveAdapter reserveAdapter =
            new ERC4626ReserveAdapter(address(fundingAccount), IERC4626(STATA_WETH), 0, 0);
        fundingAccount.configureReserve(reserveAdapter);

        AsyncClaimSettlement settlement = new AsyncClaimSettlement(factor, fundingAccount);
        LidoWithdrawalClaimAdapter lidoAdapter =
            new LidoWithdrawalClaimAdapter(address(settlement), IERC20(STETH), ILidoWithdrawalQueue(QUEUE));

        fundingAccount.configureSettlement(address(settlement));
        fundingAccount.setPaused(true);
        fundingAccount.seal();

        settlement.allowAdapter(address(lidoAdapter));
        settlement.setPaused(true);
        settlement.seal();
        vm.stopBroadcast();

        require(fundingAccount.factor() == factor, "factor binding mismatch");
        require(address(fundingAccount.paymentAsset()) == WETH, "payment asset mismatch");
        require(address(fundingAccount.vault()) == STATA_WETH, "funding vault mismatch");
        require(address(fundingAccount.reserveAdapter()) == address(reserveAdapter), "reserve adapter mismatch");
        require(fundingAccount.settlement() == address(settlement), "settlement binding mismatch");
        require(fundingAccount.isSealed() && fundingAccount.isPaused(), "funding not sealed and paused");
        require(settlement.factorSigner() == factor, "settlement factor mismatch");
        require(settlement.adapterCount() == 1 && settlement.nonceFloor() == 0, "kernel state mismatch");
        require(settlement.isAdapterAllowed(address(lidoAdapter)), "Lido adapter not allowed");
        require(settlement.isSealed() && settlement.isPaused(), "settlement not sealed and paused");
        require(IERC20(WETH).balanceOf(address(fundingAccount)) == 0, "unexpected idle WETH");
        require(IERC20(STATA_WETH).balanceOf(address(fundingAccount)) == 0, "unexpected vault shares");
        require(fundingAccount.availableFor(1) == 0, "paused deployment exposed capacity");

        console2.log("RESERVOIR_MAINNET_DEPLOYMENT_BEGIN");
        console2.log(
            string.concat(
                '{"chainId":1,"releaseState":"paused-unfunded","factor":"',
                vm.toString(factor),
                '","fundingAccount":"',
                vm.toString(address(fundingAccount)),
                '","reserveAdapter":"',
                vm.toString(address(reserveAdapter)),
                '","kernel":"',
                vm.toString(address(settlement)),
                '","lidoAdapter":"',
                vm.toString(address(lidoAdapter)),
                '","fundingCodeHash":"',
                vm.toString(address(fundingAccount).codehash),
                '","reserveCodeHash":"',
                vm.toString(address(reserveAdapter).codehash),
                '","kernelCodeHash":"',
                vm.toString(address(settlement).codehash),
                '","lidoAdapterCodeHash":"',
                vm.toString(address(lidoAdapter).codehash),
                '","paymentAsset":"',
                vm.toString(WETH),
                '","vault":"',
                vm.toString(STATA_WETH),
                '","stETH":"',
                vm.toString(STETH),
                '","queue":"',
                vm.toString(QUEUE),
                '"}'
            )
        );
        console2.log("RESERVOIR_MAINNET_DEPLOYMENT_END");
    }

    function _requireCanonicalCode() private view {
        require(STETH.code.length != 0, "canonical stETH missing");
        require(WETH.code.length != 0, "canonical WETH missing");
        require(STATA_WETH.code.length != 0, "canonical StataWETH missing");
        require(QUEUE.code.length != 0, "canonical Lido queue missing");
        require(IERC4626(STATA_WETH).asset() == WETH, "StataWETH asset mismatch");
    }
}
