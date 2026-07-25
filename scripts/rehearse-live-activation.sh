#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_RPC_URL="${ETH_RPC_URL:-}"
LOCAL_RPC_URL="http://127.0.0.1:8546"
FUNDING_WEI="${REHEARSAL_FUNDING_WEI:-2000000000000000000}"
MIN_CAPACITY_WEI="${REHEARSAL_MIN_CAPACITY_WEI:-1000000000000000000}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reservoir-activation.XXXXXX")"
ANVIL_LOG="${TEMP_DIR}/anvil.log"
DEPLOYMENT_LOG="${TEMP_DIR}/deployment.log"
DEPLOYMENT_JSON="${TEMP_DIR}/deployment.json"
BAD_ACK_LOG="${TEMP_DIR}/bad-ack.log"
OVERCAP_LOG="${TEMP_DIR}/overcap.log"
WRONG_HASH_LOG="${TEMP_DIR}/wrong-hash.log"
FUNDING_LOG="${TEMP_DIR}/funding.log"
ACTIVATION_LOG="${TEMP_DIR}/activation.log"
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
  echo "ETH_RPC_URL is required for the current-head chain-1 activation rehearsal." >&2
  exit 1
fi

for command_name in anvil cast forge node curl grep; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Activation rehearsal requires '${command_name}' on PATH." >&2
    exit 1
  fi
done

if [[ "$(cast chain-id --rpc-url "${UPSTREAM_RPC_URL}")" != "1" ]]; then
  echo "ETH_RPC_URL must target Ethereum mainnet." >&2
  exit 1
fi

if curl --silent --max-time 1 \
  --header "content-type: application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
  "${LOCAL_RPC_URL}" >/dev/null 2>&1; then
  echo "Port 8546 is already serving JSON-RPC. Stop it before running this rehearsal." >&2
  exit 1
fi

cd "${REPO_ROOT}"

anvil \
  --host 127.0.0.1 \
  --port 8546 \
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

if RESERVOIR_MAINNET_ACK="WRONG_ACKNOWLEDGEMENT" \
  FACTOR_ADDRESS="${factor_address}" \
  forge script script/DeployV2Mainnet.s.sol:DeployV2Mainnet \
    --rpc-url "${LOCAL_RPC_URL}" \
    --sender "${factor_address}" \
    --private-key "${factor_key}" \
    -vv >"${BAD_ACK_LOG}" 2>&1; then
  echo "Deployment script accepted an invalid acknowledgement." >&2
  exit 1
fi
if ! grep -Fq "deployment acknowledgement mismatch" "${BAD_ACK_LOG}"; then
  echo "Invalid acknowledgement failed for an unexpected reason." >&2
  sed -n '1,180p' "${BAD_ACK_LOG}" >&2
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

node --input-type=module - "${DEPLOYMENT_JSON}" "${factor_address}" <<'NODE'
import { readFileSync } from "node:fs";
const deployment = JSON.parse(readFileSync(process.argv[2], "utf8"));
if (
  deployment.chainId !== 1 ||
  deployment.releaseState !== "paused-unfunded" ||
  deployment.factor.toLowerCase() !== process.argv[3].toLowerCase()
) {
  throw new Error("Paused deployment output does not match the disposable factor");
}
for (const key of [
  "fundingCodeHash",
  "reserveCodeHash",
  "kernelCodeHash",
  "lidoAdapterCodeHash",
]) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(deployment[key])) {
    throw new Error(`Deployment output has an invalid ${key}`);
  }
}
NODE

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

if env \
  ETH_RPC_URL="${LOCAL_RPC_URL}" \
  EXPECTED_RELEASE_STATE="paused-unfunded" \
  "${reviewed_environment[@]}" \
  EXPECTED_FUNDING_CODEHASH="0x0000000000000000000000000000000000000000000000000000000000000000" \
  node frontend/scripts/verify-live-deployment.mjs >"${WRONG_HASH_LOG}" 2>&1; then
  echo "Verifier accepted an incorrect reviewed runtime code hash." >&2
  exit 1
fi
if ! grep -Fq "fundingAccount runtime codehash mismatch" "${WRONG_HASH_LOG}"; then
  echo "Incorrect runtime code hash failed for an unexpected reason." >&2
  sed -n '1,180p' "${WRONG_HASH_LOG}" >&2
  exit 1
fi

if env \
  RESERVOIR_MAINNET_ACK="FUND_PAUSED_RESERVOIR_V2" \
  FUNDING_WETH_WEI="5000000000000000001" \
  MIN_CAPACITY_WEI="${MIN_CAPACITY_WEI}" \
  "${reviewed_environment[@]}" \
  forge script script/FundV2Mainnet.s.sol:FundV2Mainnet \
    --rpc-url "${LOCAL_RPC_URL}" \
    --sender "${factor_address}" \
    --private-key "${factor_key}" \
    -vv >"${OVERCAP_LOG}" 2>&1; then
  echo "Funding script accepted funding above the jury cap." >&2
  exit 1
fi
if ! grep -Fq "funding outside jury bounds" "${OVERCAP_LOG}"; then
  echo "Over-cap funding failed for an unexpected reason." >&2
  sed -n '1,180p' "${OVERCAP_LOG}" >&2
  exit 1
fi

cast send \
  0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
  "deposit()" \
  --value "${FUNDING_WEI}" \
  --private-key "${factor_key}" \
  --rpc-url "${LOCAL_RPC_URL}" \
  >/dev/null

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

echo "ACTIVATION REHEARSAL 1 | exact release deployed paused and unfunded"
echo "ACTIVATION REHEARSAL 2 | acknowledgement and funding cap fail closed for the expected reasons"
echo "ACTIVATION REHEARSAL 3 | exact runtime hash mismatch rejected; reviewed bindings verified"
echo "ACTIVATION REHEARSAL 4 | capped WETH deposited into canonical StataWETH while settlement stayed paused"
echo "ACTIVATION REHEARSAL 5 | independently verified release activated with one final unpause"
echo "ACTIVATION REHEARSAL PASS | no persistent transaction broadcast"
