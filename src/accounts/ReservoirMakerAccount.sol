// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { IMakerHooks } from "@1inch/swap-vm/src/interfaces/IMakerHooks.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";

import { IAquaReserveAdapter } from "../interfaces/IAquaReserveAdapter.sol";
import { IAquaReserveResolver } from "../interfaces/IAquaReserveResolver.sol";

interface IERC4626ReserveMetadata {
    function makerAccount() external view returns (address);
    function asset() external view returns (address);
    function vault() external view returns (IERC4626);
}

interface IReservoirRouterMetadata {
    function AQUA() external view returns (IAqua);
}

/// @notice Disposable two-asset Aqua maker account backed by ERC-4626 reserves.
contract ReservoirMakerAccount is IAquaReserveResolver, IMakerHooks {
    using SafeERC20 for IERC20;

    enum FailureReason {
        LowGas,
        CallFailed
    }

    struct ReserveConfig {
        IAquaReserveAdapter adapter;
        uint32 reinvestGasLimit;
    }

    error InvalidController();
    error InvalidAqua();
    error OnlyController(address caller);
    error ConfigurationSealed();
    error ConfigurationIncomplete();
    error AlreadyConfigured();
    error InvalidRouter();
    error RouterAquaMismatch(address expected, address actual);
    error InvalidAsset();
    error InvalidAdapter();
    error InvalidGasLimit();
    error AdapterBindingMismatch(address asset, address adapter);
    error TooManyReserves();
    error UnsupportedAsset(address asset);
    error InvalidVirtualBalance(address asset, uint256 requested, uint256 nav);
    error StrategyHashMismatch(bytes32 routerHash, bytes32 aquaHash);
    error StrategyNotShipped();
    error OnlyRouter(address caller);
    error InvalidHookMaker(address supplied);
    error InvalidOrderHash(bytes32 supplied);
    error InvalidTokenPair(address tokenIn, address tokenOut);
    error InvalidSettlementPhase(uint256 expected, uint256 actual);
    error InexactMaterialization(uint256 requested, uint256 delivered);
    error HookDisabled();

    event RouterConfigured(address indexed router);
    event ReserveConfigured(
        address indexed asset, address indexed adapter, address indexed vault, uint32 reinvestGasLimit
    );
    event StrategyShipped(bytes32 indexed strategyHash, address indexed router, uint256 balanceA, uint256 balanceB);
    event ReinvestSucceeded(address indexed asset, address indexed adapter);
    event ReinvestFailed(address indexed asset, FailureReason reason);

    uint256 public constant POST_HOOK_GAS_RESERVE = 40_000;
    uint256 public constant CALL_OVERHEAD = 10_000;

    uint256 private constant _PHASE_NONE = 0;
    uint256 private constant _PHASE_OUTPUT_MATERIALIZED = 1;
    uint256 private constant _PHASE_INPUT_AUTHORIZED = 2;
    bytes32 private constant _PHASE_NAMESPACE = keccak256("reservoir.maker.settlement.phase.v1");

    address public immutable controller;
    IAqua public immutable AQUA;

    ISwapVM public router;
    address public tokenA;
    address public tokenB;
    bytes32 public strategyHash;
    bool public isSealed;

    mapping(address asset => ReserveConfig config) public reserveConfig;

    address[2] private _configuredAssets;
    uint8 private _reserveCount;
    bytes private _strategyProgram;

    modifier onlyController() {
        if (msg.sender != controller) {
            revert OnlyController(msg.sender);
        }
        _;
    }

    modifier beforeSeal() {
        if (isSealed) {
            revert ConfigurationSealed();
        }
        _;
    }

    constructor(address controller_, IAqua aqua_) {
        if (controller_ == address(0)) {
            revert InvalidController();
        }
        if (address(aqua_) == address(0) || address(aqua_).code.length == 0) {
            revert InvalidAqua();
        }
        controller = controller_;
        AQUA = aqua_;
    }

    function configureRouter(ISwapVM router_) external onlyController beforeSeal {
        if (address(router) != address(0)) {
            revert AlreadyConfigured();
        }
        if (address(router_) == address(0) || address(router_).code.length == 0) {
            revert InvalidRouter();
        }
        address routerAqua = address(IReservoirRouterMetadata(address(router_)).AQUA());
        if (routerAqua != address(AQUA)) {
            revert RouterAquaMismatch(address(AQUA), routerAqua);
        }
        router = router_;
        emit RouterConfigured(address(router_));
    }

    function configureReserve(
        address asset,
        IAquaReserveAdapter adapter,
        uint32 reinvestGasLimit
    )
        external
        onlyController
        beforeSeal
    {
        if (asset == address(0) || asset.code.length == 0) {
            revert InvalidAsset();
        }
        if (address(adapter) == address(0) || address(adapter).code.length == 0) {
            revert InvalidAdapter();
        }
        if (reinvestGasLimit == 0) {
            revert InvalidGasLimit();
        }
        if (address(reserveConfig[asset].adapter) != address(0)) {
            revert AlreadyConfigured();
        }
        if (_reserveCount >= 2) {
            revert TooManyReserves();
        }

        IERC4626ReserveMetadata metadata = IERC4626ReserveMetadata(address(adapter));
        if (metadata.makerAccount() != address(this) || metadata.asset() != asset) {
            revert AdapterBindingMismatch(asset, address(adapter));
        }
        IERC4626 vault = metadata.vault();
        if (address(vault) == address(0) || address(vault).code.length == 0 || vault.asset() != asset) {
            revert AdapterBindingMismatch(asset, address(adapter));
        }

        reserveConfig[asset] = ReserveConfig({ adapter: adapter, reinvestGasLimit: reinvestGasLimit });
        _configuredAssets[_reserveCount] = asset;
        unchecked {
            ++_reserveCount;
        }

        IERC20(asset).forceApprove(address(AQUA), type(uint256).max);
        IERC20(asset).forceApprove(address(adapter), type(uint256).max);
        IERC20(address(vault)).forceApprove(address(adapter), type(uint256).max);

        if (_reserveCount == 2) {
            address first = _configuredAssets[0];
            address second = _configuredAssets[1];
            (tokenA, tokenB) = first < second ? (first, second) : (second, first);
        }

        emit ReserveConfigured(asset, address(adapter), address(vault), reinvestGasLimit);
    }

    function prepareInventory(address asset) external onlyController beforeSeal {
        IAquaReserveAdapter adapter = reserveConfig[asset].adapter;
        if (address(adapter) == address(0)) {
            revert UnsupportedAsset(asset);
        }
        adapter.reinvest(asset);
    }

    function sealAndShip(
        bytes calldata program,
        uint256 balanceA,
        uint256 balanceB
    )
        external
        onlyController
        beforeSeal
        returns (ISwapVM.Order memory order, bytes32 shippedHash)
    {
        if (
            address(router) == address(0) || _reserveCount != 2 || tokenA == address(0) || tokenB == address(0)
                || program.length == 0
        ) {
            revert ConfigurationIncomplete();
        }

        _requireNavBacking(tokenA, balanceA);
        _requireNavBacking(tokenB, balanceB);

        order = _buildOrder(program);
        bytes32 expectedHash = router.hash(order);

        _strategyProgram = program;
        strategyHash = expectedHash;
        isSealed = true;

        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        uint256[] memory balances = new uint256[](2);
        balances[0] = balanceA;
        balances[1] = balanceB;

        shippedHash = AQUA.ship(address(router), abi.encode(order), tokens, balances);
        if (shippedHash != expectedHash) {
            revert StrategyHashMismatch(expectedHash, shippedHash);
        }
        emit StrategyShipped(shippedHash, address(router), balanceA, balanceB);
    }

    function buildOrder(bytes memory program) public view returns (ISwapVM.Order memory order) {
        if (_reserveCount != 2 || tokenA == address(0) || tokenB == address(0)) {
            revert ConfigurationIncomplete();
        }
        return _buildOrder(program);
    }

    function shippedOrder() external view returns (ISwapVM.Order memory order) {
        if (!isSealed) {
            revert StrategyNotShipped();
        }
        return _buildOrder(_strategyProgram);
    }

    function strategyProgram() external view returns (bytes memory) {
        return _strategyProgram;
    }

    function adapterOf(address asset) external view returns (IAquaReserveAdapter) {
        return reserveConfig[asset].adapter;
    }

    function navOf(address asset) public view returns (uint256 nav) {
        ReserveConfig memory config = reserveConfig[asset];
        if (address(config.adapter) == address(0)) {
            return 0;
        }
        IERC4626 vault = IERC4626ReserveMetadata(address(config.adapter)).vault();
        uint256 idle = IERC20(asset).balanceOf(address(this));
        uint256 shareAssets = vault.convertToAssets(IERC20(address(vault)).balanceOf(address(this)));
        unchecked {
            return type(uint256).max - idle < shareAssets ? type(uint256).max : idle + shareAssets;
        }
    }

    function availableFor(
        address asset,
        uint256 wanted
    )
        external
        view
        returns (uint256 canDeliver, uint256 exitCostWad)
    {
        IAquaReserveAdapter adapter = reserveConfig[asset].adapter;
        if (address(adapter) == address(0)) {
            return (0, 0);
        }
        try adapter.availableFor(asset, wanted) returns (uint256 available, uint256 cost) {
            return (available, cost);
        } catch {
            return (0, 0);
        }
    }

    function preTransferOut(
        address maker,
        address,
        address tokenIn,
        address tokenOut,
        uint256,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata,
        bytes calldata
    )
        external
    {
        ReserveConfig memory config = _validateHook(maker, tokenIn, tokenOut, orderHash, tokenOut);
        _requirePhase(orderHash, _PHASE_NONE);

        uint256 delivered = config.adapter.materialize(tokenOut, amountOut);
        if (delivered != amountOut) {
            revert InexactMaterialization(amountOut, delivered);
        }
        _setPhase(orderHash, _PHASE_OUTPUT_MATERIALIZED);
    }

    function preTransferIn(
        address maker,
        address,
        address tokenIn,
        address tokenOut,
        uint256,
        uint256,
        bytes32 orderHash,
        bytes calldata,
        bytes calldata
    )
        external
    {
        _validateHook(maker, tokenIn, tokenOut, orderHash, tokenIn);
        _requirePhase(orderHash, _PHASE_OUTPUT_MATERIALIZED);
        _setPhase(orderHash, _PHASE_INPUT_AUTHORIZED);
    }

    function postTransferIn(
        address maker,
        address,
        address tokenIn,
        address tokenOut,
        uint256,
        uint256,
        bytes32 orderHash,
        bytes calldata,
        bytes calldata
    )
        external
    {
        ReserveConfig memory config = _validateHook(maker, tokenIn, tokenOut, orderHash, tokenIn);
        _requirePhase(orderHash, _PHASE_INPUT_AUTHORIZED);
        _setPhase(orderHash, _PHASE_NONE);
        _bestEffortReinvest(tokenIn, config);
    }

    function postTransferOut(
        address maker,
        address,
        address tokenIn,
        address tokenOut,
        uint256,
        uint256,
        bytes32 orderHash,
        bytes calldata,
        bytes calldata
    )
        external
        view
    {
        _validateHook(maker, tokenIn, tokenOut, orderHash, tokenOut);
        revert HookDisabled();
    }

    function settlementPhase(bytes32 orderHash) external view returns (uint256) {
        return _phase(orderHash);
    }

    function _buildOrder(bytes memory program) private view returns (ISwapVM.Order memory order) {
        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: address(this),
                receiver: address(this),
                tokenA: tokenA,
                tokenB: tokenB,
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: true,
                allowZeroAmountIn: false,
                hasPreTransferInHook: true,
                hasPostTransferInHook: true,
                hasPreTransferOutHook: true,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(this),
                preTransferInData: "",
                postTransferInTarget: address(this),
                postTransferInData: "",
                preTransferOutTarget: address(this),
                preTransferOutData: "",
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: program
            })
        );
    }

    function _requireNavBacking(address asset, uint256 requested) private view {
        uint256 nav = navOf(asset);
        if (requested > nav) {
            revert InvalidVirtualBalance(asset, requested, nav);
        }
    }

    function _validateHook(
        address maker,
        address tokenIn,
        address tokenOut,
        bytes32 orderHash,
        address relevantAsset
    )
        private
        view
        returns (ReserveConfig memory config)
    {
        if (msg.sender != address(router)) {
            revert OnlyRouter(msg.sender);
        }
        if (!isSealed) {
            revert StrategyNotShipped();
        }
        if (maker != address(this)) {
            revert InvalidHookMaker(maker);
        }
        if (orderHash != strategyHash) {
            revert InvalidOrderHash(orderHash);
        }
        if (!((tokenIn == tokenA && tokenOut == tokenB) || (tokenIn == tokenB && tokenOut == tokenA))) {
            revert InvalidTokenPair(tokenIn, tokenOut);
        }
        config = reserveConfig[relevantAsset];
        if (address(config.adapter) == address(0)) {
            revert UnsupportedAsset(relevantAsset);
        }
    }

    function _bestEffortReinvest(address asset, ReserveConfig memory config) private {
        bytes memory callData = abi.encodeCall(IAquaReserveAdapter.reinvest, (asset));
        uint256 remaining = gasleft();
        if (remaining <= POST_HOOK_GAS_RESERVE + CALL_OVERHEAD) {
            emit ReinvestFailed(asset, FailureReason.LowGas);
            return;
        }

        uint256 availableGas;
        unchecked {
            availableGas = remaining - POST_HOOK_GAS_RESERVE - CALL_OVERHEAD;
        }
        uint256 configuredGas = uint256(config.reinvestGasLimit);
        uint256 gasToForward = configuredGas < availableGas ? configuredGas : availableGas;
        address adapter = address(config.adapter);
        bool success;
        assembly ("memory-safe") {
            success := call(gasToForward, adapter, 0, add(callData, 0x20), mload(callData), 0, 0)
        }

        if (success) {
            emit ReinvestSucceeded(asset, adapter);
        } else {
            emit ReinvestFailed(asset, FailureReason.CallFailed);
        }
    }

    function _phaseSlot(bytes32 orderHash) private pure returns (bytes32) {
        return keccak256(abi.encode(_PHASE_NAMESPACE, orderHash));
    }

    function _phase(bytes32 orderHash) private view returns (uint256 value) {
        bytes32 slot = _phaseSlot(orderHash);
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _setPhase(bytes32 orderHash, uint256 value) private {
        bytes32 slot = _phaseSlot(orderHash);
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _requirePhase(bytes32 orderHash, uint256 expected) private view {
        uint256 actual = _phase(orderHash);
        if (actual != expected) {
            revert InvalidSettlementPhase(expected, actual);
        }
    }
}
