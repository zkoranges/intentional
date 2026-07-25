# Third-party notices

Reservoir contains code under several licenses. The top-level MIT license does
not replace a file's SPDX identifier or an upstream dependency's terms.

## Immutable Solidity dependencies

The following Git submodules are pinned by commit and must not be floated:

| Dependency | Commit | Upstream terms |
|---|---|---|
| 1inch SwapVM | `0817db4a618d975648e018222aedcdeb1206959e` | `LicenseRef-Degensoft-SwapVM-1.1` |
| 1inch Aqua | `7a5972a6b562e3e622f6e6b2a0befef659cd5386` | `LicenseRef-Degensoft-Aqua-Source-1.1` |
| 1inch Solidity Utils | `2d91bb67665467afc06907a69513b0fa66c46f0d` | MIT |
| OpenZeppelin Contracts | `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0` | MIT |
| Forge Standard Library | `8e40513d678f392f398620b3ef2b418648b33e89` | Apache-2.0 OR MIT |

Each dependency retains its complete license, copyright notice, and
corresponding source inside its submodule:

- `lib/swap-vm/LICENSE` and `lib/swap-vm/LICENSES/`;
- `lib/aqua/LICENSE` and `lib/aqua/LICENSES/`;
- `lib/solidity-utils/LICENSE.md`;
- `lib/openzeppelin-contracts/LICENSE`; and
- `lib/forge-std/LICENSE-APACHE` and `lib/forge-std/LICENSE-MIT`.

SwapVM and Aqua are source-available under Degensoft's own terms, not under a
generic permissive license. Those complete upstream terms control use,
modification, and distribution.

**Powered by SwapVM — © Degensoft Ltd 2025**

**Powered by Aqua — © Degensoft Ltd 2025**

## Reservoir v1 SwapVM-derived extensions

Reservoir adds the following files against SwapVM commit
`0817db4a618d975648e018222aedcdeb1206959e`. No pinned upstream file is modified
in place. These files carry
`SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1`:

- `src/instructions/ReserveClamp.sol`
- `src/opcodes/ReservoirOpcodes.sol`
- `src/routers/ReservoirSwapVMRouter.sol`
- `src/interfaces/IAquaReserveAdapter.sol`
- `src/interfaces/IAquaReserveResolver.sol`
- `src/accounts/ReservoirMakerAccount.sol`
- `src/adapters/ERC4626ReserveAdapter.sol`

They were first authored for Reservoir on 2026-07-24. Their source is included
in this repository, and their governing SwapVM license text is preserved in
the pinned submodule.

## Ethereum standards interfaces

These local interface surfaces carry
`SPDX-License-Identifier: CC0-1.0`:

- `src/claims/interfaces/IERC7540Redeem.sol`
- `src/claims/interfaces/IERC7540RedeemTransferable.sol`
- `src/claims/interfaces/IERC7575.sol`

They are minimal Solidity surfaces derived from the canonical Ethereum ERC
specifications:

- [ERC-7540: Asynchronous ERC-4626 Tokenized Vaults](https://github.com/ethereum/ERCs/blob/73672565aeb10e615905663ad457d75a19eae0c2/ERCS/erc-7540.md)
- [ERC-8161: Transferable Tokenized Vault Requests](https://github.com/ethereum/ERCs/blob/73672565aeb10e615905663ad457d75a19eae0c2/ERCS/erc-8161.md)
- [ERC-7575: Multi-Asset ERC-4626 Vaults](https://github.com/ethereum/ERCs/blob/73672565aeb10e615905663ad457d75a19eae0c2/ERCS/erc-7575.md)

The provenance snapshot above is Ethereum/ERCs commit
`73672565aeb10e615905663ad457d75a19eae0c2`, retrieved on 2026-07-25. The
Ethereum/ERCs repository publishes these standards under CC0-1.0. The local
files contain only the functions needed by Reservoir; they are not complete
copies of the standards.

## Lido withdrawal-queue interface

`src/claims/interfaces/ILidoWithdrawalQueue.sol` carries
`SPDX-License-Identifier: GPL-3.0`.

Its `requestWithdrawals` and `getWithdrawalStatus` surface and
`WithdrawalRequestStatus` layout are derived from Lido core tag `v3.0.2`,
commit `2a2210baa3939f8079c47e8b45656b9d40e90650`:

- [`contracts/0.8.9/WithdrawalQueue.sol`](https://github.com/lidofinance/core/blob/2a2210baa3939f8079c47e8b45656b9d40e90650/contracts/0.8.9/WithdrawalQueue.sol)
- [`contracts/0.8.9/WithdrawalQueueBase.sol`](https://github.com/lidofinance/core/blob/2a2210baa3939f8079c47e8b45656b9d40e90650/contracts/0.8.9/WithdrawalQueueBase.sol)

Those upstream files state copyright © 2023 Lido and GPL-3.0. Reservoir vendors
only the minimal interface surface, not the Lido implementation. GPL-3.0
governs that interface file; the independently authored v2 kernel and adapter
files retain their own MIT SPDX identifiers. This file-level description does
not narrow any obligation that GPL-3.0 may impose when code is combined or
distributed. “Lido,” “stETH,” and “unstETH” identify the integrated protocol
and assets and do not imply endorsement.

## Reservoir v2 and frontend

The independently authored v2 contracts and shared types use MIT unless a
source file says otherwise. OpenZeppelin imports remain governed by
OpenZeppelin's pinned MIT license.

The frontend dependency graph is locked in `frontend/package-lock.json`.
`frontend/package.json` identifies the direct Next.js, React, Vinext, Vite,
Cloudflare, Tailwind, TypeScript, and lint/build dependencies. Those packages
are not relicensed by Reservoir; each package retains its own published
license and notice.

## No endorsement claim

A Reservoir live-beta deployment may bind the canonical external addresses
documented in the repository. This does not claim endorsement by Degensoft,
1inch, Lido, Aave, the Ethereum standards authors, OpenZeppelin, Foundry, or
any frontend dependency author. Product names and addresses identify
interoperability targets only.
