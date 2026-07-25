# Reservoir v2 fork-realism record

> Audited: 2026-07-25
>
> Pin: Ethereum mainnet block `25,604,561`
>
> Hash:
> `0x95ca77908413d71bd01cada1ece52b6c2f35467dbbb8f2367144cd0ffbe7888d`

Every fork acceptance uses canonical production external contracts. The only
test-created components are the Reservoir contracts under review, disposable
users, and their funded balances. No mock contract is imported anywhere under
`test/fork/`.

| Suite | Canonical mainnet execution | Test-created component | What it proves |
|---|---|---|---|
| `AaveStataUSDCFixture.t.sol` | USDC, StataUSDC, aUSDC, Aave V3 Pool; exact pinned views; real deposit and time-indexed NAV | Disposable depositor; USDC test balance | The reviewed addresses are wired together at the pin, deposits mint real Stata shares, fixed-share NAV accrues, and real deposit gas is measured. |
| `AaveStataUSDC.t.sol` | canonical Aqua, USDC, WETH, StataUSDC, StataWETH, aUSDC, aWETH, Aave V3 Pool; real deposits, withdrawals, reinvestment, and NAV | Reservoir router/maker deployed on the fork; disposable taker/maker balances | Canonical Aqua swaps canonical WETH against canonical USDC while both maker reserves remain in their canonical production Aave Stata vaults. |
| `LidoWithdrawalClaim.t.sol` | stETH `submit`, WithdrawalQueueERC721 request, WETH, StataWETH, aWETH, Aave V3 Pool | Reservoir v2 contracts and disposable seller/factor accounts | A real Lido claim is acquired before a real Aave StataWETH withdrawal pays the seller, atomically, through the signed v2 kernel. |
| `LiveProductMainnet.t.sol` | canonical Lido approval/request/mint/status and a historical finalized claim/ETH payout/burn | Disposable wallet for origination; historical request owner impersonated only for its normal public claim call | The exact browser wallet calls work against live protocol state, and a real finalized unstETH can be claimed by its current owner without privileged protocol impersonation. |

## Canonical bindings checked in code

Every suite checks runtime code and protocol wiring, not merely hard-coded
addresses. The Lido proof requires:

- WithdrawalQueueERC721 reports canonical stETH;
- StataWETH reports canonical WETH as `asset()`;
- StataWETH reports canonical aWETH;
- aWETH reports canonical WETH and the canonical Aave V3 Pool; and
- the new queue request is owned by the factor with the measured stETH-share
  amount and remains unfinalized and unclaimed.

The Aave proofs bind both StataUSDC and StataWETH to their canonical
underlyings, aTokens, and the Aave V3 Pool. The isolated USDC fixture also
asserts exact historical values.

## Cheatcodes and their boundary

- `vm.rollFork` pins and restores historical mainnet state. The exact block
  hash is checked at `N + 1`, then execution returns to `N`.
- `deal(USDC, ...)` gives disposable accounts input capital. It does not mock
  StataUSDC, aUSDC, or the Aave Pool; subsequent deposits and withdrawals call
  the canonical contracts.
- `vm.deal(... ETH ...)` gives disposable Lido/factor accounts ETH. stETH and
  WETH are then obtained through their canonical payable entry points.
- `vm.warp` advances timestamp without rolling to invented future chain state.
  It isolates and proves the real Aave time-indexed NAV formula at fixed shares;
  the snapshot is restored before settlement.
- `vm.prank` represents disposable users. No deployed protocol, oracle,
  finalizer, keeper, or privileged governance address is impersonated.
- `vm.cool` makes named Aave accounts cold before gas calibration, which
  conservatively raises the measured first-path cost. `vm.rpc` performs the
  archive preflight; snapshot/revert cheatcodes isolate the NAV warp.
- Local Reservoir contracts are expected: the purpose is to exercise the code
  under review against canonical external protocols before any deployment.

No `vm.etch`, `vm.store`, `vm.mockCall`, mocked return data, or oracle/finalizer
impersonation is used in the fork suites.

## Assertions that make the Lido proof non-cosmetic

The flagship fork proof requires all of the following in one transaction:

1. a canonical Lido ERC-721 mint to the factor;
2. the mint log occurs before the canonical StataWETH `Withdraw` log;
3. the request status matches the measured stETH shares and signed floor;
4. the seller receives exactly the signed WETH payment;
5. the funding account burns exactly `previewWithdraw(payment)` StataWETH
   shares and holds no idle WETH before or after settlement;
6. nonce consumption and zero token/share adapter custody; and
7. any pre-existing forced native dust at deterministic fork deployment
   addresses remains unchanged.

The last assertion is relative by necessity: no Solidity contract can prevent
forced native-token donations. Transaction-flow ERC-20/share custody remains
zero. The live Lido adapter preserves any pre-existing donated stETH shares
relative to its entry baseline; it cannot recover those unsolicited shares.

## What the fork suite does not prove

- It does not finalize a Lido request or impersonate Lido's oracle.
- It does not prove live ERC-8161 adoption; that standard path uses the strict
  reference vault and adversarial local suite.
- It does not source USDC through a market trade.
- A pinned historical fork proves compatibility at that state, not future
  proxy behavior or production lifecycle safety.

The no-mock rule applies to the jury and fork acceptance surface. Local unit
tests still use deliberately hostile fixtures to exercise failures that cannot
be induced safely against production contracts. The ERC-8161 generality proof
also uses the strict reference implementation because no live production
ERC-8161 deployment is claimed.

Run the complete proof with an archive endpoint:

```sh
forge test --match-path "test/fork/*" --fork-url "$ETH_RPC_URL"
```

The jury-facing proof is:

```sh
ETH_RPC_URL="https://your-archive-mainnet-rpc.example" make live-product-e2e
```

This command additionally deploys the exact release bytecode, signs a
target-chain-timestamped quote, uses exact seller approval, executes through
the product ABI, and asserts the resulting Lido NFT, seller payment, and
remaining Aave NAV. Its temporary signer keys and quote file are generated at
runtime and deleted on exit.
