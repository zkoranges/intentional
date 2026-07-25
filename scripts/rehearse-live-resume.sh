#!/usr/bin/env bash
set -Eeuo pipefail

# Resume-aware rehearsal: forks CURRENT mainnet (with the v2 stack and the
# shipped Aqua strategy already live) and rehearses only the REMAINING
# production path against the real deployed contracts:
#   quote-bound Aqua fill -> receipt-and-calldata-verified firm Lido quote
#   -> seller fill -> paused reserve recovery.
# The factor sends via anvil impersonation; its key is used only for offline
# EIP-712 quote signing. The seller key is used on the fork only (mainnet
# seller transactions are wallet-signed by the user).
# Pristine nonce-zero deployment rehearsal remains rehearse-mainnet-complete.sh.
#
# Required env: ETH_RPC_URL, FACTOR_ADDRESS, FACTOR_PRIVATE_KEY, PRIVATE_KEY.
# Reads live addresses from deployments/mainnet-v2.json + mainnet-aqua.json.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_RPC_URL="${ETH_RPC_URL:?ETH_RPC_URL is required}"
FACTOR_ADDRESS="${FACTOR_ADDRESS:?FACTOR_ADDRESS is required}"
FACTOR_PRIVATE_KEY="${FACTOR_PRIVATE_KEY:?FACTOR_PRIVATE_KEY is required for quote signing}"
SELLER_KEY="${PRIVATE_KEY:?PRIVATE_KEY (seller wallet, fork-only use) is required}"
LOCAL_RPC_URL="http://127.0.0.1:8550"
REQUESTED_STETH="0.005"
PAYMENT_WETH="0.0049875"
PAYMENT_WEI="4987500000000000"
WETH_ADDRESS="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
STATA_WETH_ADDRESS="0x0bfc9d54Fc184518A81162F8fB99c2eACa081202"
QUEUE_ADDRESS="0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reservoir-resume.XXXXXX")"
ANVIL_LOG="${TEMP_DIR}/anvil.log"
AQUA_FILL_LOG="${TEMP_DIR}/aqua-fill.log"
QUOTE_FILE="${TEMP_DIR}/quote.json"
export FOUNDRY_BROADCAST="${TEMP_DIR}/broadcast"
ANVIL_PID=""

cleanup() {
  if [[ -n "${ANVIL_PID}" ]] && kill -0 "${ANVIL_PID}" 2>/dev/null; then
    kill "${ANVIL_PID}" 2>/dev/null || true
    wait "${ANVIL_PID}" 2>/dev/null || true
  fi
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
router_address="$(manifest deployments/mainnet-aqua.json router.address)"
maker_address="$(manifest deployments/mainnet-aqua.json maker.address)"
strategy_hash="$(manifest deployments/mainnet-aqua.json strategy.hash)"
taker_wsteth_wei="$(manifest deployments/mainnet-aqua.json taker.retainedWstETHWei)"
seller_address="$(cast wallet address --private-key "${SELLER_KEY}")"

if curl --silent --max-time 1 \
  --header "content-type: application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
  "${LOCAL_RPC_URL}" >/dev/null 2>&1; then
  echo "Port 8550 is already serving JSON-RPC." >&2
  exit 1
fi

anvil \
  --host 127.0.0.1 \
  --port 8550 \
  --chain-id 1 \
  --auto-impersonate \
  --fork-url "${UPSTREAM_RPC_URL}" \
  --allow-origin "*" \
  >"${ANVIL_LOG}" 2>&1 &
ANVIL_PID="$!"

anvil_ready=false
for _ in $(seq 1 150); do
  if curl --silent --fail --max-time 1 \
    --header "content-type: application/json" \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
    "${LOCAL_RPC_URL}" >/dev/null 2>&1; then
    anvil_ready=true
    break
  fi
  sleep 0.1
done
if [[ "${anvil_ready}" != "true" ]]; then
  echo "Disposable current-head fork did not become ready." >&2
  exit 1
fi

sealed="$(cast call "${maker_address}" 'isSealed()(bool)' --rpc-url "${LOCAL_RPC_URL}")"
if [[ "${sealed}" != "true" ]]; then
  echo "Live maker is not sealed on the fork — resume state mismatch." >&2
  exit 1
fi

upstream_gas_price="$(cast gas-price --rpc-url "${UPSTREAM_RPC_URL}")"
export GAS_PRICE_WEI_OVERRIDE="${upstream_gas_price}"

RPC_URL="${LOCAL_RPC_URL}" FACTOR_ADDRESS="${FACTOR_ADDRESS}" \
  ./scripts/check-gas-budget.sh aqua-fill

RESERVOIR_MAINNET_ACK="FILL_AQUA_INTENT_RESERVOIR_V1" \
FACTOR_ADDRESS="${FACTOR_ADDRESS}" \
AQUA_MAKER_ADDRESS="${maker_address}" \
AQUA_ROUTER_ADDRESS="${router_address}" \
TAKER_WSTETH_WEI="${taker_wsteth_wei}" \
forge script script/FillAquaIntentMainnet.s.sol:FillAquaIntentMainnet \
  --rpc-url "${LOCAL_RPC_URL}" \
  --sender "${FACTOR_ADDRESS}" \
  --unlocked \
  --broadcast \
  --slow \
  -vv >"${AQUA_FILL_LOG}" 2>&1 || {
    sed -n '1,260p' "${AQUA_FILL_LOG}" >&2
    exit 1
  }

grep -F "AQUA INTENT MAINNET |" "${AQUA_FILL_LOG}" | sed 's/^[[:space:]]*//'

fill_tx_hash="$(node --input-type=module -e '
import fs from "node:fs";
const run = JSON.parse(
  fs.readFileSync(process.argv[1] + "/FillAquaIntentMainnet.s.sol/1/run-latest.json", "utf8"),
);
const txs = run.transactions.filter((t) => t.hash);
console.log(txs[txs.length - 1].hash);
' "${FOUNDRY_BROADCAST}")"

ETH_RPC_URL="${LOCAL_RPC_URL}" \
FACTOR_PRIVATE_KEY="${FACTOR_PRIVATE_KEY}" \
KERNEL_ADDRESS="${kernel_address}" \
LIDO_ADAPTER_ADDRESS="${lido_adapter}" \
SELLER_ADDRESS="${seller_address}" \
REQUESTED_STETH="${REQUESTED_STETH}" \
PAYMENT_WETH="${PAYMENT_WETH}" \
OPERATOR_FIRM_QUOTE=1 \
AQUA_INTENT_PROOF_TX="${fill_tx_hash}" \
AQUA_ROUTER_ADDRESS="${router_address}" \
AQUA_STRATEGY_HASH="${strategy_hash}" \
AQUA_TAKER_WSTETH_WEI="${taker_wsteth_wei}" \
node --experimental-strip-types frontend/scripts/create-lido-quote.mjs >"${QUOTE_FILE}"

if ! grep -Fq '"aquaProofVerification": "receipt-and-calldata-verified"' "${QUOTE_FILE}"; then
  echo "Quote evidence is not fully receipt-and-calldata verified." >&2
  exit 1
fi

seller_weth_before="$(cast call "${WETH_ADDRESS}" "balanceOf(address)(uint256)" "${seller_address}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"

ETH_RPC_URL="${LOCAL_RPC_URL}" \
SELLER_PRIVATE_KEY="${SELLER_KEY}" \
QUOTE_FILE="${QUOTE_FILE}" \
FUNDING_ACCOUNT="${funding_account}" \
AQUA_PROOF_PASSED="1" \
node frontend/scripts/execute-lido-quote.mjs

seller_weth_after="$(cast call "${WETH_ADDRESS}" "balanceOf(address)(uint256)" "${seller_address}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
if [[ "$((seller_weth_after - seller_weth_before))" != "${PAYMENT_WEI}" ]]; then
  echo "Seller WETH delta does not equal the exact payment." >&2
  exit 1
fi
factor_requests="$(cast call "${QUEUE_ADDRESS}" "balanceOf(address)(uint256)" "${FACTOR_ADDRESS}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
if [[ "${factor_requests}" != "1" ]]; then
  echo "Factor does not own exactly one canonical withdrawal request." >&2
  exit 1
fi

cast send "${kernel_address}" "setPaused(bool)" true \
  --from "${FACTOR_ADDRESS}" --unlocked --rpc-url "${LOCAL_RPC_URL}" >/dev/null
cast send "${funding_account}" "setPaused(bool)" true \
  --from "${FACTOR_ADDRESS}" --unlocked --rpc-url "${LOCAL_RPC_URL}" >/dev/null
funding_shares="$(cast call "${STATA_WETH_ADDRESS}" "balanceOf(address)(uint256)" "${funding_account}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
cast send "${funding_account}" "withdrawShares(address,uint256)" "${FACTOR_ADDRESS}" "${funding_shares}" \
  --from "${FACTOR_ADDRESS}" --unlocked --rpc-url "${LOCAL_RPC_URL}" >/dev/null

echo "LIVE RESUME 1 | quote-bound Aqua fill succeeded against the LIVE shipped strategy; receipt ${fill_tx_hash}"
echo "LIVE RESUME 2 | firm quote receipt-and-calldata verified with no bypass"
echo "LIVE RESUME 3 | seller filled: exact ${PAYMENT_WEI} wei WETH; factor owns the unstETH"
echo "LIVE RESUME 4 | paused recovery drained ${funding_shares} StataWETH shares to the factor"
echo "LIVE RESUME PASS | remaining production path proven against current mainnet state"
