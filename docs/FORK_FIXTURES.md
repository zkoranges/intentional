# Reservoir fork fixtures

This file records external facts and disposable measurements for the Reservoir
fork tests. It is evidence, not production configuration.

## Ethereum RPC source

- Verification date: 2026-07-24
- Primary endpoint: `https://eth.drpc.org`
- Fallback checked: `https://1rpc.io/eth`
- Network: Ethereum mainnet
- Authentication or secrets used: none

`eth.drpc.org` served both the pinned header and historical state reliably
during this pass. `1rpc.io` served the block and some historical calls but was
intermittent, so it is not the primary acceptance source.

`https://ethereum-rpc.publicnode.com` was used as a negative preflight check.
It served the historical header but rejected historical state without a
personal token. The fixture fails that case with:

```text
archive RPC required for block 25,604,561
```

All state-changing measurements below ran only inside Foundry fork snapshots.
Nothing was deployed to or funded on a persistent network.

## Pinned Aave Stata USDC fixture

| Fact | Value |
|---|---:|
| Block | `25,604,561` (`0x186b1d1`) |
| Block hash | `0x95ca77908413d71bd01cada1ece52b6c2f35467dbbb8f2367144cd0ffbe7888d` |
| Block timestamp | `1,784,919,683` (`2026-07-24T19:01:23Z`) |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| StataTokenV2 USDC | `0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E` |
| aUSDC | `0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c` |
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |

The fixture asserts nonempty code at all four addresses and verifies these
runtime links:

```text
Stata.asset()                  = USDC
Stata.aToken()                 = aUSDC
aUSDC.UNDERLYING_ASSET_ADDRESS() = USDC
aUSDC.POOL()                   = Aave V3 Pool
```

The exact block hash is checked at `N + 1` with `blockhash(N)`, after which the
fork is restored to block `N` for every state assertion.

## Pinned views

The preview probe amount is one USDC (`1,000,000` asset units). The receiver
for `maxDeposit` and owner for the empty `maxWithdraw` probe are the isolated
test contract.

| Call | Result |
|---|---:|
| `Stata.totalAssets()` | `78,663,143,378,150` |
| `Stata.totalSupply()` | `66,688,030,062,749` |
| `Stata.maxDeposit(probe)` | `347,266,066,238,697` |
| `Stata.maxWithdraw(emptyProbe)` | `0` |
| `Stata.previewDeposit(1 USDC)` | `847,767` shares |
| `Stata.previewWithdraw(1 USDC)` | `847,768` shares |
| `USDC.balanceOf(aUSDC)` | `224,640,199,584,485` |

`USDC.balanceOf(aUSDC)` is recorded as the directly observable underlying
liquidity reference. Reservoir still treats `Stata.maxWithdraw(maker)` as the
authoritative per-maker delivery limit.

## Timestamp-yield behavior

The isolated yield test deposits `1,000 USDC`, records a fixed share count, and
warps forward 30 days without rolling the block:

| Measurement | Result |
|---|---:|
| Fixed shares | `847,767,165` |
| `convertToAssets(shares)` before | `999,999,999` |
| `convertToAssets(shares)` after | `1,002,580,075` |
| Share-count delta | `0` |
| Block-number delta | `0` |

This proves the fixture's NAV movement is timestamp-based and does not require
`vm.roll`.

## Direct vault-deposit gas lower bounds

Setup:

- isolated calibration account funded with Foundry `deal`;
- one approval sufficient for both deposits is performed before measurement;
- each call deposits `1,000 USDC` directly into Stata for that account;
- the first measurement explicitly cools the Stata, USDC, aUSDC, and Pool
  accounts and writes a new receiver share balance;
- the repeat measurement is intentionally warm in the same test transaction
  and writes an existing receiver share balance; and
- gas excludes the initial funding and approval.

| Measurement | Gas / result |
|---|---:|
| First direct deposit, cold named accounts/new receiver | `225,031` gas |
| Repeat direct deposit, same-transaction warm receiver | `71,449` gas |
| Shares minted by each deposit | `847,767,165` |
| `maxWithdraw` after two deposits | `1,999,999,999` assets |

These are direct-vault lower bounds, not a maker-hook gas limit. The complete
adapter path also includes maker-to-adapter transfer, allowance handling,
preview/limit reads, dust checks, and event work. The USDC reinvest gas limit
was therefore chosen only after the complete-path measurement below.

## Complete adapter calibration and sealed limit

The complete calibration calls
`ReservoirMakerAccount.prepareInventory(USDC)` through the real generic
adapter. It includes the maker-to-adapter transfer, adapter-to-Stata approval,
deposit, dust check, and events. Configuration, initial maker allowances, and
funding are excluded.

| Measurement | Gas / result |
|---|---:|
| First full reinvest, cold named accounts/new receiver | `293,771` gas |
| Repeat full reinvest, same-transaction warm receiver | `151,071` gas |
| Sealed USDC hook limit | `500,000` gas |
| Absolute margin over measured first path | `206,229` gas |
| Shares minted by each `1,000 USDC` reinvest | `847,767,165` |

The `500,000` value is sealed only for the USDC reserve. The fork suite also
executes an output-first swap with USDC as the input and positively asserts:

```text
maker idle USDC decreases to zero
maker Stata shares increase
AssetsReinvested is emitted by the adapter
Deposit is emitted by Stata
ReinvestSucceeded is emitted by the maker
ReinvestFailed is not emitted
```

The full-path first measurement remains below the limit with substantial
absolute and percentage margin. The mock-asset reserve uses its separately
tested local limit.

## Commands

Compile without an RPC:

```sh
forge build
```

Run the isolated fixture suite:

```sh
forge test --match-path "test/fork/*Fixture*" \
  --fork-url "https://eth.drpc.org" -vv
```

The submission command should pass an archive-capable private or public
`ETH_RPC_URL` rather than hard-coding either endpoint in production or scripts.
