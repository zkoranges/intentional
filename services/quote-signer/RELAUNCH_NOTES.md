# Quote desk relaunch notes (lane B4a)

These notes live here because `README.md` is owned by another lane during
Release A; fold them into the README once that lane lands. They cover what
changed in the service, what the operator must provide before go-live, and
what lane B4b still does afterward.

## What changed in the service (B4a)

- **Persistent reservations.** The single-flight guard ("one outstanding
  unexpired quote at a time") now lives in a SQLite store
  (`reservations.mjs`, `node:sqlite`, WAL + full sync) keyed by quote nonce
  with the deadline and amounts alongside. A restart no longer forgets an
  outstanding quote, so two live quotes can never coexist.
- **Fill-release.** On every quote request the desk sweeps its open
  reservations against the kernel: a reservation whose nonce the kernel
  reports consumed (`nonceUsed`) is released as `consumed-on-chain` instead
  of blocking new quotes until TTL expiry. Expired reservations are released
  as `expired` without a chain read. Every release is audited.
- **First-class readiness.** `/health` now reports an explicit readiness
  state — `ready`, `paused` (settlement paused on the kernel), `refused`
  (retired / mismatched deployment or signer), `not-ready` (unsealed
  contracts, Lido paused or bunker, no capacity), `pending`, `error` — plus
  chain id, all configured contract addresses, pause flags, and current
  on-chain capacity. The payload is asserted free of secret material (shared
  secret, factor key, RPC URL) before every response.
- **Deployment refusal.** At startup the service verifies its configuration
  against an optional `DEPLOYMENT_MANIFEST` (chain id, kernel and adapter
  addresses, `releaseState`); anything but an `active` manifest is refused.
  The retired v2 kernel (`0x50b619295e00990feB28E79fA939B5f42aF6AF53`) is
  additionally refused whenever the RPC endpoint is non-loopback — only a
  local fork rehearsal may target it. Refusal is a readiness state, not a
  crash: the process serves `/health` explaining itself and answers `/quote`
  with `503 REFUSED_DEPLOYMENT`; it never signs.
- **Bind safety.** A non-loopback `HOST` refuses to start unless
  `ALLOW_NONLOCAL_BIND=1` is set explicitly, and then it starts with a loud
  warning. The reviewed posture is loopback-only behind a tunnel.
- **Pricing wording.** The envelope and `/health` state the basis outright:
  a fixed operator spread, never presented as a market or oracle price.

### New environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `EXPECTED_CHAIN_ID` | `1` | Enforced against the manifest at startup and against the RPC (`eth_chainId`) on every quote. |
| `DEPLOYMENT_MANIFEST` | unset | Path to the deployment manifest to verify against. **Set this in production**; B4b points it at `deployments/mainnet-v3.json`. |
| `RESERVATIONS_DB` | `<dir of AUDIT_LOG>/quote-reservations.sqlite` | Reservation store location. Defaults next to the audit log so both durable records share the operator-owned directory. |
| `ALLOW_NONLOCAL_BIND` | unset | `1` permits a non-loopback `HOST`, with a warning. Leave unset. |

Runtime state files (`quote-reservations.sqlite` + WAL/SHM, the `*.jsonl`
audit log) are gitignored; nothing under the operator directory is ever
committed.

### Behavior contracts preserved

`scripts/rehearse-quote-signer.sh` semantics are unchanged: 401 on a bad
secret, 400 over the hard ceiling, 409 while a quote is outstanding (now
backed by SQLite), and the exact 0.0049875 WETH fill. The rehearsal's fork
targets a loopback RPC, which is exactly the carve-out the retired-kernel
guard allows. `node --test` (or `npm test` in this directory) covers the new
guarantees: reservation survival across restart, consumed-nonce release,
the 409 condition, bind refusal, deployment refusal, and the `/health`
shape with a no-secret-material assertion.

## Ops prerequisite for go-live: a NAMED tunnel on a zone the operator controls

The desk binds `127.0.0.1` only; the public hostname is a Cloudflare tunnel
in front of it. Two hard requirements, surfaced now rather than at go-live:

1. **Named tunnel, not a quick tunnel.** A quick tunnel
   (`cloudflared tunnel --url ...`) gets a random `trycloudflare.com`
   hostname that CHANGES on every restart — the Vercel proxy's `SIGNER_URL`
   would silently break at the first VPS reboot. The relaunch requires a
   *named* tunnel with a pinned hostname.
2. **A DNS zone the operator controls — NOT `outreach.sh`.** The co-tenant
   zone belongs to a different owner; parking the quote desk's hostname on
   it couples the desk's availability and trust to someone else's zone
   (owner separation). **If no operator-controlled zone exists today,
   acquiring one is an unplanned external prerequisite — flagging it here,
   ahead of go-live.**

What is needed from the operator (one-time, on the VPS; credentials never in
the repo):

- a domain/zone in the operator's own Cloudflare account;
- `cloudflared tunnel login` and `cloudflared tunnel create reservoir-quote-desk`
  (writes a credentials JSON on the VPS — keep it 0600, out of the repo);
- `cloudflared tunnel route dns reservoir-quote-desk quotes.<operator-zone>`
  to pin the hostname;
- a tunnel config whose ingress points at `http://127.0.0.1:8791`
  (everything else `http_status:404`), run as a systemd unit;
- update the Vercel proxy's `SIGNER_URL` to `https://quotes.<operator-zone>`
  once, after which restarts never change it.

The factor key never goes to Vercel, the tunnel config, or this repo; it
lives only in the signer host's environment file.

## Deferred to lane B4b (after B1 + B3)

- **v3 manifest repoint.** `scripts/deploy-quote-signer.sh` and
  `scripts/rehearse-quote-signer.sh` still read `deployments/mainnet-v2.json`;
  B4b reparameterizes both to `deployments/mainnet-v3.json` and sets
  `DEPLOYMENT_MANIFEST` in the service environment so the startup guard binds
  the desk to the fresh deployment. Until then the guards added here make the
  stale configuration fail closed: a retired manifest (or the retired kernel
  over a live RPC) comes up `refused` and never signs.
- **Both modes.** Origination and existing-unstETH quoting, with readiness
  checks verifying `isAdapterAllowed` for both adapters, land in B4b.
- **Go-live rehearsal.** Frontend → VPS quote → approval → fill on a
  current-head fork with the exact v3 addresses before pointing at mainnet.
