# Reservoir v2 scope lock

> Status: public frontend live; Reservoir contracts not persistently deployed
> or funded
>
> Scope frozen: 2026-07-25
>
> Goal: ship one repeatable, wallet-driven hackathon product for race-safe
> asynchronous-claim settlement. The public frontend can originate and claim
> canonical Lido withdrawals and can execute a factor-signed Reservoir quote
> against a deployed v2 kernel. Do not turn v2 into a general exchange, solver
> network, or claim marketplace.

## 0. Live-beta amendment

The release target is Ethereum mainnet. Before any real funding, the exact
release bytecode must pass the chain-1 dress rehearsal at block `25,604,561`
against canonical stETH, Lido WithdrawalQueueERC721, WETH, Aave StataWETH, and
Aqua. A persistent deployment is permitted only after that rehearsal, the
complete test matrix, the public-wallet frontend checks, and the final Opus 5
review pass.

The first funded deployment is intentionally small and operator-managed:

- the factor controls signing, pause, nonce cancellation/floor, adapter
  revocation, reserve top-up, and paused recovery;
- quotes expire no more than 15 minutes after their target-chain block;
- the seller grants an exact stETH allowance for one fill;
- the frontend simulates every write before asking the wallet to submit it;
- the factor may be a code-free EOA for the jury beta or an ERC-1271 smart
  account; an EIP-7702-delegated EOA is supported only if its delegate
  implements compatible ERC-1271 validation;
- deployment addresses are shown and verified against immutable/canonical
  bindings before a fill; and
- private keys, RPC credentials, quote secrets, and deployment environment
  files never enter the repository or frontend bundle.

No production ERC-8161 deployment is claimed. The ERC-7540/8161 adapter remains
the standards-hard reference path until a reviewed production vault implements
the required interfaces.

As of this release candidate, no Reservoir contract is deployed or funded on a
persistent network. The hosted page enables canonical Lido queue operations
but disables Reservoir approvals/fills until the reviewed kernel and Lido
adapter addresses are compiled into the build.

## 1. Name and relationship to v1

The project is called **Reservoir v2**.

- **Reservoir v1** is the shipped Aqua/SwapVM reserve engine.
- **Reservoir v2** is a separate asynchronous-claim settlement layer that
  reuses v1's generic `ERC4626ReserveAdapter`.
- There is no secondary product name.

The v1 contracts, tests, demo, interfaces, opcode, and normative documents stay
unchanged. In particular, v2 does not add claim settlement to
`ReserveClamp`, `ReservoirSwapVMRouter`, or `ReservoirMakerAccount`.

## 2. The product proof

Reservoir v2 proves one invariant:

> **The seller is paid now if and only if the quoted asynchronous claim is
> irrevocably acquired in the same transaction, while the factor's standby
> capital stays productive until that fill.**

The hard correctness case is a nonzero-ID ERC-7540 redemption request on a
vault implementing ERC-8161:

```text
quote state:       100 Pending + 0 Claimable
fill state:         60 Pending + 40 Claimable
settlement:         transfer 60 + redeem 40 + verify both
payment:            exact fixed WETH, only after acquisition
```

The Pending/Claimable split may change after the quote. The total request
shares and signed economic bounds may not.

Lido is the live application, not an independent novelty claim:

```text
seller supplies measured stETH
    -> a real unstETH request is minted directly to the factor
    -> exact WETH is withdrawn from the productive reserve
    -> seller receives WETH
```

Together these are one proof:

- the ERC-7540/8161 reference path is **standards-hard** and demonstrates the
  race correctly; and
- the pinned Lido fork path is **production-hard** and demonstrates that the
  same kernel can settle against an unmodified live protocol.

## 3. Judge demo

The demo has three short acts.

### Act 1 — productive standby capital

- Factor WETH starts with zero idle underlying and is represented by
  ERC-4626 shares.
- The same shares gain NAV before a fill.
- The quote promises one exact WETH payment.

### Act 2 — state changes, economics do not

- The ERC-7540/8161 request changes from all-Pending to 60/40
  Pending/Claimable after the quote is signed.
- Reservoir transfers the Pending portion and redeems the Claimable portion.
- Measured postconditions prove complete acquisition.
- Only then does Reservoir materialize and pay the exact WETH amount.
- The operator is revoked and a second attempted fill is shown to fail.

### Act 3 — real Lido application

- On a pinned mainnet fork, Reservoir pulls stETH and measures the actual
  receipt.
- It creates a real Lido withdrawal request directly for the factor.
- It reconciles the request ID, owner, stETH amount, and Lido share floor.
- It materializes exact WETH and pays the seller atomically.

The local demo is mandatory and deterministic. The Lido demo requires an
archive-capable `ETH_RPC_URL`; it must fail clearly rather than fake success
when the RPC is absent.

## 4. Frozen v2 decisions

### 4.1 Settlement shape

`AsyncClaimSettlement` is a separate, non-upgradeable, single-chain,
single-factor, EIP-712 fill-or-kill kernel.

The factor signs the quote. In v2:

```text
msg.sender == quoted seller == ERC-7540 seller controller
```

This is a security control, not merely a UX choice. Relayed fills and a payee
different from the request controller require an additional controller
authorization and are outside v2.

The sequence is:

1. validate domain, factor signature, seller/caller, deadline, adapter, and
   hashed adapter data;
2. consume the nonce before any state-changing external call;
3. require full view-safe capacity for the fixed payment;
4. acquire the claim and enforce measured postconditions;
5. materialize the exact payment;
6. transfer the exact payment to the seller; and
7. emit the normalized fill event.

Any failure reverts claim acquisition, reserve withdrawal, nonce consumption,
and payment.

### 4.2 Fixed payment, state-contingent execution

The quote binds an **exact fixed payment**, not settlement-time unit prices.
State contingency is binary:

- all signed preconditions and measured postconditions hold, so the seller
  receives the exact quoted amount; or
- the fill reverts and the seller receives nothing.

This gives the seller quote certainty, avoids silent impairment or
transfer-fee haircuts, and lets the funding account check and materialize one
exact amount just in time. Variable settlement-time pricing is deferred.

### 4.3 Exact preconditions and measured postconditions

The generic quote binds:

- factor signer;
- seller/controller/caller;
- adapter;
- claim-data hash;
- bounds-data hash;
- factor claim controller;
- factor asset/NFT receiver;
- payment asset and exact payment amount;
- nonce; and
- deadline.

For ERC-7540/8161, claim data binds the vault, external share token, asset,
nonzero request ID, and seller controller. Bounds bind:

- `expectedTotalShares`;
- `minPendingTransferRateWad`; and
- `minAssetsPerClaimableShareWad`.

Before movement:

```text
pendingShares + claimableShares == expectedTotalShares
```

This exact-total check is both an upper and lower bound. It is mandatory
because ERC-8161 transfers the seller's entire Pending balance; a minimum-only
check could over-transfer units added after signing.

After movement, balance and state deltas—not return values—must prove:

- the factor received the minimum permitted Pending amount;
- the factor received the minimum permitted assets for Claimable shares;
- the seller has zero remaining Pending and Claimable balance for the request;
  and
- the adapter retains no claim, asset, share, NFT, ETH, or payment dust.

Each adapter rejects its own address wherever that address would take claim
custody: controller or receiver for ERC-8161, and NFT receiver for Lido
Originate. Other nonzero recipients remain factor-signed underwriting choices.

The adapter never calls `previewRedeem` or `previewWithdraw`.

### 4.4 Operator approval

The ERC-7540 operator approval is vault-wide. v2 narrows how it can be
exercised:

- the adapter is non-upgradeable and bound to one immutable vault and kernel;
- only the kernel can call `acquire`;
- only the quoted seller/controller can initiate that fill; and
- the fill is factor-signed, expiring, nonce-protected, and hash-bound.

The demo must show `approve -> fill -> revoke -> rejected second fill`.
Production documentation recommends atomic approve/fill/revoke through an
EIP-7702 or smart-account batch, but v2 does not build it. ERC-8161 has no
request-scoped approval equivalent to ERC-721 `approve(tokenId)`.

### 4.5 Productive funding

`ProductiveFundingAccount` reuses the shipped `ERC4626ReserveAdapter`; it does
not fork or rewrite the adapter.

- The adapter is deployed with `liquidityBufferAssets = 0` for fill-or-kill
  payment capacity.
- The account grants the adapter unlimited approval for both underlying and
  vault shares using `SafeERC20.forceApprove`.
- Capacity must cover the complete fixed payment.
- Materialization is exact-or-revert.
- WETH funds Lido's ETH-denominated claim. Cross-currency underwriting is out.

Productive reserves improve **standby-inventory economics**, not the funding
cost or risk after the factor has paid and is holding the claim.

### 4.6 Lido origination

The hard-cut Lido adapter only needs Originate mode:

- pull the signed maximum stETH amount;
- measure the balance delta because stETH may transfer one or two wei less;
- enforce a signed maximum shortfall and Lido's request bounds;
- request only the measured amount;
- mint the NFT directly to the factor;
- enforce a signed minimum `amountOfShares`; and
- reconcile owner, request amount, and request ID;
- return any queue-side stETH rounding residue to the seller in shares; and
- prove zero adapter shares/dust before payment.

The canonical queue is an upgradeable proxy. The fork pins and validates
historical behavior; an immutable proxy address does not freeze its
implementation.

## 5. Hard-cut deliverables

The submission is incomplete without all of these:

1. `V2_SPEC.md`, this scope lock, and `V2_THREAT_MODEL.md`.
2. `AsyncClaimSettlement`, `ProductiveFundingAccount`, and `IClaimAdapter`.
3. A strict ERC-7540/8161 reference vault with an external ERC-7575 share
   token and controllable partial processing.
4. A nonzero-ID ERC-7540/8161 adapter that handles Pending and Claimable in the
   same fill.
5. A Lido Originate adapter with measured stETH receipt and share-floor
   validation.
6. Targeted unit tests before integration tests.
7. Fuzzing across every Pending/Claimable split for a constant total.
8. Malicious adapter, payment failure, replay, reentrancy, stale state,
   transfer-fee, impairment, revoked-operator, and atomic-rollback tests.
9. One deterministic local vertical-slice demo.
10. One real Lido Originate fill on a pinned mainnet fork.
11. A dark, wallet-connected frontend that reads canonical mainnet state,
    originates and claims Lido withdrawals, validates pasted signed Reservoir
    quotes, requests exact approval, simulates the fill, and derives success
    from the `ClaimSettled` receipt.
12. Full Reservoir v1 non-regression.
13. A final independent Claude Opus 5 review after development, with confirmed
    findings fixed and false positives recorded with evidence.

The pre-scope Opus 5 architecture review performed on 2026-07-25 does not
satisfy item 13.

The jury and full fork acceptance surface must import no mock external
contract. It uses canonical Lido, WETH/USDC, StataWETH/StataUSDC, their aTokens,
and the Aave V3 Pool. Disposable balances may be created with Foundry `deal` or
through the canonical payable token entry points.

## 6. Optional stretch, in order

Only begin these after the hard-cut demo is repeatably green:

1. acquire an existing Pending `unstETH` locally;
2. claim an existing finalized `unstETH`, guard native ETH receipt, and wrap it
   to WETH;
3. add snapshot-isolated fork fixtures for the existing-NFT paths;
4. use Aave StataWETH as the Lido fork's payment vault (**completed**); and
5. add a computed CoW/Curve route comparison from explicit inputs.

The shipped v1 Aave StataUSDC fork remains an independent compatibility and gas
proof. The completed StataWETH stretch makes the v2 Lido fill itself a
canonical Lido-plus-Aave transaction; see `docs/V2_FORK_REALISM.md`.

## 7. Explicitly outside v2

- a marketplace, order book, solver auction, or solver network;
- CoW Atomic Bundles, 0x, or Seaport integration;
- live CoW/Curve API integration;
- variable settlement-time payment or predictive pricing;
- an onchain oracle, ML model, or general risk engine;
- `requestId == 0` support;
- base ERC-7540 requests without ERC-8161;
- relayed fills or a payee different from the request controller;
- EIP-7702/smart-account batching implementation;
- encumbered-position or leveraged-position unwinds;
- pooling, borrowing, leverage, cross-chain, or cross-currency settlement;
- batch claims, multiple LST protocols, or a third adapter;
- an indexer, custody wallet, automated market maker, or persistent quote
  backend;
- unreviewed or automatically funded persistent deployments; and
- production upgrade, recovery, governance, or lifecycle design.

## 8. Commercial claim

Reservoir v2 is an episodic stress-liquidity proof, not an always-on CoW
competitor.

The supplied backtest reports that under a 10% APR, 15 bps risk/margin, and
0.003 ETH gas model, 4.6% of comparable trades and 5.3% of volume beat CoW,
clustered on 15 of 87 sampled active days. Those figures were reported from
another workspace and have not been reproduced in this repository. The
direction—episodic opportunity—is more robust than the precise magnitude,
which is sensitive to funding-cost assumptions and revealed-demand selection.

That intermittency is why productive standby reserves matter: without them,
capital waits idle for the rare periods when factoring wins. Reservoir does not
claim that vault yield removes queue duration, slashing, impairment, liquidity,
or post-fill funding risk.

## 9. Gates

### Gate 0 — freeze and feasibility

- Freeze `V2_SPEC.md` only after the ERC-8161 mixed-state spike and the Lido
  fork-fixture spike pass.
- Do not fan implementation lanes out before the interfaces and postconditions
  are frozen.

### Gate 1 — local kernel and funding

- Exact signed fill, seller-only caller, replay/reentrancy protection.
- Rest -> earn -> capacity -> acquisition -> materialize -> exact payment.

### Gate 2 — mixed-state vertical slice

- 60/40 deterministic fill.
- Every constant-total split fuzzed.
- Exact-total drift rejection, rate floors, operator lifecycle, and rollback.

### Gate 3 — real Lido application

- Local rounding/boundary/failure coverage.
- One pinned mainnet-fork Originate fill against the real queue.

### Gate 4 — demo package

- One-command local demo and explicit RPC-gated Lido demo.
- One-command local frontend setup backed by the same deterministic fixture.
- README, threat model, licenses, limitations, and honest economics.
- All v1 and v2 build, format, test, invariant, fork, and demo gates green.

### Gate 5 — final external review

- Request Claude Opus 5 review only after Gates 0–4 pass.
- Fix confirmed findings, record rejected false positives with evidence, and
  rerun every affected gate.

## 10. Definition of ready

Reservoir v2 is:

- **demo-ready** when Gates 0–2 and the deterministic Gate-4 demo pass;
- **fork-ready** when Gate 3 passes with an archive RPC; and
- **submission-ready** only when all Gates 0–5 pass.

No stretch item can substitute for a missing hard-cut item.

## 11. Document authority

For v2:

1. this file controls product and delivery scope;
2. `V2_SPEC.md` controls contract behavior inside that scope;
3. `V2_IMPLEMENTATION_PLAN.md` controls sequencing and gate acceptance;
4. `V2_REVIEW_FINDINGS.md` records verified evidence and dispositions; and
5. `DIRECTION.md` is advisory.

Any conflict among the first three blocks implementation until the documents
are reconciled. In particular, earlier text that makes Lido Originate the
primary identity, requires existing-`unstETH` paths, or proposes
settlement-time variable payment is superseded by this scope.
