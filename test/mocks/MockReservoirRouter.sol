// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { IMakerHooks } from "@1inch/swap-vm/src/interfaces/IMakerHooks.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

contract MockReservoirRouter is ISwapVM {
    error UnsupportedMockCall();

    IAqua public immutable AQUA;
    bool public returnBadHash;

    constructor(IAqua aqua_) {
        AQUA = aqua_;
    }

    function setReturnBadHash(bool enabled) external {
        returnBadHash = enabled;
    }

    function hash(Order calldata order) external view returns (bytes32) {
        bytes32 orderHash = keccak256(abi.encode(order));
        return returnBadHash ? bytes32(uint256(orderHash) ^ 1) : orderHash;
    }

    function quote(Order calldata, uint256, bytes calldata) external pure returns (uint256, uint256, bytes32) {
        revert UnsupportedMockCall();
    }

    function swap(Order calldata, uint256, bytes calldata) external payable returns (uint256, uint256, bytes32) {
        revert UnsupportedMockCall();
    }

    function forwardPreTransferOut(
        IMakerHooks hooks,
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash
    )
        external
    {
        hooks.preTransferOut(maker, taker, tokenIn, tokenOut, amountIn, amountOut, orderHash, "", "");
    }

    function forwardPreTransferIn(
        IMakerHooks hooks,
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash
    )
        external
    {
        hooks.preTransferIn(maker, taker, tokenIn, tokenOut, amountIn, amountOut, orderHash, "", "");
    }

    function forwardPostTransferIn(
        IMakerHooks hooks,
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash
    )
        external
    {
        hooks.postTransferIn(maker, taker, tokenIn, tokenOut, amountIn, amountOut, orderHash, "", "");
    }

    function forwardPostTransferInWithGas(
        IMakerHooks hooks,
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        uint256 hookGas
    )
        external
        returns (bool success)
    {
        bytes memory data = abi.encodeCall(
            hooks.postTransferIn,
            (maker, taker, tokenIn, tokenOut, amountIn, amountOut, orderHash, bytes(""), bytes(""))
        );
        assembly ("memory-safe") {
            success := call(hookGas, hooks, 0, add(data, 0x20), mload(data), 0, 0)
        }
    }

    function forwardPostTransferOut(
        IMakerHooks hooks,
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash
    )
        external
    {
        hooks.postTransferOut(maker, taker, tokenIn, tokenOut, amountIn, amountOut, orderHash, "", "");
    }
}
