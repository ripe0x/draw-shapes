"use client";

import { eth, pct } from "../lib/format";
import { usePool } from "../lib/pool";
import { useDeployment } from "../Providers";
import { GrailBoard } from "./GrailBoard";
import { Eth, Kv, shares } from "./Measure";
import { OddsGlance } from "./OddsGlance";
import { ParamsDisclosure } from "./ParamsDisclosure";
import { Upkeep } from "./Upkeep";
import { VaultStats } from "./VaultStats";

const FAQS = [
  {
    question: "What happens when someone pulls?",
    answer:
      "The pool forwards the purchase to FWA after its reopen guards pass. FWA selects one listing by weight 1e36 divided by list price, using VRF randomness, and sends it to the purchaser. A later settle books the capture, splits the margin and queues a replacement row sampled from the mix.",
  },
  {
    question: "Where does a ticket go?",
    answer:
      "FWA pays the pool owner paid - (paid - base) / 2 per acquisition, where base is the lower of the fee and the harmonic mean of list prices at request time. The margin over the captured item's backing first repays the replacement mint fee. The rest divides premium : maintenance : feed by their bps. The premium share stays in ordinary NAV. The maintenance and feed shares become receivables of their own buckets. The quote lists FWA's fee and the VRF fee separately.",
  },
  {
    question: "Why can a pull be refunded?",
    answer:
      "FWA credits slippage, timeout and failed delivery to the purchaser. The purchaser claims the credit at the FWA pool. The VRF fee is spent when the request is made.",
  },
  {
    question: "How do deposits and withdrawals work?",
    answer:
      "The entry contribution funds the GRAIL. It is the depositor premium times the daily fee volume over NAV, for the payback days, kept between the floor and the cap. The rest of a deposit mints shares at ordinary NAV per share. Deposits are admitted while ordinary NAV is below the NAV cap, which is the larger of the floor and the daily fee volume divided by the turnover. Daily fee volume is the mean over the last seven complete UTC days. Deposits open after the founder window that follows the pool opening. A withdrawal burns shares and pays shares * NAV / total shares: the part cash covers is paid at once and the remainder joins a FIFO claim queue. Anyone can call payClaims, and rotate redeems items for the head claim once it is a rotate interval old. Shares are nontransferable.",
  },
  {
    question: "How does the GRAIL build?",
    answer:
      "One fund, fed by the entry contribution, the feed share of every settled ticket and fundGrail. Rotate mints 1 ETH pieces from the fund and lists each at face, then merges listed pieces by fixed recipes: five ones make a 5, two fives a 10, two tens and a five the 25, two 25s a 50, two 50s a 100. The target is one of those sizes and the admin sets the next cycle's target. Every listed GRAIL item drops in price by a fixed amount per pull down to its floor, 0.25 ETH for a piece and 1 ETH otherwise, and the decay stops while the listed GRAIL weight would pass the probability cap. A captured item pays its proceeds to the fund and the cycle carries on.",
  },
  {
    question: "Who pays for upkeep?",
    answer:
      "Settle and rotate refund the caller min(maintenance, (gas used + 30,000) * basefee + tip) from the maintenance bucket. The maintenance share of each margin refills it.",
  },
  {
    question: "What can the admin change?",
    answer:
      "One admin address pauses pulls and deposits and sets the parameters listed above, each within a bound: the premium, maintenance and feed rates sum to at most 1,000 bps, the entry fee cap is at most 10,000 bps and the tip is at most 0.01 ETH. Setters take effect immediately. The admin also creates the FWA pool, calls adminCall, which checks the book invariants afterward, and starts an exit.",
  },
  {
    question: "What does an exit do?",
    answer:
      "Starting an exit closes pulls, deposits, rotation and GRAIL growth. Anyone then runs exportStep until every listing is withdrawn. On retirement each ordinary item is redeemed into cash and holders withdraw against it. On migration items move to the successor pool while cash covers claims, and each holder mints successor shares with migrateHolder.",
  },
] as const;

/** Board rows as a table: made of, share, backing per item, list price, item counts and target depth. */
function BoardTable() {
  const pool = usePool().data;
  if (!pool) return null;
  return (
    <div className="card">
      <h3 className="vault-h2">Board</h3>
      <div className="table-scroll">
        <table className="odds-table">
          <thead>
            <tr>
              <th>Row</th>
              <th>Made of</th>
              <th>Share</th>
              <th>Backing per item</th>
              <th>List price</th>
              <th>Items</th>
              <th>Listed</th>
              <th>Target</th>
            </tr>
          </thead>
          <tbody>
            {pool.board.map((r, i) => (
              <tr key={i}>
                <td>{i}</td>
                <td>{r.rungs.length > 1 ? `Draw Pack of ${r.rungs.length} Shapes` : "1 Shape"}</td>
                <td>{pct(r.shareBps)}</td>
                <td>{eth(r.backingWei)} ETH</td>
                <td>{eth(r.listingPrice, 5)} ETH</td>
                <td>{r.count.toLocaleString("en-US")}</td>
                <td>{r.listed.toLocaleString("en-US")}</td>
                <td>{r.target.toLocaleString("en-US")}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="vault-note">
        Items counts listed, held and queued replacements of a row. Backing is the redeemable value of one item at Shapes, at face.
      </p>
    </div>
  );
}

/** Ordinary buckets that make NAV, then the buckets outside it. */
function Buckets() {
  const pool = usePool().data;
  if (!pool) return null;
  return (
    <div className="card">
      <Kv label="Cash" value={<Eth wei={pool.cash} digits={4} />} />
      <Kv label="Backing" value={<Eth wei={pool.backing} digits={4} />} />
      <Kv label="Receivable" value={<Eth wei={pool.receivable} digits={4} />} />
      <Kv label="Claims" value={<>{pool.claims > 0n ? "-" : ""}{eth(pool.claims, 4)} ETH</>} />
      <Kv label="Ordinary NAV" value={<Eth wei={pool.nav} digits={4} />} strong />
      <Kv label="Share price" value={`${eth(pool.sharePrice, 6)} ETH, ${shares(pool.totalShares)} shares`} />
      <Kv
        label="Maintenance"
        value={`${eth(pool.maintenance, 4)} ETH, receivable ${eth(pool.maintenanceReceivable, 4)} ETH`}
      />
      <Kv label="GRAIL fund" value={<Eth wei={pool.grail.fund} digits={4} />} />
      <p className="vault-note">
        Ordinary NAV = cash + backing + receivable - claims, with backing counted at face. The GRAIL fund, the GRAIL items and maintenance
        sit outside ordinary NAV.
      </p>
    </div>
  );
}

function Section({ n, title, lead, children }: { n: string; title: string; lead: string; children: React.ReactNode }) {
  return (
    <section className="protocol-section">
      <div className="protocol-section-head">
        <span>{n}</span>
        <div>
          <h2>{title}</h2>
          <p>{lead}</p>
        </div>
      </div>
      {children}
    </section>
  );
}

/** `/protocol`: live pool state, the pull path, board, GRAIL, buckets, upkeep, control and FAQ. */
export function ProtocolPage() {
  const dep = useDeployment();
  const grailCapBps = usePool().data?.params.grailProbCapBps;

  return (
    <main className="protocol-page">
      <header className="protocol-hero">
        <h1>Protocol</h1>
        <p>Live pool state, the path of a pull, the board and the GRAIL, the buckets behind NAV, upkeep and admin control.</p>
      </header>

      {!dep.present && (
        <p className="vault-note">This build has no pool deployment configured, so the live sections stay empty.</p>
      )}

      <Section n="01" title="Live state" lead="Current values read from the pool and its Lens.">
        <VaultStats />
      </Section>

      <Section
        n="02"
        title="One pull, end to end"
        lead="The ticket, the purchase at FWA and the replacement that follows."
      >
        <div className="protocol-flow">
          <article>
            <strong>Quote</strong>
            <p>The Lens quotes FWA&apos;s fee and the VRF fee for the pull count.</p>
          </article>
          <article>
            <strong>Acquire</strong>
            <p>The pool forwards the purchase to FWA after its reopen guards pass.</p>
          </article>
          <article>
            <strong>Deliver</strong>
            <p>
              FWA selects one listing by weight 1e36 / list price, using VRF randomness, and sends it to the purchaser.
            </p>
          </article>
          <article>
            <strong>Settle</strong>
            <p>Settle books the capture, splits the margin and queues a replacement row sampled from the mix.</p>
          </article>
        </div>
        <div className="protocol-data-grid">
          <OddsGlance />
          <BoardTable />
        </div>
      </Section>

      <Section
        n="03"
        title="GRAIL"
        lead="Two prize packs, Minor and Major, funded from their own buckets."
      >
        <div className="protocol-data-grid">
          <GrailBoard detail />
        </div>
        <p className="vault-note">
          Each track grows by its step while its bucket covers the step and the mint fees, up to its target. The list price
          drops by the decay amount per pull down to the floor. When the listed GRAIL weight exceeds the probability cap
          {grailCapBps === undefined ? "" : ` of ${pct(grailCapBps)}`}, settle lifts the price to the smallest value that restores the cap.
        </p>
      </Section>

      <Section
        n="04"
        title="Buckets and NAV"
        lead="Every wei the pool holds is in one bucket. Depositors own ordinary NAV."
      >
        <Buckets />
      </Section>

      <Section
        n="05"
        title="Upkeep"
        lead="Settle books captures and lists replacements. Rotate pays claims, mints and merges GRAIL pieces and lists held items."
      >
        <Upkeep />
      </Section>

      <Section
        n="06"
        title="Capital and control"
        lead="What belongs to depositors, what gameplay funds and what the admin holds."
      >
        <div className="protocol-principles">
          <article>
            <strong>Depositor NAV</strong>
            <p>Depositors hold shares of ordinary NAV and exit at NAV per share in ETH.</p>
          </article>
          <article>
            <strong>Separate buckets</strong>
            <p>The GRAIL fund, GRAIL backing and maintenance are accounted apart from ordinary NAV.</p>
          </article>
          <article>
            <strong>One admin</strong>
            <p>One admin address sets bounded parameters, pauses pulls and deposits, and can start an exit.</p>
          </article>
        </div>
        <div className="card protocol-params">
          <h3 className="vault-h2">Current operating parameters</h3>
          <ParamsDisclosure />
        </div>
      </Section>

      <section className="protocol-section protocol-faq">
        <div className="protocol-section-head">
          <span>07</span>
          <div>
            <h2>Questions</h2>
          </div>
        </div>
        <div className="protocol-faq-list">
          {FAQS.map((item) => (
            <details key={item.question}>
              <summary>
                {item.question}
                <span>+</span>
              </summary>
              <p>{item.answer}</p>
            </details>
          ))}
        </div>
      </section>
    </main>
  );
}
