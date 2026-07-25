import type { Metadata } from "next";
import Link from "next/link";

import "./docs.css";

export const metadata: Metadata = {
  title: "Documentation — Impatience",
  description:
    "Reservoir protocol documentation: factoring for onchain claims.",
};

const SECTIONS = [
  ["overview", "Overview"],
  ["how-it-works", "How it works"],
  ["factor", "The factor"],
  ["architecture", "Architecture"],
  ["limits", "Limits"],
] as const;

const MONO = "ui-monospace, SFMono-Regular, Menlo, monospace";
const SANS =
  "ui-sans-serif, system-ui, -apple-system, Segoe UI, Helvetica, Arial, sans-serif";

const PARTY_FILL = "rgba(139, 92, 246, 0.07)";
const PARTY_STROKE = "rgba(139, 92, 246, 0.24)";
const BOX_FILL = "#0e0e0f";
const BOX_STROKE = "rgba(255, 255, 255, 0.1)";
const FLOW = "#8b5cf6";
const TITLE_INK = "#e2e2e5";
const MICRO_INK = "#6e6e75";
const LABEL_INK = "#8e8e95";

type NodeProps = {
  x: number;
  y: number;
  w: number;
  h: number;
  title: string;
  sub: string;
  party?: boolean;
  dashed?: boolean;
};

function FlowNode({ x, y, w, h, title, sub, party, dashed }: NodeProps) {
  const cx = x + w / 2;
  const cy = y + h / 2;
  return (
    <g>
      <rect
        x={x}
        y={y}
        width={w}
        height={h}
        rx={11}
        fill={party ? PARTY_FILL : BOX_FILL}
        stroke={party ? PARTY_STROKE : BOX_STROKE}
        strokeDasharray={dashed ? "4 4" : undefined}
      />
      <text
        x={cx}
        y={cy - 3}
        textAnchor="middle"
        fontFamily={MONO}
        fontSize={11}
        fontWeight={600}
        fill={TITLE_INK}
      >
        {title}
      </text>
      <text
        x={cx}
        y={cy + 12}
        textAnchor="middle"
        fontFamily={SANS}
        fontSize={9}
        fontWeight={700}
        letterSpacing="0.09em"
        fill={MICRO_INK}
      >
        {sub.toUpperCase()}
      </text>
    </g>
  );
}

function FlowLabel({
  x,
  y,
  step,
  text,
  note,
}: {
  x: number;
  y: number;
  step: string;
  text: string;
  note: string;
}) {
  return (
    <g>
      <text x={x} y={y} textAnchor="middle" fontFamily={SANS} fontSize={10}>
        <tspan fill={FLOW} fontWeight={700}>
          {step}
        </tspan>
        <tspan fill={LABEL_INK}> {text}</tspan>
      </text>
      <text
        x={x}
        y={y + 26}
        textAnchor="middle"
        fontFamily={SANS}
        fontSize={9}
        fill={MICRO_INK}
      >
        {note}
      </text>
    </g>
  );
}

/**
 * The claim travels right, the money travels left, and the border is the
 * transaction: everything inside it commits together. Exactly one leg leaves
 * that border, because the factor's return is the part that has to wait.
 */
function FundsFlowDiagram() {
  return (
    <figure className="docsFigure">
      <svg
        viewBox="0 0 880 344"
        role="img"
        aria-labelledby="fundsFlowTitle fundsFlowDesc"
        className="docsDiagram"
      >
        <title id="fundsFlowTitle">Funds flow of one Lido factoring settlement</title>
        <desc id="fundsFlowDesc">
          Inside a single transaction: the seller sends stETH to the Lido
          adapter, the adapter sends the measured amount to the Lido withdrawal
          queue, and the queue mints the withdrawal claim directly to the
          factor. In the opposite direction, the Aave StataWETH vault releases
          only the exact shortfall to the funding account, which pays the exact
          WETH amount to the seller. Days later, outside the transaction, the
          queue pays the factor ETH at par.
        </desc>

        <defs>
          <marker
            id="flowArrow"
            viewBox="0 0 10 10"
            refX="9"
            refY="5"
            markerWidth="6"
            markerHeight="6"
            orient="auto-start-reverse"
          >
            <path d="M 0 1 L 9 5 L 0 9 z" fill={FLOW} />
          </marker>
          <marker
            id="waitArrow"
            viewBox="0 0 10 10"
            refX="9"
            refY="5"
            markerWidth="6"
            markerHeight="6"
            orient="auto-start-reverse"
          >
            <path d="M 0 1 L 9 5 L 0 9 z" fill="rgba(139, 92, 246, 0.5)" />
          </marker>
        </defs>

        <text
          x={20}
          y={44}
          fontFamily={SANS}
          fontSize={9}
          fontWeight={750}
          letterSpacing="0.12em"
          fill="#ac91f7"
        >
          ONE TRANSACTION · ALL OF IT OR NONE OF IT
        </text>
        <rect
          x={12}
          y={58}
          width={856}
          height={196}
          rx={18}
          fill="rgba(139, 92, 246, 0.03)"
          stroke="rgba(139, 92, 246, 0.3)"
        />

        <FlowNode x={24} y={84} w={112} h={144} title="Seller" sub="holds stETH" party />
        <FlowNode x={224} y={84} w={152} h={52} title="Lido adapter" sub="measures" />
        <FlowNode x={464} y={84} w={152} h={52} title="Lido queue" sub="canonical" />
        <FlowNode x={704} y={84} w={112} h={144} title="Factor" sub="holds claim" party />
        <FlowNode x={224} y={176} w={152} h={52} title="Funding account" sub="pays" />
        <FlowNode x={464} y={176} w={124} h={52} title="Aave StataWETH" sub="canonical" />

        <g stroke={FLOW} strokeWidth={1.25} markerEnd="url(#flowArrow)" fill="none">
          <path d="M 136 110 H 220" />
          <path d="M 376 110 H 460" />
          <path d="M 616 110 H 700" />
          <path d="M 464 202 H 380" />
          <path d="M 224 202 H 140" />
        </g>

        <FlowLabel x={178} y={101} step="1" text="stETH" note="measured delta" />
        <FlowLabel x={420} y={101} step="2" text="stETH" note="exact measured" />
        <FlowLabel x={660} y={101} step="3" text="unstETH" note="minted to factor" />
        <FlowLabel x={422} y={193} step="4" text="WETH" note="exact shortfall" />
        <FlowLabel x={182} y={193} step="5" text="WETH" note="exact payment" />

        <path
          d="M 602 136 V 300 H 696"
          stroke="rgba(139, 92, 246, 0.5)"
          strokeWidth={1.25}
          strokeDasharray="5 5"
          fill="none"
          markerEnd="url(#waitArrow)"
        />
        <text
          x={584}
          y={272}
          textAnchor="end"
          fontFamily={SANS}
          fontSize={9}
          fill={MICRO_INK}
        >
          <tspan fill={FLOW} fontWeight={700}>
            6
          </tspan>
          <tspan> days later, when the queue finalizes</tspan>
        </text>
        <FlowNode
          x={700}
          y={278}
          w={160}
          h={44}
          title="ETH at par"
          sub="factor collects"
          dashed
        />
      </svg>
      <figcaption>
        The claim moves right, the money moves left, and the outline is the
        transaction. Only the sixth leg happens outside it — that wait is what
        the discount pays for.
      </figcaption>
    </figure>
  );
}

/**
 * The economic argument in one picture: standby capital is the cost of being
 * ready, so the reserve stays deposited and only the exact payment is cut out
 * of it.
 */
function ReserveDiagram() {
  const barX = 210;
  const barW = 460;
  const rows = [
    { y: 40, label: "Before", note: "reserve deposited", w: barW, ann: "idle balance: zero" },
    { y: 108, label: "During", note: "one fill settles", w: barW, ann: "exact amount withdrawn" },
    { y: 176, label: "After", note: "fill complete", w: barW - 80, ann: "remainder keeps earning" },
  ];

  return (
    <figure className="docsFigure">
      <svg
        viewBox="0 0 880 232"
        role="img"
        aria-labelledby="reserveTitle reserveDesc"
        className="docsDiagram"
      >
        <title id="reserveTitle">What a fill takes out of the reserve</title>
        <desc id="reserveDesc">
          Before a fill the whole reserve is deposited in the Aave vault and the
          idle balance is zero. During a fill only the exact payment is
          withdrawn. After a fill the remainder is still deposited and still
          earning.
        </desc>

        {rows.map((row) => (
          <g key={row.label}>
            <text
              x={190}
              y={row.y + 14}
              textAnchor="end"
              fontFamily={SANS}
              fontSize={10}
              fontWeight={750}
              letterSpacing="0.1em"
              fill={TITLE_INK}
            >
              {row.label.toUpperCase()}
            </text>
            <text
              x={190}
              y={row.y + 28}
              textAnchor="end"
              fontFamily={SANS}
              fontSize={9}
              fill={MICRO_INK}
            >
              {row.note}
            </text>
            <rect
              x={barX}
              y={row.y}
              width={row.w}
              height={30}
              rx={7}
              fill="rgba(139, 92, 246, 0.14)"
              stroke="rgba(139, 92, 246, 0.3)"
            />
            <text
              x={690}
              y={row.y + 19}
              fontFamily={SANS}
              fontSize={9}
              fill={MICRO_INK}
            >
              {row.ann}
            </text>
          </g>
        ))}

        <text
          x={barX + 190}
          y={59}
          textAnchor="middle"
          fontFamily={MONO}
          fontSize={10}
          fill="#b9a6f5"
        >
          reserve earning in Aave StataWETH
        </text>

        <rect
          x={barX + barW - 80}
          y={108}
          width={80}
          height={30}
          rx={7}
          fill="rgba(139, 92, 246, 0.55)"
          stroke="rgba(139, 92, 246, 0.75)"
        />
        <text
          x={barX + (barW - 80) / 2}
          y={127}
          textAnchor="middle"
          fontFamily={MONO}
          fontSize={10}
          fill="#b9a6f5"
        >
          still earning
        </text>
        <text
          x={barX + barW - 40}
          y={127}
          textAnchor="middle"
          fontFamily={MONO}
          fontSize={9}
          fill="#f4f4f4"
        >
          payment
        </text>

        <text
          x={barX + (barW - 80) / 2}
          y={195}
          textAnchor="middle"
          fontFamily={MONO}
          fontSize={10}
          fill="#b9a6f5"
        >
          reserve, less the payment
        </text>
      </svg>
      <figcaption>
        The factor is idle on most days. Nothing sits in a wallet waiting: the
        reserve stays deposited, and a fill cuts out the exact payment and
        nothing more.
      </figcaption>
    </figure>
  );
}

export default function DocsPage() {
  return (
    <div className="docsPage">
      <header className="docsHeader">
        <Link className="docsBrand" href="/">
          <strong>
            impatience<span>.</span><em>xyz</em>
          </strong>
          <i />
          <small>Docs</small>
        </Link>
        <div className="docsHeaderActions">
          <a
            href="https://github.com/zkoranges/reservoir-v2-eth-lisbon"
            target="_blank"
            rel="noreferrer"
          >
            GitHub <span aria-hidden="true">↗</span>
          </a>
          <Link className="docsAppLink" href="/">
            Open app
          </Link>
        </div>
      </header>

      <div className="docsLayout">
        <aside className="docsSidebar">
          <p>Reservoir protocol</p>
          <nav aria-label="Documentation">
            {SECTIONS.map(([id, label], index) => (
              <a key={id} href={`#${id}`}>
                <span>{String(index + 1).padStart(2, "0")}</span>
                {label}
              </a>
            ))}
          </nav>
          <div className="docsSidebarNote">
            <i />
            <span>
              Hackathon software
              <small>Unaudited · Live mainnet beta · Recovery pending</small>
            </span>
          </div>
        </aside>

        <main className="docsContent">
          <section id="overview" className="docsHero">
            <p className="docsEyebrow">Reservoir protocol</p>
            <h1>Factoring for onchain claims.</h1>
            <p className="docsLead">
              Sell a future payment. Get paid today.
            </p>

            <div className="docsCallout">
              <span>In one sentence</span>
              <p>
                A factor buys your pending withdrawal claim, pays you now,
                and redeems the claim at full value when it finalizes.
              </p>
            </div>

            <h2>The problem</h2>
            <p>
              Many DeFi positions are claims on future payments: a Lido
              withdrawal request, or an ERC-7540 redemption request waiting
              for the next epoch. While a claim sits in the queue it cannot
              be spent, and it cannot be sold on a normal exchange.
            </p>

            <div className="docsTerminal" aria-label="Factoring example">
              <div>
                <span>You hold</span>
                <code>A claim on 2.6 ETH, arriving in ~5 days</code>
              </div>
              <div>
                <span>You get</span>
                <code>~2.59 ETH, right now</code>
              </div>
              <div>
                <span>The factor</span>
                <code>Waits, then collects the 2.6 ETH</code>
              </div>
            </div>

            <h2>Why this cannot just be a swap</h2>
            <p>
              Uniswap and CoW orders name an ERC-20 <code>sellToken</code>. A
              withdrawal claim is an NFT or an entry in vault storage, so the
              order cannot even be expressed. The person waiting in the queue
              has no market; Reservoir provides one.
            </p>
            <p>
              The production demo factors Lido withdrawals. The settlement
              kernel is claim-agnostic: supporting a new claim type means
              writing an adapter, not changing the kernel. An ERC-7540/8161
              adapter ships alongside the Lido one to demonstrate this.
            </p>

            <blockquote>
              Payment happens if and only if the claim is secured—in the same
              transaction.
            </blockquote>
          </section>

          <section id="how-it-works">
            <p className="docsEyebrow">Flow</p>
            <h2>How it works</h2>
            <p className="docsSectionLead">Four steps, one onchain transaction.</p>

            <ol className="docsSteps">
              <li>
                <span>01</span>
                <div>
                  <strong>Quote</strong>
                  <p>
                    The factor signs an EIP-712 price offer offchain. It has a
                    nonce and deadline and remains valid for at most 15
                    minutes.
                  </p>
                </div>
              </li>
              <li>
                <span>02</span>
                <div>
                  <strong>Accept</strong>
                  <p>
                    The named seller submits the quote. A quote signed for one
                    seller cannot be used by another.
                  </p>
                </div>
              </li>
              <li>
                <span>03</span>
                <div>
                  <strong>Settle atomically</strong>
                  <p>
                    The contract verifies the quote, acquires and measures the
                    claim, withdraws the exact payment, and pays the seller.
                    If one step fails, all of it reverts.
                  </p>
                </div>
              </li>
              <li>
                <span>04</span>
                <div>
                  <strong>Collect</strong>
                  <p>
                    The factor waits for finalization and redeems the claim at
                    full value. The difference is its return.
                  </p>
                </div>
              </li>
            </ol>

            <h3>Where the tokens actually go</h3>
            <FundsFlowDiagram />

            <h3>Two kinds of claim</h3>
            <div className="docsCardGrid">
              <article>
                <span className="docsTag">Originate</span>
                <h4>The claim does not exist yet</h4>
                <p>
                  The seller holds stETH and wants ETH now. During settlement,
                  the adapter creates a new Lido withdrawal ticket owned by
                  the factor while WETH is paid to the seller.
                </p>
                <pre>{`seller stETH
    ↓
new Lido withdrawal ticket → factor
WETH payment               → seller`}</pre>
              </article>
              <article>
                <span className="docsTag">Acquire</span>
                <h4>The claim already exists</h4>
                <p>
                  An ERC-7540 request can be partly Pending and partly
                  Claimable. The adapter transfers the Pending portion using
                  ERC-8161 and redeems the Claimable portion to the factor
                  before payment is allowed.
                </p>
                <pre>{`pending portion   → transferred
claimable portion → redeemed
complete value    → measured`}</pre>
              </article>
            </div>

            <h3>Where the factor&apos;s money comes from</h3>
            <p>
              The factor&apos;s WETH is not left idle in a wallet. It lives in
              an Aave ERC-4626 vault, earning yield, and is withdrawn just in
              time inside the settlement transaction. Before a fill, idle
              balance can be zero. After a fill, only the exact payment has
              left and the remainder keeps earning.
            </p>
            <ReserveDiagram />
          </section>

          <section id="factor">
            <p className="docsEyebrow">Market participant</p>
            <h2>The factor</h2>
            <p className="docsSectionLead">
              The buyer with money now, willing to wait, charging for the
              wait.
            </p>

            <div className="docsNumberGrid">
              <div>
                <span>01</span>
                <strong>Holds capital</strong>
                <p>WETH in a productive funding account.</p>
              </div>
              <div>
                <span>02</span>
                <strong>Quotes prices</strong>
                <p>Signs offers offchain using its own risk policy.</p>
              </div>
              <div>
                <span>03</span>
                <strong>Stays offline</strong>
                <p>The seller sends the transaction, not the factor.</p>
              </div>
              <div>
                <span>04</span>
                <strong>Collects later</strong>
                <p>Redeems the claim when the queue finalizes.</p>
              </div>
            </div>

            <h3>Example pricing</h3>
            <div className="docsPrice">
              <div>
                <span>Funding cost</span>
                <small>10% APR × 5 days</small>
                <strong>≈ 0.0018 ETH</strong>
              </div>
              <div>
                <span>Risk margin</span>
                <small>0.15%</small>
                <strong>≈ 0.0039 ETH</strong>
              </div>
              <div>
                <span>Collection gas</span>
                <small>Estimated</small>
                <strong>≈ 0.003 ETH</strong>
              </div>
              <div className="total">
                <span>Offer now</span>
                <small>Claim value: 2.60 ETH</small>
                <strong>~2.59 ETH</strong>
              </div>
            </div>
            <p>
              The discount pays for duration, impairment, protocol risk,
              opportunity cost, and operations. All of these risks transfer
              from the seller to the factor.
            </p>

            <h3>Why productive reserves matter</h3>
            <p>
              In sampled settlement data, opportunities appeared on 15 out
              of 87 active days; the factor was idle roughly{" "}
              <strong>83% of the time</strong>. Keeping the reserve in an
              ERC-4626 vault means the same capital earns lending yield on
              idle days and the factoring spread when a deal appears.
              Without that yield, holding standby capital would rarely be
              worth it.
            </p>
          </section>

          <section id="architecture">
            <p className="docsEyebrow">Contracts</p>
            <h2>Architecture</h2>
            <p className="docsSectionLead">Four contracts, one invariant.</p>

            <div className="docsArchitecture" aria-label="Protocol architecture">
              <div className="architectureKernel">
                <small>Settlement kernel</small>
                <strong>AsyncClaimSettlement</strong>
                <span>Payment iff acquisition</span>
              </div>
              <i />
              <div className="architectureBranches">
                <article>
                  <small>Capital</small>
                  <strong>ProductiveFundingAccount</strong>
                  <span>ERC-4626 vault · Aave WETH</span>
                </article>
                <article>
                  <small>Claim</small>
                  <strong>Protocol adapter</strong>
                  <span>Lido · ERC-7540 / ERC-8161</span>
                </article>
              </div>
            </div>

            <h3>The kernel</h3>
            <p>
              <code>AsyncClaimSettlement</code> knows nothing about Lido,
              Aave, or a specific vault. It enforces a valid chain-bound
              signature, seller-only execution, fresh nonces and deadlines,
              exact funding, measurable claim acquisition before payment, and
              one settlement per quote.
            </p>

            <h3>The funding account</h3>
            <p>
              <code>ProductiveFundingAccount</code> materializes the exact
              payment from an ERC-4626 vault. If delivery is uncertain—the
              vault reverts, capacity is short, or the account is paused—it
              reports zero and settlement never starts.
            </p>

            <h3>The adapters</h3>
            <div className="docsTableWrap">
              <table>
                <thead>
                  <tr>
                    <th>Adapter</th>
                    <th>Claim</th>
                    <th>Action</th>
                  </tr>
                </thead>
                <tbody>
                  <tr>
                    <td>LidoWithdrawalClaimAdapter</td>
                    <td>Lido withdrawal ticket</td>
                    <td>Creates a new request owned by the factor</td>
                  </tr>
                  <tr>
                    <td>ERC8161RedeemClaimAdapter</td>
                    <td>ERC-7540 redemption request</td>
                    <td>
                      Transfers Pending and redeems Claimable portions
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p>
              Adapters confirm acquisition by measuring balances before and
              after; they do not trust return values.
            </p>

            <h3>Where 1inch Aqua and SwapVM fit</h3>
            <p>
              Reservoir ships a working Aqua / SwapVM strategy: a custom VM
              instruction (<code>0x92</code>) clamps swap output to what the
              maker&apos;s ERC-4626 reserve can currently deliver, proven
              against production Aqua contracts on a mainnet fork. A
              factoring fill does not execute through SwapVM; it reuses the
              reserve engine built for that strategy to hold the
              factor&apos;s WETH in an Aave vault and withdraw the exact
              payment inside the fill.
            </p>
            <p>
              The split is structural. A claim is not an ERC-20 and cannot
              be named in a SwapVM order, so claim settlement needs the
              kernel and its adapters. Aqua fits on the factor side:
              competing factors are makers whose capital must earn between
              fills, which is what the reserve engine provides.
            </p>

            <div className="docsMetric">
              <strong>187</strong>
              <span>
                deterministic tests passing
                <small>Unit · integration · invariant — plus 10 mainnet-fork suites</small>
              </span>
            </div>
          </section>

          <section id="limits">
            <p className="docsEyebrow">Scope</p>
            <h2>Limits</h2>
            <p className="docsSectionLead">
              Measured performance, unbuilt features, and where risk sits.
            </p>

            <h3>For liquid assets, use an exchange</h3>
            <p>
              Across a year of settlement data—308,160 CoW settlements, 568
              comparable stETH→ETH executions, and 42,074 Lido requests—
              factoring beat the open market on{" "}
              <strong>4.6% of trades and 5.3% of volume</strong>.
            </p>
            <p>
              Factoring applies when there is no liquid token market: a
              non-transferable claim, a position too large to sell without
              slippage, or a stressed market where the queue still pays par.
            </p>

            <h3>What is not built</h3>
            <ul className="docsLimitList">
              <li>
                <strong>No competing factors yet.</strong>
                <span>
                  One factor, one funding account, one payment asset.
                </span>
              </li>
              <li>
                <strong>No secondary market.</strong>
                <span>The factor holds each purchased claim to maturity.</span>
              </li>
              <li>
                <strong>No production ERC-8161 vault.</strong>
                <span>
                  The reference path is conformant; the Lido path runs
                  against mainnet contracts.
                </span>
              </li>
              <li>
                <strong>Request ID zero is rejected.</strong>
                <span>
                  Ambiguous aggregate requests are refused rather than guessed.
                </span>
              </li>
            </ul>

            <h3>Risk remains with the factor</h3>
            <p>
              The queue may take longer than modelled, the claim may settle
              below face value, withdrawals may pause, and capital may remain
              locked. There is no oracle, insurance, or pooled backstop. Each
              claim stands alone, so one impaired position cannot reach
              another.
            </p>

            <div className="docsWarning">
              <span>Deployment status</span>
              <p>
                This is unaudited hackathon software. Contracts deploy paused
                and unfunded; funding and activation are separate, deliberate
                steps with read-only verification between each.
              </p>
            </div>
          </section>

          <footer className="docsFooter">
            <div>
              <strong>Future value, liquid today.</strong>
              <span>Powered by Reservoir.</span>
            </div>
            <Link href="/">Open Impatience</Link>
          </footer>
        </main>
      </div>
    </div>
  );
}
