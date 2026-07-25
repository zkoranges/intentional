// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC7540RedeemTransferable } from "../../src/claims/interfaces/IERC7540RedeemTransferable.sol";
import { ClaimTypes } from "../../src/claims/types/ClaimTypes.sol";
import { ERC8161RedeemClaimAdapter } from "../../src/claims/adapters/ERC8161RedeemClaimAdapter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC7540ERC8161Vault } from "../mocks/claims/MockERC7540ERC8161Vault.sol";

contract ERC8161RaceKernelStub { }

/// @notice Gate-0 proof that one exact-total quote survives partial processing.
contract ERC8161RaceSpikeTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant TOTAL = 100e18;

    function test_ERC8161RaceSpike_Quote100PendingSettles60Pending40Claimable() public {
        address kernel = address(new ERC8161RaceKernelStub());
        address seller = makeAddr("seller");
        address factor = makeAddr("factor");
        address receiver = makeAddr("receiver");

        MockERC20 asset = new MockERC20("Mock Claim Asset", "MCA", 18);
        MockERC7540ERC8161Vault vault = new MockERC7540ERC8161Vault(asset);
        ERC8161RedeemClaimAdapter adapter =
            new ERC8161RedeemClaimAdapter(IERC7540RedeemTransferable(address(vault)), kernel);

        asset.mint(address(vault), 1000e18);
        vault.mintShares(seller, TOTAL);
        vm.prank(seller);
        uint256 requestId = vault.requestRedeem(TOTAL, seller, seller);
        vm.prank(seller);
        vault.setOperator(address(adapter), true);

        bytes memory claimData = abi.encode(
            ERC8161RedeemClaimAdapter.ERC8161ClaimData({
                vault: address(vault),
                share: vault.share(),
                asset: address(asset),
                requestId: requestId,
                sellerController: seller
            })
        );
        bytes memory boundsData = abi.encode(
            ERC8161RedeemClaimAdapter.ERC8161Bounds({
                expectedTotalShares: TOTAL, minPendingTransferRateWad: WAD, minAssetsPerClaimableShareWad: WAD
            })
        );

        ClaimTypes.ClaimFacts memory quoted = adapter.inspect(claimData);
        assertEq(quoted.pendingUnits, TOTAL, "quote pending");
        assertEq(quoted.claimableUnits, 0, "quote claimable");

        vault.process(requestId, seller, 40e18);
        ClaimTypes.ClaimFacts memory atFill = adapter.inspect(claimData);
        assertEq(atFill.pendingUnits, 60e18, "fill pending");
        assertEq(atFill.claimableUnits, 40e18, "fill claimable");
        assertEq(atFill.pendingUnits + atFill.claimableUnits, TOTAL, "total drifted");

        ClaimTypes.ClaimContext memory context =
            ClaimTypes.ClaimContext({ seller: seller, claimController: factor, claimReceiver: receiver });
        vm.prank(kernel);
        ClaimTypes.Acquisition memory acquired = adapter.acquire(context, claimData, boundsData);

        assertEq(acquired.pendingUnits, 60e18, "reported pending");
        assertEq(acquired.pendingReceived, 60e18, "measured pending");
        assertEq(acquired.claimableUnits, 40e18, "reported claimable");
        assertEq(acquired.assetsReceived, 40e18, "measured assets");
        assertEq(vault.pendingRedeemRequest(requestId, seller), 0, "seller pending");
        assertEq(vault.claimableRedeemRequest(requestId, seller), 0, "seller claimable");
        assertEq(vault.pendingRedeemRequest(requestId, factor), 60e18, "factor pending");
        assertEq(asset.balanceOf(receiver), 40e18, "factor assets");
        assertEq(asset.balanceOf(address(adapter)), 0, "adapter asset dust");
    }
}
