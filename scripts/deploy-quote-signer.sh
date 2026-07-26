#!/usr/bin/env bash
set -Eeuo pipefail

# Idempotent deploy of the Reservoir quote signer onto the shared VPS.
#
# Co-tenancy rules on that box (inherited from outreach/docs/DEPLOY.md):
#   NEVER touch the docker stack, nginx, or any database that isn't ours.
#   Nothing here installs a system package, binds a public port, or edits any
#   file outside /home/impatience and one dedicated systemd unit.
#
# Mirrors the outreach pattern: dedicated unprivileged user, user-local Node
# tarball, systemd unit bound to 127.0.0.1, logs under the user's home.
#
# Required env (from the repo .env): DEPLOY_HOST, DEPLOY_SSH_KEY,
# ETH_RPC_URL, FACTOR_PRIVATE_KEY, SIGNER_SECRET.
# Reads contract addresses from a required active deployment manifest.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

HOST="${DEPLOY_HOST:?DEPLOY_HOST is required}"
KEY="${DEPLOY_SSH_KEY:?DEPLOY_SSH_KEY is required}"
RPC="${ETH_RPC_URL:?ETH_RPC_URL is required}"
FACTOR_KEY="${FACTOR_PRIVATE_KEY:?FACTOR_PRIVATE_KEY is required}"
SECRET="${SIGNER_SECRET:?SIGNER_SECRET is required (openssl rand -hex 32)}"
MAX_QUOTE_WEI="${MAX_QUOTE_WEI:-1500000000000000}"
MIN_QUOTE_WEI="${MIN_QUOTE_WEI:-500000000000000}"
SPREAD_BPS="${SPREAD_BPS:-25}"
MAX_SPREAD_BPS="${MAX_SPREAD_BPS:-100}"
QUOTE_TTL_SECONDS="${QUOTE_TTL_SECONDS:-120}"
MAX_STETH_SHORTFALL_WEI="${MAX_STETH_SHORTFALL_WEI:-2}"
NODE_VERSION="${NODE_VERSION:-22.18.0}"
MANIFEST_PATH="${DEPLOYMENT_MANIFEST_PATH:-deployments/mainnet-pre-alpha-001.json}"
SVC_USER=impatience
SVC_HOME="/home/${SVC_USER}"
APP="${SVC_HOME}/app"
APP_NEXT="${SVC_HOME}/app.next"
APP_PREVIOUS="${SVC_HOME}/app.previous"
PORT=8791
SSH=(ssh -i "${KEY}" -o ConnectTimeout=20 "${HOST}")

[[ "${RPC}" =~ ^https?://[^[:space:]]+$ ]] || {
  echo "ETH_RPC_URL must be one whitespace-free http(s) URL" >&2
  exit 1
}
[[ "${FACTOR_KEY}" =~ ^0x[0-9a-fA-F]{64}$ ]] || {
  echo "FACTOR_PRIVATE_KEY must be one 32-byte 0x-prefixed key" >&2
  exit 1
}
[[ "${SECRET}" =~ ^[0-9a-fA-F]{64}$ ]] || {
  echo "SIGNER_SECRET must be exactly 32 random bytes encoded as hex" >&2
  exit 1
}
for numeric_value in \
  "${MAX_QUOTE_WEI}" \
  "${MIN_QUOTE_WEI}" \
  "${SPREAD_BPS}" \
  "${MAX_SPREAD_BPS}" \
  "${QUOTE_TTL_SECONDS}" \
  "${MAX_STETH_SHORTFALL_WEI}"; do
  [[ "${numeric_value}" =~ ^(0|[1-9][0-9]*)$ ]] || {
    echo "quote-desk numeric settings must be unsigned base-10 integers" >&2
    exit 1
  }
done

manifest() {
  node --input-type=module -e \
    'import fs from "node:fs"; let o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); for (const k of process.argv[2].split(".")) o=o[k]; console.log(o);' \
    "$1" "$2"
}
[[ -f "${MANIFEST_PATH}" ]] || { echo "active deployment manifest missing: ${MANIFEST_PATH}" >&2; exit 1; }
RELEASE_STATE="$(manifest "${MANIFEST_PATH}" releaseState)"
[[ "${RELEASE_STATE}" == "active" ]] || {
  echo "ABORT: ${MANIFEST_PATH} releaseState=${RELEASE_STATE}; only active is allowed" >&2
  exit 1
}
KERNEL="$(manifest "${MANIFEST_PATH}" contracts.kernel.address)"
FACTOR="$(manifest "${MANIFEST_PATH}" factor)"
FUNDING_ACCOUNT="$(manifest "${MANIFEST_PATH}" contracts.fundingAccount.address)"
RESERVE_ADAPTER="$(manifest "${MANIFEST_PATH}" contracts.reserveAdapter.address)"
LIDO_ADAPTER="$(manifest "${MANIFEST_PATH}" contracts.lidoAdapter.address)"
LIDO_UNSTETH_ADAPTER="$(manifest "${MANIFEST_PATH}" contracts.lidoUnstETHExitAdapter.address)"
FUNDING_CODEHASH="$(manifest "${MANIFEST_PATH}" contracts.fundingAccount.runtimeCodeHash)"
RESERVE_CODEHASH="$(manifest "${MANIFEST_PATH}" contracts.reserveAdapter.runtimeCodeHash)"
KERNEL_CODEHASH="$(manifest "${MANIFEST_PATH}" contracts.kernel.runtimeCodeHash)"
LIDO_ADAPTER_CODEHASH="$(manifest "${MANIFEST_PATH}" contracts.lidoAdapter.runtimeCodeHash)"
LIDO_UNSTETH_ADAPTER_CODEHASH="$(
  manifest "${MANIFEST_PATH}" contracts.lidoUnstETHExitAdapter.runtimeCodeHash
)"

[[ -d frontend/node_modules/viem ]] || {
  echo "frontend dependencies missing; run npm --prefix frontend ci before deployment" >&2
  exit 1
}
[[ -d services/quote-signer/node_modules/viem ]] || {
  echo "quote-signer dependencies missing; run npm --prefix services/quote-signer ci before deployment" >&2
  exit 1
}

FACTOR_KEY_ADDRESS="$(
  cd services/quote-signer
  FACTOR_PRIVATE_KEY="${FACTOR_KEY}" node --input-type=module -e \
    'import { privateKeyToAccount } from "viem/accounts"; console.log(privateKeyToAccount(process.env.FACTOR_PRIVATE_KEY).address);'
)"
node --input-type=module -e '
  if (process.argv[1].toLowerCase() !== process.argv[2].toLowerCase()) {
    throw new Error(
      `injected factor key derives ${process.argv[1]}, but the manifest binds ${process.argv[2]}`,
    );
  }
' "${FACTOR_KEY_ADDRESS}" "${FACTOR}"

echo "==> verifying the active manifest and live mainnet deployment"
ETH_RPC_URL="${RPC}" \
FACTOR_ADDRESS="${FACTOR}" \
KERNEL_ADDRESS="${KERNEL}" \
FUNDING_ACCOUNT_ADDRESS="${FUNDING_ACCOUNT}" \
RESERVE_ADAPTER_ADDRESS="${RESERVE_ADAPTER}" \
LIDO_ADAPTER_ADDRESS="${LIDO_ADAPTER}" \
LIDO_UNSTETH_ADAPTER_ADDRESS="${LIDO_UNSTETH_ADAPTER}" \
EXPECTED_FUNDING_CODEHASH="${FUNDING_CODEHASH}" \
EXPECTED_RESERVE_CODEHASH="${RESERVE_CODEHASH}" \
EXPECTED_KERNEL_CODEHASH="${KERNEL_CODEHASH}" \
EXPECTED_LIDO_ADAPTER_CODEHASH="${LIDO_ADAPTER_CODEHASH}" \
EXPECTED_LIDO_UNSTETH_ADAPTER_CODEHASH="${LIDO_UNSTETH_ADAPTER_CODEHASH}" \
EXPECTED_RELEASE_STATE=active \
MIN_CAPACITY_WEI="${MAX_QUOTE_WEI}" \
node frontend/scripts/verify-live-deployment.mjs >/dev/null

echo "==> preflight: co-tenant safety and disk"
"${SSH[@]}" bash -s <<PREFLIGHT
set -euo pipefail
free_kb=\$(df --output=avail / | tail -1)
if [ "\$free_kb" -lt 2097152 ]; then
  echo "ABORT: less than 2 GiB free on /" >&2
  exit 1
fi
if ss -tlnp | awk '{print \$4}' | grep -qE "(^|:)${PORT}\$"; then
  if systemctl is-active --quiet impatience-signer; then
    echo "existing impatience-signer owns the deployment port; it will be updated"
  else
    echo "ABORT: port ${PORT} is already bound outside the managed service" >&2
    exit 1
  fi
fi
systemctl is-active --quiet outreach || echo "note: outreach service is not active"
echo "preflight ok: \$((free_kb/1048576)) GiB free, port ${PORT} available"
PREFLIGHT

echo "==> ensuring the dedicated unprivileged user"
"${SSH[@]}" bash -s <<PROVISION
set -euo pipefail
if ! id ${SVC_USER} >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash ${SVC_USER}
fi
install -d -m 700 -o ${SVC_USER} -g ${SVC_USER} ${SVC_HOME}
install -d -m 700 -o ${SVC_USER} -g ${SVC_USER} ${APP_NEXT} ${SVC_HOME}/logs
PROVISION

echo "==> ensuring user-local Node ${NODE_VERSION} (no system packages)"
"${SSH[@]}" bash -s <<NODEINSTALL
set -euo pipefail
if [ ! -x ${SVC_HOME}/node/bin/node ] || [ "\$(${SVC_HOME}/node/bin/node -v)" != "v${NODE_VERSION}" ]; then
  tmp=\$(mktemp -d)
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o "\$tmp/node.tar.xz"
  rm -rf ${SVC_HOME}/node
  mkdir -p ${SVC_HOME}/node
  tar -xJf "\$tmp/node.tar.xz" -C ${SVC_HOME}/node --strip-components=1
  rm -rf "\$tmp"
  chown -R ${SVC_USER}:${SVC_USER} ${SVC_HOME}/node
fi
observed_node="\$(${SVC_HOME}/node/bin/node -v)"
[ "\$observed_node" = "v${NODE_VERSION}" ] || {
  echo "ABORT: expected Node v${NODE_VERSION}, observed \$observed_node" >&2
  exit 1
}
sudo -u ${SVC_USER} -H ${SVC_HOME}/node/bin/node --input-type=module -e \
  'import("node:sqlite").then(({ DatabaseSync }) => { const db = new DatabaseSync(":memory:"); db.close(); })'
echo "\$observed_node with node:sqlite ready"
NODEINSTALL

echo "==> staging the service source without touching the running release"
rsync -az -e "ssh -i ${KEY}" --delete \
  --exclude node_modules --exclude .env \
  services/quote-signer/ "${HOST}:${APP_NEXT}/"
rsync -az -e "ssh -i ${KEY}" "${MANIFEST_PATH}" "${HOST}:${APP_NEXT}/deployment-manifest.json"
"${SSH[@]}" "chown -R ${SVC_USER}:${SVC_USER} ${APP_NEXT}"

echo "==> writing the service environment (0600, never logged)"
"${SSH[@]}" "install -m 600 -o ${SVC_USER} -g ${SVC_USER} /dev/null ${APP_NEXT}/.env && cat > ${APP_NEXT}/.env" <<ENVFILE
HOST=127.0.0.1
PORT=${PORT}
ETH_RPC_URL=${RPC}
FACTOR_PRIVATE_KEY=${FACTOR_KEY}
KERNEL_ADDRESS=${KERNEL}
LIDO_ADAPTER_ADDRESS=${LIDO_ADAPTER}
LIDO_UNSTETH_ADAPTER_ADDRESS=${LIDO_UNSTETH_ADAPTER}
DEPLOYMENT_MANIFEST=${APP}/deployment-manifest.json
SIGNER_SECRET=${SECRET}
MAX_QUOTE_WEI=${MAX_QUOTE_WEI}
MIN_QUOTE_WEI=${MIN_QUOTE_WEI}
SPREAD_BPS=${SPREAD_BPS}
MAX_SPREAD_BPS=${MAX_SPREAD_BPS}
QUOTE_TTL_SECONDS=${QUOTE_TTL_SECONDS}
MAX_STETH_SHORTFALL_WEI=${MAX_STETH_SHORTFALL_WEI}
EXPECTED_CHAIN_ID=1
AUDIT_LOG=${SVC_HOME}/logs/quote-audit.jsonl
ENVFILE
"${SSH[@]}" "chmod 600 ${APP_NEXT}/.env && chown ${SVC_USER}:${SVC_USER} ${APP_NEXT}/.env"

echo "==> installing staged dependencies as the service user"
"${SSH[@]}" "sudo -u ${SVC_USER} -H bash -lc 'cd ${APP_NEXT} && PATH=${SVC_HOME}/node/bin:\$PATH npm ci --omit=dev --no-audit --no-fund'" >/dev/null

echo "==> installing the systemd unit (isolated; touches nothing else)"
"${SSH[@]}" bash -s <<UNIT
set -euo pipefail
cat > /etc/systemd/system/impatience-signer.service <<'SERVICE'
[Unit]
Description=Intentional quote signer (internal unit: impatience-signer)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SVC_USER}
WorkingDirectory=${APP}
ExecStart=${SVC_HOME}/node/bin/node --env-file=${APP}/.env ${APP}/server.mjs
Restart=always
RestartSec=3
Nice=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${SVC_HOME}/logs
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
systemctl enable impatience-signer
UNIT

rollback_release() {
  echo "quote signer failed deployment/readiness; rolling back the VPS release" >&2
  "${SSH[@]}" bash -s <<ROLLBACK
set -euo pipefail
systemctl stop impatience-signer 2>/dev/null || true
if [ -d ${APP_PREVIOUS} ]; then
  rm -rf ${APP}
  mv ${APP_PREVIOUS} ${APP}
  systemctl start impatience-signer
fi
ROLLBACK
}

echo "==> atomically promoting the staged release"
if ! "${SSH[@]}" bash -s <<PROMOTE
set -euo pipefail
systemctl stop impatience-signer 2>/dev/null || true
rm -rf ${APP_PREVIOUS}
if [ -d ${APP} ]; then
  mv ${APP} ${APP_PREVIOUS}
fi
mv ${APP_NEXT} ${APP}
systemctl start impatience-signer
PROMOTE
then
  rollback_release
  exit 1
fi

echo "==> health check through localhost on the box"
health_json=""
for _ in $(seq 1 30); do
  health_json="$("${SSH[@]}" "curl -sf http://127.0.0.1:${PORT}/health 2>/dev/null || true")"
  if printf '%s' "${health_json}" | node --input-type=module -e '
    let data = "";
    process.stdin.on("data", (chunk) => (data += chunk)).on("end", () => {
      try {
        const health = JSON.parse(data);
        process.exit(health.ok === true && health.readiness?.state === "ready" ? 0 : 1);
      } catch {
        process.exit(1);
      }
    });
  '; then
    break
  fi
  sleep 1
done
if ! printf '%s' "${health_json}" | node --input-type=module -e '
  let data = "";
  process.stdin.on("data", (chunk) => (data += chunk)).on("end", () => {
    const health = JSON.parse(data);
    if (health.ok !== true || health.readiness?.state !== "ready") {
      throw new Error(`quote signer is not ready: ${health.readiness?.state ?? "unknown"}`);
    }
    if (!health.contracts?.lidoAdapter || !health.contracts?.lidoUnstETHAdapter) {
      throw new Error("quote signer health is missing one or both Lido adapters");
    }
    console.log(
      `health ready factor=${health.factor} kernel=${health.kernel} ` +
        `maxQuoteWei=${health.maxQuoteWei} ttl=${health.quoteTtlSeconds}s`,
    );
  });
'; then
  rollback_release
  exit 1
fi

echo "SIGNER DEPLOY PASS | impatience-signer active on 127.0.0.1:${PORT}; docker/nginx/outreach untouched"
