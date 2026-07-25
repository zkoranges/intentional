#!/usr/bin/env bash
set -Eeuo pipefail

# Proves the paste-free path end to end on a disposable current-head fork:
#   re-arm the demo instance (unpause + refund reserve)
#   -> run the quote signer against the fork
#   -> HTTP POST /quote (the exact call the Vercel proxy will make)
#   -> fill the returned envelope with the seller wallet
#   -> assert exact seller WETH delta and factor unstETH ownership
# Also exercises the guards: bad secret, over-ceiling amount, single-flight.
#
# Required env: ETH_RPC_URL, FACTOR_ADDRESS, FACTOR_PRIVATE_KEY, PRIVATE_KEY.
# Reads live addresses from deployments/mainnet-v2.json.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_RPC_URL="${ETH_RPC_URL:?ETH_RPC_URL is required}"
FACTOR_ADDRESS="${FACTOR_ADDRESS:?FACTOR_ADDRESS is required}"
FACTOR_PRIVATE_KEY="${FACTOR_PRIVATE_KEY:?FACTOR_PRIVATE_KEY is required}"
SELLER_KEY="${PRIVATE_KEY:?PRIVATE_KEY (seller wallet) is required}"
LOCAL_RPC_URL="http://127.0.0.1:8551"
SIGNER_URL="http://127.0.0.1:8791"
REQUESTED_STETH_WEI="5000000000000000"
PAYMENT_WEI="4987500000000000"
WETH_ADDRESS="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
QUEUE_ADDRESS="0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reservoir-signer.XXXXXX")"
ANVIL_LOG="${TEMP_DIR}/anvil.log"
SIGNER_LOG="${TEMP_DIR}/signer.log"
QUOTE_FILE="${TEMP_DIR}/quote.json"
ANVIL_PID=""
SIGNER_PID=""

cleanup() {
  for pid in "${SIGNER_PID}" "${ANVIL_PID}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT INT TERM

cd "${REPO_ROOT}"

manifest() {
  node --input-type=module -e \
    'import fs from "node:fs"; let o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); for (const k of process.argv[2].split(".")) o=o[k]; console.log(o);' \
    "$1" "$2"
}
kernel_address="$(manifest deployments/mainnet-v2.json contracts.kernel.address)"
funding_account="$(manifest deployments/mainnet-v2.json contracts.fundingAccount.address)"
lido_adapter="$(manifest deployments/mainnet-v2.json contracts.lidoAdapter.address)"
seller_address="$(cast wallet address --private-key "${SELLER_KEY}")"

if curl --silent --max-time 1 "${LOCAL_RPC_URL}" >/dev/null 2>&1; then
  echo "Port 8551 is already in use." >&2
  exit 1
fi

anvil --host 127.0.0.1 --port 8551 --chain-id 1 --auto-impersonate \
  --fork-url "${UPSTREAM_RPC_URL}" >"${ANVIL_LOG}" 2>&1 &
ANVIL_PID="$!"
for _ in $(seq 1 150); do
  curl --silent --fail --max-time 1 --header "content-type: application/json" \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
    "${LOCAL_RPC_URL}" >/dev/null 2>&1 && break
  sleep 0.1
done

echo "==> re-arming the demo instance on the fork (unpause + refund reserve)"
factor_weth="$(cast call "${WETH_ADDRESS}" "balanceOf(address)(uint256)" "${FACTOR_ADDRESS}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
if [[ "${factor_weth}" -lt "${PAYMENT_WEI}" ]]; then
  echo "Factor holds ${factor_weth} wei WETH, below the ${PAYMENT_WEI} wei payment." >&2
  exit 1
fi
cast send "${WETH_ADDRESS}" "transfer(address,uint256)" "${funding_account}" "${factor_weth}" \
  --from "${FACTOR_ADDRESS}" --unlocked --rpc-url "${LOCAL_RPC_URL}" >/dev/null
cast send "${funding_account}" "setPaused(bool)" false \
  --from "${FACTOR_ADDRESS}" --unlocked --rpc-url "${LOCAL_RPC_URL}" >/dev/null
cast send "${funding_account}" "reinvestInventory()" \
  --from "${FACTOR_ADDRESS}" --unlocked --rpc-url "${LOCAL_RPC_URL}" >/dev/null
cast send "${kernel_address}" "setPaused(bool)" false \
  --from "${FACTOR_ADDRESS}" --unlocked --rpc-url "${LOCAL_RPC_URL}" >/dev/null
capacity="$(cast call "${funding_account}" "availableFor(uint256)(uint256)" "${PAYMENT_WEI}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
if [[ "${capacity}" != "${PAYMENT_WEI}" ]]; then
  echo "Reserve capacity ${capacity} != ${PAYMENT_WEI}." >&2
  exit 1
fi

echo "==> starting the quote signer against the fork"
signer_secret="$(openssl rand -hex 32)"
HOST=127.0.0.1 PORT=8791 \
ETH_RPC_URL="${LOCAL_RPC_URL}" \
FACTOR_PRIVATE_KEY="${FACTOR_PRIVATE_KEY}" \
KERNEL_ADDRESS="${kernel_address}" \
LIDO_ADAPTER_ADDRESS="${lido_adapter}" \
SIGNER_SECRET="${signer_secret}" \
MAX_QUOTE_WEI="6000000000000000" \
SPREAD_BPS=25 \
QUOTE_TTL_SECONDS=120 \
AUDIT_LOG="${TEMP_DIR}/quote-audit.jsonl" \
node services/quote-signer/server.mjs >"${SIGNER_LOG}" 2>&1 &
SIGNER_PID="$!"
for _ in $(seq 1 100); do
  curl --silent --fail --max-time 1 "${SIGNER_URL}/health" >/dev/null 2>&1 && break
  sleep 0.1
done
if ! curl --silent --fail --max-time 2 "${SIGNER_URL}/health" >/dev/null; then
  echo "Signer did not become ready:" >&2
  sed -n '1,40p' "${SIGNER_LOG}" >&2
  exit 1
fi

echo "==> guard: wrong secret must be rejected"
status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${SIGNER_URL}/quote" \
  -H 'content-type: application/json' -H 'x-signer-secret: wrong-secret' \
  -d "{\"seller\":\"${seller_address}\",\"requestedStEth\":\"${REQUESTED_STETH_WEI}\"}")"
[[ "${status}" == "401" ]] || { echo "expected 401, got ${status}" >&2; exit 1; }

echo "==> guard: above the hard ceiling must be rejected"
status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${SIGNER_URL}/quote" \
  -H 'content-type: application/json' -H "x-signer-secret: ${signer_secret}" \
  -d "{\"seller\":\"${seller_address}\",\"requestedStEth\":\"60000000000000000\"}")"
[[ "${status}" == "400" ]] || { echo "expected 400, got ${status}" >&2; exit 1; }

echo "==> requesting a firm quote over HTTP (the call the app will make)"
curl -s --fail -X POST "${SIGNER_URL}/quote" \
  -H 'content-type: application/json' -H "x-signer-secret: ${signer_secret}" \
  -d "{\"seller\":\"${seller_address}\",\"requestedStEth\":\"${REQUESTED_STETH_WEI}\"}" >"${QUOTE_FILE}"
grep -q '"factorSignature"' "${QUOTE_FILE}" || { echo "no signature in envelope" >&2; exit 1; }

echo "==> guard: single-flight — a second request while one is outstanding"
status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${SIGNER_URL}/quote" \
  -H 'content-type: application/json' -H "x-signer-secret: ${signer_secret}" \
  -d "{\"seller\":\"${seller_address}\",\"requestedStEth\":\"${REQUESTED_STETH_WEI}\"}")"
[[ "${status}" == "409" ]] || { echo "expected 409 single-flight, got ${status}" >&2; exit 1; }

echo "==> filling the fetched envelope with the seller wallet"
seller_weth_before="$(cast call "${WETH_ADDRESS}" "balanceOf(address)(uint256)" "${seller_address}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
factor_nfts_before="$(cast call "${QUEUE_ADDRESS}" "balanceOf(address)(uint256)" "${FACTOR_ADDRESS}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"

ETH_RPC_URL="${LOCAL_RPC_URL}" \
SELLER_PRIVATE_KEY="${SELLER_KEY}" \
QUOTE_FILE="${QUOTE_FILE}" \
FUNDING_ACCOUNT="${funding_account}" \
AQUA_PROOF_PASSED="1" \
node frontend/scripts/execute-lido-quote.mjs

seller_weth_after="$(cast call "${WETH_ADDRESS}" "balanceOf(address)(uint256)" "${seller_address}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
factor_nfts_after="$(cast call "${QUEUE_ADDRESS}" "balanceOf(address)(uint256)" "${FACTOR_ADDRESS}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
delta="$((seller_weth_after - seller_weth_before))"
[[ "${delta}" == "${PAYMENT_WEI}" ]] || { echo "seller delta ${delta} != ${PAYMENT_WEI}" >&2; exit 1; }
[[ "$((factor_nfts_after - factor_nfts_before))" == "1" ]] || { echo "factor did not receive the unstETH" >&2; exit 1; }

audit_lines="$(wc -l <"${TEMP_DIR}/quote-audit.jsonl" | tr -d ' ')"

echo "SIGNER REHEARSAL 1 | demo instance re-armed on the fork; capacity exactly ${PAYMENT_WEI} wei"
echo "SIGNER REHEARSAL 2 | guards enforced: bad secret 401, over-ceiling 400, single-flight 409"
echo "SIGNER REHEARSAL 3 | firm quote delivered over HTTP with no copy-paste"
echo "SIGNER REHEARSAL 4 | seller filled the fetched envelope: exactly ${PAYMENT_WEI} wei WETH"
echo "SIGNER REHEARSAL 5 | factor owns the new canonical unstETH; audit log has ${audit_lines} entries"
echo "SIGNER REHEARSAL PASS | paste-free path proven end to end"
