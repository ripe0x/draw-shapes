"use client";

import Link from "next/link";
import { drawOdds, usePool } from "./lib/pool";
import { eth } from "./lib/format";
import { CardFan } from "./components/CardFan";
import { GrailBoard } from "./components/GrailBoard";
import { HeadlinePrize } from "./components/HeadlinePrize";
import { OddsGlance } from "./components/OddsGlance";
import { PoolGrid } from "./components/PoolGrid";
import { PullCard } from "./components/PullCard";

/** `/`: the pull promise and live board summary, the card carousel, the pull card, the listed items
 *  grid beside the GRAIL, what a pull can draw and the deposit band. */
export default function Landing() {
  const pool = usePool().data;
  const odds = pool ? drawOdds(pool.board, pool.grail) : undefined;
  const smallestWei = odds?.rows[0]?.backingWei;

  return (
    <main className="landing-page">
      <section className="landing-hero" id="pull">
        <h1 className="landing-hero-promise">
          Draw a card.
          <br />
          Redeem for ETH.
        </h1>
        {odds && (
          <p className="landing-hero-pool-summary">
            <strong>{eth(odds.listedBackingWei)} ETH</strong> of backing listed across{" "}
            <strong>{odds.listedItems.toLocaleString("en-US")} Shapes and Draw Packs</strong>. Largest: <strong>{eth(odds.largestWei)} ETH</strong>.
          </p>
        )}
        <CardFan />
        <PullCard variant="hero" />
      </section>

      <HeadlinePrize />

      <div className="landing-facts">
        <div className="landing-fact">
          <div className="landing-fact-title">Every pull draws a Shape or a Draw Pack</div>
          <div className="landing-fact-sub">
            Each one redeems at Shapes for its ETH backing at face.
            {smallestWei !== undefined && ` The smallest listed holds ${eth(smallestWei)} ETH.`}
          </div>
        </div>
        <div className="landing-fact">
          <div className="landing-fact-title">The GRAIL builds on the board</div>
          <div className="landing-fact-sub">1 ETH pieces list as they mint and merge up to the target. Each list price drops a little with every pull.</div>
        </div>
        <div className="landing-fact">
          <div className="landing-fact-title">Built on FWA custom pools</div>
          <div className="landing-fact-sub">
            <a href="https://www.fwa.fun/" target="_blank" rel="noreferrer">
              FWA
            </a>{" "}
            selects each item with verifiable randomness and delivers it to your wallet.
          </div>
        </div>
      </div>

      <div className="landing-pool-layout">
        <PoolGrid />
        <div className="landing-grail-col">
          <GrailBoard />
        </div>
      </div>

      <div className="landing-odds-row">
        <OddsGlance />
      </div>

      <div className="landing-supply-band">
        <div>
          <div className="landing-supply-title">Fund the engine</div>
          <div className="landing-supply-sub">
            Founders fund a conditional escrow that becomes the game&apos;s opening bankroll. They are credited up to a capped
            share of coin-trading receipts and game earnings, never guaranteed. Public deposits are closed.
          </div>
        </div>
        <Link className="landing-supply-link" href="/fund">
          Fund the engine
        </Link>
      </div>

      <div className="landing-how-it-works">
        <p>
          The pool mints Shapes and Draw Packs and lists them on its FWA pool. A pull pays FWA&apos;s ticket, and the pool lists a replacement
          for every item drawn. <Link href="/protocol">How the pool works</Link>
        </p>
      </div>
    </main>
  );
}
