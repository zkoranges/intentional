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
  against a required `DEPLOYMENT_MANIFEST` (chain id, kernel and both adapter
  addresses, `releaseState`); anything but an `active` manifest is refused.
  The retired v2 kernel (`0x50b619295e00990feB28E79fA939B5f42aF6AF53`) is
  additionally refused unconditionally. A local rehearsal must deploy a fresh
  disposable kernel rather than reusing a compromised identity. Refusal is a readiness state, not a
  crash: the process serves `/health` explaining itself and answers `/quote`
  with `503 REFUSED_DEPLOYMENT`; it never signs.
- **Bind safety.** A non-loopback `HOST` always refuses to start. There is no
  override. The reviewed posture is loopback-only behind an authenticated
  reverse proxy.
- **Both Lido modes.** The desk signs either a measured stETH origination or
  the purchase of one existing unstETH NFT. Existing-claim quotes bind the
  exact stETH/share economics but deliberately do not bind finalization state,
  so a pending claim that finalizes before fill remains executable.
- **Pricing wording.** The envelope and `/health` state the basis outright:
  a fixed operator spread, never presented as a market or oracle price.

### New environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `EXPECTED_CHAIN_ID` | `1` | Enforced against the manifest at startup and against the RPC (`eth_chainId`) on every quote. |
| `DEPLOYMENT_MANIFEST` | none | Required path to the active deployment manifest. Missing, retired, or mismatched manifests are refused. |
| `RESERVATIONS_DB` | `<dir of AUDIT_LOG>/quote-reservations.sqlite` | Reservation store location. Defaults next to the audit log so both durable records share the operator-owned directory. |
| `LIDO_UNSTETH_ADAPTER_ADDRESS` | none | Fresh existing-unstETH adapter; must match `contracts.lidoUnstETHExitAdapter.address` in the manifest. |

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
the 409 condition, unconditional bind refusal, deployment refusal, and the `/health`
shape with a no-secret-material assertion.

## Ops prerequisite for go-live: stable `quotes.intentional.so`

The desk binds `127.0.0.1` only. Dynadot must publish
`A quotes 62.171.182.177`; the existing Caddy instance terminates TLS and
proxies only this hostname to `127.0.0.1:8791`. Back up the shared Caddyfile,
add one isolated site, run `caddy validate`, then reload—never restart or
modify another service's site.

The factor key never goes to Vercel, Caddy, or this repo; it lives in the
signer service's mode-0600 environment. Vercel receives the shared
`SIGNER_SECRET` as a server-only value; the browser receives only the three
reviewed public contract pins.

## Fresh pre-alpha release integration

- **Fresh pre-alpha manifest.** `scripts/deploy-quote-signer.sh` reads
  `deployments/mainnet-pre-alpha-001.json` by default and sets
  `DEPLOYMENT_MANIFEST` in the service environment so the startup guard binds
  the desk to the fresh deployment. The stale retired deployment always comes
  up `refused` and never signs.
- **Go-live rehearsal.** Frontend → VPS quote → exact ERC-721 approval → fill
  on a current-head fork with the exact pre-alpha bytecode and both adapter
  bindings before pointing the desk at mainnet.
