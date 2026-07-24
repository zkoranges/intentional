// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ITakerCallbacks } from "@1inch/swap-vm/src/interfaces/ITakerCallbacks.sol";

/// @notice Configurable callback actor for caught and propagated nested calls.
contract MaliciousTaker is ITakerCallbacks {
    using SafeERC20 for IERC20;

    enum AttackPoint {
        None,
        PreTransferOut,
        PreTransferIn
    }

    error ExecutedCallFailed();

    event AttackAttempt(AttackPoint indexed point, address indexed target, bool success);

    address public attackTarget;
    bytes public attackCalldata;
    AttackPoint public attackPoint;
    bool public propagateFailure;
    uint256 public attempts;
    bool public lastSuccess;

    function configureAttack(address target, bytes calldata callData, AttackPoint point, bool propagate) external {
        attackTarget = target;
        attackCalldata = callData;
        attackPoint = point;
        propagateFailure = propagate;
        attempts = 0;
        lastSuccess = false;
    }

    function approveToken(IERC20 token, address spender, uint256 amount) external {
        token.forceApprove(spender, amount);
    }

    function execute(address target, bytes calldata callData) external payable returns (bytes memory result) {
        bool success;
        (success, result) = target.call{ value: msg.value }(callData);
        if (!success) {
            _bubble(result);
        }
    }

    function preTransferOutCallback(
        address,
        address,
        address,
        address,
        uint256,
        uint256,
        bytes32,
        bytes calldata
    )
        external
    {
        if (attackPoint == AttackPoint.PreTransferOut) {
            _attack(AttackPoint.PreTransferOut);
        }
    }

    function preTransferInCallback(
        address,
        address,
        address,
        address,
        uint256,
        uint256,
        bytes32,
        bytes calldata
    )
        external
    {
        if (attackPoint == AttackPoint.PreTransferIn) {
            _attack(AttackPoint.PreTransferIn);
        }
    }

    function _attack(AttackPoint point) private {
        unchecked {
            ++attempts;
        }
        bytes memory result;
        (lastSuccess, result) = attackTarget.call(attackCalldata);
        emit AttackAttempt(point, attackTarget, lastSuccess);
        if (!lastSuccess && propagateFailure) {
            _bubble(result);
        }
    }

    function _bubble(bytes memory result) private pure {
        if (result.length == 0) {
            revert ExecutedCallFailed();
        }
        assembly ("memory-safe") {
            revert(add(result, 0x20), mload(result))
        }
    }
}
