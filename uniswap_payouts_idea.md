# Reservoir Uniswap payouts specification

> Version: proposed 0.1.0
>
> Status: second-priority design candidate; Gate 0 only after the Aqua intent
> production proof remains green
>
> Target product release: Reservoir v2.1
>
> Target bounty: ETHGlobal Lisbon 2026 — Best Uniswap API Integration
>
> Last verified against public Uniswap documentation: 2026-07-25

## 0. Decision

Reservoir Uniswap payouts let a seller exchange a delayed protocol claim for an
immediate payment in an approved ERC-20 chosen by the seller.

The factor continues to underwrite and fund the claim in WETH. When the seller
requests another asset, Reservoir atomically converts the factor's exact WETH
advance through a route produced by the Uniswap Trading API and delivers the
output directly to the seller.

```text
seller claim or claim-producing asset
    -> Reservoir irrevocably acquires the complete claim
    -> exact factor WETH is materialized from Aave StataWETH
    -> Uniswap API-produced CLASSIC route executes
    -> seller receives at least the signed minimum payout asset
```

The complete transaction reverts unless both conditions hold:

1. Reservoir acquires the complete quoted claim; and
2. the seller receives at least the signed minimum amount of the selected
   payout asset.

This is a new payout rail for the existing claim-settlement product. It is not:

- a new claim-pricing model;
- a Uniswap liquidity position;
- a v4 hook;
- a general-purpose arbitrary-call router;
- a solver auction;
- a cross-chain swap;
- a UniswapX order; or
- a replacement for the existing exact-WETH settlement path.

## 1. Why this product exists

The current Reservoir v2 product pays exact WETH. That is appropriate for a
factor underwriting an ETH-denominated Lido withdrawal, but it does not satisfy
every seller's objective.

A user accepting a discount for immediate liquidity may specifically want to:

- exit ETH exposure into USDC;
- receive a treasury's accounting asset;
- avoid a second wallet transaction;
- avoid temporarily holding WETH; or
- guarantee that claim transfer and final payout either both happen or neither
  happens.

Uniswap becomes load-bearing because Reservoir cannot complete a non-WETH
payout without the route and execution calldata returned by the Uniswap API.
Displaying a Uniswap quote without executing it does not satisfy this
specification.

## 2. Current baseline and compatibility

The implementation must begin from the current shipped architecture:

- `AsyncClaimSettlement` validates a factor-signed EIP-712 quote, acquires the
  complete claim, and only then pays the seller.
- `ProductiveFundingAccount` holds WETH or ERC-4626 vault shares and can
  materialize an exact WETH payment to a recipient selected by its sealed
  settlement contract.
- `LidoWithdrawalClaimAdapter` originates one canonical Lido withdrawal request
  directly for the factor.
- `ERC8161RedeemClaimAdapter` acquires Pending and Claimable portions of one
  nonzero-ID request using measured postconditions.
- `ERC4626ReserveAdapter` provides conservative capacity and exact
  materialization from Aave StataWETH.

The existing contracts and their tests remain unchanged. The payout feature is
implemented as a sibling release, not by silently changing the semantics or
EIP-712 domain of the reviewed WETH-only kernel.

The recommended new deployment contains:

```text
AsyncClaimSettlementWithPayouts
    |- existing allowlisted IClaimAdapter contracts
    |- new UniswapPayoutExecutor
    `- new ProductiveFundingAccount instance
           `- existing ERC4626ReserveAdapter instance
                  `- Aave StataWETH
```

The new funding account instance is required because a sealed
`ProductiveFundingAccount` is bound to exactly one settlement contract.

Reservoir v1 Aqua/SwapVM is unaffected.

## 3. Product modes

### 3.1 Direct WETH payout

This preserves the current behavior:

```text
exact WETH materialized -> exact WETH transferred to seller
```

Rules:

- `payoutAsset == fundingAsset == WETH`;
- `payoutExecutor == address(0)`;
- `payoutDataHash == keccak256("")`;
- `minimumPayoutAmount == fundingAmount`; and
- the seller's measured WETH increase must equal `fundingAmount`.

No Uniswap API call is needed for this mode.

### 3.2 Uniswap ERC-20 payout

This is the new behavior:

```text
exact WETH materialized
    -> Uniswap approval proxy
    -> Universal Router v2/v3/v4 liquidity
    -> approved ERC-20 paid directly to seller
```

Rules:

- the funding asset is WETH;
- the payout asset is an allowlisted ERC-20 other than WETH;
- the factor spends exactly `fundingAmount` WETH;
- the seller receives at least `minimumPayoutAmount`;
- favorable execution above the minimum belongs to the seller;
- the route is an `EXACT_INPUT` route;
- the Uniswap API response must have `routing == CLASSIC`;
- the API request must restrict protocols to `V2`, `V3`, and `V4`;
- `x-permit2-disabled: true` must be used;
- the response transaction must target the current approved Uniswap proxy;
- the response transaction must declare the payout executor as `from`;
- the API recipient must be the seller;
- the route must be same-chain;
- native ETH input, native ETH output, wrapping, unwrapping, bridges, Chained
  Actions, UniswapX and Priority routes are rejected; and
- any unused WETH or unexpected executor custody causes a revert.

The first production allowlist should contain only canonical mainnet USDC.
Additional assets require separate token-behavior and liquidity review.

## 4. Hard invariants

The implementation is not complete unless these properties hold.

### 4.1 Acquisition-payment equivalence

> A seller receives a payout if and only if the complete quoted claim is
> irrevocably acquired in the same transaction.

If claim acquisition fails, no reserve assets leave the productive funding
account and no payout executes.

If funding, approval, Uniswap execution, payout measurement or cleanup fails,
the claim acquisition and consumed nonce roll back.

### 4.2 Exact factor debit

The factor commits exactly `fundingAmount` WETH to a fill.

- Direct mode pays exactly that WETH amount.
- Uniswap mode supplies exactly that amount as swap input.
- The payout executor must not spend preexisting assets.
- An exact-input route must leave no transaction-relative WETH residue.

### 4.3 Minimum seller credit

For Uniswap mode:

```text
sellerPayoutAfter - sellerPayoutBefore >= minimumPayoutAmount
```

Router return values, API estimates and emitted Uniswap amounts never replace
the seller balance-delta check.

For direct WETH mode, the delta must equal the exact funding amount.

### 4.4 No transient-custody residue

After a successful Uniswap payout:

- payout executor WETH balance equals its pre-fill balance;
- payout executor payout-token balance equals its pre-fill balance;
- no native ETH remains on the payout executor;
- no new proxy allowance remains above the pre-fill allowance;
- no claim NFT, vault share or claim asset remains on the payout executor; and
- no payout token remains on the claim adapter.

The deployed payout executor must start with zero token and native balances.
Unexpected preexisting WETH, payout-token or native-ETH dust makes a fill fail
closed.

### 4.5 No arbitrary execution

Only the immutable settlement contract may call the payout executor.

The payout executor may call only the immutable, reviewed Uniswap approval
proxy for the current chain. The call value must be zero. Calldata must be
nonempty and hash-bound by the factor's Reservoir quote.

No factor-signed route may authorize a target selected at fill time.

### 4.6 API independence onchain

The Uniswap API is used offchain to find a route and construct calldata. The
onchain contracts do not call HTTP services, parse JSON, trust an API price or
require the API to be online after the quote bundle has been returned.

Onchain safety comes from:

- the factor signature;
- immutable endpoint binding;
- route-data hash binding;
- the short Reservoir deadline;
- exact WETH input;
- measured seller output;
- custody cleanup; and
- atomic rollback.

## 5. Gate 0 — mandatory feasibility spike

Implementation must not begin until this spike passes against the current
Uniswap API.

The API documentation describes its `swapper` as a wallet and normally returns
a transaction for that address to broadcast. Reservoir instead needs a
contract to be the swapper and to invoke the API-produced transaction as a
nested call during settlement.

The no-Permit2 proxy flow is the intended compatibility path:

- send `x-permit2-disabled: true` to `/check_approval`, `/quote`, and `/swap`;
- approve WETH directly to the Uniswap proxy;
- request an `EXACT_INPUT` WETH-to-USDC quote;
- set `swapper` to the deployed payout executor;
- set `recipient` to a different seller address;
- set `protocols` to `["V2", "V3", "V4"]`;
- require `routing == "CLASSIC"`; and
- use the same explicitly pinned Universal Router version header on `/quote`
  and `/swap`.

The spike passes only if all of the following are demonstrated:

1. the API accepts a contract address as `swapper`;
2. `permitData` is null;
3. the returned transaction targets the current Uniswap approval proxy;
4. `swap.from` equals the payout executor;
5. `swap.chainId` equals the requested chain;
6. `swap.value` is zero for WETH input;
7. the payout executor can approve the proxy and call `swap.to` with
   `swap.data`;
8. the proxy pulls exactly the funded WETH from the executor;
9. USDC is delivered directly to the separate seller recipient;
10. the call succeeds when nested inside a harness transaction;
11. the same call reverts when the signed minimum output is not met; and
12. no executor balance or approval residue remains after success.

Run the spike first on Sepolia or another API-supported testnet with a deployed
executor. Then repeat it on a current mainnet fork using canonical WETH, USDC,
the Uniswap proxy and the API-selected Universal Router.

The API may simulate against public-chain state before the atomic transaction
has temporarily funded the executor. The spike must establish whether the API
still returns usable quote and swap calldata when the executor has no
persistent WETH balance. A requirement to pre-fund the executor with the full
advance is a failure because it defeats productive just-in-time funding.

### Gate 0 stop condition

Stop this direction and ask the Uniswap sponsor for a supported
contract-as-swapper workflow if:

- a public-chain WETH balance is required before the API will build calldata;
- nested execution changes required sender semantics;
- the proxy cannot pull from a contract caller;
- `/swap` requires a signature the executor cannot produce;
- only a UniswapX or Chained route is returned; or
- the output recipient cannot differ from the contract swapper.

Do not replace atomic execution with a cosmetic API quote merely to qualify for
the bounty.

## 6. Signed quote

### 6.1 New EIP-712 domain

Use a new contract and domain:

```text
name              Reservoir Uniswap Payouts
version           1
chainId           current chain
verifyingContract AsyncClaimSettlementWithPayouts
```

The old `Reservoir v2` domain and signatures must not be valid in the new
kernel.

### 6.2 Quote type

Recommended type:

```solidity
struct PayoutQuote {
    address factor;
    address seller;
    address claimAdapter;
    address claimController;
    address claimReceiver;
    address fundingAsset;
    uint256 fundingAmount;
    address payoutExecutor;
    address payoutAsset;
    uint256 minimumPayoutAmount;
    bytes32 claimDataHash;
    bytes32 boundsHash;
    bytes32 payoutDataHash;
    uint256 nonce;
    uint256 deadline;
}
```

EIP-712 type:

```text
PayoutQuote(
  address factor,
  address seller,
  address claimAdapter,
  address claimController,
  address claimReceiver,
  address fundingAsset,
  uint256 fundingAmount,
  address payoutExecutor,
  address payoutAsset,
  uint256 minimumPayoutAmount,
  bytes32 claimDataHash,
  bytes32 boundsHash,
  bytes32 payoutDataHash,
  uint256 nonce,
  uint256 deadline
)
```

Meanings:

- `fundingAsset`: exact asset debited from productive factor inventory; WETH in
  v2.1.
- `fundingAmount`: exact WETH input committed by the factor.
- `payoutExecutor`: zero for direct WETH, otherwise the immutable deployed
  Uniswap payout executor.
- `payoutAsset`: token the seller receives.
- `minimumPayoutAmount`: minimum measured seller delta.
- `payoutDataHash`: hash of the complete execution payload.

### 6.3 Payout data

Recommended opaque onchain payload:

```solidity
struct UniswapPayoutData {
    address target;
    uint256 value;
    bytes callData;
    bytes32 apiQuoteHash;
    bytes32 apiRequestIdHash;
    bytes32 universalRouterVersionHash;
}
```

Hash:

```text
payoutDataHash = keccak256(abi.encode(uniswapPayoutData))
```

`apiQuoteHash` is the hash of the RFC 8785 JSON Canonicalization Scheme
serialization of the Uniswap `/quote` object used in `/swap`.
`apiRequestIdHash` is for correlation and evidence; it is not a pricing oracle.

The server must use and test one RFC 8785-compatible implementation. It must
never hash implementation-dependent object key order.

The onchain executor does not need to understand the JSON hash. It verifies the
target, value, calldata and postconditions. The signed hashes provide audit
traceability and prevent the route bundle from being substituted after the
factor signs.

### 6.4 Quote validity

The existing v2 rules remain:

- factor matches the immutable factor signer;
- EOA or ERC-1271 factor signature is valid;
- caller equals seller;
- claim adapter is allowlisted;
- claim parties are nonzero;
- hashes match supplied bytes;
- nonce is unused and at or above the nonce floor;
- current timestamp is not after the deadline;
- deadline is no more than 15 minutes from fill time; and
- funding capacity covers the complete funding amount.

New rules:

- funding asset equals the funding account asset and WETH;
- funding amount is nonzero;
- payout asset is allowlisted;
- minimum payout is nonzero;
- direct and Uniswap mode constraints are internally consistent;
- supplied payout bytes hash to `payoutDataHash`;
- Uniswap payout executor equals the immutable configured executor;
- route target equals the immutable Uniswap proxy;
- call value is zero;
- calldata is nonempty;
- calldata selector equals the immutable swap selector established by Gate 0;
  and
- payout asset is a deployed ERC-20, not the native-token sentinel.

## 7. Contract responsibilities

### 7.1 `AsyncClaimSettlementWithPayouts`

The new kernel:

- copies the reviewed v2 authentication, nonce, pause, allowlist, seal,
  reentrancy and quote-lifetime behavior;
- uses the existing `IClaimAdapter` interface unchanged;
- binds one `ProductiveFundingAccount`;
- binds one `UniswapPayoutExecutor`;
- maintains an allowlist of payout assets;
- supports direct WETH and Uniswap ERC-20 payout modes;
- acquires before materializing;
- measures the seller's final payout;
- emits normalized claim and payout facts; and
- reverts the entire transaction on any failure.

Payout-asset management:

- `allowPayoutAsset` is factor-only and requires settlement to be paused;
- `revokePayoutAsset` is factor-only and may be called at any time;
- WETH must be allowed before sealing;
- at least one non-WETH asset is required to claim the Uniswap feature;
- every change emits an event; and
- revocation affects new fills immediately, including already signed but
  unfilled quotes.

### 7.2 `ProductiveFundingAccount`

No semantic change is required.

The new kernel calls:

```text
materializeAndPay(payoutExecutor, fundingAmount)
```

instead of hard-coding the seller in Uniswap mode. Existing recipient
balance-delta verification proves that the executor received exact WETH.

Direct WETH mode continues to call:

```text
materializeAndPay(seller, fundingAmount)
```

### 7.3 `UniswapPayoutExecutor`

Recommended immutable bindings:

```solidity
address public immutable settlement;
IERC20 public immutable fundingAsset;       // WETH
address public immutable uniswapProxy;
uint256 public immutable chainId;
bytes32 public immutable routerVersionHash;
bytes4 public immutable proxySwapSelector;
```

Recommended entry point:

```solidity
function execute(
    address seller,
    address payoutAsset,
    uint256 exactInputAmount,
    uint256 minimumOutputAmount,
    bytes calldata payoutData
) external returns (uint256 actualOutputAmount);
```

Rules:

1. only the immutable settlement may call;
2. `seller` and `payoutAsset` are nonzero;
3. payout asset differs from funding asset;
4. before kernel materialization, the executor has zero WETH, payout token and
   native ETH; on entry to `execute`, WETH equals exactly `exactInputAmount`
   while payout token and native ETH remain zero;
5. payout data decodes successfully;
6. target equals the immutable Uniswap proxy;
7. value equals zero;
8. call data is nonempty;
9. call-data selector equals the immutable proxy swap selector established by
   Gate 0;
10. record seller payout-token balance;
11. grant the proxy exactly `exactInputAmount` WETH allowance using a
    zero-first-safe approval pattern;
12. call the proxy with the exact API-produced calldata and bounded revert-data
    handling;
13. clear any remaining proxy allowance;
14. measure the seller's payout-token increase;
15. require the increase is at least `minimumOutputAmount`;
16. require executor WETH, payout token and native ETH return to zero; and
17. return the measured seller increase.

The executor must not:

- accept arbitrary target addresses;
- accept native value;
- expose factor withdrawals;
- expose token rescue in the initial release;
- retain user or factor funds;
- call claim adapters;
- calculate prices; or
- decode and rewrite API calldata.

Absence of a rescue method is intentional: successful calls must be dustless,
and failed calls roll back. Any unsolicited token transfer makes future fills
fail closed and requires deploying a new executor. If operational experience
shows griefing is practical, add a paused, factor-controlled recovery method in
a separately reviewed release rather than weakening the initial invariant.

## 8. Uniswap API integration

### 8.1 Server-side request

The Uniswap API key must remain in a server-side secret. It must never appear
in:

- frontend JavaScript;
- a public environment file;
- generated static assets;
- logs;
- quote bundles;
- demo recordings; or
- the repository.

For Uniswap mode, the quote service sends:

```json
{
  "type": "EXACT_INPUT",
  "amount": "<fundingAmount>",
  "tokenInChainId": 1,
  "tokenOutChainId": 1,
  "tokenIn": "<WETH>",
  "tokenOut": "<approved payout asset>",
  "swapper": "<UniswapPayoutExecutor>",
  "recipient": "<seller>",
  "slippageTolerance": 0.5,
  "routingPreference": "BEST_PRICE",
  "protocols": ["V2", "V3", "V4"]
}
```

Headers:

```text
x-api-key: server secret
x-permit2-disabled: true
x-erc20eth-enabled: false
x-universal-router-version: explicitly pinned supported version
```

The same router-version and no-Permit2 headers must be sent to `/swap`.

The exact initial slippage tolerance is a product policy input, not a protocol
constant. It must be displayed to the seller and capped by the quote service.
The recommended beta cap is 0.50%.

### 8.2 Required `/quote` checks

Reject unless:

- HTTP status is successful;
- `routing == "CLASSIC"`;
- quote input token is WETH;
- quote input amount equals `fundingAmount`;
- quote output token equals the requested payout asset;
- output recipient equals seller;
- quoted swapper equals payout executor;
- input and output chain IDs equal the target chain;
- the quoted minimum output is nonzero;
- no bridge or chained step exists;
- no integrator fee exists unless explicitly approved in a later spec; and
- `permitData` is null.

The Reservoir `minimumPayoutAmount` should equal the stricter of:

- the minimum encoded by the API route; and
- the product's independently calculated minimum.

If the two cannot be reconciled without rewriting API calldata, reject the
route.

### 8.3 Required `/swap` checks

Call `/swap` with the exact quote object returned by `/quote`,
`simulateTransaction` enabled when compatible with the contract-as-swapper
flow, and a deadline no later than the Reservoir quote deadline.

Reject unless:

- `swap.from == payoutExecutor`;
- `swap.to == configured Uniswap proxy`;
- `swap.chainId == target chain`;
- `swap.value == 0`;
- `swap.data` is a nonempty hex string;
- the first four bytes of `swap.data` equal the configured proxy swap selector;
- returned router version matches the pinned request version; and
- request IDs and quote hashes are recorded for debugging.

Never alter `swap.data`. Any alteration invalidates the API-built transaction
and the Reservoir route hash.

### 8.4 API failures

The quote service returns no Reservoir quote if Uniswap returns:

- no route;
- unsupported token;
- authentication failure;
- rate limit;
- failed simulation without an explicitly reviewed exception;
- non-CLASSIC routing;
- wrong recipient or swapper;
- a nonzero call value;
- stale quote;
- inconsistent router version; or
- malformed data.

Retry policy:

- no automatic retry for validation or unsupported-token errors;
- exponential backoff with jitter for HTTP 429, 500, 503 or 504;
- no more than three attempts;
- never reuse a prior route with a new Reservoir signature; and
- surface a WETH-direct fallback to the user when the API is unavailable.

## 9. Factor quote service

The Uniswap API prices only the WETH-to-payout conversion. It does not price the
future claim.

The factor quote service remains responsible for:

- inspecting the claim;
- estimating expected recovery;
- pricing queue delay, slashing, impairment, protocol and operational risk;
- selecting exact `fundingAmount` WETH;
- checking productive reserve capacity;
- requesting the Uniswap route;
- validating the API response;
- setting the minimum payout;
- allocating a nonce and deadline;
- hashing all claim, bounds and payout bytes; and
- signing the Reservoir EIP-712 quote.

Recommended endpoint:

```text
POST /api/reservoir/payout-quote
```

Request:

```json
{
  "chainId": 1,
  "seller": "0x...",
  "claimAdapter": "0x...",
  "claimController": "0x...",
  "claimReceiver": "0x...",
  "claimData": "0x...",
  "boundsData": "0x...",
  "payoutAsset": "0x...",
  "maximumSlippageBps": 50
}
```

Response:

```json
{
  "quote": {},
  "factorSignature": "0x...",
  "claimData": "0x...",
  "boundsData": "0x...",
  "payoutData": "0x...",
  "display": {
    "fundingAmountWeth": "...",
    "quotedPayoutAmount": "...",
    "minimumPayoutAmount": "...",
    "slippageBps": 50,
    "routing": "CLASSIC",
    "protocolsConsidered": ["V2", "V3", "V4"],
    "expiresAt": 0
  },
  "uniswapEvidence": {
    "quoteRequestId": "...",
    "swapRequestId": "...",
    "routerVersion": "..."
  }
}
```

The public response must not include the API key or factor private key.

### 9.1 Signing-key separation

The Uniswap API service and factor signing service should be separate trust
domains.

For the hackathon rehearsal:

- the API key may live in a local or hosted server environment;
- the disposable factor key may live in a local CLI environment; and
- the route JSON may be passed from the API client into the offline quote
  builder.

For any funded beta:

- use a reviewed ERC-1271 factor account or isolated signer;
- enforce adapter, asset, amount, slippage, target and deadline policy before
  signing;
- never place the factor key in the public frontend worker; and
- log hashes and decisions, not secrets.

## 10. Settlement sequence

`fillWithPayout` executes:

1. reject if paused or unsealed;
2. validate caller, factor, claim parties, claim adapter and payout asset;
3. validate funding and payout mode consistency;
4. hash and validate claim, bounds and payout bytes;
5. validate deadline, nonce and factor signature;
6. consume the nonce before every state-changing external call;
7. require complete WETH funding capacity;
8. record the seller's payout-asset balance;
9. call the claim adapter and require complete acquisition;
10. direct mode:
    - materialize and pay exact WETH to the seller;
11. Uniswap mode:
    - materialize and pay exact WETH to the payout executor;
    - call the payout executor with the hash-bound route;
    - require measured seller output at least the signed minimum;
12. verify no unexpected executor custody;
13. emit the normalized settlement event; and
14. return claim acquisition facts and actual payout amount.

External-call ordering:

```text
claim acquisition
    < Aave/StataWETH materialization
    < Uniswap proxy execution
    < successful final settlement event
```

Any later failure reverts every earlier step.

## 11. Events

Recommended event:

```solidity
event ClaimPayoutSettled(
    bytes32 indexed quoteHash,
    address indexed claimAdapter,
    address indexed seller,
    address factor,
    address claimController,
    address claimReceiver,
    address fundingAsset,
    uint256 fundingAmount,
    address payoutAsset,
    uint256 minimumPayoutAmount,
    uint256 actualPayoutAmount,
    address payoutExecutor,
    bytes32 payoutDataHash,
    bytes32 apiQuoteHash,
    bytes32 positionKey,
    uint256 claimId,
    uint256 pendingUnits,
    uint256 pendingReceived,
    uint256 claimableUnits,
    uint256 assetsReceived
);
```

Additional events:

```solidity
event PayoutAssetAllowed(address indexed asset);
event PayoutAssetRevoked(address indexed asset);
event UniswapPayoutExecuted(
    bytes32 indexed payoutDataHash,
    address indexed seller,
    address indexed payoutAsset,
    uint256 exactWethInput,
    uint256 actualOutput
);
```

Never emit raw API keys, signatures beyond the transaction input, or complete
API responses.

## 12. Economic semantics

The factor's claim quote and the Uniswap conversion are separate calculations.

Example:

```text
Expected claim recovery:           1.0000 WETH
Queue/risk/funding discount:        0.0200 WETH
Factor WETH advance:                0.9800 WETH
Uniswap quoted USDC output:       3,420.00 USDC
Maximum route slippage:              0.50%
Signed minimum seller payout:     3,402.90 USDC
```

Rules:

- factor risk is capped at exact WETH input plus claim underwriting risk;
- seller receives all positive Uniswap price improvement;
- seller bears no execution below the signed minimum because the fill reverts;
- seller pays transaction gas unless a later relayer spec says otherwise;
- Reservoir does not promise the API quote is globally optimal;
- no hidden protocol or integrator fee is enabled in v2.1;
- the frontend separates the claim discount from swap slippage; and
- annualized claim return must not be represented as guaranteed yield.

## 13. Frontend

### 13.1 Seller flow

1. Connect wallet.
2. Select or inspect the Lido/claim position.
3. Choose payout:
   - WETH; or
   - approved USDC.
4. Request a factor quote.
5. Display:
   - claim input and expected protocol recovery;
   - exact factor WETH advance;
   - selected payout asset;
   - current Uniswap estimate;
   - signed minimum payout;
   - maximum slippage;
   - factor discount;
   - gas estimate;
   - expiration; and
   - risk warning.
6. Request only the claim-side approval required by the selected claim adapter.
7. Simulate the complete Reservoir fill.
8. Submit one seller transaction.
9. Derive success only from:
   - a successful receipt;
   - `ClaimPayoutSettled`;
   - canonical claim owner/controller state; and
   - the seller's canonical payout-token balance delta.

The frontend must not infer success from an API response.

### 13.2 Failure states

Provide explicit messages for:

- factor quote expired;
- Uniswap route unavailable;
- route became stale;
- minimum payout not met;
- unsupported payout asset;
- insufficient productive funding capacity;
- claim state changed outside signed bounds;
- Lido queue paused;
- approval missing;
- API rate limited or unavailable;
- wrong network; and
- contracts not deployed or activation bindings not verified.

When the API is unavailable, offer a fresh direct-WETH quote. Never silently
change the payout asset.

## 14. Security model

### 14.1 Trusted components

- factor pricing and signing policy;
- allowlisted claim adapter code;
- immutable ProductiveFundingAccount and reserve adapter code;
- immutable Uniswap payout executor code;
- the configured Uniswap approval proxy;
- the Universal Router and pools reached through the proxy;
- canonical WETH and approved payout-token contracts; and
- chain consensus.

### 14.2 Untrusted components

- seller;
- arbitrary quote requester;
- browser;
- public RPC responses;
- Uniswap API availability;
- API output until validated and factor-signed;
- pool price between quote and fill;
- claim-protocol return values;
- token/router return values;
- unsolicited token transfers; and
- event-only evidence.

### 14.3 Principal risks and controls

| Risk | Required control |
|---|---|
| API key leakage | Server-side secret; never return or log it |
| Arbitrary-call injection | Immutable proxy target, zero value, signed calldata hash |
| Route substitution | Bind complete payout bytes in EIP-712 quote |
| Price movement | API slippage plus independently signed minimum seller delta |
| API/router version drift | Explicit version header and immutable reviewed target |
| UniswapX asynchronous fill | Protocol restriction and `routing == CLASSIC` |
| Cross-chain partial completion | Same-chain IDs and reject `CHAINED`/`BRIDGE` |
| Contract-swapper incompatibility | Mandatory Gate 0 spike |
| Long-lived approval drain | Exact per-fill approval, zero-first set and clear |
| Executor dust griefing | Zero pre/post balances; new deployment if griefed |
| Fee-on-transfer payout | Measured seller delta; initial allowlist excludes it |
| Reentrancy | Kernel non-reentrancy, only-kernel executor, checks/effects ordering |
| Stale claim state | Existing adapter measured postconditions and bounds |
| Stale route | Maximum 15-minute Reservoir deadline; API deadline no later |
| Partial claim without payment | Atomic rollback after any payout failure |
| Payment without claim | Acquisition completes before materialization |
| Favorable execution capture | Direct API recipient is seller |
| Malicious factor signature | Operational signer policy; short quotes; pause/cancel |

## 15. Required tests

### 15.1 Gate 0 API tests

- valid API key authenticates;
- explicit router version is honored on `/quote` and `/swap`;
- no-Permit2 header returns null permit data;
- API returns `CLASSIC` for WETH/USDC with V2/V3/V4 only;
- contract swapper plus separate recipient is accepted;
- API output transaction fields match the request;
- nested contract execution succeeds;
- no persistent full WETH balance is required before route construction; and
- invalid API key, rate limit and no-route responses fail clearly.

### 15.2 Quote and kernel unit tests

- direct-WETH quote remains exact;
- every new quote field is EIP-712-bound;
- old v2 signatures fail in the new domain;
- wrong payout executor, asset, minimum, route hash, target or call value fails;
- empty payout data fails in Uniswap mode;
- nonempty payout data fails in direct mode;
- unallowlisted or revoked payout asset fails;
- payout-asset changes require pause;
- quote deadline remains capped at 15 minutes;
- replay, nonce cancellation and nonce floor behave as v2;
- EOA and ERC-1271 factor signatures work;
- claim acquisition failure prevents funding;
- funding failure rolls back claim and nonce;
- payout failure rolls back claim, funding and nonce; and
- malicious/reentrant claim or payout adapter cannot double fill.

### 15.3 Payout executor unit tests

- only immutable settlement can execute;
- exact WETH is approved and spent;
- approval is reset after success;
- zero-first approval supports USDT-like behavior even though initial output is
  USDC;
- wrong target, nonzero value and empty calldata fail;
- proxy revert data is bounded;
- seller output below minimum fails;
- exact minimum succeeds;
- positive price improvement accrues to seller;
- preexisting WETH, output-token or native dust fails closed;
- leftover WETH or output-token dust fails;
- unexpected native ETH fails;
- payout token `balanceOf` revert fails atomically;
- fee-on-transfer output below minimum fails;
- malicious output token reentrancy fails;
- direct calls from factor or seller fail; and
- all approval and balance changes roll back after later failure.

### 15.4 Integration tests

- Lido origination -> StataWETH materialization -> mocked Uniswap USDC payout;
- ERC-8161 mixed Pending/Claimable acquisition -> USDC payout;
- direct WETH mode through the new kernel;
- claim succeeds but route reverts: everything rolls back;
- route succeeds internally but seller delta is insufficient: everything rolls
  back;
- stale pool price fails minimum payout;
- two sequential fills do not reuse nonce, balances or approvals; and
- payout-asset revocation invalidates an outstanding quote.

### 15.5 Canonical mainnet-fork test

Use:

- canonical stETH;
- canonical Lido WithdrawalQueueERC721;
- canonical WETH;
- canonical USDC;
- canonical Aave V3 StataWETH and Pool;
- current official Uniswap approval proxy;
- API-selected, explicitly pinned Universal Router version; and
- a live API-produced route generated with a valid API key.

Prove:

1. factor inventory begins as StataWETH shares with zero idle WETH;
2. seller begins with stETH and no transaction-relative USDC;
3. Lido mints the withdrawal request directly to the factor;
4. exact WETH is withdrawn only after claim acquisition;
5. the Uniswap proxy pulls exact WETH from the payout executor;
6. seller receives at least signed minimum USDC;
7. factor owns the canonical Lido claim;
8. executor and adapters are dustless;
9. nonce is consumed;
10. event ordering matches the settlement sequence; and
11. a forced slippage failure rolls back the Lido request and all token deltas.

### 15.6 Non-regression

The complete existing deterministic and fork suites remain green:

- Reservoir v1 Aqua/SwapVM;
- ReserveClamp and reserve adapters;
- existing WETH-only v2 kernel;
- Lido adapter;
- ERC-8161 adapter;
- invariant suites;
- frontend verification; and
- deployment/activation rehearsal.

## 16. Deployment and activation

The release follows the existing paused, unfunded activation discipline.

Deployment order:

1. deploy new ProductiveFundingAccount;
2. deploy new AsyncClaimSettlementWithPayouts;
3. deploy UniswapPayoutExecutor with immutable settlement, WETH, current
   Uniswap proxy, chain ID, router version hash and proxy swap selector;
4. deploy/bind existing ERC4626ReserveAdapter to the new funding account;
5. deploy or bind reviewed claim adapters to the new kernel;
6. configure funding account settlement and reserve;
7. allow WETH and USDC payout assets;
8. allow claim adapters;
9. keep settlement and funding paused;
10. seal all configuration;
11. publish addresses and runtime code hashes;
12. compile exact bindings into the frontend;
13. verify every immutable and code hash independently;
14. run the full current-chain rehearsal;
15. cap and deposit funding while paused; and
16. activate with one explicit operation only after all gates pass.

The official Uniswap proxy address and router version must be revalidated from
current official Uniswap documentation at build and deployment time. Do not
copy an address from this document into a deployment script without that
check.

## 17. Monitoring and operations

Monitor:

- settlement and funding pause state;
- claim-adapter allowlist;
- payout-asset allowlist;
- Uniswap proxy and router code hashes;
- Uniswap API status and error rate;
- quote-to-fill latency;
- route failure and minimum-output failure rate;
- funding capacity and StataWETH `maxWithdraw`;
- executor unsolicited balances;
- outstanding quote nonces;
- Lido queue pause, bunker mode and proxy upgrades; and
- actual versus quoted payout.

Emergency response:

1. pause settlement;
2. pause funding;
3. revoke affected payout asset or claim adapter;
4. cancel exposed nonce or advance nonce floor;
5. preserve API request IDs, quote hashes and transaction evidence;
6. do not activate a new router/proxy address without redeployment or reviewed
   configuration support; and
7. recover factor funding only through the existing paused recovery path.

API outage is not a solvency event. It disables new non-WETH quotes while
direct WETH settlement can remain available if operators intentionally leave
that mode active.

## 18. Demo

The judge demo has four acts.

### Act 1 — productive capital

- Factor owns StataWETH shares and zero idle WETH.
- Show capacity and share NAV.

### Act 2 — API is load-bearing

- Seller selects USDC.
- Show the live server request using a valid Uniswap API key without revealing
  the key.
- Show `EXACT_INPUT`, WETH/USDC, separate swapper/recipient,
  `V2/V3/V4`, `CLASSIC`, no-Permit2 proxy mode and pinned router version.
- Show the API request IDs and signed route hash.

### Act 3 — atomic claim cashout

- Seller submits one transaction.
- Lido claim is minted to factor.
- WETH materializes from StataWETH.
- API-produced route executes through Uniswap.
- Seller receives at least the signed USDC minimum.
- Executor ends empty.

### Act 4 — failure is atomic

- Reuse a fresh quote against deliberately changed price or excessive minimum.
- Uniswap payout fails.
- Show that no Lido claim was created, no nonce was consumed and no reserve
  assets left the funding account.

The demo must not claim that Uniswap prices the withdrawal claim. It routes the
immediate payout after the factor prices the claim.

## 19. ETHGlobal Uniswap prize requirements

As published for ETHGlobal Lisbon 2026, the open Best Uniswap API Integration
prize is $7,000:

- first: $4,000;
- second: $2,000; and
- third: $1,000.

Qualification requires:

- a valid Uniswap Developer Platform API key;
- Uniswap API use for core functionality;
- a public open-source GitHub repository;
- `FEEDBACK.md`;
- a completed
  [Uniswap Developer Feedback Form](https://developers.uniswap.org/hackathon-feedback)
  linking `FEEDBACK.md`; and
- README links to the relevant integration contracts and lines.

Submission checklist:

- [ ] Live valid-key `/quote` and `/swap` flow.
- [ ] Uniswap execution is necessary for USDC payout.
- [ ] Public repository.
- [ ] `FEEDBACK.md` covers API key setup, contract-as-swapper behavior,
      no-Permit2 proxy behavior, recipient support, routing restrictions,
      simulation friction and error handling.
- [ ] Feedback form submitted with the public `FEEDBACK.md` link.
- [ ] README links exact files and relevant lines.
- [ ] Demo video shows API evidence and onchain execution.
- [ ] No API key or factor key appears in repository, build or recording.

The Continuity-only Best Uniswap Stack Contribution is not a primary target.
This design uses the API as a product dependency; it does not claim to be an
open-source contribution to the Uniswap stack.

## 20. Implementation gates

### Gate 0 — API feasibility

Exit only when the contract-as-swapper, separate-recipient, no-Permit2,
nested-call flow passes.

### Gate 1 — scope and threat model

Freeze:

- direct WETH plus USDC-only beta;
- exact-input semantics;
- proxy and router version;
- quote type and domain;
- no native ETH;
- no UniswapX or cross-chain;
- no integrator fee; and
- all security invariants.

### Gate 2 — local contracts

Exit only when:

- new kernel and payout executor unit tests pass;
- direct WETH is preserved;
- mocked Uniswap integration passes;
- rollback and dust invariants pass; and
- existing v1/v2 tests remain green.

### Gate 3 — live API service

Exit only when:

- API key remains server-side;
- request and response validation is complete;
- route bytes are signed and reproducible;
- error handling is fail-closed;
- factor-key separation is demonstrated; and
- API request IDs are retained safely.

### Gate 4 — canonical fork proof

Exit only when one live API-produced WETH-to-USDC route settles the complete
canonical Lido/Aave/Uniswap transaction and the forced-failure case rolls back.

### Gate 5 — frontend and demo

Exit only when:

- seller can choose WETH or USDC;
- economic components are displayed separately;
- full fill simulation works;
- receipt verification uses canonical deltas and events;
- failure messages are explicit; and
- the four-act demo is repeatable.

### Gate 6 — release and submission

Exit only when:

- exact deployment bytecode matches tested bytecode;
- paused/unfunded activation rehearsal passes;
- full test matrix passes;
- independent security review is complete;
- README and `FEEDBACK.md` are complete;
- feedback form is submitted; and
- no secret scanning finding remains.

## 21. Hard acceptance criteria

The feature is complete only when all statements are true:

1. Existing Reservoir v1 and v2 remain unchanged and green.
2. Direct exact-WETH payout still works in the new kernel.
3. A seller can select canonical USDC.
4. A valid-key Uniswap API call produces the actual route used onchain.
5. The route is `CLASSIC`, same-chain, exact-input and limited to V2/V3/V4.
6. The payout executor is the API swapper and the seller is the API recipient.
7. Exact WETH is withdrawn from StataWETH only after complete claim acquisition.
8. The factor spends exactly the signed WETH amount.
9. The seller receives at least the signed USDC minimum.
10. Positive execution improvement goes to the seller.
11. All claim, nonce, reserve, approval and payout changes roll back on any
    later failure.
12. Executor and adapters retain no transaction-relative assets.
13. The API key and factor key remain private.
14. The canonical mainnet-fork success and failure proofs pass.
15. The submission requirements and feedback artifacts are complete.

## 22. Explicitly outside v2.1

- UniswapX Dutch or Priority orders;
- RFQ or solver competition for claim pricing;
- cross-chain or Chained Actions;
- native ETH output;
- arbitrary payout tokens;
- tokenized stocks;
- v4 hooks;
- liquidity provision;
- integrator or protocol fees;
- partial claim fills;
- batched claims;
- relayed Reservoir fills;
- seller smart-account batching;
- EIP-5792 or EIP-7702;
- existing unstETH purchase mode;
- Ether.fi adapter;
- a generalized marketplace or order book;
- settlement-time claim repricing;
- onchain price or risk oracle;
- AI pricing;
- payout executor upgrades; and
- mainnet funding beyond the existing capped-beta policy.

## 23. Open questions that must be answered at Gate 0

1. Does `/quote` return usable calldata when the contract swapper has zero
   persistent WETH because funding arrives only inside the atomic transaction?
2. Does `simulateTransaction: true` support the same just-in-time funding
   condition, or must Reservoir rely on its own fork simulation?
3. Which proxy and Universal Router version does the API currently select for
   Ethereum mainnet under `x-permit2-disabled: true`?
4. Can the returned proxy calldata be called from a contract without any
   `tx.origin`, EOA or signature assumption?
5. Does the API minimum output exactly match the amount enforced by the
   generated calldata?
6. Can the API deadline always be made no later than Reservoir's 15-minute
   deadline?
7. Is the API request/response schema stable enough to canonicalize and retain
   a reproducible quote hash?
8. What evidence do Uniswap judges want shown for valid-key core integration
   without exposing the key?

No implementation plan should estimate completion time until questions 1–6
have passing evidence.

## 24. References

- [ETHGlobal Lisbon 2026 prizes](https://ethglobal.com/events/lisbon2026/prizes)
- [Uniswap Swapping API integration guide](https://developers.uniswap.org/docs/trading/swapping-api/integration-guide)
- [Uniswap quote API reference](https://developers.uniswap.org/docs/api-reference/aggregator_quote)
- [Uniswap swap-calldata API reference](https://developers.uniswap.org/docs/api-reference/create_swap_transaction)
- [Uniswap swap routing](https://developers.uniswap.org/docs/trading/swapping-api/concepts/swap-routing)
- [Uniswap custom recipient support](https://developers.uniswap.org/docs/changelog/active-notifications/recipient-parameter-on-trading-api)
- [Uniswap proxy approval flow](https://developers.uniswap.org/docs/trading/swapping-api/concepts/no-permit2-workflow)
- [Uniswap supported chains and router versions](https://developers.uniswap.org/docs/trading/swapping-api/supported-chains)
- [Uniswap Universal Router overview](https://developers.uniswap.org/docs/protocols/universal-router/overview)
- `README.md`
- `V2_SCOPE.md`
- `V2_SPEC.md`
- `V2_THREAT_MODEL.md`
- `src/claims/AsyncClaimSettlement.sol`
- `src/claims/ProductiveFundingAccount.sol`
- `src/claims/types/ClaimTypes.sol`
