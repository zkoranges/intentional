# Quote desk — operations

> **Status (2026-07-26): active capped pre-alpha.** The fresh deployment,
> productive reserve, authenticated quote service, DNS, and Vercel frontend are
> live. The previous proof deployment remains permanently retired because its
> immutable signer key was exposed; none of the active addresses below reuse
> that identity.

The paste box is gone. When the desk runs, the app requests a seller-bound
firm quote over HTTP and lands directly on Approve.

```text
browser → Vercel /api/quote/lido      (validates; holds NO key)
        → HTTPS at quotes.intentional.so
        → VPS impatience-signer        (factor key, auth, aggregate capacity, audit)
```

## Where things live

| Piece | Location |
|---|---|
| Service source | `services/quote-signer/` (this repo) |
| Deploy | `scripts/deploy-quote-signer.sh` (idempotent) |
| Fork proof | `scripts/rehearse-quote-signer.sh` |
| On the VPS | user `impatience`, app `/home/impatience/app`, logs `/home/impatience/logs` |
| Unit | `impatience-signer.service` (127.0.0.1:8791) |
| Vercel (server-only) | `SIGNER_URL`, `SIGNER_SECRET` — never `NEXT_PUBLIC_*` |

## Co-tenancy rules on the shared VPS

The box is shared with unrelated Docker and systemd workloads. Caddy owns the
public HTTP/TLS entry point; the quote signer owns only loopback port 8791.

- **Never** touch the Docker stack, unrelated Caddy sites, databases, nginx,
  or unrelated systemd units.
- Our footprint is one legacy isolated user, one app directory, one systemd
  unit, and one dedicated Caddy site.
- The Node process binds only `127.0.0.1:8791`; Caddy proxies only
  `quotes.intentional.so`.
- `deploy-quote-signer.sh` aborts below 2 GiB free. Watch `df -h /`.

## Day-to-day

```sh
make remote   # opens /root/.intentional/pre-alpha-001 on the VPS
ssh $DEPLOY_HOST systemctl status impatience-signer
ssh $DEPLOY_HOST journalctl -u impatience-signer -n 50 --no-pager
ssh $DEPLOY_HOST curl -sf http://127.0.0.1:8791/health
ssh $DEPLOY_HOST tail -f /home/impatience/logs/quote-audit.jsonl   # every quote + rejection
ssh $DEPLOY_HOST systemctl restart impatience-signer
```

Redeploy after a code change: `scripts/deploy-quote-signer.sh` (re-runs
safely; only rewrites our own files).

## Stable public ingress

Create DNS `A quotes 62.171.182.177`, then add only the dedicated
`quotes.intentional.so` Caddy site from
[`LIVE_ACTIVATION.md`](LIVE_ACTIVATION.md). Back up and validate the full
Caddyfile before a reload. The edge proxies only `/health` and `/quote`;
all scanner paths receive `404` without reaching Node. Do not restart Caddy
and do not edit another service's site.

## Safety properties (why this is safe to expose)

1. Signer binds `127.0.0.1`; Caddy is the only ingress.
2. Shared secret, constant-time compared; the browser never sees it.
3. **Hard `MAX_QUOTE_WEI` ceiling** independent of measured capacity.
4. **Aggregate-liability admission** — multiple wallets may hold quotes only
   while the sum of every still-fillable nonce liability fits the
   chain-observed reserve. SQLite transactions and an optimistic version guard
   make this restart- and cross-process-safe.
5. Same-nonce requotes are mutually exclusive onchain, but the store retains
   the maximum payment ever signed for that nonce until every superseded
   envelope has expired.
6. 600-second expiry, inside the kernel's 15-minute bound.
7. Fails closed on paused settlement, paused/bunker Lido, thin capacity,
   seller balance, signer/kernel mismatch.
8. Every signature and authenticated quote rejection is appended to a JSONL
   audit log. Unauthenticated scanner traffic is summarized at most once per
   minute to bounded journald rather than persisted request-by-request.

## Key handling

The factor key of the earlier deployment in `deployments/mainnet-v2.json` was
exposed and is **burned**. Its immutable signer can never be rotated, so:

- that deployment is **permanently retired** — paused, unfunded, and never
  to be re-armed;
- service-side guards bound the
  *service*, not the key — they are **no protection** against a key holder
  who signs outside the service;
- the active pre-alpha therefore uses a fresh deployment with a dedicated key
  held only by the protected VPS service account. Host compromise remains an
  explicit risk bounded by the capped reserve and prompt pause/recovery, not
  eliminated by service guards.

## Current active state

The active addresses, code hashes, receipts, canonical bindings, and release
limits are in `deployments/mainnet-pre-alpha-001.json`. Public status is
available from:

```sh
curl -fsS https://www.intentional.so/api/status
curl -fsS https://quotes.intentional.so/health
```

At release, the kernel and funding account are unpaused and sealed, both Lido
adapters are allowlisted, the signer reports `ready`, and quote admission uses
the current chain-observed capacity rather than a static claim that the full
pilot ceiling is always available.

## Historical retired deployment

The earlier v2 proof recorded in `deployments/mainnet-v2.json` is paused,
unfunded, and permanently retired. **Never point the desk at it, re-fund it, or
attempt to re-arm it.**
