// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice S-1 Gate 0 fork spike (uniswap_payouts_idea.md §2.1): a throwaway
///         harness with no dependency on the payout contracts. Replays the
///         exact Uniswap Trading API route recorded by
///         frontend/scripts/fetch-uniswap-route.mjs at the block observed at
///         fetch time, and answers the open integration questions.
/// @dev Skips with a clear message when no fixture is present.
contract UniswapPayoutSpikeTest is Test {
    using stdJson for string;

    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    string private constant FIXTURE_PATH = "test/spikes/fixtures/uniswap-route.json";

    address private harness;
    address private recipient;
    uint256 private amountIn;
    uint256 private apiQuotedOut;
    address private swapTo;
    bytes private swapData;
    uint256 private fetchedAtBlock;
    bool private fixtureLoaded;

    function setUp() public {
        try vm.readFile(FIXTURE_PATH) returns (string memory fixture) {
            harness = fixture.readAddress(".swapper");
            recipient = fixture.readAddress(".recipient");
            amountIn = vm.parseUint(fixture.readString(".amountInWei"));
            apiQuotedOut = vm.parseUint(fixture.readString(".apiQuotedOut"));
            swapTo = fixture.readAddress(".swapTo");
            swapData = fixture.readBytes(".swapData");
            fetchedAtBlock = fixture.readUint(".fetchedAtBlock");
            fixtureLoaded = true;
        } catch {
            fixtureLoaded = false;
            return;
        }

        // The fixture swapper/recipient must be the deterministic makeAddr
        // derivations both sides agree on.
        assertEq(harness, makeAddr("uniswapPayoutSpikeHarness"), "fixture swapper mismatch");
        assertEq(recipient, makeAddr("uniswapPayoutSpikeRecipient"), "fixture recipient mismatch");

        vm.createSelectFork(vm.envString("ETH_RPC_URL"), fetchedAtBlock);

        // Assertion 1 context: the swapper must be a CONTRACT caller with no
        // Permit2 signature. Give the harness bytecode so the proxy sees code.
        vm.etch(harness, hex"00");
        deal(WETH, harness, amountIn);
    }

    modifier requiresFixture() {
        if (!fixtureLoaded) {
            emit log_string("SKIP: no fixture; run frontend/scripts/fetch-uniswap-route.mjs first");
            return;
        }
        _;
    }

    function test_SpikeContractSwapperRouteExecutesExactlyAndDustlessly() public requiresFixture {
        uint256 recipientUsdcBefore = IERC20(USDC).balanceOf(recipient);

        vm.prank(harness);
        IERC20(WETH).approve(swapTo, amountIn);

        vm.prank(harness);
        (bool ok, bytes memory ret) = swapTo.call(swapData);
        // Assertion 1: the no-Permit2 proxy flow accepts a contract swapper.
        assertTrue(ok, string.concat("proxy call reverted: ", vm.toString(ret)));

        // Assertion 2: the proxy pulls EXACTLY the funded WETH.
        assertEq(IERC20(WETH).balanceOf(harness), 0, "proxy left WETH residue on the harness");

        // Assertion 3: USDC arrives at the separate recipient, not the harness.
        uint256 delivered = IERC20(USDC).balanceOf(recipient) - recipientUsdcBefore;
        assertGt(delivered, 0, "recipient received no USDC");
        assertEq(IERC20(USDC).balanceOf(harness), 0, "USDC landed on the harness instead of the recipient");

        // Assertion 5: the executor pattern can be dustless.
        vm.prank(harness);
        IERC20(WETH).approve(swapTo, 0);
        assertEq(IERC20(WETH).allowance(harness, swapTo), 0, "allowance did not clear");
        assertEq(harness.balance, 0, "harness holds native dust");

        // Assertions 6-7 are FINDINGS, not gates: the proxy calldata layout is
        // not publicly ABI-documented, so the embedded deadline and minimum
        // are not decoded here. The executor enforces the signed minimum from
        // the measured recipient delta regardless of what the calldata encodes.
        emit log_named_uint("SPIKE FINDING | api quoted out (USDC)", apiQuotedOut);
        emit log_named_uint("SPIKE FINDING | measured delivered (USDC)", delivered);
        emit log_named_uint("SPIKE FINDING | calldata bytes", swapData.length);
        emit log_string("SPIKE FINDING | deadline/min not decoded from calldata; signed-minimum enforcement is executor-side");
    }

    function test_SpikeExcessiveMinimumRevertsTheWholeCall() public requiresFixture {
        uint256 recipientUsdcBefore = IERC20(USDC).balanceOf(recipient);

        // Assertion 4: an executor-style enforced minimum reverts the whole
        // call frame, rolling back every token movement.
        vm.expectRevert(bytes("SPIKE: minimum not met"));
        this.harnessFillWithMinimum(type(uint256).max, recipientUsdcBefore);

        assertEq(IERC20(WETH).balanceOf(harness), amountIn, "WETH movement was not rolled back");
        assertEq(
            IERC20(USDC).balanceOf(recipient), recipientUsdcBefore, "USDC movement was not rolled back"
        );
    }

    /// @dev External so the whole approve+swap+check sequence shares one
    ///      revertable call frame, mirroring the executor's fill path.
    function harnessFillWithMinimum(uint256 minimumOut, uint256 recipientUsdcBefore) external {
        require(msg.sender == address(this), "self only");
        vm.prank(harness);
        IERC20(WETH).approve(swapTo, amountIn);
        vm.prank(harness);
        (bool ok,) = swapTo.call(swapData);
        require(ok, "SPIKE: proxy call failed");
        uint256 delivered = IERC20(USDC).balanceOf(recipient) - recipientUsdcBefore;
        require(delivered >= minimumOut, "SPIKE: minimum not met");
    }
}
