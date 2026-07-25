# Reservoir quote signer

> **Status: stopped.** The v2 mainnet deployment this desk served is
> permanently retired (the immutable factor key was exposed), the service and
> tunnel units are stopped and disabled, and the key material was removed from
> the host. The desk relaunches only against a fresh deployment with a fresh
> key — see "Key handling" below.

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
   measured reserve capacity, so a bug elsewhere in the service cannot issue
   an oversized quote. This bounds the **service**, not the key — see "Key
   handling" below.
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

## Key handling — why the v2 instance is retired

The mainnet factor key **was exposed in a working session transcript** and must
be treated as burned. `AsyncClaimSettlement.factorSigner` is immutable, so the
exposed key can never be rotated out of the v2 stack (kernel, funding account,
reserve adapter, Lido adapter).

Consequences that are **operating rules, not suggestions**:

- The v2 mainnet deployment is **permanently retired** — paused, unfunded,
  and never to be re-armed, re-funded, or unpaused.
- `MAX_QUOTE_WEI` and the other guards above bound the *service* only. They
  are **no protection** against someone who holds the key and signs outside
  the service — nothing in this service constrains an exposed key.
- The desk relaunches only against a **fresh deployment with a fresh key**,
  and that key never lives on a shared host.

The key material was removed from the VPS and the service units were stopped
and disabled when the deployment was retired.

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
