# Reservoir v2 threat model

> Status: live-beta companion to `V2_SPEC.md`
>
> Scope: pinned-fork rehearsal plus a deliberately capped, operator-managed
> mainnet beta. This is not an audit.

## 1. Assets and actors

Assets at risk:

- the seller's asynchronous request, stETH, or newly originated Lido claim;
- the factor's WETH reserve and ERC-4626 shares;
- immediately redeemed claim assets;
- the factor's claim-controller/NFT ownership; and
- the seller's fixed payment.

Actors:

- **factor signer** — prices and signs one exact fixed-payment quote;
- **seller/controller** — owns the request or stETH and directly calls `fill`;
- **settlement kernel** — validates and atomically orchestrates acquisition and
  payment;
- **funding account** — owns reserve underlying/shares and pays only through the
  kernel;
- **claim adapter** — protocol-specific, immutable, allowlisted, and
  kernel-only;
- **external vault/protocol/token** — potentially reverting, fee-charging,
  upgradeable, reentrant, or dishonest; and
- **frontend** — an untrusted convenience surface, never an authority.

## 2. Security boundary

The kernel does not underwrite or predict future value. Its security claim is
transactional:

```text
valid fixed quote
AND exact current claim units
AND measured acquisition above signed floors
AND exact funding capacity
    => exact seller payment

otherwise
    => full transaction revert
```

The factor bears queue duration, slashing, impairment within signed floors,
liquidity, pause, and protocol-upgrade risk after acquisition.

## 3. Critical invariants

1. Seller payment is impossible without successful measured acquisition.
2. A later materialization/payment failure rolls acquisition back.
3. The seller receives exactly the signed ERC-20 amount or the transaction
   reverts.
4. Only the quoted seller/controller can initiate a fill.
5. The factor signer, chain, kernel, adapter, byte hashes, recipients, payment,
   nonce, and deadline are bound.
6. ERC-8161 settlement moves exactly the signed total request units, regardless
   of the Pending/Claimable split.
7. External return values never substitute for balance/state postconditions.
8. Adapters and the funding account retain no unintended successful-fill dust.
9. A quote cannot be replayed.
10. Reservoir v1 behavior does not change.

## 4. Threats and controls

### 4.1 Forged, replayed, or transplanted quote

Threats:

- wrong signer;
- replayed nonce;
- signature reused on another chain/kernel;
- claim/bounds bytes substituted after signing;
- recipient or payment changed; and
- fill after expiry.

Controls:

- EIP-712 domain binds chain and verifying contract;
- immutable factor signer;
- hashes of both dynamic byte blobs;
- nonce marked before external mutation;
- exact signed addresses/payment;
- deadline check; and
- successful nonce reuse rejection.

### 4.2 Broad ERC-7540 operator approval

Threat: `setOperator` is vault-wide rather than request-scoped.

Controls:

- adapter is non-upgradeable and immutable to one vault and kernel;
- `acquire` is kernel-only;
- kernel is sealed to allowlisted adapters;
- `msg.sender == seller == sellerController`;
- only a factor-signed, expiring, nonce-protected fill reaches the adapter; and
- demo proves approval, fill, revocation, and post-revocation failure.

Residual risk:

- a user can approve the wrong adapter or sign/call malicious calldata through
  a compromised frontend.

Production direction:

- atomic approve/fill/revoke through an EIP-7702 or smart-account batch. Not
  implemented in v2.

### 4.3 Pending/Claimable race

Threat: quote observes Pending, but some or all units become Claimable before
execution; an `if/else` implementation acquires only one leg.

Controls:

- read both balances at fill;
- exact-total precondition;
- independently transfer Pending and redeem Claimable;
- drain seller state to zero;
- measure both factor-side deltas; and
- fuzz every split for a constant total.

### 4.4 Seller unit drift and whole-balance transfer

Threat: ERC-8161 transfers the complete Pending balance. If the seller adds
units after signing, a minimum-only check would over-transfer them for the old
price.

Controls:

- exact `pending + claimable == expectedTotalShares` before movement;
- nonzero ID only; and
- changed total above or below the quote reverts.

### 4.5 Transfer fee or impaired redemption

Threats:

- ERC-8161 permits the recipient to receive less than the seller lost;
- ERC-7540 does not promise a previewable future exchange rate; and
- external return values may lie.

Controls:

- ceil-rounded minimum Pending transfer-rate floor;
- ceil-rounded minimum assets-per-Claimable-share floor;
- receiver balance/state deltas; and
- no `previewRedeem`/`previewWithdraw`.

Residual risk:

- the factor deliberately signs floors that are economically poor. This is
  underwriting, not settlement correctness.

### 4.6 Reentrancy and malicious adapter

Threat: an adapter, vault, token, receiver, or callback re-enters `fill` or
mutates state between checks.

Controls:

- kernel-wide `nonReentrant`;
- nonce consumed before state-changing external calls;
- immutable/allowlisted adapters;
- seller/controller check;
- explicit rejection of adapter self-custody while preserving arbitrary
  factor-signed third-party recipients;
- exact preconditions inside the adapter immediately before mutation;
- postconditions after mutation; and
- all later failures revert atomically.

### 4.7 Funding-capacity drift

Threat: view-safe capacity passes, but the exact vault withdrawal later fails
or is reduced.

Controls:

- fixed payment known before acquisition;
- complete capacity precheck;
- `ERC4626ReserveAdapter.materialize` is exact-or-revert;
- `materializeAndPay` measures the seller delta; and
- acquisition occurs in the same transaction, so a later failure rolls it
  back.

Residual risk:

- a malicious claim adapter could perturb the payment vault, causing a clean
  fill revert. It cannot cause an underpayment or keep the claim.

### 4.8 Funding approvals and custody

Threat: the adapter cannot withdraw shares or can spend unrelated funds.

Controls:

- funding account validates adapter maker/asset/vault metadata;
- unlimited underlying and share approvals go only to the immutable adapter;
- state-changing reserve functions are maker-account-only;
- one payment reserve, one settlement, one factor, then seal; and
- the funding account holds only the configured payment asset/vault shares;
- the factor can pause, top up, and recover assets or shares while paused; and
- the jury deployment is funded only after the exact fork rehearsal passes.

### 4.9 stETH rounding

Threat: stETH share accounting delivers one or two wei less than a requested
`transferFrom`, so requesting the signed nominal amount reverts or creates the
wrong claim.

Controls:

- measure the received balance delta;
- signed maximum shortfall;
- request only the measured amount;
- enforce measured Lido bounds;
- bind economics with a minimum Lido share amount; and
- return any second-transfer rounding residue with `transferShares`;
- prove the adapter has zero remaining stETH shares; and
- test exact, one-wei, two-wei, queue-side residue, and excessive shortfall.

### 4.10 Lido proxy and queue behavior

Threats:

- canonical queue is upgradeable;
- queue can pause or enter stress behavior;
- status/owner/amount can fail reconciliation; and
- a fork fixture becomes stale.

Controls:

- exact block number/hash;
- runtime code and canonical address checks;
- post-request status reconciliation;
- one returned request ID;
- zero adapter dust;
- archive-RPC preflight with clear failure; and
- no claim that immutable endpoint means immutable implementation.

### 4.11 Frontend deception or stale data

Threat: the frontend shows a benign quote but submits different bytes or
pretends a simulated replay is an onchain fill.

Controls:

- display exact chain, kernel, adapter, bytes hashes, payment, nonce, and
  deadline in connected mode;
- enforce mainnet and show canonical/deployed bindings;
- disable approvals and fills unless the reviewed kernel and Lido adapter
  addresses are build-pinned;
- validate hashes, signer (EOA or ERC-1271), capacity, nonce, allowance, seller
  balance, and deadline before enabling a fill;
- use exact stETH approval and simulate each write;
- after mining, independently measure the canonical WETH seller delta and
  canonical Lido request ownership/share amount;
- derive success from transaction receipt/event, not optimistic UI state;
- no embedded private key; and
- terminal/Foundry tests remain authoritative.

## 5. Assumptions

- WETH and deterministic test tokens have ordinary non-fee-on-transfer
  semantics.
- The allowlisted ERC-4626 vault conforms sufficiently for exact withdrawal.
- The factor protects its signing key and prices risk offchain.
- The seller understands and intentionally grants operator/token approval.
- Pinned fork infrastructure supplies correct historical state.
- A live deployment uses the exact rehearsed bytecode and a deliberately
  limited funding amount; funding is a separate authorized operation.

## 6. Explicit non-claims

Reservoir v2 does not claim:

- a fair or canonical price for Pending claims;
- immunity from slashing, queue delay, pause, or protocol upgrades;
- profitability versus CoW in ordinary markets;
- production-safe long-lived operator approvals;
- support for ID-zero or non-ERC-8161 requests;
- protection against a malicious factor quote the seller knowingly fills; or
- production lifecycle, governance, recovery, or upgrade safety.

## 7. Verification map

| Threat | Required proof |
|---|---|
| Forgery/replay | kernel signature/domain/hash/nonce tests |
| Operator breadth | approve -> fill -> revoke -> rejected fill |
| Mixed state | deterministic 60/40 and all-split fuzz |
| Unit drift | changed-total-above/below tests |
| Fee/impairment | transfer-rate and redemption-rate boundary tests |
| Reentrancy | malicious adapter/token callback tests |
| Funding drift | acquisition then materialization/payment rollback tests |
| stETH rounding | exact and 1/2-wei short-transfer tests |
| Lido fixture | exact pin, code, request, status, owner, shares |
| UI truthfulness | build plus rendered-content/fixture consistency test |
| v1 regression | complete existing non-fork/fork/demo suites |
