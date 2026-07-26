#!/usr/bin/env bash
set -Eeuo pipefail

# Full production-contract rehearsal for the public existing-unstETH flow:
# fresh disposable deployment -> real canonical unstETH transfer -> HTTP firm
# quote -> exact NFT approval -> atomic settlement -> receipt/state assertions.
# No mock contract or persistent key is used.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_RPC_URL="${ETH_RPC_URL:?ETH_RPC_URL with archive access is required}"
LOCAL_RPC_URL="http://127.0.0.1:8551"
SIGNER_URL="http://127.0.0.1:8791"
FORK_BLOCK="25612678"
# The real canonical pending request owned by the jury-demo wallet. Its
# measured notional is one wei below the pre-alpha cap: 0.005 stETH.
REQUEST_ID="130880"
FUNDING_WEI="6000000000000000"
MIN_QUOTE_WEI="500000000000000"
MAX_QUOTE_WEI="5000000000000000"
QUEUE="0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/intentional-unsteth-e2e.XXXXXX")"
ANVIL_LOG="${TEMP_DIR}/anvil.log"
DEPLOYMENT_LOG="${TEMP_DIR}/deployment.log"
DEPLOYMENT_JSON="${TEMP_DIR}/deployment.json"
MANIFEST="${TEMP_DIR}/active-manifest.json"
QUOTE_FILE="${TEMP_DIR}/quote.json"
QUOTE_A="${TEMP_DIR}/quote-a.json"
QUOTE_B="${TEMP_DIR}/quote-b.json"
QUOTE_BODY_A="${TEMP_DIR}/quote-body-a.json"
QUOTE_BODY_B="${TEMP_DIR}/quote-body-b.json"
QUOTE_STATUS_A="${TEMP_DIR}/quote-a.status"
QUOTE_STATUS_B="${TEMP_DIR}/quote-b.status"
SIGNER_LOG="${TEMP_DIR}/signer.log"
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

for command_name in anvil cast forge node curl openssl; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "missing required command: ${command_name}" >&2
    exit 1
  }
done

cd "${REPO_ROOT}"
if curl --silent --max-time 1 "${LOCAL_RPC_URL}" >/dev/null 2>&1; then
  echo "port 8551 is already in use" >&2
  exit 1
fi

anvil --host 127.0.0.1 --port 8551 --chain-id 1 --accounts 3 --balance 10000 \
  --mnemonic-random 24 --auto-impersonate --fork-url "${UPSTREAM_RPC_URL}" \
  --fork-block-number "${FORK_BLOCK}" >"${ANVIL_LOG}" 2>&1 &
ANVIL_PID="$!"
for _ in $(seq 1 150); do
  curl --silent --fail --max-time 1 --header "content-type: application/json" \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
    "${LOCAL_RPC_URL}" >/dev/null 2>&1 && break
  sleep 0.1
done

factor_key=""
seller_key=""
for _ in $(seq 1 100); do
  factor_key="$(awk '/Private Keys/{capture=1; next} capture && $1 == "(0)" {print $2; exit}' "${ANVIL_LOG}")"
  seller_key="$(awk '/Private Keys/{capture=1; next} capture && $1 == "(1)" {print $2; exit}' "${ANVIL_LOG}")"
  if [[ "${factor_key}" =~ ^0x[0-9a-fA-F]{64}$ ]] && [[ "${seller_key}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    break
  fi
  sleep 0.05
done
[[ "${factor_key}" =~ ^0x[0-9a-fA-F]{64}$ ]] || { echo "factor key unavailable" >&2; exit 1; }
[[ "${seller_key}" =~ ^0x[0-9a-fA-F]{64}$ ]] || { echo "seller key unavailable" >&2; exit 1; }
factor_address="$(cast wallet address --private-key "${factor_key}")"
seller_address="$(cast wallet address --private-key "${seller_key}")"

echo "==> deploy fresh settlement, both Lido adapters, and productive Aave reserve"
FACTOR_PRIVATE_KEY="${factor_key}" SELLER_PRIVATE_KEY="${seller_key}" \
REHEARSAL_FUNDING_WEI="${FUNDING_WEI}" \
REHEARSAL_MIN_CAPACITY_WEI="${MAX_QUOTE_WEI}" \
forge script script/DeployV2MainnetFork.s.sol:DeployV2MainnetFork \
  --rpc-url "${LOCAL_RPC_URL}" --broadcast --slow -vv >"${DEPLOYMENT_LOG}" 2>&1 || {
    sed -n '1,260p' "${DEPLOYMENT_LOG}" >&2
    exit 1
  }
awk '
  /RESERVOIR_LIVE_DEPLOYMENT_BEGIN/ { capture = 1; next }
  /RESERVOIR_LIVE_DEPLOYMENT_END/ { exit }
  capture { sub(/^[[:space:]]+/, ""); print }
' "${DEPLOYMENT_LOG}" >"${DEPLOYMENT_JSON}"

deployment_value() {
  node --input-type=module -e \
    'import fs from "node:fs"; console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8"))[process.argv[2]])' \
    "${DEPLOYMENT_JSON}" "$1"
}
kernel="$(deployment_value kernel)"
funding="$(deployment_value fundingAccount)"
lido_adapter="$(deployment_value lidoAdapter)"
unsteth_adapter="$(deployment_value lidoUnstETHExitAdapter)"

node --input-type=module - "${DEPLOYMENT_JSON}" "${MANIFEST}" <<'NODE'
import { readFileSync, writeFileSync } from "node:fs";
const deployment = JSON.parse(readFileSync(process.argv[2], "utf8"));
writeFileSync(process.argv[3], JSON.stringify({
  schemaVersion: 2,
  chainId: 1,
  releaseState: "active",
  factor: deployment.factor,
  contracts: {
    kernel: { address: deployment.kernel },
    lidoAdapter: { address: deployment.lidoAdapter },
    lidoUnstETHExitAdapter: { address: deployment.lidoUnstETHExitAdapter },
  },
}));
NODE

echo "==> move one real canonical unstETH position to the disposable seller"
original_owner="$(cast call "${QUEUE}" "ownerOf(uint256)(address)" "${REQUEST_ID}" --rpc-url "${LOCAL_RPC_URL}")"
cast rpc anvil_setBalance "${original_owner}" 0x8AC7230489E80000 --rpc-url "${LOCAL_RPC_URL}" >/dev/null
cast send "${QUEUE}" "transferFrom(address,address,uint256)" \
  "${original_owner}" "${seller_address}" "${REQUEST_ID}" \
  --from "${original_owner}" --unlocked --rpc-url "${LOCAL_RPC_URL}" >/dev/null
owner_after="$(cast call "${QUEUE}" "ownerOf(uint256)(address)" "${REQUEST_ID}" --rpc-url "${LOCAL_RPC_URL}")"
owner_after_lower="$(printf '%s' "${owner_after}" | tr '[:upper:]' '[:lower:]')"
seller_address_lower="$(printf '%s' "${seller_address}" | tr '[:upper:]' '[:lower:]')"
[[ "${owner_after_lower}" == "${seller_address_lower}" ]] || { echo "fixture transfer failed" >&2; exit 1; }

echo "==> start the fail-closed quote desk against the fresh fork deployment"
signer_secret="$(openssl rand -hex 32)"
HOST=127.0.0.1 PORT=8791 ETH_RPC_URL="${LOCAL_RPC_URL}" \
FACTOR_PRIVATE_KEY="${factor_key}" KERNEL_ADDRESS="${kernel}" \
LIDO_ADAPTER_ADDRESS="${lido_adapter}" LIDO_UNSTETH_ADAPTER_ADDRESS="${unsteth_adapter}" \
DEPLOYMENT_MANIFEST="${MANIFEST}" SIGNER_SECRET="${signer_secret}" \
MAX_QUOTE_WEI="${MAX_QUOTE_WEI}" MIN_QUOTE_WEI="${MIN_QUOTE_WEI}" \
SPREAD_BPS=25 QUOTE_TTL_SECONDS=600 \
AUDIT_LOG="${TEMP_DIR}/audit.jsonl" RESERVATIONS_DB="${TEMP_DIR}/reservations.sqlite" \
node services/quote-signer/server.mjs >"${SIGNER_LOG}" 2>&1 &
SIGNER_PID="$!"
ready=false
for _ in $(seq 1 150); do
  health="$(curl --silent --fail --max-time 1 "${SIGNER_URL}/health" 2>/dev/null || true)"
  if [[ "${health}" == *'"state":"ready"'* ]]; then
    ready=true
    break
  fi
  sleep 0.1
done
if [[ "${ready}" != "true" ]]; then
  echo "quote desk did not become ready" >&2
  sed -n '1,100p' "${SIGNER_LOG}" >&2
  exit 1
fi

make_quote_body() {
  local output_file="$1"
  (
    cd services/quote-signer
    SELLER_PRIVATE_KEY="${seller_key}" SELLER_ADDRESS="${seller_address}" \
      REQUEST_ID="${REQUEST_ID}" OUTPUT_FILE="${output_file}" \
      node --input-type=module <<'NODE'
import { randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";
import { privateKeyToAccount } from "viem/accounts";
import {
  QUOTE_REQUEST_AUTH_CHAIN_ID,
  QUOTE_REQUEST_AUTH_VERSION,
  quoteRequestAuthorizationMessage,
} from "./request-authorization.mjs";

const account = privateKeyToAccount(process.env.SELLER_PRIVATE_KEY);
if (account.address.toLowerCase() !== process.env.SELLER_ADDRESS.toLowerCase()) {
  throw new Error("throwaway seller key/address mismatch");
}
const now = Math.floor(Date.now() / 1_000);
const authorization = {
  version: QUOTE_REQUEST_AUTH_VERSION,
  chainId: QUOTE_REQUEST_AUTH_CHAIN_ID,
  seller: account.address,
  mode: "existing-unsteth",
  requestedStEth: null,
  requestId: process.env.REQUEST_ID,
  nonce: `0x${randomBytes(32).toString("hex")}`,
  issuedAt: String(now),
  expiresAt: String(now + 60),
};
const authorizationSignature = await account.signMessage({
  message: quoteRequestAuthorizationMessage(authorization),
});
writeFileSync(
  process.env.OUTPUT_FILE,
  JSON.stringify({
    mode: "existing-unsteth",
    seller: account.address,
    requestId: process.env.REQUEST_ID,
    authorization,
    authorizationSignature,
  }),
  { mode: 0o600 },
);
NODE
  )
}
make_quote_body "${QUOTE_BODY_A}"
make_quote_body "${QUOTE_BODY_B}"

echo "==> race two authenticated real quote requests; both must recover one envelope"
quote_request() {
  local body_file="$1"
  local output_file="$2"
  local status_file="$3"
  curl --silent --output "${output_file}" --write-out '%{http_code}' \
    -X POST "${SIGNER_URL}/quote" \
    -H 'content-type: application/json' -H "x-signer-secret: ${signer_secret}" \
    --data-binary "@${body_file}" \
    >"${status_file}"
}
quote_request "${QUOTE_BODY_A}" "${QUOTE_A}" "${QUOTE_STATUS_A}" &
quote_pid_a="$!"
quote_request "${QUOTE_BODY_B}" "${QUOTE_B}" "${QUOTE_STATUS_B}" &
quote_pid_b="$!"
wait "${quote_pid_a}"
wait "${quote_pid_b}"
status_a="$(cat "${QUOTE_STATUS_A}")"
status_b="$(cat "${QUOTE_STATUS_B}")"
if [[ "${status_a}:${status_b}" != "200:200" ]]; then
  echo "concurrent idempotent quote test expected 200:200, got ${status_a}:${status_b}" >&2
  exit 1
fi
cp "${QUOTE_A}" "${QUOTE_FILE}"
node --input-type=module - "${QUOTE_A}" "${QUOTE_B}" <<'NODE'
import { readFileSync } from "node:fs";
const first = JSON.parse(readFileSync(process.argv[2], "utf8"));
const second = JSON.parse(readFileSync(process.argv[3], "utf8"));
if (
  first.quote.nonce !== second.quote.nonce ||
  first.factorSignature !== second.factorSignature
) {
  throw new Error("concurrent identical requests returned independently fillable envelopes");
}
NODE
node --input-type=module - "${QUOTE_FILE}" "${unsteth_adapter}" "${REQUEST_ID}" <<'NODE'
import { readFileSync } from "node:fs";
const quote = JSON.parse(readFileSync(process.argv[2], "utf8"));
if (
  quote.version !== "reservoir-v2-lido-1" ||
  quote.mode !== "existing-unsteth" ||
  quote.quote.adapter.toLowerCase() !== process.argv[3].toLowerCase() ||
  quote.claim.requestId !== process.argv[4] ||
  !quote.factorSignature
) throw new Error("quote envelope did not bind the existing claim");
NODE

echo "==> approve and settle through the same envelope shape used by the frontend"
ETH_RPC_URL="${LOCAL_RPC_URL}" SELLER_PRIVATE_KEY="${seller_key}" QUOTE_FILE="${QUOTE_FILE}" \
node frontend/scripts/execute-existing-unsteth-quote.mjs

seller_weth="$(cast call 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
  "balanceOf(address)(uint256)" "${seller_address}" --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
[[ "${seller_weth}" -gt 0 ]] || { echo "seller received no WETH" >&2; exit 1; }
factor_address_lower="$(printf '%s' "${factor_address}" | tr '[:upper:]' '[:lower:]')"
[[ "$(cast call "${QUEUE}" "ownerOf(uint256)(address)" "${REQUEST_ID}" --rpc-url "${LOCAL_RPC_URL}" | tr '[:upper:]' '[:lower:]')" == "${factor_address_lower}" ]] ||
  { echo "factor did not acquire the canonical unstETH" >&2; exit 1; }
capacity="$(cast call "${funding}" "availableFor(uint256)(uint256)" 1 --rpc-url "${LOCAL_RPC_URL}" | awk '{print $1}')"
[[ "${capacity}" == "1" ]] || { echo "productive reserve unavailable after fill" >&2; exit 1; }

echo "EXISTING UNSTETH REHEARSAL PASS | real unstETH #130880 at 0.004999999999999999 stETH, 0.006 WETH canonical Aave reserve, real HTTP quote, exact approval, atomic fill"
