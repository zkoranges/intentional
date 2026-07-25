// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILiveProductStETH is IERC20 {
    function submit(address referral) external payable returns (uint256 sharesAmount);
}

interface ILiveProductWithdrawalQueue {
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

    function getWithdrawalRequests(address owner) external view returns (uint256[] memory requestIds);

    function getWithdrawalStatus(uint256[] calldata requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);

    function getLastRequestId() external view returns (uint256);

    function getLastFinalizedRequestId() external view returns (uint256);

    function isBunkerModeActive() external view returns (bool);

    function claimWithdrawal(uint256 requestId) external;

    function balanceOf(address owner) external view returns (uint256);
}

/// @notice Production-contract acceptance for the exact public wallet surface.
/// @dev No external protocol is substituted. The second test impersonates the
///      historical owner only inside the fork to exercise a canonical finalized
///      claim; it does not represent access to that mainnet account.
contract LiveProductMainnetForkTest is Test {
    uint256 private constant FORK_BLOCK = 25_604_561;
    bytes32 private constant FORK_BLOCK_HASH = 0x95ca77908413d71bd01cada1ece52b6c2f35467dbbb8f2367144cd0ffbe7888d;

    address private constant AQUA = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;
    address private constant SWAP_VM = 0x8fDD04Dbf6111437B44bbca99C28882434e0958f;
    address private constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant STATA_WETH = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;
    address private constant QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    string private constant ARCHIVE_FAILURE = "archive RPC required for block 25,604,561";

    ILiveProductStETH private constant LIDO = ILiveProductStETH(STETH);
    ILiveProductWithdrawalQueue private constant WITHDRAWAL_QUEUE = ILiveProductWithdrawalQueue(QUEUE);

    function setUp() public {
        _pinAndValidateFork();
    }

    function test_WalletFlowUsesCanonicalLidoApprovalRequestAndNFTReceipt() public {
        _assertLiveBindings();
        address seller = makeAddr("liveProductSeller");
        vm.deal(seller, 1 ether);

        vm.prank(seller);
        LIDO.submit{ value: 1 ether }(address(0));

        uint256 available = LIDO.balanceOf(seller);
        uint256 requested = available / 2;
        assertGe(requested, 100, "request below Lido minimum");
        assertLe(requested, 1000 ether, "request above Lido maximum");

        vm.prank(seller);
        assertTrue(LIDO.approve(QUEUE, requested), "exact approval failed");
        assertEq(LIDO.allowance(seller, QUEUE), requested, "queue allowance differs from exact amount");

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = requested;
        uint256 lastBefore = WITHDRAWAL_QUEUE.getLastRequestId();
        vm.recordLogs();
        vm.prank(seller);
        uint256[] memory requestIds = WITHDRAWAL_QUEUE.requestWithdrawals(amounts, seller);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(requestIds.length, 1, "wallet flow must mint exactly one unstETH");
        assertEq(requestIds[0], lastBefore + 1, "unexpected Lido request id");
        assertEq(WITHDRAWAL_QUEUE.getLastRequestId(), requestIds[0], "queue tail did not advance");
        assertEq(LIDO.allowance(seller, QUEUE), 0, "exact approval was not consumed");
        assertEq(WITHDRAWAL_QUEUE.balanceOf(seller), 1, "seller did not receive unstETH");

        uint256[] memory owned = WITHDRAWAL_QUEUE.getWithdrawalRequests(seller);
        assertEq(owned.length, 1, "owner request discovery failed");
        assertEq(owned[0], requestIds[0], "owner request id mismatch");

        ILiveProductWithdrawalQueue.WithdrawalRequestStatus[] memory statuses =
            WITHDRAWAL_QUEUE.getWithdrawalStatus(requestIds);
        assertEq(statuses.length, 1, "status read failed");
        assertEq(statuses[0].owner, seller, "unstETH owner mismatch");
        assertFalse(statuses[0].isFinalized, "new request unexpectedly finalized");
        assertFalse(statuses[0].isClaimed, "new request unexpectedly claimed");
        assertLe(requested - statuses[0].amountOfStETH, 2, "stETH request reconciliation exceeded two wei");
        assertGt(statuses[0].amountOfShares, 0, "Lido recorded no shares");

        bytes32 sellerTopic = bytes32(uint256(uint160(seller)));
        bytes32 tokenIdTopic = bytes32(requestIds[0]);
        bool foundMint;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == QUEUE && logs[i].topics.length == 4 && logs[i].topics[0] == TRANSFER_TOPIC
                    && logs[i].topics[1] == bytes32(0) && logs[i].topics[2] == sellerTopic
                    && logs[i].topics[3] == tokenIdTopic
            ) {
                foundMint = true;
                break;
            }
        }
        assertTrue(foundMint, "receipt is missing canonical unstETH mint");
    }

    function test_WalletClaimUsesCanonicalFinalizedUnstETHAndPaysOwner() public {
        uint256 requestId = WITHDRAWAL_QUEUE.getLastFinalizedRequestId();
        assertGt(requestId, 0, "fixture has no finalized Lido request");
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;
        ILiveProductWithdrawalQueue.WithdrawalRequestStatus[] memory beforeStatus =
            WITHDRAWAL_QUEUE.getWithdrawalStatus(requestIds);
        assertEq(beforeStatus.length, 1, "fixture status missing");
        assertTrue(beforeStatus[0].isFinalized, "fixture request not finalized");
        assertFalse(beforeStatus[0].isClaimed, "fixture request already claimed");
        address historicalOwner = beforeStatus[0].owner;
        assertNotEq(historicalOwner, address(0), "fixture owner missing");

        uint256 ownerEthBefore = historicalOwner.balance;
        uint256 queueEthBefore = QUEUE.balance;
        uint256 ownerNftsBefore = WITHDRAWAL_QUEUE.balanceOf(historicalOwner);

        vm.prank(historicalOwner);
        WITHDRAWAL_QUEUE.claimWithdrawal(requestId);

        ILiveProductWithdrawalQueue.WithdrawalRequestStatus[] memory afterStatus =
            WITHDRAWAL_QUEUE.getWithdrawalStatus(requestIds);
        assertTrue(afterStatus[0].isClaimed, "canonical claim did not mark request claimed");
        assertGt(historicalOwner.balance, ownerEthBefore, "canonical claim paid no ETH");
        assertLt(QUEUE.balance, queueEthBefore, "canonical queue ETH did not decrease");
        assertEq(WITHDRAWAL_QUEUE.balanceOf(historicalOwner), ownerNftsBefore - 1, "canonical unstETH was not burned");
    }

    function _assertLiveBindings() private view {
        assertGt(AQUA.code.length, 0, "canonical Aqua code missing");
        assertGt(SWAP_VM.code.length, 0, "canonical SwapVM code missing");
        assertGt(STETH.code.length, 0, "canonical stETH code missing");
        assertGt(WETH.code.length, 0, "canonical WETH code missing");
        assertGt(STATA_WETH.code.length, 0, "canonical StataWETH code missing");
        assertGt(QUEUE.code.length, 0, "canonical Lido queue code missing");
        WITHDRAWAL_QUEUE.isBunkerModeActive();
    }

    function __rollFork(uint256 blockNumber) external {
        require(msg.sender == address(this), "self only");
        vm.rollFork(blockNumber);
    }

    function __historicalStateProbe() external returns (bool) {
        require(msg.sender == address(this), "self only");
        bytes memory historicalCode =
            vm.rpc("eth_getCode", "[\"0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1\",\"0x186b1d1\"]");
        return historicalCode.length != 0;
    }

    function _pinAndValidateFork() private {
        try this.__historicalStateProbe() returns (bool hasHistoricalState) {
            if (!hasHistoricalState) {
                revert(ARCHIVE_FAILURE);
            }
        } catch {
            revert(ARCHIVE_FAILURE);
        }
        try this.__rollFork(FORK_BLOCK + 1) { }
        catch {
            revert(ARCHIVE_FAILURE);
        }
        assertEq(block.number, FORK_BLOCK + 1, "wrong hash preflight block");
        assertEq(blockhash(FORK_BLOCK), FORK_BLOCK_HASH, "wrong pinned fork hash");
        try this.__rollFork(FORK_BLOCK) { }
        catch {
            revert(ARCHIVE_FAILURE);
        }
        assertEq(block.number, FORK_BLOCK, "wrong fork block");
    }
}
