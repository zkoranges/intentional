# Reservoir quote signer

> **Status: pre-alpha release candidate, not yet active.** The previous
> mainnet deployment is permanently retired because its immutable factor key
> was exposed. The existing-unstETH quote path is implemented and
> canonical-mainnet-fork proven; public issuance resumes only after the fresh
> deployment and activation gates pass.

The underwriting desk as a small HTTP service, so the app can request a
seller-bound firm quote instead of a human pasting a signed envelope.

```text
browser → Vercel /api/quote/lido (validation, secret header, no key)
        → quotes.intentional.so/Caddy
        → this service (127.0.0.1, factor key, ceiling, audit)
```

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | liveness + effective config (no secrets) |
| `POST` | `/quote` | `{seller, mode, requestedStEth? , requestId?, replaceNonce?}` → signed envelope |

`POST /quote` requires the `x-signer-secret` header (constant-time compared).
The response is the same envelope shape the fill path already consumes, so the
contracts and the executor script are unchanged.

Retry behavior is explicit:

- An identical request returns the exact durable envelope (same nonce and
  signature), including after a service restart.
- A deliberate requote sends the active envelope's decimal nonce as
  `replaceNonce`. The service revalidates chain state and signs the new
  envelope with that **same nonce**. Old and new envelopes are therefore
  mutually exclusive onchain: the first successful fill consumes the nonce.
- Independent wallets may hold simultaneous quotes while the sum of their
  payments fits the reserve's authoritative `availableFor(total)` result.
  A request that would exceed remaining capacity returns
  `409 RESERVE_CAPACITY_RESERVED` with the active liability, requested
  payment, total liability, available capacity, and retry timing.

## Safety properties

1. **Binds `127.0.0.1` only.** The public edge is Vercel; the dedicated Caddy
   reverse proxy is the only network path into the service.
2. **Hard ceiling.** `MAX_QUOTE_WEI` bounds every quote *independently of*
   measured reserve capacity, so a bug elsewhere in the service cannot issue
   an oversized quote. This bounds the **service**, not the key — see "Key
   handling" below.
3. **Aggregate reservation accounting.** One serialized critical section
   covers the complete sweep → validate → sign → durable-reserve sequence.
   SQLite versioned admission extends the same guarantee across signer
   processes: a stale capacity snapshot cannot commit. Independent users fit
   until `sum(active payments) + new payment` exceeds authoritative capacity.
   Requotes preserve and exclude their old nonce liability, so replacing a
   browser-abandoned envelope does not double-reserve it.
4. **Short expiry.** Default 120s, far inside the kernel's 15-minute bound.
5. **Fails closed** on: paused settlement, unsealed/misconfigured kernel or
   funding account, insufficient measured capacity, paused Lido queue, Lido
   bunker mode, seller balance below the request, signer-key/kernel mismatch.
6. **Audit trail.** Every signature and authenticated quote rejection is
   appended to `AUDIT_LOG` as JSONL. Unauthenticated scanner traffic is
   summarized at most once per minute to bounded journald.
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
- The desk relaunches only against a **fresh deployment with a dedicated
  key**. In the capped pre-alpha the protected service account on the shared
  VPS holds it; host compromise is therefore an explicit residual risk bounded
  by the `0.006 WETH` first-test reserve and retirement procedure.

The key material was removed from the VPS and the service units were stopped
and disabled when the deployment was retired.

## Run locally (against a fork)

```sh
npm --prefix services/quote-signer install
env $(grep -v '^#' services/quote-signer/.env | xargs) node services/quote-signer/server.mjs
curl -s localhost:8791/health | jq
curl -s -X POST localhost:8791/quote \
  -H 'content-type: application/json' -H "x-signer-secret: $SIGNER_SECRET" \
  -d '{"seller":"0x…","mode":"originate","requestedStEth":"5000000000000000"}' | jq
```

## Deployment (shared VPS)

Uses a dedicated unprivileged user, user-local Node tarball (no system
packages), systemd bound to localhost, and one isolated
`quotes.intentional.so` Caddy site. **Hard rules on that box: never touch the
Docker stack, another Caddy site, nginx, or any database that isn't ours.**

`scripts/deploy-quote-signer.sh` performs the install idempotently.
