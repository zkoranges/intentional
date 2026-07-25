// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPayoutExecutor } from "./interfaces/IPayoutExecutor.sol";
import { PayoutTypes } from "./types/PayoutTypes.sol";

/// @notice The swap boundary of the payouts layer: converts an exactly funded
///         WETH amount through the immutable Uniswap Trading API proxy and
///         delivers the quote's payout asset to the recipient.
/// @dev No arbitrary targets, no native value, no rescue methods, no calldata
///      rewriting, no owner, and no payable entry point — a contract that
///      cannot receive native ETH cannot hold native dust. ERC-20 donations
///      are inert: every balance check measures against the pre-fill
///      baseline, so donated funds can neither block a fill nor be captured
///      by one — they are carried through untouched.
contract UniswapPayoutExecutor is IPayoutExecutor {
    using SafeERC20 for IERC20;

    error InvalidSettlement();
    error InvalidFundingAsset();
    error InvalidProxy();
    error InvalidSelector();
    error OnlySettlement(address caller);
    error InvalidPayoutAsset(address supplied);
    error InsufficientEntryFunding(uint256 balance, uint256 required);
    error PayoutCalldataTooShort(uint256 length);
    error PayoutSelectorMismatch(bytes4 supplied, bytes4 expected);
    error ProxyCallFailed();
    error InsufficientDelivery(uint256 delivered, uint256 minimum);
    error ExitResidue(uint256 fundingBalance, uint256 payoutBalance);

    address public immutable settlement;
    address public immutable fundingAsset;
    address public immutable proxy;
    bytes4 public immutable proxySelector;

    constructor(address settlement_, IERC20 fundingAsset_, address proxy_, bytes4 proxySelector_) {
        // The settlement is deployed AFTER the executor (mutually referential
        // immutables via a predicted CREATE address), so it has no code yet;
        // the settlement's own constructor verifies the mutual binding.
        if (settlement_ == address(0)) {
            revert InvalidSettlement();
        }
        if (address(fundingAsset_) == address(0) || address(fundingAsset_).code.length == 0) {
            revert InvalidFundingAsset();
        }
        if (proxy_ == address(0) || proxy_.code.length == 0) {
            revert InvalidProxy();
        }
        if (proxySelector_ == bytes4(0)) {
            revert InvalidSelector();
        }
        settlement = settlement_;
        fundingAsset = address(fundingAsset_);
        proxy = proxy_;
        proxySelector = proxySelector_;
    }

    /// @inheritdoc IPayoutExecutor
    function payout(
        address recipient,
        IERC20 payoutAsset,
        uint256 fundingAmount,
        uint256 minimumPayoutAmount,
        bytes calldata payoutData
    )
        external
        returns (uint256 delivered)
    {
        if (msg.sender != settlement) {
            revert OnlySettlement(msg.sender);
        }
        // The funding asset settles directly through the v2 kernel; a payout
        // in the funding asset would break the entry/exit baseline accounting.
        if (address(payoutAsset) == address(0) || address(payoutAsset) == fundingAsset) {
            revert InvalidPayoutAsset(address(payoutAsset));
        }

        // Only a real shortfall reverts. Anything above the funded amount is
        // a donation: inert, unspendable (the approval below is exact), and
        // carried through untouched — never a revert reason.
        uint256 entryFunding = IERC20(fundingAsset).balanceOf(address(this));
        if (entryFunding < fundingAmount) {
            revert InsufficientEntryFunding(entryFunding, fundingAmount);
        }
        uint256 fundingBaseline;
        unchecked {
            fundingBaseline = entryFunding - fundingAmount;
        }
        // Captured BEFORE approving or executing the route: the exit check
        // proves the fill left no payout residue on top of what was already
        // here when it started.
        uint256 payoutBaseline = payoutAsset.balanceOf(address(this));

        PayoutTypes.UniswapPayoutData memory data = abi.decode(payoutData, (PayoutTypes.UniswapPayoutData));
        if (data.callData.length < 4) {
            revert PayoutCalldataTooShort(data.callData.length);
        }
        bytes4 suppliedSelector = bytes4(data.callData);
        if (suppliedSelector != proxySelector) {
            revert PayoutSelectorMismatch(suppliedSelector, proxySelector);
        }

        uint256 recipientBefore = payoutAsset.balanceOf(recipient);

        IERC20(fundingAsset).forceApprove(proxy, fundingAmount);
        (bool ok, bytes memory returndata) = proxy.call(data.callData);
        if (!ok) {
            // Bubble the proxy's revert reason unaltered.
            if (returndata.length != 0) {
                assembly ("memory-safe") {
                    revert(add(returndata, 0x20), mload(returndata))
                }
            }
            revert ProxyCallFailed();
        }
        IERC20(fundingAsset).forceApprove(proxy, 0);

        delivered = payoutAsset.balanceOf(recipient) - recipientBefore;
        if (delivered < minimumPayoutAmount) {
            revert InsufficientDelivery(delivered, minimumPayoutAmount);
        }

        // Exactly the funded amount left and no payout stuck here: exit
        // balances must equal the entry baselines, donations included.
        uint256 exitFunding = IERC20(fundingAsset).balanceOf(address(this));
        uint256 exitPayout = payoutAsset.balanceOf(address(this));
        if (exitFunding != fundingBaseline || exitPayout != payoutBaseline) {
            revert ExitResidue(exitFunding, exitPayout);
        }
    }
}
