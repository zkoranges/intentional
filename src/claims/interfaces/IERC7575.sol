// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.30;

interface IERC7575 {
    function asset() external view returns (address);

    function share() external view returns (address);
}
