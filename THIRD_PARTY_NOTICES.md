# Third-party notices

Reservoir vendors the following immutable Git submodules:

| Dependency | Commit |
|---|---|
| 1inch SwapVM | `0817db4a618d975648e018222aedcdeb1206959e` |
| 1inch Aqua | `7a5972a6b562e3e622f6e6b2a0befef659cd5386` |
| 1inch Solidity Utils | `2d91bb67665467afc06907a69513b0fa66c46f0d` |
| OpenZeppelin Contracts | `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0` |
| Forge Standard Library | `8e40513d678f392f398620b3ef2b418648b33e89` |

Each dependency retains its upstream license and notice files inside its
submodule. SwapVM and Aqua have source-available licenses rather than a generic
permissive license; their complete terms control use and distribution.

## Reservoir modifications

Reservoir adds new files that extend SwapVM
`0817db4a618d975648e018222aedcdeb1206959e`; no upstream file is modified in
place. First authored on 2026-07-24 and licensed under
`LicenseRef-Degensoft-SwapVM-1.1`:

- `src/instructions/ReserveClamp.sol`
- `src/opcodes/ReservoirOpcodes.sol`
- `src/routers/ReservoirSwapVMRouter.sol`
- `src/interfaces/IAquaReserveAdapter.sol`
- `src/interfaces/IAquaReserveResolver.sol`
- `src/accounts/ReservoirMakerAccount.sol`
- `src/adapters/ERC4626ReserveAdapter.sol`
