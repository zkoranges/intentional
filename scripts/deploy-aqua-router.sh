#!/usr/bin/env bash
set -Eeuo pipefail

# Reviewed production deployment of ReservoirSwapVMRouter via a raw creation
# transaction. forge's broadcast encoder nondeterministically mis-decodes this
# contract's string constructor args (creation-code prefix collision with the
# parent AquaSwapVMRouter artifact), so the router must not be deployed through
# `forge script`. This script is the only sanctioned path.
#
# Required env: RPC_URL, FACTOR_ADDRESS, and either FACTOR_PRIVATE_KEY or
# ROUTER_DEPLOY_IMPERSONATE=1 (fork rehearsal; uses --unlocked --from).
# Optional: EXPECTED_ROUTER_CODEHASH (bytes32; enforced when set).
# Output: markers RESERVOIR_AQUA_ROUTER_BEGIN/END wrapping a JSON manifest.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

RPC_URL="${RPC_URL:?RPC_URL is required}"
FACTOR_ADDRESS="${FACTOR_ADDRESS:?FACTOR_ADDRESS is required}"
CANONICAL_AQUA="0x499943E74FB0cE105688beeE8Ef2ABec5D936d31"
WETH_ADDRESS="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
ROUTER_NAME="Reservoir Aqua Intent"
ROUTER_VERSION="1"
ARTIFACT="src/routers/ReservoirSwapVMRouter.sol:ReservoirSwapVMRouter"

if [[ "$(cast chain-id --rpc-url "${RPC_URL}")" != "1" ]]; then
  echo "RPC must target chain 1 (mainnet or a chain-1 fork)." >&2
  exit 1
fi

bytecode="$(forge inspect "${ARTIFACT}" bytecode)"
if [[ ! "${bytecode}" =~ ^0x[0-9a-fA-F]+$ ]]; then
  echo "Could not read creation bytecode for ${ARTIFACT}." >&2
  exit 1
fi

ctor_args="$(cast abi-encode 'constructor(address,address,address,string,string)' \
  "${CANONICAL_AQUA}" \
  "${WETH_ADDRESS}" \
  "${FACTOR_ADDRESS}" \
  "${ROUTER_NAME}" \
  "${ROUTER_VERSION}")"
creation_calldata="${bytecode}${ctor_args#0x}"
creation_hash="$(cast keccak "${creation_calldata}")"

deploy_nonce="$(cast nonce "${FACTOR_ADDRESS}" --rpc-url "${RPC_URL}")"
predicted_address="$(cast compute-address "${FACTOR_ADDRESS}" --nonce "${deploy_nonce}" | awk '{print $NF}')"

if [[ "${ROUTER_DEPLOY_IMPERSONATE:-0}" == "1" ]]; then
  receipt_json="$(cast send \
    --unlocked \
    --from "${FACTOR_ADDRESS}" \
    --rpc-url "${RPC_URL}" \
    --json \
    --create "${creation_calldata}")"
else
  : "${FACTOR_PRIVATE_KEY:?FACTOR_PRIVATE_KEY is required without impersonation}"
  receipt_json="$(cast send \
    --private-key "${FACTOR_PRIVATE_KEY}" \
    --rpc-url "${RPC_URL}" \
    --json \
    --create "${creation_calldata}")"
fi

read -r deployed_address tx_hash tx_status < <(printf '%s' "${receipt_json}" | node --input-type=module -e '
let d = "";
process.stdin.on("data", (c) => (d += c)).on("end", () => {
  const r = JSON.parse(d);
  console.log(`${r.contractAddress} ${r.transactionHash} ${r.status}`);
});')

if [[ "${tx_status}" != "0x1" && "${tx_status}" != "1" ]]; then
  echo "Router creation transaction ${tx_hash} did not succeed (status ${tx_status})." >&2
  exit 1
fi
if [[ "$(cast to-check-sum-address "${deployed_address}")" != "$(cast to-check-sum-address "${predicted_address}")" ]]; then
  echo "Deployed router ${deployed_address} does not match predicted ${predicted_address}." >&2
  exit 1
fi

runtime_code="$(cast code "${deployed_address}" --rpc-url "${RPC_URL}")"
if [[ "${runtime_code}" == "0x" ]]; then
  echo "Deployed router has no runtime code." >&2
  exit 1
fi
runtime_codehash="$(cast keccak "${runtime_code}")"
if [[ -n "${EXPECTED_ROUTER_CODEHASH:-}" ]]; then
  actual_lower="$(printf '%s' "${runtime_codehash}" | tr '[:upper:]' '[:lower:]')"
  expected_lower="$(printf '%s' "${EXPECTED_ROUTER_CODEHASH}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${actual_lower}" != "${expected_lower}" ]]; then
    echo "Router runtime codehash ${runtime_codehash} does not match expected ${EXPECTED_ROUTER_CODEHASH}." >&2
    exit 1
  fi
fi

bound_aqua="$(cast call "${deployed_address}" 'AQUA()(address)' --rpc-url "${RPC_URL}")"
if [[ "$(cast to-check-sum-address "${bound_aqua}")" != "$(cast to-check-sum-address "${CANONICAL_AQUA}")" ]]; then
  echo "Router immutable AQUA binding ${bound_aqua} is not canonical Aqua." >&2
  exit 1
fi

echo "RESERVOIR_AQUA_ROUTER_BEGIN"
printf '{"chainId":1,"router":"%s","predictedAddress":"%s","deployNonce":%s,"transactionHash":"%s","runtimeCodeHash":"%s","creationCalldataKeccak":"%s","boundAqua":"%s","verifyCommand":"forge verify-contract %s %s --constructor-args %s --watch"}\n' \
  "${deployed_address}" \
  "${predicted_address}" \
  "${deploy_nonce}" \
  "${tx_hash}" \
  "${runtime_codehash}" \
  "${creation_hash}" \
  "$(cast to-check-sum-address "${bound_aqua}")" \
  "${deployed_address}" \
  "${ARTIFACT}" \
  "${ctor_args}"
echo "RESERVOIR_AQUA_ROUTER_END"
