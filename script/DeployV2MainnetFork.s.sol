// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ERC4626ReserveAdapter } from "../src/adapters/ERC4626ReserveAdapter.sol";
import { AsyncClaimSettlement } from "../src/claims/AsyncClaimSettlement.sol";
import { ProductiveFundingAccount } from "../src/claims/ProductiveFundingAccount.sol";
import { LidoWithdrawalClaimAdapter } from "../src/claims/adapters/LidoWithdrawalClaimAdapter.sol";
import { LidoUnstETHExitAdapter } from "../src/claims/adapters/LidoUnstETHExitAdapter.sol";
import { ILidoWithdrawalQueue } from "../src/claims/interfaces/ILidoWithdrawalQueue.sol";

interface IMainnetWETH is IERC20 {
    function deposit() external payable;
}

interface IMainnetStETH is IERC20 {
    function submit(address referral) external payable returns (uint256 sharesAmount);
}

/// @notice Deploys the exact live Lido/Aave product bytecode on a chain-1 fork.
/// @dev This script refuses every other chain. It is used only by the
///      disposable production rehearsal and never writes a secret to output.
contract DeployV2MainnetFork is Script {
    uint256 private constant PINNED_BLOCK = 25_612_678;
    uint256 private constant FUNDING_WETH = 5 ether;
    uint256 private constant SELLER_STAKE_ETH = 1 ether;

    address private constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant STATA_WETH = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;
    address private constant QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    address private constant AQUA = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;

    function run() external {
        require(block.chainid == 1, "chain 1 fork required");
        require(block.number == PINNED_BLOCK, "pinned fork block required");
        require(STETH.code.length != 0, "canonical stETH missing");
        require(WETH.code.length != 0, "canonical WETH missing");
        require(STATA_WETH.code.length != 0, "canonical StataWETH missing");
        require(QUEUE.code.length != 0, "canonical Lido queue missing");
        require(AQUA.code.length != 0, "canonical Aqua missing");

        uint256 factorKey = vm.envUint("FACTOR_PRIVATE_KEY");
        uint256 sellerKey = vm.envUint("SELLER_PRIVATE_KEY");
        address factor = vm.addr(factorKey);
        address seller = vm.addr(sellerKey);
        IMainnetWETH weth = IMainnetWETH(WETH);
        IMainnetStETH stETH = IMainnetStETH(STETH);

        vm.startBroadcast(factorKey);
        ProductiveFundingAccount fundingAccount = new ProductiveFundingAccount(factor);
        ERC4626ReserveAdapter reserveAdapter =
            new ERC4626ReserveAdapter(address(fundingAccount), IERC4626(STATA_WETH), 0, 0);
        fundingAccount.configureReserve(reserveAdapter);
        AsyncClaimSettlement settlement = new AsyncClaimSettlement(factor, fundingAccount);
        LidoWithdrawalClaimAdapter lidoAdapter =
            new LidoWithdrawalClaimAdapter(address(settlement), IERC20(STETH), ILidoWithdrawalQueue(QUEUE));
        LidoUnstETHExitAdapter lidoUnstETHExitAdapter =
            new LidoUnstETHExitAdapter(address(settlement), IERC20(STETH), ILidoWithdrawalQueue(QUEUE));

        weth.deposit{ value: FUNDING_WETH }();
        require(weth.transfer(address(fundingAccount), FUNDING_WETH), "WETH funding transfer failed");
        fundingAccount.prepareInventory();
        fundingAccount.configureSettlement(address(settlement));
        fundingAccount.seal();
        settlement.allowAdapter(address(lidoAdapter));
        settlement.allowAdapter(address(lidoUnstETHExitAdapter));
        settlement.seal();
        vm.stopBroadcast();

        vm.startBroadcast(sellerKey);
        stETH.submit{ value: SELLER_STAKE_ETH }(address(0));
        vm.stopBroadcast();

        require(weth.balanceOf(address(fundingAccount)) == 0, "funding account retained idle WETH");
        require(IERC4626(STATA_WETH).balanceOf(address(fundingAccount)) != 0, "funding account received no shares");
        require(fundingAccount.availableFor(FUNDING_WETH - 1) == FUNDING_WETH - 1, "reserve unavailable");
        require(stETH.balanceOf(seller) > 0.9 ether, "seller received insufficient stETH");
        require(settlement.factorSigner() == factor, "factor binding mismatch");
        require(settlement.isAdapterAllowed(address(lidoAdapter)), "adapter not allowed");
        require(settlement.isAdapterAllowed(address(lidoUnstETHExitAdapter)), "unstETH adapter not allowed");

        console2.log("RESERVOIR_LIVE_DEPLOYMENT_BEGIN");
        console2.log(
            string.concat(
                '{"chainId":1,"factor":"',
                vm.toString(factor),
                '","seller":"',
                vm.toString(seller),
                '","fundingAccount":"',
                vm.toString(address(fundingAccount)),
                '","reserveAdapter":"',
                vm.toString(address(reserveAdapter)),
                '","kernel":"',
                vm.toString(address(settlement)),
                '","lidoAdapter":"',
                vm.toString(address(lidoAdapter)),
                '","lidoUnstETHExitAdapter":"',
                vm.toString(address(lidoUnstETHExitAdapter)),
                '","fundingCodeHash":"',
                vm.toString(address(fundingAccount).codehash),
                '","reserveCodeHash":"',
                vm.toString(address(reserveAdapter).codehash),
                '","kernelCodeHash":"',
                vm.toString(address(settlement).codehash),
                '","lidoAdapterCodeHash":"',
                vm.toString(address(lidoAdapter).codehash),
                '","lidoUnstETHExitAdapterCodeHash":"',
                vm.toString(address(lidoUnstETHExitAdapter).codehash),
                '","paymentAsset":"',
                vm.toString(WETH),
                '","vault":"',
                vm.toString(STATA_WETH),
                '","stETH":"',
                vm.toString(STETH),
                '","queue":"',
                vm.toString(QUEUE),
                '","aqua":"',
                vm.toString(AQUA),
                '","fundingWei":"',
                vm.toString(FUNDING_WETH),
                '","sellerStETHWei":"',
                vm.toString(stETH.balanceOf(seller)),
                '"}'
            )
        );
        console2.log("RESERVOIR_LIVE_DEPLOYMENT_END");
    }
}
