# How it works

Four steps. One transaction.

```
1. QUOTE     Factor signs a price offer, offline.
2. ACCEPT    Seller submits it. Only the seller can.
3. SETTLE    Claim → factor.  Payment → seller.  Atomically.
4. COLLECT   Factor waits out the queue, redeems at full value.
```

## Step by step

### 1. The factor quotes

The factor signs an EIP-712 offer off-chain: *"I will pay 2.59 WETH for this claim."*

It carries a **nonce** and a **deadline**, and it is valid for at most **15 minutes**. Nothing is on-chain yet. The factor's key never touches a website.

### 2. The seller accepts

The seller submits the signed quote to the settlement contract. This is the only transaction in the flow, and **only the named seller can send it** — a quote signed for Bob cannot be used by anyone else.

### 3. Settlement

Inside that single transaction:

| | |
|---|---|
| **a.** | Check the signature, nonce, deadline, and that the payment is fully funded |
| **b.** | Acquire the claim for the factor — and **measure that it actually arrived** |
| **c.** | Pull the exact payment out of the yield vault |
| **d.** | Pay the seller the exact amount |

If any step fails, **all of it reverts.** No half-settled state exists.

### 4. The factor collects

Days later, the queue finalizes and the factor redeems the claim for its full value. The difference is the factor's return.

## Two kinds of claim

Reservoir ships two adapters, because claims come in two shapes.

### Originate — the claim doesn't exist yet

The seller holds stETH. They want ETH now, not in two weeks.

```
seller's stETH  →  a NEW Lido withdrawal ticket, minted to the factor
                →  WETH paid to the seller, same transaction
```

The ticket is **created during settlement**. This is something a swap cannot do: you cannot trade an object that doesn't exist yet.

### Acquire — the claim already exists

The seller already has an ERC-7540 redemption request pending in a vault. They want out early.

The tricky part: a request can be **partly ready and partly still waiting** at the same time. So the adapter does both legs at once:

- transfers the still-**Pending** portion to the factor ([ERC-8161](https://ercs.ethereum.org/ERCS/erc-8161))
- redeems the already-**Claimable** portion to the factor

and only then allows payment. Handling one but not the other would silently lose value — so it is never an either/or.

## Where the factor's money comes from

Not a wallet sitting idle.

The factor's WETH lives in an **Aave ERC-4626 vault**, earning yield. It is withdrawn **just in time**, inside the settlement transaction, at the moment a deal is struck.

Before a fill: idle balance is **zero**, everything is in vault shares.
After a fill: the exact payment left, and the rest is still earning.

---

**Next:** [The factor →](factor.md)
