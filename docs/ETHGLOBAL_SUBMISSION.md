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
  and the modified Reservoir router; and
- the final Lido/Aave settlement uses a separate production-contract chain-1
  fork. The two proofs are required but are not represented as one transaction.

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

- [`72056ce` CI](https://github.com/zkoranges/reservoir-v2-eth-lisbon/actions/runs/30154260385)
- [`eda8999` CI](https://github.com/zkoranges/reservoir-v2-eth-lisbon/actions/runs/30154309267)
- [`0fe0ddb` CI](https://github.com/zkoranges/reservoir-v2-eth-lisbon/actions/runs/30155110086)
- [`24fbe79` CI](https://github.com/zkoranges/reservoir-v2-eth-lisbon/actions/runs/30156452745)
- [`b2cf9fe` CI](https://github.com/zkoranges/reservoir-v2-eth-lisbon/actions/runs/30156720242)
- [`b2cf9fe` production fork proof](https://github.com/zkoranges/reservoir-v2-eth-lisbon/actions/runs/30156722744)
- [`e847845` CI](https://github.com/zkoranges/reservoir-v2-eth-lisbon/actions/runs/30159117366)
- [`e847845` production fork proof](https://github.com/zkoranges/reservoir-v2-eth-lisbon/actions/runs/30159264327)

## AI assistance disclosure

The team directed product scope, protocol selection, threat-model priorities,
acceptance criteria, and release decisions. Coding and review used Codex and
Claude Opus 5 agents. Agent findings were accepted only after reproduction
against source, tests, pinned fork state, or compiled artifacts.

`FINAL_V2_REVIEW.md` is an AI-assisted review record, not an independent
professional audit.

## Final-demo boundary

The public Vercel page provides:

- a wallet-free replay of the exact green fork proof;
- links to the public source and reproducible CI run;
- live canonical Lido originate/claim operations for connected mainnet
  wallets; and
- a fail-closed Reservoir card until a reviewed persistent deployment is
  build-pinned.

For final judging, `make live-product-e2e` performs the actual onchain token
transfers on a disposable chain-1 fork using canonical Aqua, Lido, Aave, stETH,
WETH, and StataWETH contracts. This is within the explicit local-fork allowance.
No persistent mainnet deployment is claimed.
