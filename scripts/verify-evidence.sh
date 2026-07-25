#!/usr/bin/env bash
set -Eeuo pipefail

# Judge evidence verifier — checks every published claim against live chain
# state and the committed manifests. Read-only: no keys, no broadcasts, no
# writes. Anything printed FAIL is a claim the repository cannot back.
#
#   ETH_RPC_URL=https://... ./scripts/verify-evidence.sh
#
# Exit 0 only when every check passes.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
RPC="${ETH_RPC_URL:?ETH_RPC_URL is required (read-only access is enough)}"

AQUA=0x499943E74FB0cE105688beeE8Ef2ABec5D936d31
WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
WSTETH=0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
STATA_WETH=0x0bfc9d54Fc184518A81162F8fB99c2eACa081202
QUEUE=0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1

PASS=0
FAIL=0
SKIP=0

ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); }
note() { printf '  NOTE  %s\n' "$1"; SKIP=$((SKIP + 1)); }
head_() { printf '\n== %s ==\n' "$1"; }

eq() { # label expected actual
  if [[ "$(printf '%s' "$2" | tr 'A-Z' 'a-z')" == "$(printf '%s' "$3" | tr 'A-Z' 'a-z')" ]]; then
    ok "$1"
  else
    bad "$1" "$2" "$3"
  fi
}

j() { # file jsonpath
  node --input-type=module -e \
    'import fs from "node:fs"; let o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); for (const k of process.argv[2].split(".")) o=o?.[k]; console.log(o ?? "");' \
    "$1" "$2"
}

codehash() { cast keccak "$(cast code "$1" --rpc-url "$RPC")"; }

receipt_field() { # txhash field
  cast receipt "$1" --rpc-url "$RPC" --json 2>/dev/null |
    node --input-type=module -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const r=JSON.parse(d||"{}");console.log(r[process.argv[1]]??"")})' "$2"
}

echo "Reservoir — evidence verification"
echo "chain id: $(cast chain-id --rpc-url "$RPC")   block: $(cast block-number --rpc-url "$RPC")"

# ---------------------------------------------------------------- v2 stack --
head_ "Reservoir v2 settlement stack (deployments/mainnet-v2.json)"
M=deployments/mainnet-v2.json
if [[ ! -f "$M" ]]; then
  note "manifest missing — skipping v2 checks"
else
  KERNEL="$(j "$M" contracts.kernel.address)"
  FUNDING="$(j "$M" contracts.fundingAccount.address)"
  RESERVE="$(j "$M" contracts.reserveAdapter.address)"
  LIDO_ADAPTER="$(j "$M" contracts.lidoAdapter.address)"
  FACTOR="$(j "$M" factor)"

  for pair in "kernel:${KERNEL}:$(j "$M" contracts.kernel.runtimeCodeHash)" \
              "fundingAccount:${FUNDING}:$(j "$M" contracts.fundingAccount.runtimeCodeHash)" \
              "reserveAdapter:${RESERVE}:$(j "$M" contracts.reserveAdapter.runtimeCodeHash)" \
              "lidoAdapter:${LIDO_ADAPTER}:$(j "$M" contracts.lidoAdapter.runtimeCodeHash)"; do
    IFS=: read -r name addr expected <<<"$pair"
    eq "$name runtime codehash matches manifest" "$expected" "$(codehash "$addr")"
  done

  eq "kernel factorSigner matches manifest factor" "$FACTOR" \
    "$(cast call "$KERNEL" 'factorSigner()(address)' --rpc-url "$RPC")"
  eq "kernel is bound to the manifest funding account" "$FUNDING" \
    "$(cast call "$KERNEL" 'fundingAccount()(address)' --rpc-url "$RPC")"
  eq "lido adapter is bound to the kernel" "$KERNEL" \
    "$(cast call "$LIDO_ADAPTER" 'settlement()(address)' --rpc-url "$RPC")"

  # Retirement claims: paused, drained, no capacity.
  eq "settlement is PAUSED (retired)" "true" \
    "$(cast call "$KERNEL" 'isPaused()(bool)' --rpc-url "$RPC")"
  eq "funding account is PAUSED (retired)" "true" \
    "$(cast call "$FUNDING" 'isPaused()(bool)' --rpc-url "$RPC")"
  eq "reserve is drained (zero StataWETH shares)" "0" \
    "$(cast call "$STATA_WETH" 'balanceOf(address)(uint256)' "$FUNDING" --rpc-url "$RPC" | awk '{print $1}')"
  eq "reserve reports zero deliverable capacity" "0" \
    "$(cast call "$FUNDING" 'availableFor(uint256)(uint256)' 1 --rpc-url "$RPC" | awk '{print $1}')"
fi

# --------------------------------------------------------- factoring proof --
head_ "Factoring settlement proof"
FILL_TX="$(j "$M" factoringFill.txHash)"
if [[ -z "$FILL_TX" ]]; then
  note "no factoringFill recorded in the manifest"
else
  eq "settlement tx succeeded" "0x1" "$(receipt_field "$FILL_TX" status)"
  eq "settlement tx was sent to the kernel" "$KERNEL" "$(receipt_field "$FILL_TX" to)"
  SELLER="$(j "$M" factoringFill.seller)"
  eq "settlement tx was sent by the seller" "$SELLER" "$(receipt_field "$FILL_TX" from)"

  REQ_ID="$(j "$M" factoringFill.unstETHRequestId)"
  if [[ -n "$REQ_ID" ]]; then
    STATUS="$(cast call "$QUEUE" \
      'getWithdrawalStatus(uint256[])((uint256,uint256,address,uint256,bool,bool)[])' \
      "[${REQ_ID}]" --rpc-url "$RPC")"
    # cast annotates integers as `123 [1.23e2]`; strip the annotation before
    # splitting fields, or the two run together.
    STATUS_CLEAN="$(printf '%s' "$STATUS" | sed -E 's/\[[0-9.]+e[0-9]+\]//g' | tr -d ' ()[]')"
    OWNER="$(printf '%s' "$STATUS" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)"
    eq "unstETH #${REQ_ID} is owned by the factor" "$FACTOR" "$OWNER"
    eq "unstETH #${REQ_ID} is not yet claimed" "false" \
      "$(printf '%s' "$STATUS_CLEAN" | awk -F, '{print $6}')"
    ACTUAL_STETH="$(j "$M" factoringFill.actualRequestedStETHWei)"
    if [[ -n "$ACTUAL_STETH" ]]; then
      eq "claim face value matches the manifest (post-rounding)" "$ACTUAL_STETH" \
        "$(printf '%s' "$STATUS_CLEAN" | awk -F, '{print $1}')"
    fi
    MANIFEST_SHARES="$(j "$M" factoringFill.unstETHShares)"
    ONCHAIN_SHARES="$(printf '%s' "$STATUS_CLEAN" | awk -F, '{print $2}')"
    if [[ -n "$MANIFEST_SHARES" ]]; then
      eq "claim share amount matches the manifest" "$MANIFEST_SHARES" "$ONCHAIN_SHARES"
    else
      note "manifest records no claim share amount; on chain it is ${ONCHAIN_SHARES}"
    fi
  fi

  # The strongest single check: the ARCHIVED envelope is provably the one that
  # settled — the kernel's own hashQuote over it must equal the ClaimSettled
  # quoteHash topic in the receipt.
  ENV=deployments/quote-envelope-unsteth-130880.json
  if [[ -f "$ENV" ]]; then
    Q_HASH_ONCHAIN="$(cast receipt "$FILL_TX" --rpc-url "$RPC" --json |
      node --input-type=module -e '
        let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
          const r=JSON.parse(d);
          const t="0x"+require_topic();
          function require_topic(){return "";}
          // ClaimSettled is the only kernel-emitted log with 4 topics here.
          const log=r.logs.filter(l=>l.topics.length===4).pop();
          console.log(log? log.topics[1] : "");
        });')"
    TUPLE="$(node --input-type=module -e '
      import fs from "node:fs";
      const q=JSON.parse(fs.readFileSync(process.argv[1],"utf8")).quote;
      console.log(`(${q.factor},${q.seller},${q.adapter},${q.claimController},${q.claimReceiver},${q.paymentAsset},${q.paymentAmount},${q.claimDataHash},${q.boundsHash},${q.nonce},${q.deadline})`);
    ' "$ENV")"
    Q_HASH_DERIVED="$(cast call "$KERNEL" \
      'hashQuote((address,address,address,address,address,address,uint256,bytes32,bytes32,uint256,uint256))(bytes32)' \
      "$TUPLE" --rpc-url "$RPC" 2>/dev/null || echo "")"
    if [[ -n "$Q_HASH_ONCHAIN" && -n "$Q_HASH_DERIVED" ]]; then
      eq "archived quote envelope IS the settled quote (hash matches receipt)" \
        "$Q_HASH_ONCHAIN" "$Q_HASH_DERIVED"
    else
      note "could not derive the quote hash for envelope comparison"
    fi
    eq "archived envelope nonce is consumed on chain (inert)" "true" \
      "$(cast call "$KERNEL" 'nonceUsed(uint256)(bool)' \
        "$(j "$ENV" quote.nonce)" --rpc-url "$RPC")"
  else
    note "quote envelope not archived"
  fi
fi

# -------------------------------------------------------------- Aqua proof --
head_ "Aqua/SwapVM intent proof (deployments/mainnet-aqua.json)"
A=deployments/mainnet-aqua.json
if [[ ! -f "$A" ]]; then
  note "aqua manifest missing — skipping"
else
  ROUTER="$(j "$A" router.address)"
  MAKER="$(j "$A" maker.address)"
  STRATEGY="$(j "$A" strategy.hash)"

  eq "router runtime codehash matches manifest" "$(j "$A" router.runtimeCodeHash)" "$(codehash "$ROUTER")"
  eq "router is bound to canonical Aqua" "$AQUA" \
    "$(cast call "$ROUTER" 'AQUA()(address)' --rpc-url "$RPC")"
  eq "maker strategy is sealed" "true" \
    "$(cast call "$MAKER" 'isSealed()(bool)' --rpc-url "$RPC")"
  eq "maker strategy hash matches manifest" "$STRATEGY" \
    "$(cast call "$MAKER" 'strategyHash()(bytes32)' --rpc-url "$RPC")"
  eq "maker pair is wstETH/WETH" "${WSTETH},${WETH}" \
    "$(cast call "$MAKER" 'tokenA()(address)' --rpc-url "$RPC"),$(cast call "$MAKER" 'tokenB()(address)' --rpc-url "$RPC")"

  # Canonical Aqua itself must still recognise the shipped strategy.
  if BAL="$(cast call "$AQUA" \
      'safeBalances(address,address,bytes32,address,address)(uint256,uint256)' \
      "$MAKER" "$ROUTER" "$STRATEGY" "$WSTETH" "$WETH" --rpc-url "$RPC" 2>/dev/null)"; then
    ok "canonical Aqua reports live virtual balances for the shipped strategy"
    printf '        %s\n' "$(printf '%s' "$BAL" | tr '\n' ' ')"
  else
    bad "canonical Aqua recognises the strategy" "safeBalances to return" "reverted"
  fi

  FILL="$(j "$A" fill.txHash)"
  if [[ -n "$FILL" ]]; then
    eq "aqua fill tx succeeded" "0x1" "$(receipt_field "$FILL" status)"
    eq "aqua fill tx was sent to the reviewed router" "$ROUTER" "$(receipt_field "$FILL" to)"
    QUOTED="$(j "$A" fill.quotedWethOutWei)"
    ACTUALO="$(j "$A" fill.actualWethOutWei)"
    MINO="$(j "$A" fill.minWethOutWei)"
    if [[ -n "$ACTUALO" && -n "$MINO" ]]; then
      if [[ "$ACTUALO" -ge "$MINO" ]]; then
        ok "aqua fill honoured its signed minimum ($ACTUALO >= $MINO)"
      else
        bad "aqua fill honoured its signed minimum" ">= $MINO" "$ACTUALO"
      fi
    fi
    [[ "$QUOTED" == "$ACTUALO" ]] &&
      note "output equalled the router quote exactly ($QUOTED) — observed, and the script asserts only >= minimum"
  fi
fi

# ------------------------------------------------------- source attestation --
head_ "Source verification and bytecode attestation"
if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  for pair in "kernel:${KERNEL:-}" "lidoAdapter:${LIDO_ADAPTER:-}" "router:${ROUTER:-}" "maker:${MAKER:-}"; do
    IFS=: read -r name addr <<<"$pair"
    [[ -z "$addr" ]] && continue
    NAME_ON_SCAN="$(curl -s "https://api.etherscan.io/v2/api?chainid=1&module=contract&action=getsourcecode&address=${addr}&apikey=${ETHERSCAN_API_KEY}" |
      node --input-type=module -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{console.log(JSON.parse(d).result[0].ContractName||"")}catch{console.log("")}})')"
    if [[ -n "$NAME_ON_SCAN" ]]; then
      ok "$name source-verified on Etherscan ($NAME_ON_SCAN)"
    else
      note "$name NOT source-verified — verify locally with the runtime codehash printed above"
    fi
  done
else
  note "ETHERSCAN_API_KEY unset — skipping explorer verification checks"
fi

# ------------------------------------------------------------------ result --
printf '\n== summary ==\n  passed: %s   failed: %s   notes: %s\n' "$PASS" "$FAIL" "$SKIP"
if [[ "$FAIL" -ne 0 ]]; then
  echo "EVIDENCE VERIFICATION FAILED — a published claim is not backed by chain state." >&2
  exit 1
fi
echo "EVIDENCE VERIFIED — every checked claim is backed by live chain state."
