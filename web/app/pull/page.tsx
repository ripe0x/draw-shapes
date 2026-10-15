"use client";

import { useState } from "react";
import { OddsGlance } from "../components/OddsGlance";
import { PayWithShapes } from "../components/PayWithShapes";
import { PullCard } from "../components/PullCard";
import { Pulls } from "../components/Pulls";
import { PullTicket } from "../components/PullTicket";

/** `/pull`: the pull card with batch size and price, pay with Shapes, the price breakdown, what a pull
 *  can draw, and the wallet's pulls with their reveal. */
export default function PullPage() {
  const [count, setCount] = useState(1);
  return (
    <main className="vault-page">
      <section className="vault-hero">
        <h1 className="vault-headline">Pull</h1>
        <p className="vault-lede">
          One pull buys one listing from the board at FWA&apos;s ticket. FWA picks it with verifiable randomness, each listing weighted by the
          inverse of its list price, and delivers it to your wallet.
        </p>
      </section>
      <section className="vault-section two-col">
        <div>
          <div className="card">
            <h3 className="vault-h2">Pull</h3>
            <PullCard variant="panel" count={count} onCount={setCount} />
          </div>
          <PayWithShapes count={count} />
        </div>
        <div>
          <PullTicket count={count} />
          <OddsGlance />
        </div>
      </section>
      <Pulls />
    </main>
  );
}
