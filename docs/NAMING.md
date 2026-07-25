# Naming: Intentional and Reservoir

Two names, on purpose.

**Intentional** is the product. It is what a visitor sees, what the domain says,
and the voice everything user-facing is written in.

**Reservoir** is the protocol — the settlement kernel, its adapters, and the
funding account. It is a technical term. It belongs in code, in contract and
protocol documentation, in wire formats, and in attribution.

Neither name is a rename of the other. A person selling a withdrawal claim is
using Intentional; the thing that settles it is Reservoir. Keeping them separate
lets the app be marketed freely while the protocol keeps a neutral identity that
another front end could build on — the same shape as the SwapVM and Aqua
attribution this repository already carries.

## The rule

| Surface | Name | Why |
|---|---|---|
| Page titles, meta descriptions, social cards | **Intentional** | This is the product a visitor found |
| Headings, body copy, button labels | **Intentional** | Product voice |
| Status messages and errors shown in the app | **neither, by default** | Errors should name what the person controls, not the system underneath |
| Public footer | **Intentional** | Product identity only; technical attribution lives in protocol documentation |
| Protocol documentation (`/docs`) | **Reservoir** | It genuinely documents the protocol |
| Contracts, specs, threat model, this repository | **Reservoir** | Technical register throughout |
| Code identifiers, env vars, API enums, wire formats | **Reservoir** | Internal; renaming buys nothing and breaks things |

The rule for user-facing failure text is worth stating on its own, because it is
the one most easily broken: **a person who hits an error should not have to learn
a second product name to understand it.** "Firm quotes are disabled while Lido
bunker mode is active" tells them what happened. Naming the settlement engine in
that sentence adds nothing they can act on.

## Frozen — never rebrand these

Some Reservoir strings are load-bearing. Changing them is not a rename; it is a
breaking change.

| String | Where | What breaks if changed |
|---|---|---|
| `"Reservoir v2"` | EIP-712 domain name, in [`lib/ethereum.ts`](../frontend/lib/ethereum.ts), [`scripts/create-lido-quote.mjs`](../frontend/scripts/create-lido-quote.mjs), [`services/quote-signer/server.mjs`](../services/quote-signer/server.mjs), and `EIP712("Reservoir v2", "1")` in [`AsyncClaimSettlement`](../src/claims/AsyncClaimSettlement.sol) | **Every factor signature.** The domain separator is hashed into the quote digest. A rename makes a signer compute a different digest than the deployed kernel verifies, and every fill reverts with `InvalidFactorSignature` |
| `"reservoir-v2-lido-1"` | Quote envelope `version`, in the same three places | The operator CLI, the quote desk, the browser parser, and the archived envelope in [`deployments/`](../deployments/) stop agreeing |

There are now **three signers** — the browser-side verifier, the operator CLI,
and the quote-desk service — and one on-chain verifier. Every one of them has to
spell the domain identically. Add a fourth and it goes in the test below too.
| `NEXT_PUBLIC_RESERVOIR_KERNEL`, `NEXT_PUBLIC_RESERVOIR_LIDO_ADAPTER` | Build-pinned env vars | Vercel and CI configuration, and the pinned-build check |
| `zkoranges/intentional` | Public repository identity | Website, documentation, CI and ETHGlobal submission links |

The EIP-712 domain is the dangerous one. It reads like display text and is not.

## What the scan found

The split is enforced in source and rendered-output tests. Marketing metadata in
[`app/layout.tsx`](../frontend/app/layout.tsx) is Intentional throughout, the
wordmark is Intentional, and in-app copy that addresses the user by name already
says things like "Intentional verifies its amount, signature, contracts, expiry".

Technical pages may name Reservoir when they explain the settlement protocol.
The public app and its footer use the Intentional product identity.

### What violated the rule

Four thrown `Error` messages in `lib/ethereum.ts` named the protocol in text
that reaches the user. `errorMessage()` in `app/page.tsx` passes `error.message`
straight into the status line, so these were product copy without being written
like it:

| Was | Now |
|---|---|
| "Reservoir fills are disabled until the reviewed deployment is pinned" | "Firm quotes are disabled until the reviewed deployment is pinned" |
| "The quote does not use the reviewed Reservoir deployment" | "This quote does not use the reviewed deployment" |
| "Reservoir firm quotes are disabled while Lido bunker mode is active" | "Firm quotes are disabled while Lido bunker mode is active" |
| "The Reservoir transaction mined but reverted" | "The settlement transaction mined but reverted" |

Each drops the name rather than swapping in "Intentional", because naming either
system tells the reader nothing they can act on.

## Enforcement

[`frontend/tests/naming.test.mjs`](../frontend/tests/naming.test.mjs) runs with
`npm test` and holds the line in both directions: it fails if the frozen strings
drift, and it fails if the protocol name reappears in marketing metadata or in
user-facing failure text. A test rather than a convention, because this is the
kind of rule that erodes quietly.
