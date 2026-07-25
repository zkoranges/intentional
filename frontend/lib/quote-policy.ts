const BPS = 10_000n;
const YEAR_MS = 365n * 24n * 60n * 60n * 1_000n;

export type QuotePolicy = {
  fundingAprBps: number;
  riskBps: number;
  userEdgeShareBps: number;
  claimGasUnits: number;
};

export type UnderwrittenQuote = {
  reservoirAvailable: boolean;
  reservoirPaymentAmount: bigint | null;
  underwritingCap: bigint;
  fundingCost: bigint;
  riskCost: bigint;
  claimGasCost: bigint;
  userImprovement: bigint;
};

function checkedBps(value: number, name: string) {
  if (!Number.isSafeInteger(value) || value < 0 || value > 10_000) {
    throw new Error(`${name} must be between 0 and 10,000 bps`);
  }
  return BigInt(value);
}

function ceilDiv(numerator: bigint, denominator: bigint) {
  return numerator === 0n ? 0n : (numerator - 1n) / denominator + 1n;
}

export function underwriteLidoExit({
  requestedStEth,
  cowBuyAmount,
  estimatedWaitMs,
  gasPriceWei,
  policy,
}: {
  requestedStEth: bigint;
  cowBuyAmount: bigint;
  estimatedWaitMs: bigint;
  gasPriceWei: bigint;
  policy: QuotePolicy;
}): UnderwrittenQuote {
  if (
    requestedStEth <= 0n ||
    cowBuyAmount <= 0n ||
    estimatedWaitMs < 0n ||
    gasPriceWei <= 0n ||
    !Number.isSafeInteger(policy.claimGasUnits) ||
    policy.claimGasUnits <= 0
  ) {
    throw new Error("invalid live quote inputs");
  }

  const fundingAprBps = checkedBps(
    policy.fundingAprBps,
    "funding APR",
  );
  const riskBps = checkedBps(policy.riskBps, "risk charge");
  const userEdgeShareBps = checkedBps(
    policy.userEdgeShareBps,
    "user edge share",
  );
  const fundingCost = ceilDiv(
    requestedStEth * fundingAprBps * estimatedWaitMs,
    BPS * YEAR_MS,
  );
  const riskCost = ceilDiv(requestedStEth * riskBps, BPS);
  const claimGasCost = gasPriceWei * BigInt(policy.claimGasUnits);
  const totalCost = fundingCost + riskCost + claimGasCost;
  const underwritingCap =
    totalCost < requestedStEth ? requestedStEth - totalCost : 0n;

  if (underwritingCap <= cowBuyAmount) {
    return {
      reservoirAvailable: false,
      reservoirPaymentAmount: null,
      underwritingCap,
      fundingCost,
      riskCost,
      claimGasCost,
      userImprovement: 0n,
    };
  }

  const edge = underwritingCap - cowBuyAmount;
  const userImprovement = (edge * userEdgeShareBps) / BPS;
  const reservoirPaymentAmount = cowBuyAmount + userImprovement;
  return {
    reservoirAvailable: reservoirPaymentAmount > cowBuyAmount,
    reservoirPaymentAmount,
    underwritingCap,
    fundingCost,
    riskCost,
    claimGasCost,
    userImprovement,
  };
}
