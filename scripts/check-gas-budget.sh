#!/usr/bin/env bash
set -Eeuo pipefail

# Executable per-phase abort threshold for the mainnet micro-demo
# (docs/MAINNET_MICRO_DEMO.md §6). Refuses the phase unless
#   factor balance >= remaining allocations + remaining gas × live price × 3.
# Usage: check-gas-budget.sh <phase>
# Phases: v2-deploy v2-fund-activate aqua-router aqua-deploy aqua-fill recovery
# Required env: RPC_URL, FACTOR_ADDRESS.

PHASE="${1:?phase name required}"
RPC_URL="${RPC_URL:?RPC_URL is required}"
FACTOR_ADDRESS="${FACTOR_ADDRESS:?FACTOR_ADDRESS is required}"
HEADROOM_MULTIPLIER=3

case "${PHASE}" in
  v2-deploy)        REMAINING_GAS=17500000; REMAINING_ALLOC_WEI=12460000000000000 ;;
  v2-fund-activate) REMAINING_GAS=10900000; REMAINING_ALLOC_WEI=12460000000000000 ;;
  aqua-router)      REMAINING_GAS=10000000; REMAINING_ALLOC_WEI=2460000000000000 ;;
  aqua-deploy)      REMAINING_GAS=5500000;  REMAINING_ALLOC_WEI=2460000000000000 ;;
  aqua-fill)        REMAINING_GAS=1500000;  REMAINING_ALLOC_WEI=0 ;;
  recovery)         REMAINING_GAS=500000;   REMAINING_ALLOC_WEI=0 ;;
  *) echo "Unknown phase '${PHASE}'." >&2; exit 2 ;;
esac

balance="$(cast balance "${FACTOR_ADDRESS}" --rpc-url "${RPC_URL}")"
# GAS_PRICE_WEI_OVERRIDE is rehearsal-only: anvil forks report a synthetic
# ~1 gwei suggested tip, so rehearsals pass the live upstream price instead.
# Mainnet runs must NOT set it.
gas_price="${GAS_PRICE_WEI_OVERRIDE:-$(cast gas-price --rpc-url "${RPC_URL}")}"
if ! [[ "${gas_price}" =~ ^[0-9]+$ ]] || [[ "${gas_price}" == "0" ]]; then
  echo "GAS BUDGET ABORT | invalid gas price '${gas_price}'." >&2
  exit 2
fi

# Arbitrary-precision arithmetic: bash $((...)) is int64 and silently wraps
# negative above ~175 gwei at these gas figures, which would INVERT the gate
# exactly during a spike (independent judge finding, empirically confirmed).
read -r required verdict < <(python3 -c "
balance = int('${balance}')
required = int('${REMAINING_ALLOC_WEI}') + int('${REMAINING_GAS}') * int('${gas_price}') * int('${HEADROOM_MULTIPLIER}')
print(required, 'PASS' if balance >= required else 'ABORT')
")

echo "GAS BUDGET | phase=${PHASE} balance=${balance} wei"
echo "GAS BUDGET | live gas price=${gas_price} wei; remaining gas=${REMAINING_GAS}; remaining allocations=${REMAINING_ALLOC_WEI} wei"
echo "GAS BUDGET | required (alloc + gas x price x ${HEADROOM_MULTIPLIER}) = ${required} wei"

if [[ "${verdict}" != "PASS" ]]; then
  echo "GAS BUDGET ABORT | balance below threshold for phase ${PHASE}; top up or wait for cheaper gas." >&2
  exit 1
fi
echo "GAS BUDGET PASS | phase ${PHASE} may broadcast"
