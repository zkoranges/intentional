// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/0817db4a618d975648e018222aedcdeb1206959e/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { ReservoirMakerAccount } from "../src/accounts/ReservoirMakerAccount.sol";
import { ERC4626ReserveAdapter } from "../src/adapters/ERC4626ReserveAdapter.sol";
import { ReservoirProgramLib } from "../src/opcodes/ReservoirOpcodes.sol";
import { ReservoirSwapVMRouter } from "../src/routers/ReservoirSwapVMRouter.sol";

interface ILidoStETHDeploy is IERC20 {
    function submit(address referral) external payable returns (uint256 sharesAmount);
}

interface ILidoWstETHDeploy is IERC20 {
    function wrap(uint256 stETHAmount) external returns (uint256 wstETHAmount);
}

interface IMainnetWETHDeploy is IERC20 {
    function deposit() external payable;
}

interface IStataMetadataDeploy {
    function aToken() external view returns (address);
}

/// @notice Deploys the disposable Reservoir v1 Aqua maker on Ethereum mainnet,
///         seeds micro inventory through canonical Lido and WETH entry points,
///         and ships the productive-reserve strategy to canonical Aqua.
/// @dev The maker account is disposable by design: seeded inventory can only
///      move through fills of the shipped strategy, never be withdrawn. Keep
///      seeds at micro scale.
contract DeployAquaIntentMainnet is Script {
    using SafeERC20 for IERC20;

    bytes32 private constant ACK_HASH = keccak256("DEPLOY_AQUA_INTENT_RESERVOIR_V1");

    address private constant CANONICAL_AQUA = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;
    address private constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant STATA_WSTETH = 0x322AA5F5Be95644d6c36544B6c5061F072D16DF5;
    address private constant STATA_WETH = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;

    uint32 private constant REINVEST_GAS_LIMIT = 500_000;
    uint256 private constant MIN_SEED_WEI = 0.0001 ether;
    uint256 private constant MAX_SEED_WEI = 0.01 ether;

    function run() external {
        require(
            keccak256(bytes(vm.envString("RESERVOIR_MAINNET_ACK"))) == ACK_HASH,
            "aqua intent deployment acknowledgement mismatch"
        );
        require(block.chainid == 1, "Ethereum mainnet required");

        address operator = vm.envAddress("FACTOR_ADDRESS");
        uint256 seedWstEthWei = vm.envUint("SEED_WSTETH_ETH_WEI");
        uint256 seedWethWei = vm.envUint("SEED_WETH_WEI");
        uint256 takerInputEthWei = vm.envUint("TAKER_INPUT_ETH_WEI");
        require(
            seedWstEthWei >= MIN_SEED_WEI && seedWstEthWei <= MAX_SEED_WEI && seedWethWei >= MIN_SEED_WEI
                && seedWethWei <= MAX_SEED_WEI,
            "seed outside micro-jury bounds"
        );
        require(takerInputEthWei != 0 && takerInputEthWei <= seedWstEthWei / 10, "taker input outside micro bounds");
        require(
            operator.balance >= seedWstEthWei + seedWethWei + takerInputEthWei, "operator balance below staging total"
        );

        _validateCanonicalContracts();

        // The router is deployed beforehand with `cast send --create` because
        // forge's broadcast encoder nondeterministically mismatches this
        // contract's creation code against its parent artifact when decoding
        // string constructor args. The script binds to and validates the
        // pre-deployed instance instead.
        ReservoirSwapVMRouter router = ReservoirSwapVMRouter(payable(vm.envAddress("AQUA_ROUTER_ADDRESS")));
        require(address(router).code.length != 0, "pre-deployed router code missing");
        require(address(router.AQUA()) == CANONICAL_AQUA, "router is not bound to canonical Aqua");
        bytes32 expectedRouterCodehash = vm.envOr("EXPECTED_ROUTER_CODEHASH", bytes32(0));
        if (expectedRouterCodehash != bytes32(0)) {
            require(address(router).codehash == expectedRouterCodehash, "router runtime codehash mismatch");
        }

        vm.startBroadcast();

        ReservoirMakerAccount maker = new ReservoirMakerAccount(operator, Aqua(CANONICAL_AQUA));
        ERC4626ReserveAdapter wstETHAdapter = new ERC4626ReserveAdapter(address(maker), IERC4626(STATA_WSTETH), 0, 0);
        ERC4626ReserveAdapter wethAdapter = new ERC4626ReserveAdapter(address(maker), IERC4626(STATA_WETH), 0, 0);

        maker.configureRouter(ISwapVM(address(router)));
        maker.configureReserve(WSTETH, wstETHAdapter, REINVEST_GAS_LIMIT);
        maker.configureReserve(WETH, wethAdapter, REINVEST_GAS_LIMIT);

        uint256 wstETHReceived = _stakeAndWrap(operator, seedWstEthWei);
        IERC20(WSTETH).safeTransfer(address(maker), wstETHReceived);
        uint256 takerWstETH = _stakeAndWrap(operator, takerInputEthWei);

        IMainnetWETHDeploy(WETH).deposit{ value: seedWethWei }();
        IERC20(WETH).safeTransfer(address(maker), seedWethWei);

        maker.prepareInventory(WSTETH);
        maker.prepareInventory(WETH);

        uint256 virtualWstETH = maker.navOf(WSTETH);
        uint256 virtualWeth = maker.navOf(WETH);
        require(virtualWstETH != 0 && virtualWeth != 0, "seeded NAV is zero");

        (ISwapVM.Order memory order, bytes32 strategyHash) =
            maker.sealAndShip(ReservoirProgramLib.build(), virtualWstETH, virtualWeth);

        vm.stopBroadcast();

        require(maker.isSealed(), "maker did not seal");
        require(maker.tokenA() == WSTETH && maker.tokenB() == WETH, "unexpected sorted token pair");
        require(router.hash(order) == strategyHash, "strategy hash mismatch after ship");
        require(IERC20(WSTETH).balanceOf(address(maker)) == 0, "maker retained idle wstETH");
        require(IERC20(WETH).balanceOf(address(maker)) == 0, "maker retained idle WETH");
        (uint256 aquaWstETH, uint256 aquaWeth) =
            Aqua(CANONICAL_AQUA).safeBalances(address(maker), address(router), strategyHash, WSTETH, WETH);
        require(aquaWstETH == virtualWstETH && aquaWeth == virtualWeth, "Aqua virtual balances mismatch");

        string memory manifestHead = string.concat(
            '{"chainId":1,"operator":"',
            vm.toString(operator),
            '","router":"',
            vm.toString(address(router)),
            '","maker":"',
            vm.toString(address(maker)),
            '","wstETHAdapter":"',
            vm.toString(address(wstETHAdapter)),
            '","wethAdapter":"',
            vm.toString(address(wethAdapter))
        );
        string memory manifestTail = string.concat(
            '","strategyHash":"',
            vm.toString(strategyHash),
            '","virtualWstETHWei":"',
            vm.toString(virtualWstETH),
            '","virtualWethWei":"',
            vm.toString(virtualWeth),
            '","takerWstETHWei":"',
            vm.toString(takerWstETH),
            '"}'
        );
        console2.log("RESERVOIR_AQUA_INTENT_DEPLOYMENT_BEGIN");
        console2.log(string.concat(manifestHead, manifestTail));
        console2.log("RESERVOIR_AQUA_INTENT_DEPLOYMENT_END");
    }

    function _stakeAndWrap(address operator, uint256 ethAmount) private returns (uint256 wstETHReceived) {
        uint256 stETHBefore = IERC20(STETH).balanceOf(operator);
        ILidoStETHDeploy(STETH).submit{ value: ethAmount }(address(0));
        uint256 stETHReceived = IERC20(STETH).balanceOf(operator) - stETHBefore;
        require(stETHReceived != 0, "canonical Lido stake minted no stETH");
        IERC20(STETH).forceApprove(WSTETH, stETHReceived);
        wstETHReceived = ILidoWstETHDeploy(WSTETH).wrap(stETHReceived);
        require(wstETHReceived != 0, "canonical Lido wrap minted no wstETH");
    }

    function _validateCanonicalContracts() private view {
        require(CANONICAL_AQUA.code.length != 0, "canonical Aqua code missing");
        require(STETH.code.length != 0, "canonical stETH code missing");
        require(WSTETH.code.length != 0, "canonical wstETH code missing");
        require(WETH.code.length != 0, "canonical WETH code missing");
        require(IERC4626(STATA_WSTETH).asset() == WSTETH, "StatawstETH asset mismatch");
        require(IERC4626(STATA_WETH).asset() == WETH, "StataWETH asset mismatch");
    }
}
