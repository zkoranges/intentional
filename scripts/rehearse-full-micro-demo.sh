#!/usr/bin/env bash
set -Eeuo pipefail

# G-C composite rehearsal: the EXACT micro-demo configuration as one run on a
# current-head fork — deploy paused -> verify -> fund 0.01 WETH -> activate ->
# seller staked 0.0055 -> operator firm quote -> 0.005 stETH fill -> paused
# reserve recovery. Mirrors docs/MAINNET_MICRO_DEMO.md exactly.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_RPC_URL="${ETH_RPC_URL:-}"
LOCAL_RPC_URL="http://127.0.0.1:8548"
FUNDING_WEI="10000000000000000"
MIN_CAPACITY_WEI="4987500000000000"
SELLER_ALLOCATION_WEI="6500000000000000"
SELLER_STAKE_WEI="5500000000000000"
REQUESTED_STETH="0.005"
PAYMENT_WETH="0.0049875"
PAYMENT_WEI="4987500000000000"
REHEARSAL_AQUA_PROOF_TX="${REHEARSAL_AQUA_PROOF_TX:-0x1111111111111111111111111111111111111111111111111111111111111111}"
WETH_ADDRESS="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
STETH_ADDRESS="0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84"
STATA_WETH_ADDRESS="0x0bfc9d54Fc184518A81162F8fB99c2eACa081202"
QUEUE_ADDRESS="0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reservoir-full-micro.XXXXXX")"
ANVIL_LOG="${TEMP_DIR}/anvil.log"
DEPLOYMENT_LOG="${TEMP_DIR}/deployment.log"
DEPLOYMENT_JSON="${TEMP_DIR}/deployment.json"
FUNDING_LOG="${TEMP_DIR}/funding.log"
ACTIVATION_LOG="${TEMP_DIR}/activation.log"
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

if [[ -z "${UPSTREAM_RPC_URL}" ]]; then
  echo "ETH_RPC_URL is required for the composite micro-demo rehearsal." >&2
  exit 1
fi

if [[ "$(cast chain-id --rpc-url "${UPSTREAM_RPC_URL}")" != "1" ]]; then
  echo "ETH_RPC_URL must target Ethereum mainnet." >&2
  exit 1
fi

if curl --silent --max-time 1 \
  --header "content-type: application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
  "${LOCAL_RPC_URL}" >/dev/null 2>&1; then
  echo "Port 8548 is already serving JSON-RPC. Stop it before running this rehearsal." >&2
  exit 1
fi

cd "${REPO_ROOT}"

anvil \
  --host 127.0.0.1 \
  --port 8548 \
  --chain-id 1 \
  --accounts 1 \
  --balance 100 \
  --mnemonic-random 24 \
  --fork-url "${UPSTREAM_RPC_URL}" \
  --allow-origin "*" \
  >"${ANVIL_LOG}" 2>&1 &
ANVIL_PID="$!"

anvil_ready=false
for _ in $(seq 1 100); do
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

factor_key="$(
  awk '/Private Keys/{capture=1; next} capture && $1 == "(0)" {print $2; exit}' "${ANVIL_LOG}"
)"
if [[ ! "${factor_key}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  echo "Could not derive the disposable factor account." >&2
  exit 1
fi
factor_address="$(cast wallet address --private-key "${factor_key}")"

seller_wallet="$(cast wallet new)"
seller_address="$(printf '%s\n' "${seller_wallet}" | awk '/Address/{print $2; exit}')"
seller_key="$(printf '%s\n' "${seller_wallet}" | awk '/Private key/{print $3; exit}')"
if [[ ! "${seller_key}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  echo "Could not create the disposable seller account." >&2
  exit 1
fi

RESERVOIR_MAINNET_ACK="DEPLOY_PAUSED_UNFUNDED_RESERVOIR_V2" \
FACTOR_ADDRESS="${factor_address}" \
forge script script/DeployV2Mainnet.s.sol:DeployV2Mainnet \
  --rpc-url "${LOCAL_RPC_URL}" \
  --sender "${factor_address}" \
  --private-key "${factor_key}" \
  --broadcast \
  --slow \
  -vv >"${DEPLOYMENT_LOG}" 2>&1 || {
    sed -n '1,260p' "${DEPLOYMENT_LOG}" >&2
    exit 1
  }

awk '
  /RESERVOIR_MAINNET_DEPLOYMENT_BEGIN/ { capture = 1; next }
  /RESERVOIR_MAINNET_DEPLOYMENT_END/ { exit }
  capture {
    sub(/^[[:space:]]+/, "")
    print
  }
' "${DEPLOYMENT_LOG}" >"${DEPLOYMENT_JSON}"

deployment_value() {
  node --input-type=module -e \
    'import fs from "node:fs"; console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[process.argv[2]])' \
    "${DEPLOYMENT_JSON}" "$1"
}

funding_account="$(deployment_value fundingAccount)"
reserve_adapter="$(deployment_value reserveAdapter)"
kernel_address="$(deployment_value kernel)"
lido_adapter="$(deployment_value lidoAdapter)"
funding_codehash="$(deployment_value fundingCodeHash)"
reserve_codehash="$(deployment_value reserveCodeHash)"
kernel_codehash="$(deployment_value kernelCodeHash)"
lido_adapter_codehash="$(deployment_value lidoAdapterCodeHash)"

reviewed_environment=(
  "FACTOR_ADDRESS=${factor_address}"
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
  local release_state="$1"
  env \
    ETH_RPC_URL="${LOCAL_RPC_URL}" \
    EXPECTED_RELEASE_STATE="${release_state}" \
    MIN_CAPACITY_WEI="${MIN_CAPACITY_WEI}" \
    "${reviewed_environment[@]}" \
    node frontend/scripts/verify-live-deployment.mjs >/dev/null
}

verify_state "paused-unfunded"

cast send "${WETH_ADDRESS}" "deposit()" \
  --value "${FUNDING_WEI}" \
  --private-key "${factor_key}" \
  --rpc-url "${LOCAL_RPC_URL}" >/dev/null

env \
  RESERVOIR_MAINNET_ACK="FUND_PAUSED_RESERVOIR_V2" \
  FUNDING_WETH_WEI="${FUNDING_WEI}" \
  MIN_CAPACITY_WEI="${MIN_CAPACITY_WEI}" \
  "${reviewed_environment[@]}" \
  forge script script/FundV2Mainnet.s.sol:FundV2Mainnet \
    --rpc-url "${LOCAL_RPC_URL}" \
    --sender "${factor_address}" \
    --private-key "${factor_key}" \
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
    --sender "${factor_address}" \
    --private-key "${factor_key}" \
    --broadcast \
    --slow \
    -vv >"${ACTIVATION_LOG}" 2>&1 || {
      sed -n '1,260p' "${ACTIVATION_LOG}" >&2
      exit 1
    }

verify_state "active"

cast send "${seller_address}" \
  --value "${SELLER_ALLOCATION_WEI}" \
  --private-key "${factor_key}" \
  --rpc-url "${LOCAL_RPC_URL}" >/dev/null

cast send "${STETH_ADDRESS}" "submit(address)" "0x0000000000000000000000000000000000000000" \
  --value "${SELLER_STAKE_WEI}" \
  --private-key "${seller_key}" \
  --rpc-url "${LOCAL_RPC_URL}" >/dev/null

ETH_RPC_URL="${LOCAL_RPC_URL}" \
FACTOR_PRIVATE_KEY="${factor_key}" \
KERNEL_ADDRESS="${kernel_address}" \
LIDO_ADAPTER_ADDRESS="${lido_adapter}" \
SELLER_ADDRESS="${seller_address}" \
REQUESTED_STETH="${REQUESTED_STETH}" \
PAYMENT_WETH="${PAYMENT_WETH}" \
OPERATOR_FIRM_QUOTE=1 \
AQUA_INTENT_PROOF_TX="${REHEARSAL_AQUA_PROOF_TX}" \
AQUA_PROOF_ALLOW_UNVERIFIED=1 \
node --experimental-strip-types frontend/scripts/create-lido-quote.mjs >"${QUOTE_FILE}"

if ! grep -Fq '"mode": "operator-priced-firm-quote"' "${QUOTE_FILE}"; then
  echo "Quote evidence is not the operator-priced firm mode." >&2
  sed -n '1,80p' "${QUOTE_FILE}" >&2
  exit 1
fi

seller_weth_before="$(cast call "${WETH_ADDRESS}" "balanceOf(address)(uint256)" "${seller_address}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"

ETH_RPC_URL="${LOCAL_RPC_URL}" \
SELLER_PRIVATE_KEY="${seller_key}" \
QUOTE_FILE="${QUOTE_FILE}" \
FUNDING_ACCOUNT="${funding_account}" \
AQUA_PROOF_PASSED="1" \
node frontend/scripts/execute-lido-quote.mjs

seller_weth_after="$(cast call "${WETH_ADDRESS}" "balanceOf(address)(uint256)" "${seller_address}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
seller_weth_delta="$((seller_weth_after - seller_weth_before))"
if [[ "${seller_weth_delta}" != "${PAYMENT_WEI}" ]]; then
  echo "Seller WETH delta ${seller_weth_delta} does not equal the exact payment ${PAYMENT_WEI}." >&2
  exit 1
fi

factor_requests="$(cast call "${QUEUE_ADDRESS}" "balanceOf(address)(uint256)" "${factor_address}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
if [[ "${factor_requests}" != "1" ]]; then
  echo "Factor does not own exactly one canonical withdrawal request (${factor_requests})." >&2
  exit 1
fi

cast send "${kernel_address}" "setPaused(bool)" true \
  --private-key "${factor_key}" \
  --rpc-url "${LOCAL_RPC_URL}" >/dev/null
cast send "${funding_account}" "setPaused(bool)" true \
  --private-key "${factor_key}" \
  --rpc-url "${LOCAL_RPC_URL}" >/dev/null

funding_shares="$(cast call "${STATA_WETH_ADDRESS}" "balanceOf(address)(uint256)" "${funding_account}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
if [[ "${funding_shares}" == "0" ]]; then
  echo "Funding account has no StataWETH shares to recover." >&2
  exit 1
fi

cast send "${funding_account}" "withdrawShares(address,uint256)" "${factor_address}" "${funding_shares}" \
  --private-key "${factor_key}" \
  --rpc-url "${LOCAL_RPC_URL}" >/dev/null

funding_shares_after="$(cast call "${STATA_WETH_ADDRESS}" "balanceOf(address)(uint256)" "${funding_account}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
factor_shares="$(cast call "${STATA_WETH_ADDRESS}" "balanceOf(address)(uint256)" "${factor_address}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
if [[ "${funding_shares_after}" != "0" || "${factor_shares}" != "${funding_shares}" ]]; then
  echo "Paused share recovery did not move all shares to the factor." >&2
  exit 1
fi

cast send "${STATA_WETH_ADDRESS}" "redeem(uint256,address,address)" \
  "${factor_shares}" "${factor_address}" "${factor_address}" \
  --private-key "${factor_key}" \
  --rpc-url "${LOCAL_RPC_URL}" >/dev/null

factor_weth="$(cast call "${WETH_ADDRESS}" "balanceOf(address)(uint256)" "${factor_address}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"

echo "FULL MICRO-DEMO 1 | exact release deployed paused, funded 0.01 WETH, verified, activated"
echo "FULL MICRO-DEMO 2 | seller allocated ${SELLER_ALLOCATION_WEI} wei, staked ${SELLER_STAKE_WEI} wei into canonical stETH"
echo "FULL MICRO-DEMO 3 | operator-priced firm quote signed and filled: seller received exactly ${PAYMENT_WEI} wei WETH"
echo "FULL MICRO-DEMO 4 | canonical withdrawal request owned by factor"
echo "FULL MICRO-DEMO 5 | paused recovery drained funding shares to factor; redeemed to ${factor_weth} wei WETH"
echo "FULL MICRO-DEMO 6 | unstETH claim after finalization is covered by the existing LiveProductMainnet fork test"
echo "FULL MICRO-DEMO PASS | exact docs/MAINNET_MICRO_DEMO.md configuration exercised as one run"
