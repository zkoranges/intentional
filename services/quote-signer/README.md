# Reservoir quote signer

The underwriting desk as a small HTTP service, so the app can request a
seller-bound firm quote instead of a human pasting a signed envelope.

```text
browser → Vercel /api/quote/lido (validation, secret header, no key)
        → HTTPS tunnel → this service (127.0.0.1, factor key, ceiling, audit)
```

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | liveness + effective config (no secrets) |
| `POST` | `/quote` | `{seller, requestedStEth}` → signed envelope |

`POST /quote` requires the `x-signer-secret` header (constant-time compared).
The response is the same envelope shape the fill path already consumes, so the
contracts and the executor script are unchanged.

## Safety properties

1. **Binds `127.0.0.1` only.** The public edge is Vercel; the tunnel is the
   only path in, and the tunnel hostname never reaches the client bundle.
2. **Hard ceiling.** `MAX_QUOTE_WEI` bounds every quote *independently of*
   measured reserve capacity. Even with the key, no single quote can authorize
   more than the configured ceiling.
3. **Single-flight.** One outstanding unexpired quote at a time. Concurrent
   requests cannot oversubscribe the reserve and hand a user a valid-looking
   quote that reverts at fill time (`409 SINGLE_FLIGHT`).
4. **Short expiry.** Default 120s, far inside the kernel's 15-minute bound.
5. **Fails closed** on: paused settlement, unsealed/misconfigured kernel or
   funding account, insufficient measured capacity, paused Lido queue, Lido
   bunker mode, seller balance below the request, signer-key/kernel mismatch.
6. **Audit trail.** Every signature and every rejection is appended to
   `AUDIT_LOG` as JSONL and echoed to the journal.
7. **Internal errors do not leak.** 5xx responses return a generic message;
   the detail goes to the audit log only.

## Key handling — a documented, deliberate decision

The mainnet factor key **was exposed in a working session transcript** and must
be treated as burned. `AsyncClaimSettlement.factorSigner` is immutable, so
rotating the key means redeploying the whole v2 stack (kernel, funding account,
reserve adapter, Lido adapter).

Consequences that are **operating rules, not suggestions**:

- The deployed mainnet instance is a **demo instance, permanently**.
- Keep the reserve small; do not add funds beyond demo scale.
- `MAX_QUOTE_WEI` is the real bound on exposure — set it at demo scale.
- A production deployment means a **fresh key and a fresh deployment**, and
  that key should not live on a shared host.

Hosting the burned key on the VPS does not worsen its exposure, but it does
make the ceiling and single-flight guards load-bearing rather than decorative.

## Run locally (against a fork)

```sh
npm --prefix services/quote-signer install
env $(grep -v '^#' services/quote-signer/.env | xargs) node services/quote-signer/server.mjs
curl -s localhost:8791/health | jq
curl -s -X POST localhost:8791/quote \
  -H 'content-type: application/json' -H "x-signer-secret: $SIGNER_SECRET" \
  -d '{"seller":"0x…","requestedStEth":"5000000000000000"}' | jq
```

## Deployment (shared VPS)

Mirrors the co-hosted `outreach` pattern exactly: dedicated unprivileged user,
user-local Node tarball (no system packages), systemd unit bound to localhost,
cloudflared tunnel for the public hostname. **Hard rules on that box: never
touch the docker stack, nginx, or any database that isn't ours.**

`scripts/deploy-quote-signer.sh` performs the install idempotently.
