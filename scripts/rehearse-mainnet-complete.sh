#!/usr/bin/env bash
set -Eeuo pipefail

# The single complete mainnet rehearsal (docs/MAINNET_MICRO_DEMO.md, blocker 2):
# a current-head chain-1 fork that IMPERSONATES the real factor and uses the
# real seller wallet, reproducing the exact nonce sequence and CREATE
# addresses that mainnet will produce:
#   v2 deploy (factor nonce 0) -> verify -> fund 0.01 -> activate
#   -> Aqua router (raw create) -> maker/adapters/seed/ship -> quoted fill
#   -> capture the real fill receipt
#   -> operator firm quote WITHOUT AQUA_PROOF_ALLOW_UNVERIFIED
#   -> seller pre-approval -> fill -> reserve recovery
# The factor private key is used ONLY for offline quote signing; every factor
# transaction is sent via anvil impersonation (--unlocked).
# Required env: ETH_RPC_URL, FACTOR_ADDRESS, FACTOR_PRIVATE_KEY (signing only),
# PRIVATE_KEY (seller wallet key).
# Output: PASS lines plus deployments/rehearsal-predictions.json with the
# predicted mainnet addresses, code hashes, and strategy hash.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_RPC_URL="${ETH_RPC_URL:?ETH_RPC_URL is required}"
FACTOR_ADDRESS="${FACTOR_ADDRESS:?FACTOR_ADDRESS is required}"
FACTOR_PRIVATE_KEY="${FACTOR_PRIVATE_KEY:?FACTOR_PRIVATE_KEY is required for quote signing}"
SELLER_KEY="${PRIVATE_KEY:?PRIVATE_KEY (seller wallet) is required}"
LOCAL_RPC_URL="http://127.0.0.1:8549"
FUNDING_WEI="10000000000000000"
MIN_CAPACITY_WEI="4987500000000000"
SELLER_STAKE_WEI="5500000000000000"
REQUESTED_STETH="0.005"
PAYMENT_WETH="0.0049875"
PAYMENT_WEI="4987500000000000"
SEED_WSTETH_ETH_WEI="1200000000000000"
SEED_WETH_WEI="1200000000000000"
TAKER_INPUT_ETH_WEI="60000000000000"
WETH_ADDRESS="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
STETH_ADDRESS="0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84"
STATA_WETH_ADDRESS="0x0bfc9d54Fc184518A81162F8fB99c2eACa081202"
QUEUE_ADDRESS="0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1"
PREDICTIONS_OUT="${PREDICTIONS_OUT:-deployments/rehearsal-predictions.json}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reservoir-complete.XXXXXX")"
ANVIL_LOG="${TEMP_DIR}/anvil.log"
V2_DEPLOY_LOG="${TEMP_DIR}/v2-deploy.log"
V2_DEPLOY_JSON="${TEMP_DIR}/v2-deploy.json"
FUNDING_LOG="${TEMP_DIR}/funding.log"
ACTIVATION_LOG="${TEMP_DIR}/activation.log"
ROUTER_JSON="${TEMP_DIR}/router.json"
AQUA_DEPLOY_LOG="${TEMP_DIR}/aqua-deploy.log"
AQUA_DEPLOY_JSON="${TEMP_DIR}/aqua-deploy.json"
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

if [[ "$(cast chain-id --rpc-url "${UPSTREAM_RPC_URL}")" != "1" ]]; then
  echo "ETH_RPC_URL must target Ethereum mainnet." >&2
  exit 1
fi
if curl --silent --max-time 1 \
  --header "content-type: application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
  "${LOCAL_RPC_URL}" >/dev/null 2>&1; then
  echo "Port 8549 is already serving JSON-RPC." >&2
  exit 1
fi

seller_address="$(cast wallet address --private-key "${SELLER_KEY}")"

anvil \
  --host 127.0.0.1 \
  --port 8549 \
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

factor_nonce="$(cast nonce "${FACTOR_ADDRESS}" --rpc-url "${LOCAL_RPC_URL}")"
if [[ "${factor_nonce}" != "0" ]]; then
  echo "Factor nonce on fork is ${factor_nonce}, expected 0 — mainnet already diverged." >&2
  exit 1
fi

# Anvil's eth_gasPrice includes a synthetic ~1 gwei tip; use the live upstream
# price for the budget gates so the rehearsal reflects real mainnet economics.
upstream_gas_price="$(cast gas-price --rpc-url "${UPSTREAM_RPC_URL}")"
export GAS_PRICE_WEI_OVERRIDE="${upstream_gas_price}"
echo "COMPLETE REHEARSAL 0 | live upstream gas price ${upstream_gas_price} wei used for budget gates"

RPC_URL="${LOCAL_RPC_URL}" FACTOR_ADDRESS="${FACTOR_ADDRESS}" \
  ./scripts/check-gas-budget.sh v2-deploy

RESERVOIR_MAINNET_ACK="DEPLOY_PAUSED_UNFUNDED_RESERVOIR_V2" \
FACTOR_ADDRESS="${FACTOR_ADDRESS}" \
forge script script/DeployV2Mainnet.s.sol:DeployV2Mainnet \
  --rpc-url "${LOCAL_RPC_URL}" \
  --sender "${FACTOR_ADDRESS}" \
  --unlocked \
  --broadcast \
  --slow \
  -vv >"${V2_DEPLOY_LOG}" 2>&1 || {
    sed -n '1,260p' "${V2_DEPLOY_LOG}" >&2
    exit 1
  }

awk '
  /RESERVOIR_MAINNET_DEPLOYMENT_BEGIN/ { capture = 1; next }
  /RESERVOIR_MAINNET_DEPLOYMENT_END/ { exit }
  capture { sub(/^[[:space:]]+/, ""); print }
' "${V2_DEPLOY_LOG}" >"${V2_DEPLOY_JSON}"

jsonval() {
  node --input-type=module -e \
    'import fs from "node:fs"; console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[process.argv[2]])' \
    "$1" "$2"
}

funding_account="$(jsonval "${V2_DEPLOY_JSON}" fundingAccount)"
reserve_adapter="$(jsonval "${V2_DEPLOY_JSON}" reserveAdapter)"
kernel_address="$(jsonval "${V2_DEPLOY_JSON}" kernel)"
lido_adapter="$(jsonval "${V2_DEPLOY_JSON}" lidoAdapter)"
funding_codehash="$(jsonval "${V2_DEPLOY_JSON}" fundingCodeHash)"
reserve_codehash="$(jsonval "${V2_DEPLOY_JSON}" reserveCodeHash)"
kernel_codehash="$(jsonval "${V2_DEPLOY_JSON}" kernelCodeHash)"
lido_adapter_codehash="$(jsonval "${V2_DEPLOY_JSON}" lidoAdapterCodeHash)"

reviewed_environment=(
  "FACTOR_ADDRESS=${FACTOR_ADDRESS}"
  "FUNDING_ACCOUNT_ADDRESS=${funding_account}"
  "RESERVE_ADAPTER_ADDRESS=${reserve_adapter}"
  "KERNEL_ADDRESS=${kernel_address}"
  "LIDO_ADAPTER_ADDRESS=${lido_adapter}"
  "EXPECTED_FUNDING_CODEHASH=${funding_codehash}"
  "EXPECTED_RESERVE_CODEHASH=${reserve_codehash}"
  "EXPECTED_KERNEL_CODEHASH=${kernel_codehash}"
  "EXPECTED_LIDO_ADAPTER_CODEHASH=${lido_adapter_codehash}"
)

verify_state() {
  env \
    ETH_RPC_URL="${LOCAL_RPC_URL}" \
    EXPECTED_RELEASE_STATE="$1" \
    MIN_CAPACITY_WEI="${MIN_CAPACITY_WEI}" \
    "${reviewed_environment[@]}" \
    node frontend/scripts/verify-live-deployment.mjs >/dev/null
}

verify_state "paused-unfunded"

RPC_URL="${LOCAL_RPC_URL}" FACTOR_ADDRESS="${FACTOR_ADDRESS}" \
  ./scripts/check-gas-budget.sh v2-fund-activate

cast send "${WETH_ADDRESS}" "deposit()" \
  --value "${FUNDING_WEI}" \
  --from "${FACTOR_ADDRESS}" --unlocked \
  --rpc-url "${LOCAL_RPC_URL}" >/dev/null

env \
  RESERVOIR_MAINNET_ACK="FUND_PAUSED_RESERVOIR_V2" \
  FUNDING_WETH_WEI="${FUNDING_WEI}" \
  MIN_CAPACITY_WEI="${MIN_CAPACITY_WEI}" \
  "${reviewed_environment[@]}" \
  forge script script/FundV2Mainnet.s.sol:FundV2Mainnet \
    --rpc-url "${LOCAL_RPC_URL}" \
    --sender "${FACTOR_ADDRESS}" \
    --unlocked \
    --broadcast \
    --slow \
    -vv >"${FUNDING_LOG}" 2>&1 || {
      sed -n '1,260p' "${FUNDING_LOG}" >&2
      exit 1
    }

verify_state "funded-paused"

env \
  RESERVOIR_MAINNET_ACK="ACTIVATE_VERIFIED_RESERVOIR_V2" \
  MIN_CAPACITY_WEI="${MIN_CAPACITY_WEI}" \
  "${reviewed_environment[@]}" \
  forge script script/ActivateV2Mainnet.s.sol:ActivateV2Mainnet \
    --rpc-url "${LOCAL_RPC_URL}" \
    --sender "${FACTOR_ADDRESS}" \
    --unlocked \
    --broadcast \
    --slow \
    -vv >"${ACTIVATION_LOG}" 2>&1 || {
      sed -n '1,260p' "${ACTIVATION_LOG}" >&2
      exit 1
    }

verify_state "active"

RPC_URL="${LOCAL_RPC_URL}" FACTOR_ADDRESS="${FACTOR_ADDRESS}" \
  ./scripts/check-gas-budget.sh aqua-router

RPC_URL="${LOCAL_RPC_URL}" \
FACTOR_ADDRESS="${FACTOR_ADDRESS}" \
ROUTER_DEPLOY_IMPERSONATE=1 \
RESERVOIR_MAINNET_ACK="DEPLOY_AQUA_ROUTER_RESERVOIR_V1" \
./scripts/deploy-aqua-router.sh | awk '
  /RESERVOIR_AQUA_ROUTER_BEGIN/ { capture = 1; next }
  /RESERVOIR_AQUA_ROUTER_END/ { exit }
  capture { print }
' >"${ROUTER_JSON}"

router_address="$(jsonval "${ROUTER_JSON}" router)"
router_codehash="$(jsonval "${ROUTER_JSON}" runtimeCodeHash)"

RPC_URL="${LOCAL_RPC_URL}" FACTOR_ADDRESS="${FACTOR_ADDRESS}" \
  ./scripts/check-gas-budget.sh aqua-deploy

RESERVOIR_MAINNET_ACK="DEPLOY_AQUA_INTENT_RESERVOIR_V1" \
FACTOR_ADDRESS="${FACTOR_ADDRESS}" \
AQUA_ROUTER_ADDRESS="${router_address}" \
EXPECTED_ROUTER_CODEHASH="${router_codehash}" \
SEED_WSTETH_ETH_WEI="${SEED_WSTETH_ETH_WEI}" \
SEED_WETH_WEI="${SEED_WETH_WEI}" \
TAKER_INPUT_ETH_WEI="${TAKER_INPUT_ETH_WEI}" \
forge script script/DeployAquaIntentMainnet.s.sol:DeployAquaIntentMainnet \
  --rpc-url "${LOCAL_RPC_URL}" \
  --sender "${FACTOR_ADDRESS}" \
  --unlocked \
  --broadcast \
  --slow \
  -vv >"${AQUA_DEPLOY_LOG}" 2>&1 || {
    sed -n '1,260p' "${AQUA_DEPLOY_LOG}" >&2
    exit 1
  }

awk '
  /RESERVOIR_AQUA_INTENT_DEPLOYMENT_BEGIN/ { capture = 1; next }
  /RESERVOIR_AQUA_INTENT_DEPLOYMENT_END/ { exit }
  capture { sub(/^[[:space:]]+/, ""); print }
' "${AQUA_DEPLOY_LOG}" >"${AQUA_DEPLOY_JSON}"

maker_address="$(jsonval "${AQUA_DEPLOY_JSON}" maker)"
strategy_hash="$(jsonval "${AQUA_DEPLOY_JSON}" strategyHash)"
taker_wsteth_wei="$(jsonval "${AQUA_DEPLOY_JSON}" takerWstETHWei)"

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

fill_tx_hash="$(node --input-type=module -e '
import fs from "node:fs";
const run = JSON.parse(
  fs.readFileSync(process.argv[1] + "/FillAquaIntentMainnet.s.sol/1/run-latest.json", "utf8"),
);
const txs = run.transactions.filter((t) => t.hash);
console.log(txs[txs.length - 1].hash);
' "${FOUNDRY_BROADCAST}")"
if [[ ! "${fill_tx_hash}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  echo "Could not extract the Aqua fill transaction hash." >&2
  exit 1
fi

cast send "${STETH_ADDRESS}" "submit(address)" "0x0000000000000000000000000000000000000000" \
  --value "${SELLER_STAKE_WEI}" \
  --private-key "${SELLER_KEY}" \
  --rpc-url "${LOCAL_RPC_URL}" >/dev/null

cast send "${STETH_ADDRESS}" "approve(address,uint256)" "${lido_adapter}" "5000000000000000" \
  --private-key "${SELLER_KEY}" \
  --rpc-url "${LOCAL_RPC_URL}" >/dev/null

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
  sed -n '1,80p' "${QUOTE_FILE}" >&2
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

RPC_URL="${LOCAL_RPC_URL}" FACTOR_ADDRESS="${FACTOR_ADDRESS}" \
  ./scripts/check-gas-budget.sh recovery

cast send "${kernel_address}" "setPaused(bool)" true \
  --from "${FACTOR_ADDRESS}" --unlocked --rpc-url "${LOCAL_RPC_URL}" >/dev/null
cast send "${funding_account}" "setPaused(bool)" true \
  --from "${FACTOR_ADDRESS}" --unlocked --rpc-url "${LOCAL_RPC_URL}" >/dev/null
funding_shares="$(cast call "${STATA_WETH_ADDRESS}" "balanceOf(address)(uint256)" "${funding_account}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
cast send "${funding_account}" "withdrawShares(address,uint256)" "${FACTOR_ADDRESS}" "${funding_shares}" \
  --from "${FACTOR_ADDRESS}" --unlocked --rpc-url "${LOCAL_RPC_URL}" >/dev/null
cast send "${STATA_WETH_ADDRESS}" "redeem(uint256,address,address)" \
  "${funding_shares}" "${FACTOR_ADDRESS}" "${FACTOR_ADDRESS}" \
  --from "${FACTOR_ADDRESS}" --unlocked --rpc-url "${LOCAL_RPC_URL}" >/dev/null
factor_weth="$(cast call "${WETH_ADDRESS}" "balanceOf(address)(uint256)" "${FACTOR_ADDRESS}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"

mkdir -p "$(dirname "${PREDICTIONS_OUT}")"
node --input-type=module -e '
import fs from "node:fs";
const [out, ...pairs] = process.argv.slice(1);
const record = {};
for (const pair of pairs) {
  const index = pair.indexOf("=");
  record[pair.slice(0, index)] = pair.slice(index + 1);
}
fs.writeFileSync(out, JSON.stringify(record, null, 2) + "\n");
' "${PREDICTIONS_OUT}" \
  "chainId=1" \
  "factor=${FACTOR_ADDRESS}" \
  "seller=${seller_address}" \
  "kernel=${kernel_address}" \
  "fundingAccount=${funding_account}" \
  "reserveAdapter=${reserve_adapter}" \
  "lidoAdapter=${lido_adapter}" \
  "kernelCodeHash=${kernel_codehash}" \
  "fundingCodeHash=${funding_codehash}" \
  "reserveCodeHash=${reserve_codehash}" \
  "lidoAdapterCodeHash=${lido_adapter_codehash}" \
  "aquaRouter=${router_address}" \
  "aquaRouterCodeHash=${router_codehash}" \
  "aquaMaker=${maker_address}" \
  "aquaStrategyHash=${strategy_hash}" \
  "aquaTakerWstEthWei=${taker_wsteth_wei}"

echo "COMPLETE REHEARSAL 1 | factor impersonated at nonce 0; v2 deployed, funded 0.01 WETH, verified, activated"
echo "COMPLETE REHEARSAL 2 | Aqua router raw-created, maker seeded, strategy shipped to canonical Aqua"
echo "COMPLETE REHEARSAL 3 | quote-bound Aqua intent filled; receipt ${fill_tx_hash}"
echo "COMPLETE REHEARSAL 4 | operator firm quote fully receipt-and-calldata verified (no rehearsal bypass)"
echo "COMPLETE REHEARSAL 5 | seller pre-approved, filled: exact ${PAYMENT_WEI} wei WETH; factor owns the unstETH"
echo "COMPLETE REHEARSAL 6 | reserve recovered to ${factor_weth} wei WETH under factor control"
echo "COMPLETE REHEARSAL 7 | predicted mainnet addresses written to ${PREDICTIONS_OUT}"
echo "COMPLETE REHEARSAL PASS | exact mainnet sequence reproduced end to end on a current-head fork"
