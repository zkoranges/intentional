#!/usr/bin/env bash
set -Eeuo pipefail

# Watches a Lido withdrawal request until it is finalizable, then prints the
# exact claim command. Lido finalization is an external clock nothing in this
# repo controls, so this is the only way to know when the last outstanding
# evidence item (the factor's claim) unblocks.
#
# Read-only: no keys, no broadcasts. It never claims anything itself — the
# claim is a user-authorized transaction.
#
#   ETH_RPC_URL=https://... ./scripts/watch-unsteth-finalization.sh          # single check
#   WATCH_INTERVAL=900 ./scripts/watch-unsteth-finalization.sh --follow      # poll until finalized
#
# Exit 0 = finalized and claimable. Exit 2 = still pending (single-check mode).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
RPC="${ETH_RPC_URL:?ETH_RPC_URL is required (read-only access is enough)}"
QUEUE=0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1
INTERVAL="${WATCH_INTERVAL:-900}"
FOLLOW=0
[[ "${1:-}" == "--follow" ]] && FOLLOW=1

manifest() {
  node --input-type=module -e \
    'import fs from "node:fs"; let o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); for (const k of process.argv[2].split(".")) o=o?.[k]; console.log(o ?? "");' \
    "$1" "$2" 2>/dev/null
}

REQUEST_ID="${REQUEST_ID:-$(manifest deployments/mainnet-v2.json factoringFill.unstETHRequestId)}"
OWNER_EXPECTED="${OWNER_EXPECTED:-$(manifest deployments/mainnet-v2.json factor)}"
if [[ -z "$REQUEST_ID" ]]; then
  echo "No request id: set REQUEST_ID, or record factoringFill.unstETHRequestId in the manifest." >&2
  exit 1
fi

check() {
  local status clean face shares owner finalized claimed last_finalized
  status="$(cast call "$QUEUE" \
    'getWithdrawalStatus(uint256[])((uint256,uint256,address,uint256,bool,bool)[])' \
    "[${REQUEST_ID}]" --rpc-url "$RPC")"
  # cast annotates integers as `123 [1.23e2]` — strip that before splitting.
  clean="$(printf '%s' "$status" | sed -E 's/\[[0-9.]+e[0-9]+\]//g' | tr -d ' ()[]')"
  face="$(printf '%s' "$clean" | awk -F, '{print $1}')"
  shares="$(printf '%s' "$clean" | awk -F, '{print $2}')"
  owner="$(printf '%s' "$status" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)"
  finalized="$(printf '%s' "$clean" | awk -F, '{print $5}')"
  claimed="$(printf '%s' "$clean" | awk -F, '{print $6}')"
  last_finalized="$(cast call "$QUEUE" 'getLastFinalizedRequestId()(uint256)' --rpc-url "$RPC" 2>/dev/null |
    sed -E 's/\[[0-9.]+e[0-9]+\]//g' | tr -d ' ' || echo "?")"

  printf '%s  unstETH #%s  finalized=%-5s claimed=%-5s  queue finalized through #%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REQUEST_ID" "$finalized" "$claimed" "$last_finalized"

  if [[ "$claimed" == "true" ]]; then
    echo
    echo "ALREADY CLAIMED — nothing outstanding. Update the manifest to 'claim collected'"
    echo "and record the ETH received plus any impairment versus the ${face} wei face value."
    return 0
  fi

  if [[ "$finalized" == "true" ]]; then
    local hint
    hint="$(cast call "$QUEUE" 'findCheckpointHints(uint256[],uint256,uint256)(uint256[])' \
      "[${REQUEST_ID}]" 1 "$(cast call "$QUEUE" 'getLastCheckpointIndex()(uint256)' --rpc-url "$RPC" |
        sed -E 's/\[[0-9.]+e[0-9]+\]//g' | tr -d ' ')" --rpc-url "$RPC" 2>/dev/null |
      tr -d ' []' || echo "")"
    cat <<EOF

FINALIZED AND CLAIMABLE.

  request       #${REQUEST_ID}
  owner         ${owner}   (expected ${OWNER_EXPECTED})
  face value    ${face} wei stETH
  shares        ${shares}
  checkpoint    ${hint:-<derive with findCheckpointHints>}

Claim is a user-authorized transaction — simulate, present, then broadcast:

  cast call ${QUEUE} "claimWithdrawal(uint256)" ${REQUEST_ID} \\
    --from ${owner} --rpc-url "\$ETH_RPC_URL"

  cast send ${QUEUE} "claimWithdrawal(uint256)" ${REQUEST_ID} \\
    --account <fresh-keystore> --rpc-url "\$ETH_RPC_URL"

Afterwards: record the receipt, the exact ETH received, any impairment against
the face value above, and set the manifest to 'claim collected'.
EOF
    return 0
  fi

  return 2
}

if [[ "$FOLLOW" -eq 0 ]]; then
  check
  exit $?
fi

echo "Polling every ${INTERVAL}s until unstETH #${REQUEST_ID} finalizes. Ctrl-C to stop."
while true; do
  if check; then
    exit 0
  fi
  sleep "$INTERVAL"
done
