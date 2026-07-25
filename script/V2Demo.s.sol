// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ERC4626ReserveAdapter } from "../src/adapters/ERC4626ReserveAdapter.sol";
import { AsyncClaimSettlement } from "../src/claims/AsyncClaimSettlement.sol";
import { ProductiveFundingAccount } from "../src/claims/ProductiveFundingAccount.sol";
import { ERC8161RedeemClaimAdapter } from "../src/claims/adapters/ERC8161RedeemClaimAdapter.sol";
import { ClaimTypes } from "../src/claims/types/ClaimTypes.sol";
import { MockERC20 } from "../test/mocks/MockERC20.sol";
import { MockERC4626 } from "../test/mocks/MockERC4626.sol";
import { MockERC7540ERC8161Vault } from "../test/mocks/claims/MockERC7540ERC8161Vault.sol";

/// @notice Six-line, RPC-free presentation of the Reservoir v2 hero scenario.
contract V2Demo is Script {
    uint256 private constant FACTOR_KEY = 0xA11CE;
    uint256 private constant FUNDING = 100 ether;
    uint256 private constant YIELD = 0.24 ether;
    uint256 private constant TOTAL_SHARES = 100 ether;
    uint256 private constant CLAIMABLE_SHARES = 40 ether;
    uint256 private constant PAYMENT = 98.7 ether;
    uint256 private constant WAD = 1e18;

    struct Scenario {
        address factor;
        address seller;
        MockERC20 paymentAsset;
        MockERC20 claimAsset;
        MockERC4626 paymentVault;
        ProductiveFundingAccount fundingAccount;
        AsyncClaimSettlement settlement;
        MockERC7540ERC8161Vault claimVault;
        ERC8161RedeemClaimAdapter claimAdapter;
        uint256 requestId;
        uint256 navBefore;
        uint256 navAfter;
    }

    function run() external {
        Scenario memory scenario = _setUp();
        require(scenario.navBefore == FUNDING, "funding NAV baseline mismatch");
        require(scenario.navAfter >= FUNDING + YIELD - 1, "funding NAV yield mismatch");
        require(scenario.navAfter <= FUNDING + YIELD, "funding NAV exceeds donation");
        require(
            scenario.paymentAsset.balanceOf(address(scenario.fundingAccount)) == 0,
            "standby WETH is not entirely in shares"
        );
        (ClaimTypes.Quote memory quote, bytes memory claimData, bytes memory boundsData) =
            _quote(scenario, scenario.requestId, TOTAL_SHARES, PAYMENT, 1);

        bytes memory signature = _sign(scenario.settlement, quote);
        scenario.claimVault.process(scenario.requestId, scenario.seller, CLAIMABLE_SHARES);

        vm.prank(scenario.seller);
        ClaimTypes.Acquisition memory acquired = scenario.settlement.fill(quote, claimData, boundsData, signature);

        require(acquired.pendingUnits == 60 ether, "pending acquisition mismatch");
        require(acquired.pendingReceived == 60 ether, "pending receipt mismatch");
        require(acquired.claimableUnits == CLAIMABLE_SHARES, "claimable acquisition mismatch");
        require(acquired.assetsReceived == CLAIMABLE_SHARES, "claimable redemption mismatch");
        require(scenario.paymentAsset.balanceOf(scenario.seller) == PAYMENT, "payment mismatch");

        vm.prank(scenario.seller);
        scenario.claimVault.setOperator(address(scenario.claimAdapter), false);
        bool revokedFillRejected = _proveRevocation(scenario);
        require(revokedFillRejected, "revoked operator accepted");

        console2.log("Funding NAV before -> after", "100.000 WETH -> 100.240 WETH");
        console2.log("Claim state at quote -> fill", "100/0 -> 60/40");
        console2.log("Quoted total / acquired Pending / redeemed Claimable", "100.00 / 60.00 / 40.00 shares");
        console2.log("Exact immediate WETH payment", "98.70 WETH");
        console2.log("Operator approve -> revoke result", "revoked; second fill rejected");
        console2.log("Settlement result", "complete acquisition before exact payment");
    }

    function _setUp() private returns (Scenario memory scenario) {
        scenario.factor = vm.addr(FACTOR_KEY);
        scenario.seller = makeAddr("reservoir-v2-seller");
        scenario.paymentAsset = new MockERC20("Wrapped Ether", "WETH", 18);
        scenario.claimAsset = new MockERC20("Async Claim Asset", "ACA", 18);
        scenario.paymentVault = new MockERC4626(IERC20(address(scenario.paymentAsset)), "Productive WETH", "pvWETH");
        scenario.fundingAccount = new ProductiveFundingAccount(scenario.factor);

        ERC4626ReserveAdapter reserveAdapter =
            new ERC4626ReserveAdapter(address(scenario.fundingAccount), IERC4626(address(scenario.paymentVault)), 0, 0);

        vm.prank(scenario.factor);
        scenario.fundingAccount.configureReserve(reserveAdapter);

        scenario.settlement = new AsyncClaimSettlement(scenario.factor, scenario.fundingAccount);
        scenario.claimVault = new MockERC7540ERC8161Vault(IERC20(address(scenario.claimAsset)));
        scenario.claimAdapter = new ERC8161RedeemClaimAdapter(scenario.claimVault, address(scenario.settlement));

        scenario.paymentAsset.mint(address(scenario.fundingAccount), FUNDING);
        scenario.claimAsset.mint(address(scenario.claimVault), TOTAL_SHARES);
        scenario.claimVault.mintShares(scenario.seller, TOTAL_SHARES + 1 ether);

        vm.startPrank(scenario.factor);
        scenario.fundingAccount.prepareInventory();
        scenario.fundingAccount.configureSettlement(address(scenario.settlement));
        scenario.fundingAccount.seal();
        scenario.settlement.allowAdapter(address(scenario.claimAdapter));
        scenario.settlement.seal();
        vm.stopPrank();

        scenario.navBefore = scenario.paymentVault.maxWithdraw(address(scenario.fundingAccount));
        scenario.paymentAsset.mint(address(scenario.paymentVault), YIELD);
        scenario.navAfter = scenario.paymentVault.maxWithdraw(address(scenario.fundingAccount));

        vm.startPrank(scenario.seller);
        scenario.requestId = scenario.claimVault.requestRedeem(TOTAL_SHARES, scenario.seller, scenario.seller);
        scenario.claimVault.setOperator(address(scenario.claimAdapter), true);
        vm.stopPrank();
    }

    function _proveRevocation(Scenario memory scenario) private returns (bool rejected) {
        vm.prank(scenario.seller);
        uint256 secondRequestId = scenario.claimVault.requestRedeem(1 ether, scenario.seller, scenario.seller);

        (ClaimTypes.Quote memory quote, bytes memory claimData, bytes memory boundsData) =
            _quote(scenario, secondRequestId, 1 ether, 1 ether, 2);
        bytes memory signature = _sign(scenario.settlement, quote);

        vm.prank(scenario.seller);
        try scenario.settlement.fill(quote, claimData, boundsData, signature) {
            return false;
        } catch (bytes memory reason) {
            bytes4 selector;
            if (reason.length >= 4) {
                assembly ("memory-safe") {
                    selector := mload(add(reason, 0x20))
                }
            }
            return selector == ERC8161RedeemClaimAdapter.OperatorNotApproved.selector;
        }
    }

    function _quote(
        Scenario memory scenario,
        uint256 requestId,
        uint256 totalShares,
        uint256 paymentAmount,
        uint256 nonce
    )
        private
        view
        returns (ClaimTypes.Quote memory quote, bytes memory claimData, bytes memory boundsData)
    {
        claimData = abi.encode(
            ERC8161RedeemClaimAdapter.ERC8161ClaimData({
                vault: address(scenario.claimVault),
                share: scenario.claimVault.share(),
                asset: address(scenario.claimAsset),
                requestId: requestId,
                sellerController: scenario.seller
            })
        );
        boundsData = abi.encode(
            ERC8161RedeemClaimAdapter.ERC8161Bounds({
                expectedTotalShares: totalShares, minPendingTransferRateWad: WAD, minAssetsPerClaimableShareWad: WAD
            })
        );
        quote = ClaimTypes.Quote({
            factor: scenario.factor,
            seller: scenario.seller,
            adapter: address(scenario.claimAdapter),
            claimController: scenario.factor,
            claimReceiver: scenario.factor,
            paymentAsset: address(scenario.paymentAsset),
            paymentAmount: paymentAmount,
            claimDataHash: keccak256(claimData),
            boundsHash: keccak256(boundsData),
            nonce: nonce,
            deadline: block.timestamp + 10 minutes
        });
    }

    function _sign(
        AsyncClaimSettlement settlement,
        ClaimTypes.Quote memory quote
    )
        private
        view
        returns (bytes memory signature)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FACTOR_KEY, settlement.hashQuote(quote));
        signature = abi.encodePacked(r, s, v);
    }
}
