// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.30;

interface IERC7540Redeem {
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);

    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);

    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    function setOperator(address operator, bool approved) external returns (bool success);

    function isOperator(address controller, address operator) external view returns (bool approved);
}
