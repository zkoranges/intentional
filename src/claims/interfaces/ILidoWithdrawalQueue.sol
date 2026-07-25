// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

interface ILidoWithdrawalQueue {
    struct WithdrawalRequestStatus {
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    function requestWithdrawals(
        uint256[] calldata amounts,
        address owner
    )
        external
        returns (uint256[] memory requestIds);

    function getWithdrawalStatus(uint256[] calldata requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);

    function MIN_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);

    function MAX_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);

    function isPaused() external view returns (bool);

    function isBunkerModeActive() external view returns (bool);
}
