# Reservoir v2 — implementation plan

> Status: Gates 0–5 passed; Gate 6 live-beta release in progress
>
> Canonical name: **Reservoir v2**
>
> `V2_SCOPE.md` controls scope. `V2_SPEC.md` controls contract behavior.
> Reservoir v1 remains frozen and must stay green.

## 1. Delivery target

Ship one local proof and one live-protocol proof:

```text
local:
  100 Pending at quote
      -> 60 Pending + 40 Claimable at fill
      -> transfer 60 + redeem 40
      -> exact fixed WETH payment

mainnet fork:
  measured stETH
      -> real Lido withdrawal request owned by factor
      -> exact fixed WETH payment
```

The product identity is the fill-or-kill kernel invariant. ERC-8161 supplies
the hardest state race; Lido supplies production credibility. Productive
reserves improve standby utilization and remain in shares until acquisition
has succeeded inside the atomic fill.

## 2. Repository layout

```text
src/claims/
  AsyncClaimSettlement.sol
  ProductiveFundingAccount.sol
  types/ClaimTypes.sol
  interfaces/
    IClaimAdapter.sol
    IERC7540Redeem.sol
    IERC7540RedeemTransferable.sol
    IERC7575.sol
    ILidoWithdrawalQueue.sol
  adapters/
    ERC8161RedeemClaimAdapter.sol
    LidoWithdrawalClaimAdapter.sol

test/mocks/claims/
  MockERC7540ERC8161Vault.sol
  MockERC7575Share.sol
  MockLidoWithdrawalQueue.sol
  MockStETH.sol
  KernelClaimAdapter.sol

test/unit/claims/
  AsyncClaimSettlement.t.sol
  ProductiveFundingAccount.t.sol
  ERC8161RedeemClaimAdapter.t.sol
  LidoWithdrawalClaimAdapter.t.sol

test/integration/
  AsyncClaimERC8161.t.sol
  AsyncClaimLido.t.sol

test/invariants/
  AsyncClaimInvariants.t.sol

test/spikes/
  ERC8161RaceSpike.t.sol

test/fork/
  LidoWithdrawalClaim.t.sol

script/
  V2Demo.s.sol
  DeployV2Local.s.sol

frontend/
  app/
  public/

V2_SCOPE.md
V2_SPEC.md
V2_IMPLEMENTATION_PLAN.md
V2_THREAT_MODEL.md
FINAL_V2_REVIEW.md
```

## 3. Gate 0 — interface freeze and mechanism proof

Sequential. No implementation lane changes a frozen ABI afterward without
updating `V2_SPEC.md` and rerunning this gate.

Tasks:

1. Freeze `ClaimTypes`, `IClaimAdapter`, quote hashing, normalized event,
   funding-account surface, and adapter byte encodings.
2. Add a strict reference vault with:
   - nonzero request IDs;
   - external ERC-7575 shares;
   - Pending and Claimable accounting;
   - partial processing;
   - ERC-8161 whole-Pending transfer;
   - configurable transfer fee and redemption rate;
   - real operator checks; and
   - preview methods that always revert.
3. Prove one minimal race:
   - quote/facts observe `100/0`;
   - process `40`;
   - adapter acquires `60/40` in one call;
   - seller ends at zero;
   - factor deltas reconcile.
4. Add the pinned Lido fork preflight and Originate spike. It must verify:
   - block number/hash;
   - code at canonical stETH and queue addresses;
   - queue/stETH wiring;
   - measured stETH receipt;
   - a real request minted directly to the factor; and
   - status reconciliation.

Pinned starting fixture:

```text
block: 25,604,561
hash:  0x95ca77908413d71bd01cada1ece52b6c2f35467dbbb8f2367144cd0ffbe7888d
stETH: 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84
queue: 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1
WETH:  0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
```

Never impersonate a Lido oracle/finalizer. Use `stETH.submit` from a funded
disposable fork address to obtain the input.

Acceptance:

```text
forge build
forge fmt --check
forge test --match-path "test/spikes/ERC8161RaceSpike.t.sol"
forge test --match-path "test/fork/LidoWithdrawalClaim.t.sol" \
  --fork-url "$ETH_RPC_URL"
```

If no RPC is configured, the fork test must still compile and is reported
pending; local work continues.

## 4. Gate 1 — kernel and productive funding

Implement:

- EIP-712 factor quote;
- factor/caller/domain/hash/deadline validation;
- nonce consumption before external mutation;
- seller-only fills;
- immutable-after-seal adapter allowlist;
- `nonReentrant` fill;
- view-safe exact capacity;
- acquire -> materialize -> pay ordering;
- `ProductiveFundingAccount`;
- one shipped `ERC4626ReserveAdapter` with zero buffer;
- unlimited adapter allowances for underlying and vault shares; and
- exact recipient-balance-delta validation.

Targeted tests precede integration:

- correct and mutated signatures;
- expired and replayed quotes;
- wrong seller, adapter, claim/bounds hash, receiver, payment;
- insufficient capacity;
- reserve failure after acquisition rolls the claim back;
- payment-token failure;
- malicious/reentrant adapter;
- account configuration/sealing/authorization; and
- rest -> earn -> exact materialize -> pay.

Acceptance:

```text
forge build
forge fmt --check
forge test --match-path "test/unit/claims/*"
```

## 5. Gate 2 — ERC-7540/8161 vertical slice

Implement the immutable vault-bound adapter and local integration.

Required proof:

1. seller/controller requests exactly 100 shares;
2. factor signs a fixed-payment quote while facts are `100/0`;
3. vault processes 40 shares;
4. seller approves the adapter;
5. fill transfers 60 Pending and redeems 40 Claimable;
6. funding is materialized and exact payment follows;
7. seller revokes the operator;
8. a new attempted fill without approval reverts.

Required properties:

- exact total is checked before movement;
- floors are checked against measured deltas after movement;
- both legs run when both are nonzero;
- seller state drains to zero;
- no previews are called;
- request ID zero is rejected;
- all Pending/Claimable splits for a constant total are fuzzed;
- transfer fee and redemption impairment are bounded; and
- every later failure rolls the two-leg acquisition back.

Acceptance:

```text
forge build
forge fmt --check
FOUNDRY_PROFILE=ci forge test --no-match-path "test/fork/*" \
  --fuzz-seed 0x5245534552564f4952
```

## 6. Gate 3 — Lido Originate

Implement only the hard-cut Originate mode:

- immutable queue/stETH/kernel;
- measured seller-to-adapter stETH delta;
- signed maximum shortfall;
- 100-wei/1,000-ETH measured bounds;
- zero-first approval;
- exactly one returned request ID;
- owner, amount, share-floor, and claimed-state checks;
- approval clearing and zero dust; and
- normalized acquisition receipt.

Local tests cover exact transfer, one/two-wei short transfer, excessive
shortfall, request boundaries, queue failure, wrong status, share impairment,
payment failure rollback, and zero dust.

The fork test uses:

- real stETH obtained with `submit`;
- the real queue proxy at the exact pin;
- real WETH as payment;
- canonical Aave StataWETH, aWETH, and the Aave V3 Pool for payment custody;
- a snapshot-isolated disposable factor/seller.

The fill asserts that the real Lido NFT mint precedes the real StataWETH
withdrawal. Fixed-share StataWETH NAV growth is proven on an isolated timestamp
warp and state is restored before settlement. `docs/V2_FORK_REALISM.md`
documents every canonical and test-created component.

Acceptance:

```text
forge build
forge fmt --check
FOUNDRY_PROFILE=ci forge test --no-match-path "test/fork/*" \
  --fuzz-seed 0x5245534552564f4952
forge test --match-path "test/fork/LidoWithdrawalClaim.t.sol" \
  --fork-url "$ETH_RPC_URL"
```

## 7. Gate 4 — demo, frontend, and documentation

### 7.1 Terminal demos

`make demo-v2` runs the deterministic local proof and prints:

```text
Funding NAV before -> after
Claim state at quote -> fill
Quoted total / acquired Pending / redeemed Claimable
Exact immediate WETH payment
Operator approve -> revoke result
Settlement result
```

`make jury-demo` runs the pinned, production-contract-only Lido+Aave proof and
prints six runtime-derived lines. `make demo-lido-v2` is an alias. Both fail
with a clear RPC message when `ETH_RPC_URL` is absent.

The existing v1 `make demo` and `make demo-aave` remain unchanged.

### 7.2 Wallet product frontend

The frontend is one dark, minimal mainnet application:

- show productive WETH reserve state;
- show quote state and changed fill state;
- show exact fixed payment and signed bounds;
- connect an injected wallet and enforce chain 1;
- read canonical Aqua, SwapVM, stETH, WETH, Lido queue, and StataWETH state;
- originate a canonical Lido withdrawal using exact approval;
- list and claim the connected wallet's finalized unstETH;
- parse and fully validate a factor-signed Reservoir quote;
- simulate before exact approval and again before fill;
- render transaction success from the bound `ClaimSettled` receipt; and
- never embed a factor or seller key.

No marketplace chrome, indexing, live pricing API, user accounts, custodial
wallet, or persistent backend.

Acceptance:

```text
npm --prefix frontend run build
npm --prefix frontend run build:vercel
ETH_RPC_URL="$ETH_RPC_URL" make live-product-e2e
```

### 7.3 Documentation

Complete:

- README v2 architecture and runbook;
- `V2_THREAT_MODEL.md`;
- exact interfaces and quote rationale;
- operator approval and revocation;
- custody and atomic rollback;
- standards and proxy limitations;
- honest Lido economics;
- all licenses and notices; and
- explicit hard cuts.

## 8. Gate 5 — complete validation and external review

Run:

```text
forge build
forge fmt --check
FOUNDRY_PROFILE=ci forge test --no-match-path "test/fork/*" \
  --fuzz-seed 0x5245534552564f4952
forge test --match-path "test/fork/*" --fork-url "$ETH_RPC_URL"
make demo
make demo-v2
npm --prefix frontend run build
```

Then request an independent Claude Opus 5 review covering:

- quote/domain/replay safety;
- seller/controller authorization;
- acquisition-before-payment ordering;
- atomic rollback;
- exact total and measured rate floors;
- mixed Pending/Claimable handling;
- operator approval surface;
- Lido receipt rounding and request reconciliation;
- productive-funding accounting;
- adapter dust and malicious external calls;
- frontend truthfulness;
- v1 non-regression;
- fork reproducibility; and
- license/source-availability compliance.

Record the review in `FINAL_V2_REVIEW.md`. Fix only confirmed findings, record
false positives with evidence, and rerun every affected gate. This is the final
development step.

## 9. Gate 6 — live-beta release

1. Deploy the exact release bytecode on a disposable chain-1 fork at block
   `25,604,561`.
2. Fund WETH through canonical Aave StataWETH and obtain stETH through
   canonical Lido.
3. Generate a target-chain-timestamped EIP-712 quote.
4. Execute the quote through the same CLI/frontend ABI used by the product.
5. Assert exact seller WETH delta, direct factor unstETH ownership, Lido share
   reconciliation, zero flow dust/allowance, and remaining productive NAV.
6. Run all deterministic and production-contract fork tests.
7. Run frontend lint, rendered tests, Vinext build, Next/Vercel build, and
   browser wallet-state checks.
8. Request a final independent Claude Opus 5 review; fix confirmed findings
   and record false positives with evidence.
9. Audit the Git index for credentials/artifacts, then commit and push.
10. Deploy the frontend publicly. Persistent contracts remain unfunded until a
    separately authorized, capped funding transaction.

## 10. Parallel lanes after Gate 0

| Lane | Ownership | Merge gate |
|---|---|---|
| K | kernel, quote, funding account, kernel unit tests | Gate 1 |
| E | reference vault, ERC-8161 adapter, split fuzzing | Gate 2 |
| L | Lido adapter, adversarial local fixtures, production-only pinned fork | Gate 3 |
| U | demo scripts, frontend, README/threat model | Gate 4 |

The integrator owns shared types/interfaces and merges K, then E, then L, then
U. Every lane runs build and formatting before handoff.

## 11. Stretch only

After Gate 5:

1. existing Pending `unstETH` acquisition;
2. finalized `unstETH` receive/claim/wrap;
3. existing-NFT fork fixtures;
4. Aave StataWETH funding; and
5. computed live-market route comparison.

Do not build relayed fills, variable payment, request ID zero, base ERC-7540,
solver networks, pooled reserves, cross-currency claims, batching, EIP-7702,
leveraged unwinds, custodial wallet infrastructure, or a quote backend.

## 12. Definition of done

- [x] v1 is unchanged and all v1 gates remain green.
- [x] Gate-0 mixed-state and fork-fixture spikes pass or the fork is explicitly
      pending only because `ETH_RPC_URL` is absent.
- [x] Exact fixed quotes are replay-safe and seller-initiated.
- [x] Productive WETH remains in shares until acquisition succeeds.
- [x] Every constant-total Pending/Claimable split settles.
- [x] Total drift, fee impairment, revoked approval, and payment failure revert
      atomically.
- [x] Lido requests only the measured stETH receipt.
- [x] One real Lido request is minted directly to the factor on the pinned fork.
- [x] Terminal demo and minimal frontend exercise the same deterministic proof.
- [x] README, v2 spec, threat model, and runbooks are complete.
- [x] Claude Opus 5 final review is closed.
- [x] Confirmed findings are fixed; false positives are evidenced.
