#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_RPC_URL="${ETH_RPC_URL:-}"
LOCAL_RPC_URL="http://127.0.0.1:8547"
SEED_WSTETH_ETH_WEI="${REHEARSAL_SEED_WSTETH_ETH_WEI:-1200000000000000}"
SEED_WETH_WEI="${REHEARSAL_SEED_WETH_WEI:-1200000000000000}"
TAKER_INPUT_ETH_WEI="${REHEARSAL_TAKER_INPUT_ETH_WEI:-60000000000000}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reservoir-aqua-intent.XXXXXX")"
ANVIL_LOG="${TEMP_DIR}/anvil.log"
DEPLOY_LOG="${TEMP_DIR}/deploy.log"
DEPLOY_JSON="${TEMP_DIR}/deploy.json"
BAD_ACK_LOG="${TEMP_DIR}/bad-ack.log"
FILL_LOG="${TEMP_DIR}/fill.log"
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
  echo "ETH_RPC_URL is required for the current-head Aqua intent rehearsal." >&2
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
  echo "Port 8547 is already serving JSON-RPC. Stop it before running this rehearsal." >&2
  exit 1
fi

cd "${REPO_ROOT}"

anvil \
  --host 127.0.0.1 \
  --port 8547 \
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

# Deploy the router with a raw creation transaction: forge's broadcast encoder
# nondeterministically mis-decodes this contract's string constructor args.
router_bytecode="$(forge inspect ReservoirSwapVMRouter bytecode)"
router_ctor_args="$(cast abi-encode 'constructor(address,address,address,string,string)' \
  0x499943E74FB0cE105688beeE8Ef2ABec5D936d31 \
  0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
  "${factor_address}" \
  'Reservoir Aqua Intent' \
  '1')"
router_address="$(
  cast send \
    --private-key "${factor_key}" \
    --rpc-url "${LOCAL_RPC_URL}" \
    --json \
    --create "${router_bytecode}${router_ctor_args#0x}" \
    | node --input-type=module -e \
      'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).contractAddress))'
)"
if [[ ! "${router_address}" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Router creation transaction did not return a contract address." >&2
  exit 1
fi

if RESERVOIR_MAINNET_ACK="WRONG_ACKNOWLEDGEMENT" \
  FACTOR_ADDRESS="${factor_address}" \
  AQUA_ROUTER_ADDRESS="${router_address}" \
  SEED_WSTETH_ETH_WEI="${SEED_WSTETH_ETH_WEI}" \
  SEED_WETH_WEI="${SEED_WETH_WEI}" \
  forge script script/DeployAquaIntentMainnet.s.sol:DeployAquaIntentMainnet \
    --rpc-url "${LOCAL_RPC_URL}" \
    --sender "${factor_address}" \
    --private-key "${factor_key}" \
    -vv >"${BAD_ACK_LOG}" 2>&1; then
  echo "Aqua intent deployment accepted an invalid acknowledgement." >&2
  exit 1
fi
if ! grep -Fq "aqua intent deployment acknowledgement mismatch" "${BAD_ACK_LOG}"; then
  echo "Invalid acknowledgement failed for an unexpected reason." >&2
  sed -n '1,120p' "${BAD_ACK_LOG}" >&2
  exit 1
fi

RESERVOIR_MAINNET_ACK="DEPLOY_AQUA_INTENT_RESERVOIR_V1" \
FACTOR_ADDRESS="${factor_address}" \
AQUA_ROUTER_ADDRESS="${router_address}" \
SEED_WSTETH_ETH_WEI="${SEED_WSTETH_ETH_WEI}" \
SEED_WETH_WEI="${SEED_WETH_WEI}" \
TAKER_INPUT_ETH_WEI="${TAKER_INPUT_ETH_WEI}" \
forge script script/DeployAquaIntentMainnet.s.sol:DeployAquaIntentMainnet \
  --rpc-url "${LOCAL_RPC_URL}" \
  --sender "${factor_address}" \
  --private-key "${factor_key}" \
  --broadcast \
  --slow \
  -vv >"${DEPLOY_LOG}" 2>&1 || {
    sed -n '1,260p' "${DEPLOY_LOG}" >&2
    exit 1
  }

awk '
  /RESERVOIR_AQUA_INTENT_DEPLOYMENT_BEGIN/ { capture = 1; next }
  /RESERVOIR_AQUA_INTENT_DEPLOYMENT_END/ { exit }
  capture {
    sub(/^[[:space:]]+/, "")
    print
  }
' "${DEPLOY_LOG}" >"${DEPLOY_JSON}"

deployment_value() {
  node --input-type=module -e \
    'import fs from "node:fs"; console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[process.argv[2]])' \
    "${DEPLOY_JSON}" "$1"
}

maker_address="$(deployment_value maker)"
router_address="$(deployment_value router)"
strategy_hash="$(deployment_value strategyHash)"

RESERVOIR_MAINNET_ACK="FILL_AQUA_INTENT_RESERVOIR_V1" \
FACTOR_ADDRESS="${factor_address}" \
AQUA_MAKER_ADDRESS="${maker_address}" \
AQUA_ROUTER_ADDRESS="${router_address}" \
forge script script/FillAquaIntentMainnet.s.sol:FillAquaIntentMainnet \
  --rpc-url "${LOCAL_RPC_URL}" \
  --sender "${factor_address}" \
  --private-key "${factor_key}" \
  --broadcast \
  --slow \
  -vv >"${FILL_LOG}" 2>&1 || {
    sed -n '1,260p' "${FILL_LOG}" >&2
    exit 1
  }

if ! grep -Fq "RESERVOIR_AQUA_INTENT_FILL_BEGIN" "${FILL_LOG}"; then
  echo "Aqua intent fill did not emit its manifest." >&2
  sed -n '1,200p' "${FILL_LOG}" >&2
  exit 1
fi

echo "AQUA INTENT REHEARSAL 1 | wrong acknowledgement failed closed"
echo "AQUA INTENT REHEARSAL 2 | router, maker, and adapters deployed; strategy ${strategy_hash} shipped to canonical Aqua"
echo "AQUA INTENT REHEARSAL 3 | exact-input wstETH -> WETH intent filled with postconditions"
grep -F "AQUA INTENT MAINNET |" "${FILL_LOG}" | sed 's/^[[:space:]]*//'
echo "AQUA INTENT REHEARSAL PASS | no persistent transaction broadcast"
