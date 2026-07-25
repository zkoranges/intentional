// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { ProductiveFundingAccount } from "../../../src/claims/ProductiveFundingAccount.sol";
import { IClaimAdapter } from "../../../src/claims/interfaces/IClaimAdapter.sol";
import { ClaimTypes } from "../../../src/claims/types/ClaimTypes.sol";

interface IKernelNonceView {
    function nonceUsed(uint256 nonce) external view returns (bool);
}

/// @notice Kernel-local adapter double with observable mutation and callback behavior.
contract KernelClaimAdapter is IClaimAdapter {
    error OnlySettlement(address caller);
    error ForcedAcquireFailure();
    error NonceNotConsumed(uint256 nonce);

    address public immutable settlement;

    bool public acquired;
    bool public returnInvalid;
    bool public revertAcquire;
    bool public checkNonce;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bool public fundingAttackAttempted;
    bool public fundingAttackSucceeded;
    uint256 public expectedNonce;
    uint256 public acquireCount;

    bytes private _reentryData;
    ProductiveFundingAccount private _fundingTarget;
    address private _fundingRecipient;
    uint256 private _fundingAmount;

    constructor(address settlement_) {
        settlement = settlement_;
    }

    function configureNonceCheck(uint256 nonce, bool enabled) external {
        expectedNonce = nonce;
        checkNonce = enabled;
    }

    function configureFailure(bool enabled) external {
        revertAcquire = enabled;
    }

    function configureInvalidReturn(bool enabled) external {
        returnInvalid = enabled;
    }

    function configureReentry(bytes calldata callData) external {
        _reentryData = callData;
    }

    function configureFundingAttack(ProductiveFundingAccount target, address recipient, uint256 amount) external {
        _fundingTarget = target;
        _fundingRecipient = recipient;
        _fundingAmount = amount;
    }

    function inspect(bytes calldata claimData) external pure returns (ClaimTypes.ClaimFacts memory facts) {
        (bytes32 positionKey, uint256 claimId, uint256 pendingUnits, uint256 claimableUnits) =
            abi.decode(claimData, (bytes32, uint256, uint256, uint256));
        return ClaimTypes.ClaimFacts({
            positionKey: positionKey,
            asset: address(0),
            share: address(0),
            claimId: claimId,
            pendingUnits: pendingUnits,
            claimableUnits: claimableUnits,
            exists: pendingUnits != 0 || claimableUnits != 0
        });
    }

    function acquire(
        ClaimTypes.ClaimContext calldata,
        bytes calldata claimData,
        bytes calldata
    )
        external
        returns (ClaimTypes.Acquisition memory acquisition)
    {
        if (msg.sender != settlement) {
            revert OnlySettlement(msg.sender);
        }
        if (revertAcquire) {
            revert ForcedAcquireFailure();
        }

        ++acquireCount;
        if (checkNonce && !IKernelNonceView(settlement).nonceUsed(expectedNonce)) {
            revert NonceNotConsumed(expectedNonce);
        }

        if (_reentryData.length != 0) {
            reentryAttempted = true;
            (reentrySucceeded,) = settlement.call(_reentryData);
        }
        if (address(_fundingTarget) != address(0)) {
            fundingAttackAttempted = true;
            (fundingAttackSucceeded,) = address(_fundingTarget)
                .call(abi.encodeCall(ProductiveFundingAccount.materializeAndPay, (_fundingRecipient, _fundingAmount)));
        }

        acquired = true;
        if (returnInvalid) {
            return acquisition;
        }

        (bytes32 positionKey, uint256 claimId, uint256 pendingUnits, uint256 claimableUnits) =
            abi.decode(claimData, (bytes32, uint256, uint256, uint256));
        return ClaimTypes.Acquisition({
            positionKey: positionKey,
            claimId: claimId,
            pendingUnits: pendingUnits,
            pendingReceived: pendingUnits,
            claimableUnits: claimableUnits,
            assetsReceived: claimableUnits
        });
    }
}

contract KernelSettlementCaller {
    function materializeAndPay(
        ProductiveFundingAccount account,
        address recipient,
        uint256 amount
    )
        external
        returns (uint256)
    {
        return account.materializeAndPay(recipient, amount);
    }
}

contract KernelFeeOnTransferToken is ERC20 {
    address public feeRecipient;
    bool public feeEnabled;

    constructor() ERC20("Kernel Fee Token", "KFT") { }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function configureFee(address recipient, bool enabled) external {
        feeRecipient = recipient;
        feeEnabled = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeEnabled && from != address(0) && to == feeRecipient && value != 0) {
            uint256 fee = 1;
            super._update(from, to, value - fee);
            super._update(from, address(0), fee);
            return;
        }
        super._update(from, to, value);
    }
}
