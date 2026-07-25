// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";

import { ERC4626ReserveAdapter } from "../src/adapters/ERC4626ReserveAdapter.sol";
import { AsyncClaimSettlement } from "../src/claims/AsyncClaimSettlement.sol";
import { ProductiveFundingAccount } from "../src/claims/ProductiveFundingAccount.sol";
import { LidoWithdrawalClaimAdapter } from "../src/claims/adapters/LidoWithdrawalClaimAdapter.sol";

abstract contract V2MainnetOpsBase is Script {
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant STATA_WETH = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;
    address internal constant QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    struct LiveDeployment {
        address factor;
        ProductiveFundingAccount fundingAccount;
        ERC4626ReserveAdapter reserveAdapter;
        AsyncClaimSettlement settlement;
        LidoWithdrawalClaimAdapter lidoAdapter;
        bytes32 fundingCodeHash;
        bytes32 reserveCodeHash;
        bytes32 kernelCodeHash;
        bytes32 lidoAdapterCodeHash;
    }

    function _loadDeployment() internal view returns (LiveDeployment memory deployed) {
        deployed.factor = vm.envAddress("FACTOR_ADDRESS");
        deployed.fundingAccount = ProductiveFundingAccount(vm.envAddress("FUNDING_ACCOUNT_ADDRESS"));
        deployed.reserveAdapter = ERC4626ReserveAdapter(vm.envAddress("RESERVE_ADAPTER_ADDRESS"));
        deployed.settlement = AsyncClaimSettlement(vm.envAddress("KERNEL_ADDRESS"));
        deployed.lidoAdapter = LidoWithdrawalClaimAdapter(vm.envAddress("LIDO_ADAPTER_ADDRESS"));
        deployed.fundingCodeHash = vm.envBytes32("EXPECTED_FUNDING_CODEHASH");
        deployed.reserveCodeHash = vm.envBytes32("EXPECTED_RESERVE_CODEHASH");
        deployed.kernelCodeHash = vm.envBytes32("EXPECTED_KERNEL_CODEHASH");
        deployed.lidoAdapterCodeHash = vm.envBytes32("EXPECTED_LIDO_ADAPTER_CODEHASH");
    }

    function _requireReviewedBindings(LiveDeployment memory deployed) internal view {
        require(block.chainid == 1, "Ethereum mainnet required");
        require(deployed.factor != address(0) && deployed.factor.code.length == 0, "code-free factor EOA required");
        require(address(deployed.fundingAccount).codehash == deployed.fundingCodeHash, "funding codehash mismatch");
        require(address(deployed.reserveAdapter).codehash == deployed.reserveCodeHash, "reserve codehash mismatch");
        require(address(deployed.settlement).codehash == deployed.kernelCodeHash, "kernel codehash mismatch");
        require(
            address(deployed.lidoAdapter).codehash == deployed.lidoAdapterCodeHash, "Lido adapter codehash mismatch"
        );

        require(deployed.fundingAccount.factor() == deployed.factor, "funding factor mismatch");
        require(address(deployed.fundingAccount.paymentAsset()) == WETH, "payment asset mismatch");
        require(address(deployed.fundingAccount.vault()) == STATA_WETH, "funding vault mismatch");
        require(
            address(deployed.fundingAccount.reserveAdapter()) == address(deployed.reserveAdapter),
            "reserve adapter mismatch"
        );
        require(deployed.fundingAccount.settlement() == address(deployed.settlement), "funding settlement mismatch");
        require(deployed.fundingAccount.isSealed(), "funding not sealed");

        require(deployed.reserveAdapter.makerAccount() == address(deployed.fundingAccount), "reserve maker mismatch");
        require(deployed.reserveAdapter.asset() == WETH, "reserve asset mismatch");
        require(address(deployed.reserveAdapter.vault()) == STATA_WETH, "reserve vault mismatch");
        require(deployed.reserveAdapter.idleThreshold(WETH) == 0, "reserve threshold mismatch");
        require(deployed.reserveAdapter.liquidityBufferAssets() == 0, "reserve buffer mismatch");

        require(deployed.settlement.factorSigner() == deployed.factor, "kernel factor mismatch");
        require(
            address(deployed.settlement.fundingAccount()) == address(deployed.fundingAccount), "kernel funding mismatch"
        );
        require(deployed.settlement.isSealed(), "kernel not sealed");
        require(deployed.settlement.adapterCount() == 1, "unexpected adapter count");
        require(deployed.settlement.nonceFloor() == 0, "unexpected nonce floor");
        require(deployed.settlement.isAdapterAllowed(address(deployed.lidoAdapter)), "Lido adapter not allowed");

        require(deployed.lidoAdapter.settlement() == address(deployed.settlement), "adapter kernel mismatch");
        require(address(deployed.lidoAdapter.stETH()) == STETH, "adapter stETH mismatch");
        require(address(deployed.lidoAdapter.queue()) == QUEUE, "adapter queue mismatch");
    }
}
