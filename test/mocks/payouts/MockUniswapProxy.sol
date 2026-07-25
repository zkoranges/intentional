// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MockERC20 } from "../MockERC20.sol";

/// @notice Payout-proxy double: pulls the funding asset from the caller and
///         mints the payout asset at a fixed rate, with adversarial modes for
///         every executor rule.
/// @dev Calldata shape: 4-byte selector then abi.encode(recipient, amountIn).
contract MockUniswapProxy {
    enum Mode {
        Normal,
        RevertAfterPull,
        PullLess,
        PayLess,
        PayCallerInstead
    }

    MockERC20 public immutable fundingAsset;
    MockERC20 public immutable payoutAsset;
    uint256 public rate; // payout units minted per 1e18 funding units pulled
    Mode public mode;

    constructor(MockERC20 fundingAsset_, MockERC20 payoutAsset_, uint256 rate_) {
        fundingAsset = fundingAsset_;
        payoutAsset = payoutAsset_;
        rate = rate_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    fallback() external {
        (address recipient, uint256 amountIn) = abi.decode(msg.data[4:], (address, uint256));
        uint256 pull = mode == Mode.PullLess ? amountIn - 1 : amountIn;
        fundingAsset.transferFrom(msg.sender, address(this), pull);
        if (mode == Mode.RevertAfterPull) {
            revert("MOCK: revert after pull");
        }
        uint256 out = (amountIn * rate) / 1e18;
        if (mode == Mode.PayLess) {
            out /= 2;
        }
        address to = mode == Mode.PayCallerInstead ? msg.sender : recipient;
        payoutAsset.mint(to, out);
    }
}
