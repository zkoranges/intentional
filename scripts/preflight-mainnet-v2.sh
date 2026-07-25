#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

required_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "PREFLIGHT FAIL | ${name} is required" >&2
    exit 1
  fi
}

required_uint() {
  local name="$1"
  local value="${!name:-}"
  if [[ ! "${value}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "PREFLIGHT FAIL | ${name} must be an unsigned base-10 integer" >&2
    exit 1
  fi
}

required_env ETH_RPC_URL
required_env FACTOR_ADDRESS

if [[ -z "${ETHERSCAN_API_KEY:-}" && "${PREFLIGHT_ALLOW_MISSING_ETHERSCAN_KEY:-0}" != "1" ]]; then
  echo "PREFLIGHT FAIL | ETHERSCAN_API_KEY is required for source verification" >&2
  exit 1
fi

EXPECTED_DEPLOYER_NONCE="${EXPECTED_DEPLOYER_NONCE:-0}"
DEPLOYMENT_GAS_UNITS="${DEPLOYMENT_GAS_UNITS:-6606588}"
DEPLOYMENT_GAS_HEADROOM_BPS="${DEPLOYMENT_GAS_HEADROOM_BPS:-20000}"
required_uint EXPECTED_DEPLOYER_NONCE
required_uint DEPLOYMENT_GAS_UNITS
required_uint DEPLOYMENT_GAS_HEADROOM_BPS

if (( DEPLOYMENT_GAS_UNITS == 0 || DEPLOYMENT_GAS_HEADROOM_BPS < 10000 )); then
  echo "PREFLIGHT FAIL | gas units must be nonzero and headroom must be at least 10000 bps" >&2
  exit 1
fi

if [[ "${PREFLIGHT_ALLOW_DIRTY:-0}" != "1" && -n "$(git status --porcelain --untracked-files=all)" ]]; then
  echo "PREFLIGHT FAIL | deployment must use a clean reviewed commit" >&2
  exit 1
fi

chain_id="$(cast chain-id --rpc-url "${ETH_RPC_URL}")"
if [[ "${chain_id}" != "1" ]]; then
  echo "PREFLIGHT FAIL | Ethereum mainnet required, received chain ${chain_id}" >&2
  exit 1
fi

factor="$(cast to-check-sum-address "${FACTOR_ADDRESS}")"
factor_code="$(cast code "${factor}" --rpc-url "${ETH_RPC_URL}")"
if [[ "${factor_code}" != "0x" ]]; then
  echo "PREFLIGHT FAIL | factor must be a code-free EOA" >&2
  exit 1
fi

factor_nonce="$(cast nonce "${factor}" --rpc-url "${ETH_RPC_URL}")"
if [[ "${factor_nonce}" != "${EXPECTED_DEPLOYER_NONCE}" ]]; then
  echo "PREFLIGHT FAIL | factor nonce ${factor_nonce}, expected ${EXPECTED_DEPLOYER_NONCE}" >&2
  exit 1
fi

canonical_addresses=(
  "stETH:0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84"
  "WETH:0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
  "StataWETH:0x0bfc9d54Fc184518A81162F8fB99c2eACa081202"
  "LidoWithdrawalQueue:0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1"
)
for entry in "${canonical_addresses[@]}"; do
  name="${entry%%:*}"
  address="${entry#*:}"
  code="$(cast code "${address}" --rpc-url "${ETH_RPC_URL}")"
  if [[ "${code}" == "0x" ]]; then
    echo "PREFLIGHT FAIL | canonical ${name} has no runtime code" >&2
    exit 1
  fi
done

stata_asset="$(
  cast call \
    0x0bfc9d54Fc184518A81162F8fB99c2eACa081202 \
    "asset()(address)" \
    --rpc-url "${ETH_RPC_URL}"
)"
if [[ "$(cast to-check-sum-address "${stata_asset}")" != "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2" ]]; then
  echo "PREFLIGHT FAIL | canonical StataWETH asset is not WETH" >&2
  exit 1
fi

gas_price="$(cast gas-price --rpc-url "${ETH_RPC_URL}")"
factor_balance="$(cast balance "${factor}" --rpc-url "${ETH_RPC_URL}")"
required_balance="$(
  node -e \
    'process.stdout.write((BigInt(process.argv[1]) * BigInt(process.argv[2]) * BigInt(process.argv[3]) / 10000n).toString())' \
    "${DEPLOYMENT_GAS_UNITS}" \
    "${gas_price}" \
    "${DEPLOYMENT_GAS_HEADROOM_BPS}"
)"
if (( factor_balance < required_balance )); then
  echo "PREFLIGHT FAIL | factor balance is below the configured deployment gas headroom" >&2
  echo "  balance:  $(cast from-wei "${factor_balance}") ETH" >&2
  echo "  required: $(cast from-wei "${required_balance}") ETH" >&2
  exit 1
fi

commit="$(git rev-parse HEAD)"
echo "MAINNET PREFLIGHT PASS"
echo "  commit:             ${commit}"
echo "  chain:              1"
echo "  factor:             ${factor}"
echo "  factor nonce:       ${factor_nonce}"
echo "  factor balance:     $(cast from-wei "${factor_balance}") ETH"
echo "  gas price:          $(cast from-wei "${gas_price}" gwei) gwei"
echo "  gas headroom:       $(cast from-wei "${required_balance}") ETH"
echo "  canonical bindings: verified"
if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "  source verification: configured"
else
  echo "  source verification: skipped by PREFLIGHT_ALLOW_MISSING_ETHERSCAN_KEY=1"
fi
if [[ "${PREFLIGHT_ALLOW_DIRTY:-0}" == "1" ]]; then
  echo "  clean-tree gate:    skipped by PREFLIGHT_ALLOW_DIRTY=1"
else
  echo "  clean-tree gate:    passed"
fi
