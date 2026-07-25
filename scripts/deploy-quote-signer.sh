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
# Reads contract addresses from deployments/mainnet-v2.json.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

HOST="${DEPLOY_HOST:?DEPLOY_HOST is required}"
KEY="${DEPLOY_SSH_KEY:?DEPLOY_SSH_KEY is required}"
RPC="${ETH_RPC_URL:?ETH_RPC_URL is required}"
FACTOR_KEY="${FACTOR_PRIVATE_KEY:?FACTOR_PRIVATE_KEY is required}"
SECRET="${SIGNER_SECRET:?SIGNER_SECRET is required (openssl rand -hex 32)}"
MAX_QUOTE_WEI="${MAX_QUOTE_WEI:-6000000000000000}"
SPREAD_BPS="${SPREAD_BPS:-25}"
QUOTE_TTL_SECONDS="${QUOTE_TTL_SECONDS:-120}"
NODE_VERSION="${NODE_VERSION:-22.13.0}"
SVC_USER=impatience
SVC_HOME="/home/${SVC_USER}"
APP="${SVC_HOME}/app"
PORT=8791
SSH=(ssh -i "${KEY}" -o ConnectTimeout=20 "${HOST}")

manifest() {
  node --input-type=module -e \
    'import fs from "node:fs"; let o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); for (const k of process.argv[2].split(".")) o=o[k]; console.log(o);' \
    "$1" "$2"
}
RELEASE_STATE="$(manifest deployments/mainnet-v2.json releaseState)"
case "${RELEASE_STATE}" in
  retired-paused | claim-collected)
    cat >&2 <<RETIRED
ABORT: deployments/mainnet-v2.json reports releaseState=${RELEASE_STATE}.
That deployment is permanently retired — its immutable factor key was exposed
and it must never be re-armed or quoted against. Deploying the quote desk
against it would point live infrastructure at a compromised, paused instance.
Wait for the fresh v3 deployment and point this script at its manifest.
RETIRED
    exit 1
    ;;
esac
KERNEL="$(manifest deployments/mainnet-v2.json contracts.kernel.address)"
LIDO_ADAPTER="$(manifest deployments/mainnet-v2.json contracts.lidoAdapter.address)"

echo "==> preflight: co-tenant safety and disk"
"${SSH[@]}" bash -s <<PREFLIGHT
set -euo pipefail
free_kb=\$(df --output=avail / | tail -1)
if [ "\$free_kb" -lt 2097152 ]; then
  echo "ABORT: less than 2 GiB free on /" >&2
  exit 1
fi
if ss -tlnp | awk '{print \$4}' | grep -qE "(^|:)${PORT}\$"; then
  echo "ABORT: port ${PORT} is already bound by another service" >&2
  exit 1
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
install -d -m 700 -o ${SVC_USER} -g ${SVC_USER} ${APP} ${SVC_HOME}/logs
PROVISION

echo "==> ensuring user-local Node ${NODE_VERSION} (no system packages)"
"${SSH[@]}" bash -s <<NODEINSTALL
set -euo pipefail
if [ ! -x ${SVC_HOME}/node/bin/node ] || ! ${SVC_HOME}/node/bin/node -v | grep -q "${NODE_VERSION}"; then
  tmp=\$(mktemp -d)
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o "\$tmp/node.tar.xz"
  rm -rf ${SVC_HOME}/node
  mkdir -p ${SVC_HOME}/node
  tar -xJf "\$tmp/node.tar.xz" -C ${SVC_HOME}/node --strip-components=1
  rm -rf "\$tmp"
  chown -R ${SVC_USER}:${SVC_USER} ${SVC_HOME}/node
fi
${SVC_HOME}/node/bin/node -v
NODEINSTALL

echo "==> syncing the service source"
rsync -az -e "ssh -i ${KEY}" --delete \
  --exclude node_modules --exclude .env \
  services/quote-signer/ "${HOST}:${APP}/"
"${SSH[@]}" "chown -R ${SVC_USER}:${SVC_USER} ${APP}"

echo "==> writing the service environment (0600, never logged)"
"${SSH[@]}" "install -m 600 -o ${SVC_USER} -g ${SVC_USER} /dev/null ${APP}/.env && cat > ${APP}/.env" <<ENVFILE
HOST=127.0.0.1
PORT=${PORT}
ETH_RPC_URL=${RPC}
FACTOR_PRIVATE_KEY=${FACTOR_KEY}
KERNEL_ADDRESS=${KERNEL}
LIDO_ADAPTER_ADDRESS=${LIDO_ADAPTER}
SIGNER_SECRET=${SECRET}
MAX_QUOTE_WEI=${MAX_QUOTE_WEI}
SPREAD_BPS=${SPREAD_BPS}
QUOTE_TTL_SECONDS=${QUOTE_TTL_SECONDS}
AUDIT_LOG=${SVC_HOME}/logs/quote-audit.jsonl
ENVFILE
"${SSH[@]}" "chmod 600 ${APP}/.env && chown ${SVC_USER}:${SVC_USER} ${APP}/.env"

echo "==> installing dependencies as the service user"
"${SSH[@]}" "sudo -u ${SVC_USER} -H bash -lc 'cd ${APP} && PATH=${SVC_HOME}/node/bin:\$PATH npm install --omit=dev --no-audit --no-fund'" >/dev/null

echo "==> installing the systemd unit (isolated; touches nothing else)"
"${SSH[@]}" bash -s <<UNIT
set -euo pipefail
cat > /etc/systemd/system/impatience-signer.service <<'SERVICE'
[Unit]
Description=Reservoir quote signer (impatience.xyz)
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
systemctl enable --now impatience-signer
sleep 2
systemctl is-active impatience-signer
UNIT

echo "==> health check through localhost on the box"
"${SSH[@]}" "curl -sf http://127.0.0.1:${PORT}/health" | node --input-type=module -e \
  'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const h=JSON.parse(d);console.log(`health ok=${h.ok} factor=${h.factor} kernel=${h.kernel} maxQuoteWei=${h.maxQuoteWei} ttl=${h.quoteTtlSeconds}s`);});'

echo "SIGNER DEPLOY PASS | impatience-signer active on 127.0.0.1:${PORT}; docker/nginx/outreach untouched"
