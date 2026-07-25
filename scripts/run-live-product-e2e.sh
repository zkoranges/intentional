#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_RPC_URL="${ETH_RPC_URL:-}"
LOCAL_RPC_URL="http://127.0.0.1:8545"
FORK_BLOCK="25604561"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reservoir-live-e2e.XXXXXX")"
ANVIL_LOG="${TEMP_DIR}/anvil.log"
DEPLOYMENT_LOG="${TEMP_DIR}/deployment.log"
DEPLOYMENT_JSON="${TEMP_DIR}/deployment.json"
QUOTE_FILE="${TEMP_DIR}/quote.json"
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
  echo "ETH_RPC_URL is required and must provide archive access to mainnet block ${FORK_BLOCK}." >&2
  exit 1
fi

for command_name in anvil cast forge node curl; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Live product rehearsal requires '${command_name}' on PATH." >&2
    exit 1
  fi
done

if curl --silent --max-time 1 \
  --header "content-type: application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
  "${LOCAL_RPC_URL}" >/dev/null 2>&1; then
  echo "Port 8545 is already serving JSON-RPC. Stop it before running this rehearsal." >&2
  exit 1
fi

cd "${REPO_ROOT}"

aqua_output="$(
  forge test \
    --match-path "test/fork/AaveStataUSDC.t.sol" \
    --match-test "test_ProductionAaveUSDCToWETHSwapAndReinvest" \
    --fork-url "${UPSTREAM_RPC_URL}" 2>&1
)" || {
  echo "${aqua_output}" >&2
  exit 1
}
if [[ "${aqua_output}" != *"1 passed; 0 failed; 0 skipped"* ]]; then
  echo "Canonical Aqua/Aave companion proof did not report a clean pass." >&2
  echo "${aqua_output}" >&2
  exit 1
fi

anvil \
  --host 127.0.0.1 \
  --port 8545 \
  --chain-id 1 \
  --accounts 3 \
  --balance 10000 \
  --mnemonic-random 24 \
  --fork-url "${UPSTREAM_RPC_URL}" \
  --fork-block-number "${FORK_BLOCK}" \
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
  echo "Disposable mainnet fork did not become ready. Log follows:" >&2
  sed -n '1,160p' "${ANVIL_LOG}" >&2
  exit 1
fi

factor_key="$(
  awk '/Private Keys/{capture=1; next} capture && $1 == "(0)" {print $2; exit}' "${ANVIL_LOG}"
)"
seller_key="$(
  awk '/Private Keys/{capture=1; next} capture && $1 == "(1)" {print $2; exit}' "${ANVIL_LOG}"
)"
if [[ ! "${factor_key}" =~ ^0x[0-9a-fA-F]{64}$ ]] || [[ ! "${seller_key}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  echo "Could not derive disposable Anvil accounts. Log follows:" >&2
  sed -n '1,160p' "${ANVIL_LOG}" >&2
  exit 1
fi

factor_address="$(cast wallet address --private-key "${factor_key}")"
seller_address="$(cast wallet address --private-key "${seller_key}")"

FACTOR_PRIVATE_KEY="${factor_key}" \
SELLER_PRIVATE_KEY="${seller_key}" \
forge script script/DeployV2MainnetFork.s.sol:DeployV2MainnetFork \
  --rpc-url "${LOCAL_RPC_URL}" \
  --broadcast \
  --slow \
  -vv >"${DEPLOYMENT_LOG}" 2>&1 || {
    sed -n '1,260p' "${DEPLOYMENT_LOG}" >&2
    exit 1
  }

awk '
  /RESERVOIR_LIVE_DEPLOYMENT_BEGIN/ { capture = 1; next }
  /RESERVOIR_LIVE_DEPLOYMENT_END/ { exit }
  capture {
    sub(/^[[:space:]]+/, "")
    print
  }
' "${DEPLOYMENT_LOG}" >"${DEPLOYMENT_JSON}"

node --input-type=module - "${DEPLOYMENT_JSON}" "${factor_address}" "${seller_address}" <<'NODE'
import { readFileSync } from "node:fs";
const deployment = JSON.parse(readFileSync(process.argv[2], "utf8"));
if (
  deployment.chainId !== 1 ||
  deployment.factor.toLowerCase() !== process.argv[3].toLowerCase() ||
  deployment.seller.toLowerCase() !== process.argv[4].toLowerCase()
) {
  throw new Error("Deployment output does not match the disposable signers");
}
NODE

deployment_value() {
  node --input-type=module -e \
    'import fs from "node:fs"; console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[process.argv[2]])' \
    "${DEPLOYMENT_JSON}" "$1"
}

kernel_address="$(deployment_value kernel)"
lido_adapter_address="$(deployment_value lidoAdapter)"
funding_account="$(deployment_value fundingAccount)"
reserve_adapter_address="$(deployment_value reserveAdapter)"
funding_codehash="$(deployment_value fundingCodeHash)"
reserve_codehash="$(deployment_value reserveCodeHash)"
kernel_codehash="$(deployment_value kernelCodeHash)"
lido_adapter_codehash="$(deployment_value lidoAdapterCodeHash)"

ETH_RPC_URL="${LOCAL_RPC_URL}" \
FACTOR_ADDRESS="${factor_address}" \
KERNEL_ADDRESS="${kernel_address}" \
FUNDING_ACCOUNT_ADDRESS="${funding_account}" \
RESERVE_ADAPTER_ADDRESS="${reserve_adapter_address}" \
LIDO_ADAPTER_ADDRESS="${lido_adapter_address}" \
EXPECTED_FUNDING_CODEHASH="${funding_codehash}" \
EXPECTED_RESERVE_CODEHASH="${reserve_codehash}" \
EXPECTED_KERNEL_CODEHASH="${kernel_codehash}" \
EXPECTED_LIDO_ADAPTER_CODEHASH="${lido_adapter_codehash}" \
EXPECTED_RELEASE_STATE="active" \
MIN_CAPACITY_WEI="1000000000000000000" \
node frontend/scripts/verify-live-deployment.mjs >/dev/null

ETH_RPC_URL="${LOCAL_RPC_URL}" \
FACTOR_PRIVATE_KEY="${factor_key}" \
KERNEL_ADDRESS="${kernel_address}" \
LIDO_ADAPTER_ADDRESS="${lido_adapter_address}" \
SELLER_ADDRESS="${seller_address}" \
REQUESTED_STETH="0.9" \
PAYMENT_WETH="0.89775" \
node frontend/scripts/create-lido-quote.mjs >"${QUOTE_FILE}"

ETH_RPC_URL="${LOCAL_RPC_URL}" \
SELLER_PRIVATE_KEY="${seller_key}" \
QUOTE_FILE="${QUOTE_FILE}" \
FUNDING_ACCOUNT="${funding_account}" \
AQUA_PROOF_PASSED="1" \
node frontend/scripts/execute-lido-quote.mjs

echo "LIVE E2E PASS | exact release bytecode exercised against production Lido and Aave state"
