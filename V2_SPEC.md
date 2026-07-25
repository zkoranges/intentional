# Reservoir v2 protocol specification

> Version: 2.1.0
>
> Status: live-beta release candidate
>
> Product scope is controlled by `V2_SCOPE.md`. This file defines contract
> behavior inside that scope. `V2_IMPLEMENTATION_PLAN.md` controls sequencing
> and acceptance.

## 0. Proof

Reservoir v2 atomically exchanges a future protocol-controlled cash flow for
an exact immediate ERC-20 payment:

> **Payment succeeds if and only if the complete quoted claim is acquired in
> the same transaction.**

The quote may survive a permitted claim-state transition. It may not survive a
change in identity, total units, economic floors, recipient, payment, nonce, or
deadline.

The hard reference case is a nonzero-ID ERC-7540 request implementing ERC-8161
that changes from all-Pending at quote time to partially Claimable at fill
time. The live application originates a Lido withdrawal request directly for
the factor on a pinned mainnet fork and pays from canonical Aave StataWETH
custody. `docs/V2_FORK_REALISM.md` defines exactly which fork components are
canonical and which are disposable test setup.

## 1. Architecture

```text
factor-signed fixed quote
           |
seller -> AsyncClaimSettlement
           |              |
           |              +--> allowlisted IClaimAdapter
           |                    |- ERC8161RedeemClaimAdapter
           |                    `- LidoWithdrawalClaimAdapter
           |
           `--> ProductiveFundingAccount
                    |
                    `--> shipped ERC4626ReserveAdapter --> ERC-4626 vault
```

Reservoir v1 remains unchanged. v2 reuses only the generic
`ERC4626ReserveAdapter`; it does not put claims inside Aqua, SwapVM,
`ReserveClamp`, or `ReservoirMakerAccount`.

The same non-upgradeable contracts are used in the disposable fork rehearsal
and the funded live beta. Mainnet deployment is gated by `V2_SCOPE.md` §0 and
must use the exact tested bytecode. The ERC-7540/8161 adapter is not deployed
without a reviewed production endpoint.

## 2. Shared types

```solidity
library ClaimTypes {
    struct Quote {
        address factor;
        address seller;
        address adapter;
        address claimController;
        address claimReceiver;
        address paymentAsset;
        uint256 paymentAmount;
        bytes32 claimDataHash;
        bytes32 boundsHash;
        uint256 nonce;
        uint256 deadline;
    }

    struct ClaimContext {
        address seller;
        address claimController;
        address claimReceiver;
    }

    struct ClaimFacts {
        bytes32 positionKey;
        address asset;
        address share;
        uint256 claimId;
        uint256 pendingUnits;
        uint256 claimableUnits;
        bool exists;
    }

    struct Acquisition {
        bytes32 positionKey;
        uint256 claimId;
        uint256 pendingUnits;
        uint256 pendingReceived;
        uint256 claimableUnits;
        uint256 assetsReceived;
    }
}
```

`pendingUnits` and `claimableUnits` are the units read or created before the
adapter mutation. `pendingReceived` and `assetsReceived` are measured
post-mutation deltas. Return values are reporting data and never replace
adapter postconditions.

## 3. Adapter interface

```solidity
interface IClaimAdapter {
    function inspect(bytes calldata claimData)
        external
        view
        returns (ClaimTypes.ClaimFacts memory facts);

    function acquire(
        ClaimTypes.ClaimContext calldata context,
        bytes calldata claimData,
        bytes calldata boundsData
    ) external returns (ClaimTypes.Acquisition memory acquisition);
}
```

Rules:

- `inspect` is view-safe.
- `acquire` is callable only by the immutable settlement kernel.
- Every adapter is bound to one protocol endpoint or vault.
- The kernel allowlists adapters before sealing.
- Adapter-specific claim and bounds bytes are hash-bound by the quote.
- All acquisition-critical checks use state and balance deltas.
- A successful call leaves no unintended token, share, NFT, WETH, or native
  ETH custody on the adapter.

## 4. Signed fixed quote

The EIP-712 domain is:

```text
name              Reservoir v2
version           1
chainId           current chain
verifyingContract AsyncClaimSettlement
```

The struct type is:

```text
ClaimQuote(
  address factor,
  address seller,
  address adapter,
  address claimController,
  address claimReceiver,
  address paymentAsset,
  uint256 paymentAmount,
  bytes32 claimDataHash,
  bytes32 boundsHash,
  uint256 nonce,
  uint256 deadline
)
```

The kernel has one immutable `factorSigner`, which may be an EOA or an
ERC-1271 contract wallet. A valid quote requires:

- `quote.factor == factorSigner`;
- `SignatureChecker` validates the signer against `factorSigner`;
- `msg.sender == quote.seller`;
- for v2 adapters, the quoted seller is also the claim's seller/controller;
- the adapter is allowlisted and configuration is sealed;
- `paymentAsset` equals the funding account asset;
- `paymentAmount > 0`;
- `claimController` and `claimReceiver` are nonzero;
- adapter-specific validation rejects the adapter itself as a claim custodian;
- the supplied byte hashes equal the signed hashes;
- `block.timestamp <= deadline`;
- `deadline <= block.timestamp + 15 minutes`;
- the nonce is at or above the factor-controlled nonce floor; and
- the nonce is unused.

The seller directly calls `fill`. Relayed fills and a separate controller
authorization are outside v2.

The payment is fixed. Reservoir does not calculate a settlement-time price:
either every precondition and postcondition holds and the exact signed payment
is delivered, or the fill reverts.

## 5. Settlement sequence

`AsyncClaimSettlement.fill` executes:

1. validate configuration, caller, quote, hashes, signature, and deadline;
2. mark the nonce used before any state-changing external call;
3. require the funding account's view-safe capacity to equal the complete
   signed payment;
4. call the adapter and require its acquisition postconditions;
5. materialize exactly `paymentAmount`;
6. transfer the exact amount to `seller`; and
7. emit `ClaimSettled`.

The function is non-reentrant. Any failure rolls back the nonce, claim
movement/origination, reserve withdrawal, and payment.

Acquisition intentionally precedes materialization. Both occur inside one
atomic transaction, so a later funding failure reverts the claim operation.
This keeps WETH in vault shares through the external claim call and until the
instant it must be paid.

The normalized event is:

```solidity
event ClaimSettled(
    bytes32 indexed quoteHash,
    address indexed adapter,
    address indexed seller,
    address factor,
    address claimController,
    address claimReceiver,
    address paymentAsset,
    uint256 paymentAmount,
    bytes32 positionKey,
    uint256 claimId,
    uint256 pendingUnits,
    uint256 pendingReceived,
    uint256 claimableUnits,
    uint256 assetsReceived
);
```

## 6. Productive funding account

`ProductiveFundingAccount` is a single-factor, single-payment-asset account.

Configuration is single-assignment:

1. configure one shipped `ERC4626ReserveAdapter`;
2. verify its `makerAccount`, asset, and vault metadata;
3. approve the adapter for unlimited underlying and vault shares with
   `SafeERC20.forceApprove`;
4. bind one settlement kernel; and
5. seal.

The reserve adapter is deployed with:

```text
idleThreshold          = 0
liquidityBufferAssets  = 0
```

Before sealing, the factor may call `prepareInventory` to deposit eligible
idle payment assets through the adapter's normal `reinvest` path.

After sealing, the factor may:

- pause materialization, top up idle inventory, and reinvest it;
- while paused, withdraw exact underlying assets or vault shares to a chosen
  recipient; and
- resume only after verifying reserve health.

The account exposes:

```solidity
function availableFor(uint256 wanted) external view returns (uint256);

function materializeAndPay(address recipient, uint256 amount)
    external
    returns (uint256 paid);
```

`availableFor` returns zero on an adapter failure or nonzero `exitCostWad`.
`materializeAndPay` is settlement-only, exact-or-revert, and verifies the
recipient's balance increased by exactly `amount`.

## 7. ERC-7540/8161 adapter

The adapter is immutable to one vault, its current `asset()`, its ERC-7575
`share()`, and the settlement kernel.

At construction it requires ERC-165 support for:

```text
0xe3bc4e65  ERC-7540 operator methods
0x620ee8e4  ERC-7540 asynchronous redeem
0x2f0a18c5  ERC-7575
0x7846f5bd  ERC-8161 transferable redeem requests
```

Claim data:

```solidity
struct ERC8161ClaimData {
    address vault;
    address share;
    address asset;
    uint256 requestId;
    address sellerController;
}
```

Bounds:

```solidity
struct ERC8161Bounds {
    uint256 expectedTotalShares;
    uint256 minPendingTransferRateWad;
    uint256 minAssetsPerClaimableShareWad;
}
```

Preconditions:

- immutable vault/share/asset values equal claim data;
- `requestId != 0`;
- `sellerController == context.seller`;
- `context.claimController` and `context.claimReceiver` are nonzero;
- neither factor-side recipient is the adapter itself;
- the adapter is an approved seller operator;
- `pending + claimable == expectedTotalShares`; and
- the exact total is nonzero.

The exact total is required because ERC-8161 transfers the entire Pending
balance. A minimum-only check could transfer units added after the quote for an
old fixed payment.

Acquisition:

1. read both Pending and Claimable;
2. snapshot the factor controller's Pending balance and receiver's asset
   balance;
3. transfer all nonzero Pending units;
4. redeem all nonzero Claimable units;
5. require the seller has zero Pending and Claimable units for that request;
6. measure both factor-side deltas;
7. require:

```text
pendingReceived >= ceil(pending * minPendingTransferRateWad / 1e18)
assetsReceived  >= ceil(claimable * minAssetsPerClaimableShareWad / 1e18)
```

8. require zero adapter dust.

Both legs execute when both are nonzero; this is never an `if/else`.
`previewRedeem` and `previewWithdraw` are never called.

The generic adapter rejects `requestId == 0`, which is a controller-wide
aggregate without stable tranche identity. Base ERC-7540 requests without
ERC-8161 are also rejected.

### 7.1 Phase-drift argument

For a nonzero request ID, passive processing changes only the split:

```text
Pending -> Claimable
```

It preserves `pending + claimable`. Seller additions, claims, or transfers
change that total and fail the precondition. Economic safety does not follow
from phase monotonicity alone, so transfer-rate and redemption-rate floors
remain mandatory.

### 7.2 Operator control

Approval is vault-wide, but its exercise surface is narrowed:

- immutable non-upgradeable adapter;
- immutable vault and kernel;
- `onlySettlement` acquisition;
- factor-signed expiring quote;
- nonce and data hashes; and
- `msg.sender == seller == sellerController` at the kernel.

The demo proves approve, fill, revoke, then rejection after revocation.

## 8. Lido Originate adapter

The adapter is immutable to canonical stETH, the
`WithdrawalQueueERC721` proxy, and the settlement kernel.

Claim data:

```solidity
struct LidoOriginateData {
    address queue;
    address stETH;
    uint256 requestedStETH;
}
```

Bounds:

```solidity
struct LidoOriginateBounds {
    uint256 maxStETHShortfall;
    uint256 minAmountOfShares;
}
```

Flow:

1. require `context.seller == msg.sender` at the kernel and a nonzero NFT
   receiver other than the adapter;
2. require immutable queue/stETH values match claim data;
3. pull `requestedStETH` with `SafeERC20`;
4. measure `receivedStETH`;
5. require `receivedStETH <= requestedStETH` and the shortfall is within the
   signed maximum;
6. require the measured amount is between Lido's documented 100-wei minimum
   and 1,000-ETH maximum;
7. zero-first approve the queue for the measured amount;
8. call `requestWithdrawals([receivedStETH], context.claimReceiver)`;
9. require exactly one nonzero request ID;
10. read `getWithdrawalStatus`;
11. require the returned owner, amount, share floor, and unclaimed state;
12. clear approval;
13. return any stETH shares left by the queue-side transfer's rounding to the
    seller with `transferShares`; and
14. require zero residual stETH shares or NFT custody.

The acquisition reports the created Lido share amount as both `pendingUnits`
and `pendingReceived`, with zero immediately received assets.

The proxy implementation can change outside the pinned fork. The adapter binds
an endpoint, not immutable protocol behavior.

## 9. Invariants

Release blockers:

1. **Payment iff acquisition:** no seller payment without complete measured
   acquisition in the same transaction.
2. **Atomic rollback:** any funding or payment failure restores the claim,
   nonce, reserve, and balances.
3. **Exact payment:** the seller's balance increases by exactly the signed
   amount.
4. **Capacity honesty:** capacity covers the complete fixed payment before
   acquisition.
5. **Identity binding:** every identity, recipient, payment, and adapter byte
   hash is signed.
6. **Exact total:** request-unit drift invalidates the quote before movement.
7. **Split independence:** every Pending/Claimable split with a constant total
   settles under the same valid bounds.
8. **Measured acquisition:** return values alone never establish success.
9. **Replay safety:** a successful nonce cannot be filled twice.
10. **Seller initiation:** only the quoted seller/controller can fill.
11. **Operator lifecycle:** revocation prevents later acquisition.
12. **Adapter isolation and zero dust.**
13. **Measured stETH:** Lido requests only the received transfer delta.
14. **v1 non-regression.**

## 10. Required tests

### 10.1 Kernel and funding

- valid and invalid factor signatures;
- wrong chain/domain/kernel, seller, adapter, bytes hash, payment, deadline,
  and nonce;
- capacity below exact payment;
- exact materialization and payment delta;
- claim success followed by funding/payment failure rolls back;
- malicious/reentrant adapter;
- nonce consumed before external interaction;
- reserve capital remains in shares before fill; and
- underlying and vault-share approvals are configured.

### 10.2 ERC-7540/8161

- Pending only, Claimable only, and mixed state;
- quote signed before full or partial phase transition;
- fuzz every split for a constant total;
- changed total above and below the quote;
- ID zero;
- preexisting factor balance and delta accounting;
- adapter self-controller and self-receiver rejection;
- permitted and excessive transfer fee;
- permitted and impaired redemption rate;
- missing and revoked operator;
- missing required interface;
- external ERC-7575 share token;
- no preview calls;
- lying return value or residual seller state; and
- rollback after later payment failure.

### 10.3 Lido

- exact transfer and one/two-wei short receipt;
- adapter self-receiver rejection;
- excessive transfer shortfall;
- measured amount below minimum and above maximum;
- paused/request failure;
- wrong returned ID/status/owner/amount;
- share floor;
- payment failure rollback;
- zero adapter dust; and
- pinned mainnet-fork Originate success funded by canonical Aave StataWETH,
  including Lido-mint-before-Aave-withdraw event ordering.

## 11. Demonstration output

The deterministic demo prints:

```text
Funding NAV before -> after
Claim state at quote -> fill
Quoted total / acquired Pending / redeemed Claimable
Exact immediate WETH payment
Operator approve -> revoke result
Settlement result
```

The public frontend is a non-custodial wallet application for the Lido path. It
reads canonical mainnet state, originates and claims Lido withdrawals, and
validates and executes factor-signed Reservoir quotes. The deterministic local
demo remains an explanatory reference; the chain-1 rehearsal is the release
acceptance path.

## 12. Explicit limitations

- No production ERC-8161 deployment is claimed; the generic path uses a strict
  standards-conformant reference vault.
- `requestId == 0` and base ERC-7540 are unsupported.
- ERC-7540 approval is broad and ERC-8161 has no request-scoped permit.
- A factor EOA with EIP-7702 delegation is treated as a contract signer and
  therefore needs a compatible ERC-1271 delegate; otherwise deploy with a
  code-free EOA or reviewed ERC-1271 account.
- Pending claims have no canonical onchain price; the factor supplies the
  fixed signed quote.
- Lido is episodic stress liquidity, not an always-on CoW replacement.
- Productive reserves improve standby utilization, not post-fill underwriting
  risk.
- Queue time, exchange-rate impairment, slashing, pause, bunker mode,
  liquidity, and proxy-upgrade risks remain with the factor.
- The live beta is production-style but unaudited. Real funding is capped by
  operator policy and occurs only after the exact fork rehearsal passes.
