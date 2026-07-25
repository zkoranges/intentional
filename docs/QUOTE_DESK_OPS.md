# Quote desk — operations

The paste box is gone. The app requests a seller-bound firm quote over HTTP
and lands directly on Approve.

```text
browser → Vercel /api/quote/lido      (validates; holds NO key)
        → HTTPS tunnel
        → VPS impatience-signer        (factor key, ceiling, single-flight, audit)
```

## Where things live

| Piece | Location |
|---|---|
| Service source | `services/quote-signer/` (this repo) |
| Deploy | `scripts/deploy-quote-signer.sh` (idempotent) |
| Fork proof | `scripts/rehearse-quote-signer.sh` |
| On the VPS | user `impatience`, app `/home/impatience/app`, logs `/home/impatience/logs` |
| Units | `impatience-signer.service` (127.0.0.1:8791), `impatience-tunnel.service` |
| Vercel (server-only) | `SIGNER_URL`, `SIGNER_SECRET` — never `NEXT_PUBLIC_*` |

## Co-tenancy rules on the shared VPS

The box also runs **cryptominute** (12 docker containers, postgres, nginx on
80/443) and **outreach** (systemd + its own tunnel, ~50k contact records).

- **Never** touch the docker stack, nginx, or any database that isn't ours.
- Our footprint is one user, one app dir, two systemd units, ~150 MB.
- Nothing we run binds a public port; 80/443 belong to cryptominute's nginx,
  which is why the public path is a tunnel and not Caddy.
- Disk was **93% full** at deploy time (13 GiB free), almost entirely
  cryptominute's `/opt` and `/var/lib/docker`. `deploy-quote-signer.sh`
  aborts below 2 GiB free. Watch `df -h /`.

## Day-to-day

```sh
ssh $DEPLOY_HOST systemctl status impatience-signer
ssh $DEPLOY_HOST journalctl -u impatience-signer -n 50 --no-pager
ssh $DEPLOY_HOST curl -sf http://127.0.0.1:8791/health
ssh $DEPLOY_HOST tail -f /home/impatience/logs/quote-audit.jsonl   # every quote + rejection
ssh $DEPLOY_HOST systemctl restart impatience-signer
```

Redeploy after a code change: `scripts/deploy-quote-signer.sh` (re-runs
safely; only rewrites our own files).

## The tunnel URL is currently ephemeral

`impatience-tunnel.service` runs a **quick tunnel**, so the hostname is random
and **changes on every restart**. After any restart:

```sh
ssh $DEPLOY_HOST "journalctl -u impatience-tunnel -n 40 --no-pager | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1"
# then update Vercel and redeploy
printf '%s' "<new url>" | npx vercel env add SIGNER_URL production --force
npx vercel --prod --yes
```

**Upgrade path (recommended before judging):** put a domain in Cloudflare and
run a *named* tunnel, which pins the hostname permanently — the same pattern
`outreach` already uses. That needs a zone the owner controls; it must not
reuse the `outreach.sh` zone (owner's separation rule).

## Safety properties (why this is safe to expose)

1. Signer binds `127.0.0.1`; the tunnel is the only ingress.
2. Shared secret, constant-time compared; the browser never sees it.
3. **Hard `MAX_QUOTE_WEI` ceiling** independent of measured capacity.
4. **Single-flight** — one outstanding unexpired quote at a time.
5. 120-second expiry, far inside the kernel's 15-minute bound.
6. Fails closed on paused settlement, paused/bunker Lido, thin capacity,
   seller balance, signer/kernel mismatch.
7. Every signature and rejection is appended to a JSONL audit log.

## Key handling — a permanent operating constraint

The mainnet factor key was exposed in a session transcript and is **burned**.
`factorSigner` is immutable, so rotating it means redeploying the whole v2
stack. Therefore:

- this mainnet instance is a **demo instance, permanently**;
- keep the reserve at demo scale and set `MAX_QUOTE_WEI` accordingly;
- a real deployment means a fresh key that does **not** live on a shared host.

## Current state and the one remaining step

The mainnet kernel and funding account are **paused** and the reserve was
recovered after the demo settlement, so the desk correctly answers
`503 SETTLEMENT_PAUSED` — fail-closed behavior verified end to end against
real mainnet state.

To make the public flow fillable again, **re-arm the demo instance** (two
factor transactions, user-authorized):

```sh
# 1. return WETH to the funding account and unpause it, then reinvest
cast send $WETH "transfer(address,uint256)" $FUNDING <amount> --private-key $FACTOR_PRIVATE_KEY --rpc-url $ETH_RPC_URL
cast send $FUNDING "setPaused(bool)" false ...
cast send $FUNDING "reinvestInventory()" ...
# 2. unpause settlement
cast send $KERNEL "setPaused(bool)" false ...
```

Verify with `curl $SIGNER/health` and a live quote request. Re-pause and
recover after the demo window.
