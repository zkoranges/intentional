# Reservoir

Reservoir keeps Aqua maker inventory productive in ERC-4626 vaults until the
exact moment a trade settles.

The v1 judge proof is a constrained exact-in trade: Reservoir discovers that
the vault cannot safely deliver the curve's full candidate output, reduces the
output to current capacity, and recomputes a smaller input charge. Settlement
materializes the exact output immediately before `Aqua.pull`; received input is
reinvested after `Aqua.push` on a bounded, best-effort path.

Implementation and demo instructions will be completed gate by gate according
to [V1_SCOPE.md](V1_SCOPE.md), [SPEC.md](SPEC.md), and
[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

## Upstream and licensing

Reservoir pins:

- SwapVM `0817db4a618d975648e018222aedcdeb1206959e`
- Aqua `7a5972a6b562e3e622f6e6b2a0befef659cd5386`

**Powered by SwapVM — © Degensoft Ltd 2025**

Aqua — © Degensoft Ltd 2025

Reservoir's SwapVM extension is provided under
`LicenseRef-Degensoft-SwapVM-1.1`. The complete upstream license, notices, and
corresponding source are preserved in:

- `lib/swap-vm/LICENSE`
- `lib/swap-vm/LICENSES/`
- `lib/swap-vm/THIRD_PARTY_NOTICES`
- `lib/aqua/LICENSE`
- `lib/aqua/LICENSES/`
- `lib/aqua/THIRD_PARTY_NOTICES`

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the exact dependency
pins. V1 is limited to disposable local and fork fixtures and must not be
deployed or funded on a persistent network.

