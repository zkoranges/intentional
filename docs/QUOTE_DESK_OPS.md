# Quote desk — operations

> **Status: release candidate ready; fresh activation pending.** The previous
> mainnet proof contracts are safely retired after reserve recovery and cannot
> be reactivated because their immutable signer key was exposed. Existing
> unstETH acquisition and the HTTP firm-quote flow are implemented and pass
> the canonical mainnet-fork product rehearsal. They are not publicly live
> until the fresh deployment, funding, activation, DNS and signer gates pass.
>
> This document remains the operating reference for the desk when it relaunches
> against a **fresh deployment with a fresh key**. See
> "Current state — retired, never to be re-armed" below.

The paste box is gone. When the desk runs, the app requests a seller-bound
firm quote over HTTP and lands directly on Approve.

```text
browser → Vercel /api/quote/lido      (validates; holds NO key)
        → HTTPS at quotes.intentional.so
        → VPS impatience-signer        (factor key, ceiling, single-flight, audit)
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
4. **Single-flight** — one outstanding unexpired quote at a time.
5. 120-second expiry, far inside the kernel's 15-minute bound.
6. Fails closed on paused settlement, paused/bunker Lido, thin capacity,
   seller balance, signer/kernel mismatch.
7. Every signature and rejection is appended to a JSONL audit log.

## Key handling — a permanent operating constraint

The mainnet factor key was exposed in a session transcript and is **burned**.
`factorSigner` is immutable, so the exposed key can never be rotated out of
the v2 deployment. Therefore:

- the v2 deployment is **permanently retired** — paused, unfunded, and never
  to be re-armed;
- service-side guards (`MAX_QUOTE_WEI`, single-flight, expiry) bound the
  *service*, not the key — they are **no protection** against a key holder
  who signs outside the service;
- any future desk runs against a **fresh deployment with a dedicated key**;
  for this capped pre-alpha the protected service account on the shared VPS
  holds that key, so host compromise remains an explicit risk bounded by the
  `0.002 WETH` first-test reserve and prompt retirement—not eliminated by
  service guards.

## Current state — retired, never to be re-armed

The v2 mainnet deployment (recorded in `deployments/mainnet-v2.json`)
completed its settlement proof and is **retired**: settlement and funding are
paused, the reserve was recovered, and only unstETH #130880 remains, pending
Lido finalization.

**Do not re-arm this deployment. There is no safe way to do it, and it must
never be attempted.** The factor key was exposed and `factorSigner` is
immutable, so unpausing or re-funding would hand control of any restored
reserve to whoever holds the exposed key. No re-arming runbook exists or will
exist.

The retired desk is stopped, its old key material was shredded, and the Vercel
`SIGNER_URL`/`SIGNER_SECRET` variables were removed. The fresh candidate key
and shared secret are staged outside the repository but the service remains
offline until the new deployment is active. With the desk down, the app has no
firm-quote path — by design.

Relaunching the desk means a **fresh deployment with a fresh key**, following
`docs/LIVE_ACTIVATION.md` from scratch. Never point the desk at the retired
deployment.
