// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.30;

import { IERC7540Redeem } from "./IERC7540Redeem.sol";

interface IERC7540RedeemTransferable is IERC7540Redeem {
    function transferRedeemRequest(uint256 requestId, address oldController, address newController) external;
}
