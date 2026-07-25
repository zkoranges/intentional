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

/// @notice Deploys and seeds the disposable Anvil fixture used by the v2 UI.
/// @dev The script prints JSON between stable markers. The launcher validates
///      and writes it so Foundry needs no filesystem write permission.
contract DeployV2Local is Script {
    uint256 private constant FUNDING = 100 ether;
    uint256 private constant YIELD = 0.24 ether;
    uint256 private constant TOTAL_SHARES = 100 ether;
    uint256 private constant SECOND_SHARES = 1 ether;
    uint256 private constant CLAIMABLE_SHARES = 40 ether;
    uint256 private constant PAYMENT = 98.7 ether;
    uint256 private constant SECOND_PAYMENT = 1 ether;
    uint256 private constant WAD = 1e18;
    string private constant OPERATOR_NOT_APPROVED_SELECTOR = "0xeef23db6";

    struct Deployment {
        uint256 factorKey;
        uint256 sellerKey;
        address factor;
        address seller;
        address claimReceiver;
        MockERC20 paymentAsset;
        MockERC20 claimAsset;
        MockERC4626 paymentVault;
        ProductiveFundingAccount fundingAccount;
        AsyncClaimSettlement settlement;
        MockERC7540ERC8161Vault claimVault;
        ERC8161RedeemClaimAdapter claimAdapter;
        uint256 requestId;
        uint256 secondRequestId;
        uint256 navBefore;
        uint256 navAfter;
    }

    function run() external {
        Deployment memory deployed = _deploy();
        (
            ClaimTypes.Quote memory firstQuote,
            bytes memory firstClaimData,
            bytes memory firstBoundsData,
            bytes memory firstSignature
        ) = _signedQuote(deployed, deployed.requestId, TOTAL_SHARES, PAYMENT, 1);
        (
            ClaimTypes.Quote memory secondQuote,
            bytes memory secondClaimData,
            bytes memory secondBoundsData,
            bytes memory secondSignature
        ) = _signedQuote(deployed, deployed.secondRequestId, SECOND_SHARES, SECOND_PAYMENT, 2);

        bytes memory processData =
            abi.encodeCall(MockERC7540ERC8161Vault.process, (deployed.requestId, deployed.seller, CLAIMABLE_SHARES));
        bytes memory fillData =
            abi.encodeCall(AsyncClaimSettlement.fill, (firstQuote, firstClaimData, firstBoundsData, firstSignature));
        bytes memory revokeData =
            abi.encodeCall(MockERC7540ERC8161Vault.setOperator, (address(deployed.claimAdapter), false));
        bytes memory rejectedFillData = abi.encodeCall(
            AsyncClaimSettlement.fill, (secondQuote, secondClaimData, secondBoundsData, secondSignature)
        );

        string memory json = _fixtureJson(deployed, firstQuote, processData, fillData, revokeData, rejectedFillData);
        console2.log("RESERVOIR_V2_FIXTURE_BEGIN");
        console2.log(json);
        console2.log("RESERVOIR_V2_FIXTURE_END");
    }

    function _deploy() private returns (Deployment memory deployed) {
        deployed.factorKey = vm.envUint("ANVIL_FACTOR_PRIVATE_KEY");
        deployed.sellerKey = vm.envUint("ANVIL_SELLER_PRIVATE_KEY");
        deployed.factor = vm.addr(deployed.factorKey);
        deployed.seller = vm.addr(deployed.sellerKey);
        deployed.claimReceiver = vm.envAddress("ANVIL_CLAIM_RECEIVER");

        vm.startBroadcast(deployed.factorKey);
        deployed.paymentAsset = new MockERC20("Wrapped Ether", "WETH", 18);
        deployed.claimAsset = new MockERC20("Async Claim Asset", "ACA", 18);
        deployed.paymentVault = new MockERC4626(IERC20(address(deployed.paymentAsset)), "Productive WETH", "pvWETH");
        deployed.fundingAccount = new ProductiveFundingAccount(deployed.factor);

        ERC4626ReserveAdapter reserveAdapter = new ERC4626ReserveAdapter(
            address(deployed.fundingAccount), IERC4626(address(deployed.paymentVault)), 0, 0
        );
        deployed.fundingAccount.configureReserve(reserveAdapter);

        deployed.settlement = new AsyncClaimSettlement(deployed.factor, deployed.fundingAccount);
        deployed.claimVault = new MockERC7540ERC8161Vault(IERC20(address(deployed.claimAsset)));
        deployed.claimAdapter = new ERC8161RedeemClaimAdapter(deployed.claimVault, address(deployed.settlement));

        deployed.paymentAsset.mint(address(deployed.fundingAccount), FUNDING);
        deployed.claimAsset.mint(address(deployed.claimVault), TOTAL_SHARES + SECOND_SHARES);
        deployed.claimVault.mintShares(deployed.seller, TOTAL_SHARES + SECOND_SHARES);

        deployed.fundingAccount.prepareInventory();
        deployed.fundingAccount.configureSettlement(address(deployed.settlement));
        deployed.fundingAccount.seal();
        deployed.settlement.allowAdapter(address(deployed.claimAdapter));
        deployed.settlement.seal();

        deployed.navBefore = deployed.paymentVault.maxWithdraw(address(deployed.fundingAccount));
        deployed.paymentAsset.mint(address(deployed.paymentVault), YIELD);
        deployed.navAfter = deployed.paymentVault.maxWithdraw(address(deployed.fundingAccount));
        require(deployed.navBefore == FUNDING, "funding NAV baseline mismatch");
        require(deployed.navAfter >= FUNDING + YIELD - 1, "funding NAV yield mismatch");
        require(deployed.navAfter <= FUNDING + YIELD, "funding NAV exceeds donation");
        require(
            deployed.paymentAsset.balanceOf(address(deployed.fundingAccount)) == 0,
            "standby WETH is not entirely in shares"
        );
        vm.stopBroadcast();

        vm.startBroadcast(deployed.sellerKey);
        deployed.requestId = deployed.claimVault.requestRedeem(TOTAL_SHARES, deployed.seller, deployed.seller);
        deployed.secondRequestId = deployed.claimVault.requestRedeem(SECOND_SHARES, deployed.seller, deployed.seller);
        deployed.claimVault.setOperator(address(deployed.claimAdapter), true);
        vm.stopBroadcast();
    }

    function _signedQuote(
        Deployment memory deployed,
        uint256 requestId,
        uint256 totalShares,
        uint256 paymentAmount,
        uint256 nonce
    )
        private
        view
        returns (ClaimTypes.Quote memory quote, bytes memory claimData, bytes memory boundsData, bytes memory signature)
    {
        claimData = abi.encode(
            ERC8161RedeemClaimAdapter.ERC8161ClaimData({
                vault: address(deployed.claimVault),
                share: deployed.claimVault.share(),
                asset: address(deployed.claimAsset),
                requestId: requestId,
                sellerController: deployed.seller
            })
        );
        boundsData = abi.encode(
            ERC8161RedeemClaimAdapter.ERC8161Bounds({
                expectedTotalShares: totalShares, minPendingTransferRateWad: WAD, minAssetsPerClaimableShareWad: WAD
            })
        );
        quote = ClaimTypes.Quote({
            factor: deployed.factor,
            seller: deployed.seller,
            adapter: address(deployed.claimAdapter),
            claimController: deployed.factor,
            claimReceiver: deployed.claimReceiver,
            paymentAsset: address(deployed.paymentAsset),
            paymentAmount: paymentAmount,
            claimDataHash: keccak256(claimData),
            boundsHash: keccak256(boundsData),
            nonce: nonce,
            deadline: block.timestamp + 10 minutes
        });

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployed.factorKey, deployed.settlement.hashQuote(quote));
        signature = abi.encodePacked(r, s, v);
    }

    function _fixtureJson(
        Deployment memory deployed,
        ClaimTypes.Quote memory quote,
        bytes memory processData,
        bytes memory fillData,
        bytes memory revokeData,
        bytes memory rejectedFillData
    )
        private
        view
        returns (string memory)
    {
        return string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"rpcUrl":"http://127.0.0.1:8545","expectedRevertSelector":"',
            OPERATOR_NOT_APPROVED_SELECTOR,
            '",',
            _quoteJson(deployed, quote),
            ",",
            _claimAndMetricsJson(deployed),
            ',"transactions":[',
            _transactionsJson(deployed, processData, fillData, revokeData, rejectedFillData),
            "]}"
        );
    }

    function _quoteJson(Deployment memory deployed, ClaimTypes.Quote memory quote)
        private
        view
        returns (string memory)
    {
        return string.concat(
            '"quote":{',
            '"kernel":"',
            vm.toString(address(deployed.settlement)),
            '","adapter":"',
            vm.toString(address(deployed.claimAdapter)),
            '","quoteHash":"',
            vm.toString(deployed.settlement.hashQuote(quote)),
            '","claimDataHash":"',
            vm.toString(quote.claimDataHash),
            '","boundsHash":"',
            vm.toString(quote.boundsHash),
            '","paymentAsset":"',
            vm.toString(quote.paymentAsset),
            '","paymentAmountWei":"',
            vm.toString(quote.paymentAmount),
            '","nonce":',
            vm.toString(quote.nonce),
            ',"deadline":',
            vm.toString(quote.deadline),
            "}"
        );
    }

    function _claimAndMetricsJson(Deployment memory deployed) private pure returns (string memory) {
        return string.concat(
            '"claim":{"vault":"',
            vm.toString(address(deployed.claimVault)),
            '","seller":"',
            vm.toString(deployed.seller),
            '","requestId":"',
            vm.toString(deployed.requestId),
            '"},"metrics":{"navBeforeWei":"',
            vm.toString(deployed.navBefore),
            '","navAfterWei":"',
            vm.toString(deployed.navAfter),
            '","quotedTotalSharesWei":"',
            vm.toString(TOTAL_SHARES),
            '","quotePendingSharesWei":"',
            vm.toString(TOTAL_SHARES),
            '","quoteClaimableSharesWei":"0"}'
        );
    }

    function _transactionsJson(
        Deployment memory deployed,
        bytes memory processData,
        bytes memory fillData,
        bytes memory revokeData,
        bytes memory rejectedFillData
    )
        private
        pure
        returns (string memory)
    {
        return string.concat(
            _transactionJson(
                "Process 40 Pending shares", deployed.factor, address(deployed.claimVault), processData, false
            ),
            ",",
            _transactionJson(
                "Acquire both claim legs and pay exact WETH",
                deployed.seller,
                address(deployed.settlement),
                fillData,
                false
            ),
            ",",
            _transactionJson(
                "Revoke the broad operator approval", deployed.seller, address(deployed.claimVault), revokeData, false
            ),
            ",",
            _transactionJson(
                "Confirm a second fill is rejected after revocation",
                deployed.seller,
                address(deployed.settlement),
                rejectedFillData,
                true
            )
        );
    }

    function _transactionJson(
        string memory label,
        address from,
        address to,
        bytes memory data,
        bool expectRevert
    )
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '{"label":"',
            label,
            '","from":"',
            vm.toString(from),
            '","to":"',
            vm.toString(to),
            '","data":"',
            vm.toString(data),
            '","expectRevert":',
            expectRevert ? "true" : "false",
            "}"
        );
    }
}
