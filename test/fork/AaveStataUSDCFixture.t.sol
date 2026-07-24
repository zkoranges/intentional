// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC4626 } from "forge-std/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IStataTokenV2Fixture {
    function aToken() external view returns (address);
}

interface IAaveATokenFixture {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

    function POOL() external view returns (address);
}

/// @notice Pinned external facts used by the Reservoir Aave compatibility test.
/// @dev This suite requires an active archive-capable mainnet fork. It has no
///      dependency on Reservoir production contracts and still compiles offline.
contract AaveStataUSDCFixtureTest is Test {
    using SafeERC20 for IERC20;

    uint256 internal constant PINNED_BLOCK = 25_604_561;
    bytes32 internal constant PINNED_BLOCK_HASH = 0x95ca77908413d71bd01cada1ece52b6c2f35467dbbb8f2367144cd0ffbe7888d;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant STATA_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address internal constant A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    uint256 internal constant ONE_USDC = 1_000_000;
    uint256 internal constant DIRECT_DEPOSIT_ASSETS = 1000 * ONE_USDC;
    string internal constant ARCHIVE_FAILURE = "archive RPC required for block 25,604,561";

    IERC20 internal constant UNDERLYING = IERC20(USDC);
    IERC4626 internal constant VAULT = IERC4626(STATA_USDC);

    function setUp() public {
        // Probe historical state while the active fork is still at its
        // provider-selected head. A header-only endpoint may fail as soon as
        // execution resumes on an old block (for example while loading its fee
        // recipient), before Solidity can replace the backend error.
        try this.__historicalStateProbe() returns (bool hasHistoricalState) {
            if (!hasHistoricalState) {
                revert(ARCHIVE_FAILURE);
            }
        } catch {
            revert(ARCHIVE_FAILURE);
        }

        // At block N + 1, BLOCKHASH(N) is available to Solidity. Restore the
        // fork to N after checking its exact canonical hash.
        try this.__rollFork(PINNED_BLOCK + 1) { }
        catch {
            revert(ARCHIVE_FAILURE);
        }

        assertEq(block.number, PINNED_BLOCK + 1, "fork did not roll to hash preflight block");
        assertEq(blockhash(PINNED_BLOCK), PINNED_BLOCK_HASH, "unexpected pinned block hash");

        try this.__rollFork(PINNED_BLOCK) { }
        catch {
            revert(ARCHIVE_FAILURE);
        }

        assertEq(block.number, PINNED_BLOCK, "fork did not restore pinned state");
    }

    function test_FixturePreflightAndPinnedViews() public view {
        assertGt(USDC.code.length, 0, "USDC code missing");
        assertGt(STATA_USDC.code.length, 0, "Stata USDC code missing");
        assertGt(A_USDC.code.length, 0, "aUSDC code missing");
        assertGt(AAVE_V3_POOL.code.length, 0, "Aave V3 Pool code missing");

        assertEq(VAULT.asset(), USDC, "unexpected Stata underlying");
        assertEq(IStataTokenV2Fixture(STATA_USDC).aToken(), A_USDC, "unexpected Stata aToken");
        assertEq(IAaveATokenFixture(A_USDC).UNDERLYING_ASSET_ADDRESS(), USDC, "unexpected aUSDC underlying");
        assertEq(IAaveATokenFixture(A_USDC).POOL(), AAVE_V3_POOL, "unexpected aUSDC Pool");

        assertEq(VAULT.totalAssets(), 78_663_143_378_150, "Stata totalAssets fixture drift");
        assertEq(VAULT.totalSupply(), 66_688_030_062_749, "Stata totalSupply fixture drift");
        assertEq(VAULT.maxDeposit(address(this)), 347_266_066_238_697, "Stata maxDeposit fixture drift");
        assertEq(VAULT.maxWithdraw(address(this)), 0, "empty probe owner must not withdraw");
        assertEq(VAULT.previewDeposit(ONE_USDC), 847_767, "previewDeposit fixture drift");
        assertEq(VAULT.previewWithdraw(ONE_USDC), 847_768, "previewWithdraw fixture drift");
        assertEq(UNDERLYING.balanceOf(A_USDC), 224_640_199_584_485, "Aave USDC liquidity fixture drift");
    }

    function test_FixtureWarpAccruesNAVAtFixedShares() public {
        _fundAndApprove(address(this), DIRECT_DEPOSIT_ASSETS);
        uint256 shares = VAULT.deposit(DIRECT_DEPOSIT_ASSETS, address(this));
        uint256 navBefore = VAULT.convertToAssets(shares);
        uint256 blockBefore = block.number;

        vm.warp(block.timestamp + 30 days);

        uint256 navAfter = VAULT.convertToAssets(shares);
        assertEq(VAULT.balanceOf(address(this)), shares, "warp changed fixed share count");
        assertEq(block.number, blockBefore, "yield proof must not require vm.roll");
        assertGt(navAfter, navBefore, "timestamp warp did not accrue Stata NAV");

        emit log_named_uint("fixed shares", shares);
        emit log_named_uint("NAV before", navBefore);
        emit log_named_uint("NAV after 30 days", navAfter);
    }

    function test_FixtureDirectDepositGasLowerBounds() public {
        address calibrationAccount = makeAddr("stata-direct-deposit-calibration");
        _fundAndApprove(calibrationAccount, 2 * DIRECT_DEPOSIT_ASSETS);

        vm.startPrank(calibrationAccount);
        // Approval setup is excluded. Mark directly touched accounts cold
        // before the first call; the repeat call remains naturally warm within
        // this same test transaction and writes an existing share balance.
        vm.cool(STATA_USDC);
        vm.cool(USDC);
        vm.cool(A_USDC);
        vm.cool(AAVE_V3_POOL);

        uint256 gasBeforeFirst = gasleft();
        uint256 firstShares = VAULT.deposit(DIRECT_DEPOSIT_ASSETS, calibrationAccount);
        uint256 firstDepositGas = gasBeforeFirst - gasleft();

        uint256 gasBeforeRepeat = gasleft();
        uint256 repeatShares = VAULT.deposit(DIRECT_DEPOSIT_ASSETS, calibrationAccount);
        uint256 repeatDepositGas = gasBeforeRepeat - gasleft();
        vm.stopPrank();

        assertGt(firstShares, 0, "first deposit minted no shares");
        assertGt(repeatShares, 0, "repeat deposit minted no shares");
        assertGe(
            VAULT.maxWithdraw(calibrationAccount),
            2 * DIRECT_DEPOSIT_ASSETS - 2,
            "depositor maxWithdraw unexpectedly low"
        );

        emit log_named_uint("direct first deposit gas (cold accounts, new receiver)", firstDepositGas);
        emit log_named_uint("direct repeat deposit gas (same tx, existing receiver)", repeatDepositGas);
        emit log_named_uint("maxWithdraw after two deposits", VAULT.maxWithdraw(calibrationAccount));
        emit log_named_uint("first shares", firstShares);
        emit log_named_uint("repeat shares", repeatShares);
    }

    /// @dev External self-call makes archive/header failures catchable in setUp.
    function __rollFork(uint256 blockNumber) external {
        require(msg.sender == address(this), "self only");
        vm.rollFork(blockNumber);
    }

    /// @dev Probe historical state through an explicit RPC call before the fork
    ///      backend lazily requests account data. RPC cheatcode failures are
    ///      catchable, while a lazy backend database error is not.
    function __historicalStateProbe() external returns (bool) {
        require(msg.sender == address(this), "self only");
        bytes memory historicalCode =
            vm.rpc("eth_getCode", "[\"0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E\",\"0x186b1d1\"]");
        return historicalCode.length != 0;
    }

    function _fundAndApprove(address account, uint256 assets) private {
        deal(USDC, account, assets);
        vm.prank(account);
        UNDERLYING.forceApprove(STATA_USDC, assets);
    }
}
