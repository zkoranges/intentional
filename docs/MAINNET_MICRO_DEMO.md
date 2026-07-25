# Mainnet micro-demo — locked objective

> Status (2026-07-25, past-tense proof record): **Mainnet settlement proof
> completed. Demo contracts safely retired after reserve recovery, and cannot
> be reactivated — the immutable signer key was exposed. Existing-unstETH
> acquisition and the real HTTP firm-quote path are now implemented and
> canonical-mainnet-fork proven; their fresh public deployment is tracked in
> [`LIVE_ACTIVATION.md`](LIVE_ACTIVATION.md).**
> Both objective proofs exist on Ethereum mainnet:
> Aqua intent fill `0xdfb6b280dfe8255ee3d0c4c74243ab9d9d4637b412926f1a9731654340f64d37`
> (block 25611688; 48380478256900 wei wstETH → 57142857142857 wei WETH, output
> exactly equal to the router's historical quote, minimum bound at quote minus
> 30 bps) and factoring settlement
> `0x6c7dfd20a40584cf2cb40baa27e98472599dbca62da470bab6bfd2b42071d611`
> (block 25611746; seller paid exactly 0.0049875 WETH, canonical unstETH
> #130880 minted to the factor; after stETH's one-wei share rounding the
> originated claim is 4999999999999999 wei with the 1 wei residual refunded —
> the adapter's measured-delta protection working as designed).
>
> Scope honesty (independent judge review, accepted): the two proofs are
> technically independent — the Aqua output did not finance the factoring
> payment; the operator CLI validated the Aqua receipt, calldata, strategy
> hash, amount, and WETH transfer **before signing**, and the kernel then
> verified and settled the **signed economic quote** (the provenance evidence
> is CLI-side, not covered by the EIP-712 signature). Both wallets were
> controlled demo accounts with operator pricing (25 bps): this proves
> machinery, atomicity, and real protocol integration — not market demand or
> price discovery. The exact successful quote envelope (queue snapshot at
> signing: 999.568750531812229648 stETH unfinalized across 19 requests) is
> archived at `deployments/quote-envelope-unsteth-130880.json`.
> Outstanding: the unstETH #130880 claim after Lido finalization (reserve
> recovery is complete — tracked in G-M), router/maker explorer verification
> (bytecode attestation published in the README), final review reconciliation.
> The retired contracts stay paused and unfunded permanently; the factor
> signer key was exposed and `factorSigner` is immutable, so reactivation is
> prohibited — any future demo uses a fresh deployment with a fresh key.
> This document is the single source of truth for the production demo. Any
> change to a frozen parameter must be edited here first, then applied.

## 0. Objective

Two real proofs on Ethereum mainnet before submission:

1. **Aqua/SwapVM intent proof** — deploy the Reservoir v1 router (modified
   SwapVM) and disposable maker, ship a productive-reserve wstETH/WETH strategy
   to canonical Aqua `0x499943E74FB0cE105688beeE8Ef2ABec5D936d31`, and fill one
   exact-input wstETH → WETH intent through it, bound to the router's own
   quoted output.
2. **Factoring settlement proof** — a seller sells a fresh 0.005 stETH Lido
   withdrawal claim to the factor for exactly 0.0049875 WETH in one atomic
   transaction through the deployed Reservoir v2 contracts.

**Transaction order vs. proof order (review finding, accepted):** the v2
preflight pins the factor at nonce 0, so the **v2 contracts deploy, fund and
activate first**, consuming the early nonces; the Aqua leg deploys after.
The *proof* order the interlock cares about is preserved: the Aqua intent
**fill** executes — and its receipt is verified on-chain by the quote CLI —
before the factor signs the Lido firm quote. The two proofs remain technically
independent; the interlock is a runbook provenance gate, not a protocol
dependency.

**Stage plan (per review):** both proofs are executed and confirmed *before*
judging; the presentation shows the Etherscan receipts. The interactive live
element on stage is the fork browser demo (`make jury-ui`), which cannot be
blocked by mainnet conditions.

## 1. The factoring settlement, step by step

1. The public site shows the pinned kernel and Lido adapter addresses.
2. The seller wallet holds ≥ 0.005 stETH on mainnet.
3. The factor signs an **operator-priced firm quote** (CLI): pay
   **0.0049875 WETH** for a **0.005 stETH** withdrawal claim, bound to this
   seller, one-time nonce, deadline ≈ 10 minutes ahead (kernel maximum: 15).
4. The seller loads the quote in the browser, approves exactly 0.005 stETH to
   the Lido adapter, and submits the fill.
5. **One transaction**: verify signature, nonce, deadline, capacity → pull the
   seller's 0.005 stETH → request a canonical Lido withdrawal, minting the
   unstETH **directly to the factor** → withdraw exactly 0.0049875 WETH from
   Aave StataWETH → pay the seller. Any failure reverts everything.
6. Etherscan shows: seller +0.0049875 WETH, factor owns the new unstETH, zero
   residual allowance, reserve NAV reduced exactly. The 0.25 % is the **gross
   factoring spread** (not guaranteed profit; it prices queue time and risk).

## 2. Cast and budget

| Actor | Address | Role |
|---|---|---|
| Factor / operator | `0x894E65c06722162A98bd7ed2A2aBDe1Aa6F1fc99` (nonce 0, code-free, 0.04 ETH) | deploys, funds, ships Aqua strategy, signs quote, takes the Aqua fill |
| Seller | `0x528C4E1d59fD4b187461BE9c61C668928C3cf9c3` (second funded wallet, ~0.0247 ETH) | self-funds the 0.0055 stake and its own gas; accepts the quote |

**Factor allocation ledger (seller is self-funded; factor allocations total 0.01246 ETH):**

| Item | ETH | Recoverable? |
|---|---|---|
| v2 reserve funding (WETH → StataWETH) | 0.01 | **yes** — paused share/asset recovery, rehearsed |
| Aqua maker seed (wstETH + WETH sides) | 0.0024 | **no — sunk.** The v1 maker is disposable by design: no owner withdrawal exists; value moves only through fills |
| Aqua taker input | 0.00006 | returns as WETH to the factor in the same fill |
| Gas, all phases (~17.5 M gas total) | ≈ 0.0023 at 0.13 gwei | spent |

Seller side: 0.0055 staked → 0.005 sold → receives 0.0049875 WETH at fill; the
factor recoups ~0.005 ETH by claiming the unstETH after finalization.

## 3. Frozen parameters

Factoring leg:

| Parameter | Value |
|---|---|
| `REQUESTED_STETH` | `0.005` |
| `PAYMENT_WETH` | `0.0049875` (0.25 % gross spread) |
| `FUNDING_WETH_WEI` | `10000000000000000` |
| `MIN_CAPACITY_WEI` | `4987500000000000` |
| Quote deadline | signing time + 10 minutes |
| Quote mode | operator-priced firm quote (§5), **not** test override |
| `EXPECTED_DEPLOYER_NONCE` | `0` |

Aqua intent leg (`script/DeployAquaIntentMainnet.s.sol`,
`script/FillAquaIntentMainnet.s.sol`):

| Parameter | Value |
|---|---|
| `SEED_WSTETH_ETH_WEI` | `1200000000000000` (0.0012 ETH staked → wstETH) |
| `SEED_WETH_WEI` | `1200000000000000` |
| `TAKER_INPUT_ETH_WEI` | `60000000000000` (0.00006 ETH; staked at deploy time, ≈ 5 % of pool side) |
| Fill minimum | bound to the router's own `quote()` output minus `QUOTE_DRIFT_BUFFER_BPS` (default 30) |
| `MIN_OUT_BPS_OF_FAIR` | `9000` — circuit breaker on the quote vs. the Lido rate, not the fill bound |
| Acknowledgements | `DEPLOY_AQUA_INTENT_RESERVOIR_V1`, `FILL_AQUA_INTENT_RESERVOIR_V1` |

**Track note:** the submission uses the standard **Build an Aqua App** track.
Reservoir was built from scratch during ETHGlobal Lisbon 2026: v1 is the Aqua
productive-reserve engine and v2 is its asynchronous-claim extension. The
project history is recorded in `docs/ETHGLOBAL_SUBMISSION.md`.

## 4. Deviations from the reviewed 0.9-scale runbook (all deliberate)

1. `FundV2Mainnet.MIN_JURY_FUNDING` lowered `0.1 ether → 0.01 ether`.
2. Rehearsal scripts accept env-overridable scale; defaults unchanged.
3. The factor signs with the `.env` key (micro budget) instead of a keystore.
4. Demo scale 0.005 ≠ proven 0.9 — re-proven at exact scale by G-A/G-B, and by
   the composite single-run gate G-C before any broadcast.
5. New Aqua-leg ops scripts are outside the frozen v2 review; they are
   fork-rehearsed by G-D and marked as v1-engine tooling.
6. **Formal amendment of the v1 normative boundary.** `SPEC.md` states that v1
   maker accounts "are disposable local/fork fixtures only: they must never be
   deployed or funded on a persistent network." This demo deliberately amends
   that boundary for one micro-scale deployment (~0.0024 ETH seed +
   0.00006 ETH taker input, all factor-owned): the mainnet Aqua intent proof
   is a user-mandated submission requirement, the sunk seed is disclosed in
   §2, and the maker custodies no third-party funds. The amendment applies to
   this deployment only; the SPEC text remains normative for anything larger.

## 5. Firm quote labeling (review finding, accepted)

The mainnet quote must not carry `test-override` evidence. The CLI's operator
mode (`OPERATOR_FIRM_QUOTE=1`) **verifies the Aqua proof receipt on-chain**:
the transaction must be successful on chain 1, sent by the factor, and
addressed to the reviewed Aqua router (`AQUA_ROUTER_ADDRESS`), else quoting
refuses. Evidence records `operator-priced-firm-quote`, the gross spread in
bps, the verified proof hash and router, the signing timestamp, and the live
queue facts at signing (`unfinalizedStETH`, `unfinalizedRequestNumber`). The
offer is real because it is signed, nonce-bound, expiring, and reserve-backed
— it is **not** claimed to be market-derived. `ALLOW_TEST_PAYMENT_OVERRIDE`
and `AQUA_PROOF_ALLOW_UNVERIFIED` remain fork-rehearsal-only (the latter also
re-labels the evidence mode `…-rehearsal-unverified`). The provenance
evidence lives in the CLI envelope, not under the EIP-712 signature: **a
production v3 should include a signed `evidenceHash` binding the economic
quote to its independently verifiable provenance bundle.**

## 6. Budget honesty (review finding, accepted)

The threshold is executable, not prose: `scripts/check-gas-budget.sh <phase>`
refuses any phase unless
`balance ≥ remaining allocations + remaining gas × live gas price × 3`.
With 0.04 ETH, 0.01246 ETH of factor allocations, and ~17.5 M gas at 3×
headroom, the starting ceiling is ≈ 0.52 gwei (at the earlier 0.0065-ETH
seller allocation it was ≈ 0.41 gwei — the reviewer's figure). Current gas
~0.13 gwei clears it with margin. The gate runs automatically before every
broadcast phase in both the complete rehearsal and the mainnet sequence.

## 7. Pipeline to production (gates, in order)

| Gate | What | Owner | Status |
|---|---|---|---|
| G-A | `live-product-e2e` at 0.005/0.0049875 (pinned fork) | agent | **DONE** |
| G-B | `rehearse-live-activation` at 0.01 funding | agent | **DONE** |
| G-C | **Composite single run** on a current-head fork: deploy → verify → fund 0.01 → activate → seller 0.0055 stake → operator quote → 0.005 fill → paused reserve recovery | agent | **DONE** (`rehearse-full-micro-demo.sh`; exact 0.0049875 seller delta; recovery redeemed 0.0050125 WETH incl. accrued Aave yield) |
| G-D | Aqua-leg rehearsal on current-head fork: deploy + seed + ship + fill scripts end-to-end | agent | **DONE** (`rehearse-aqua-intent.sh`; fill 48380478256900 wei wstETH → 57142857142857 wei WETH ≥ min) |
| G-E | `ETHERSCAN_API_KEY` in `.env` | user | **DONE** |
| G-F | `FACTOR_PRIVATE_KEY` deriving `0x894E…fc99` in `.env` | user | **DONE** (verified; an empty duplicate template line in `.env` was removed) |
| G-G | Factor funding for gas solvency | user | **DONE** (0.04 ETH at nonce 0) |
| G-H | Commit clean tree; preflight (`EXPECTED_DEPLOYER_NONCE=0`) | user go, agent | **DONE** (`693cb85`, preflight PASS at nonce 0) |
| G-I | **v2 leg first (nonce 0)**: deploy paused `--verify` → verifier → manifest → fund 0.01 → activate → verifier | simulate agent / broadcast user-authorized | **DONE on mainnet** — all four contracts deployed at predicted addresses, Etherscan-verified, and activated for the proof window (since retired — see G-M); manifest `deployments/mainnet-v2.json` |
| G-J | **Aqua leg second**: router via `cast send --create`, then deploy/seed/ship script, then the quote-bound fill | simulate agent / broadcast user-authorized | **DONE on mainnet** — strategy `0x80ccae4c…02be` on canonical Aqua; fill `0xdfb6b280…f64d37` (block 25611688), output exactly equal to the router quote |
| G-K | Frontend gate: pin `NEXT_PUBLIC_*` in Vercel, redeploy, then **accept**: public URL renders both pinned addresses with explorer links, `verify:deployment` passes against a production RPC, a wallet connects on chain 1, and the quote/fill card simulates | user + agent verification | **DONE** — pins committed in `frontend/.env.production`, confirmed inside the served production bundle by in-browser probe; zero console errors; firm-quote endpoint deliberately fail-closed (operator-assisted beta) |
| G-L | Seller staged (staked + exact 0.005 approval on-chain); operator firm quote (CLI-validated Aqua proof); fill; receipts + envelope archived | user-authorized | **DONE on mainnet** — fill `0x6c7dfd20…71d611` (block 25611746); first attempt `0xe2b579…69984e` exhausted its gas limit during the final WETH payment (after the Aave withdrawal path) and was fixed with an explicit ×1.5 gas cushion |
| G-M | Recovery: pause settlement + funding, withdraw StataWETH shares; after Lido finalization, claim unstETH #130880 | agent commands, user-authorized | **RECOVERY DONE on mainnet** — pauses `0x7c0ea3…39de`/`0x7ddc70…7749`, shares `0xffcce6…4747`, redeem `0x434023…45cd`; recovered 0.005012537 WETH (arithmetic remainder + Aave yield earned on standby); demo contracts retired paused. **Remaining: claim unstETH #130880 after Lido finalization (~4.7 days)** |

Every broadcast is simulated first with the identical command minus
`--broadcast`.

## 8. Fallback (already green)

`make jury-ui` — the identical product on a disposable chain-1 fork, passed
end-to-end today at both 0.9 and 0.005 scales. ETHGlobal rules explicitly
allow local-fork demos; the Aqua fork proof (canonical Aqua, pinned block)
independently satisfies the 1inch track if G-I cannot land.

## 9. Known risks

- **Gas spike**: abort thresholds in §6; top-up removes the cliff.
- **Etherscan verification lag** at G-J: `--resume --verify`; never redeploy.
- **Lido queue paused / bunker mode**: quote CLI fails closed (both inactive
  today).
- **XYC price impact on the Aqua fill**: taker input is capped at ≈ 5 % of the
  pool side; `MIN_OUT_BPS_OF_FAIR=9000` bounds the accepted execution.
- **stETH staking rounding**: stake 0.0055 for a 0.005 sale; 1–2 wei rounding
  never dips below the sale size.
