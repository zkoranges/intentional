# ETHGlobal Lisbon 2026 submission record

This document is the honest provenance and eligibility record for Reservoir.
It exists because the 1inch Aqua prize requires official Aqua/SwapVM use,
onchain token transfers in the final demo (local forks are allowed), and proper
Git history. Reservoir was built from scratch during ETHGlobal Lisbon 2026; no
project-specific code, designs, or assets predate the hackathon.

Official rules:

- [1inch Aqua prizes and qualification requirements](https://ethglobal.com/events/lisbon2026/prizes)
- [ETHGlobal rules](https://ethglobal.com/rules)

## Track decision

Reservoir qualifies technically for **Build an Aqua App** and earns the
modified-SwapVM consideration:

- official Aqua is pinned at
  `7a5972a6b562e3e622f6e6b2a0befef659cd5386`;
- official SwapVM is pinned at
  `0817db4a618d975648e018222aedcdeb1206959e`;
- `ReservoirSwapVMRouter` redeploys the reviewed router extension and handles
  custom opcode `0x92`;
- production-contract fork tests execute token transfers through official Aqua
  and the modified Reservoir router;
- **both proofs were additionally executed for real on Ethereum mainnet on
  2026-07-25**: an exact-input intent filled through canonical Aqua
  (`0xdfb6b280dfe8255ee3d0c4c74243ab9d9d4637b412926f1a9731654340f64d37`) and
  an atomic Lido factoring settlement
  (`0x6c7dfd20a40584cf2cb40baa27e98472599dbca62da470bab6bfd2b42071d611`,
  unstETH #130880); manifests live in `deployments/`; and
- the fresh `pre-alpha-001` deployment subsequently acquired that existing
  unstETH NFT in one browser-driven atomic sale
  (`0x36de5e1d760959462a5c78ea9215b17a67d03666ee4dcb1ecd34c59851ed4aa9`);
  its five source-verified contracts and productive-reserve receipts are
  recorded in `deployments/mainnet-pre-alpha-001.json`; and
- the two proofs are technically independent and are not represented as one
  transaction.

Reservoir is entered in the standard **Build an Aqua App** track. Both the v1
Aqua reserve engine and the v2 asynchronous-claim extension were designed and
implemented during ETHGlobal Lisbon 2026.

## Project layers

The repository preserves two deliberately distinct layers.

Reservoir v1 / Aqua reserve engine:

- `src/accounts/ReservoirMakerAccount.sol`
- `src/adapters/ERC4626ReserveAdapter.sol`
- `src/instructions/ReserveClamp.sol`
- `src/opcodes/ReservoirOpcodes.sol`
- `src/routers/ReservoirSwapVMRouter.sol`

Reservoir v2 / asynchronous-claim extension:

- `src/claims/**`
- live Lido withdrawal origination;
- ERC-7540/8161 mixed Pending + Claimable acquisition;
- productive StataWETH funding with acquire-before-pay settlement;
- release, activation, quote, and verification scripts;
- no-mock production-contract fork tests; and
- the wallet frontend and jury proof.

v2 is a settlement sidecar that reuses the v1 ERC-4626 reserve adapter. It does
not pretend that the claims kernel itself executes inside SwapVM.

## Repository history

The public repository was created on 2026-07-25. The first v2 import is large:

- `72056ce` — initial v2 live-beta import;
- `eda8999` — frontend runtime pin;
- `0fe0ddb` — wallet receipt verification;
- `24fbe79` — activation-boundary hardening;
- `b2cf9fe` — reproducible production-fork proof; and
- `e847845` — public ETHGlobal jury mode, provenance, and local-fork browser
  runner.

History has not been rewritten or artificially split. The following successful
GitHub Actions runs provide third-party timestamps for each release step:

- [`72056ce` CI](https://github.com/zkoranges/intentional/actions/runs/30154260385)
- [`eda8999` CI](https://github.com/zkoranges/intentional/actions/runs/30154309267)
- [`0fe0ddb` CI](https://github.com/zkoranges/intentional/actions/runs/30155110086)
- [`24fbe79` CI](https://github.com/zkoranges/intentional/actions/runs/30156452745)
- [`b2cf9fe` CI](https://github.com/zkoranges/intentional/actions/runs/30156720242)
- [`b2cf9fe` production fork proof](https://github.com/zkoranges/intentional/actions/runs/30156722744)
- [`e847845` CI](https://github.com/zkoranges/intentional/actions/runs/30159117366)
- [`e847845` production fork proof](https://github.com/zkoranges/intentional/actions/runs/30159264327)

## AI assistance disclosure

The team directed product scope, protocol selection, threat-model priorities,
acceptance criteria, and release decisions. Coding and review used Codex and
Claude Opus 5 agents. Agent findings were accepted only after reproduction
against source, tests, pinned fork state, or compiled artifacts.

`FINAL_V2_REVIEW.md` is an AI-assisted review record, not an independent
professional audit.

## Final-demo boundary

The public Vercel page provides:

- links to the public source and reproducible CI run;
- live canonical Lido originate/claim operations for connected mainnet
  wallets;
- discovery of seller-owned unstETH positions; and
- a fail-closed owned-claim sale flow that becomes actionable only when a
  fresh reviewed kernel, both Lido adapters, funded reserve, and operator
  quote desk are active and build-pinned.

For final judging, the primary evidence is the pair of real Ethereum mainnet
receipts above, executed with controlled team wallets and operator pricing —
proving machinery, atomicity, and real protocol integration, not market
demand. `make live-product-e2e` additionally reproduces the complete flow on a
disposable chain-1 fork (within the explicit local-fork allowance) as the
interactive stage demo.

## Deployment status disclosure

**Current state (2026-07-26): `pre-alpha-001` is active on Ethereum
mainnet.** [Intentional](https://www.intentional.so) serves authenticated,
seller-bound, short-lived firm quotes for stETH origination and existing
unstETH acquisition. The quote desk uses disclosed operator pricing (25 bps),
checks aggregate signed liabilities against the live productive reserve, and
keeps the signing key off Vercel and out of the browser. This is an unaudited,
capped hackathon pre-alpha rather than evidence of market price discovery or
demand.

The browser-driven existing-claim proof used controlled team wallets. Seller
`0x894E65c06722162A98bd7ed2A2aBDe1Aa6F1fc99` was also the factor signer of
the earlier, permanently retired proof deployment, and unstETH #130880 was a
re-sale of the claim originated in that earlier proof. The transaction proves
the production machinery, atomicity, real Lido integration, and exact WETH
payment; it does not prove independent customer demand.
Four later controlled browser tests exercised both live adapters and are
listed with complete receipts under `additionalControlledFills` in the active
deployment manifest.

The earlier deployment in `deployments/mainnet-v2.json` remains permanently
retired, paused, and unfunded because its immutable signer key was exposed.
It must never be reactivated. The active deployment uses a fresh factor
identity and the source-verified addresses in
`deployments/mainnet-pre-alpha-001.json`.
