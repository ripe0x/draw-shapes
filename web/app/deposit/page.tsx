"use client";

import Link from "next/link";
import { eth } from "../lib/format";
import { usePool } from "../lib/pool";
import { ClaimsQueue } from "../components/ClaimsQueue";
import { DepositCardFan } from "../components/DepositCardFan";
import { DepositForm, entryBps } from "../components/DepositForm";
import { Disclosures } from "../components/Disclosures";
import { Eth, percent } from "../components/Measure";
import { PositionsList } from "../components/PositionsList";
import { WithdrawForm } from "../components/WithdrawForm";
import "./deposit.css";

/** `/deposit`: entry, position, withdrawal and the claims queue of the pool. */
export default function DepositPage() {
  const pool = usePool().data;
  const listed = pool?.board.reduce((sum, r) => sum + r.listed, 0n);
  const listedBacking = pool?.board.reduce((sum, r) => sum + r.listed * r.backingWei, 0n);

  return (
    <main className="deposit-page">
      <section className="deposit-hero">
        <div className="deposit-hero-copy">
          {pool?.params.lifecycle === 0 && <p className="deposit-eyebrow">Opening: pulls start when the pool opens</p>}
          <h1>Fund the board.</h1>
          <p>Deposit ETH into the pool that funds the board. Depositors hold shares that redeem at ordinary NAV.</p>
        </div>
        <div className="deposit-hero-visual">
          <DepositCardFan />
          <p>Every listed item carries ETH that its holder can redeem at face.</p>
          <Link href="/protocol">How the pool works →</Link>
        </div>
      </section>

      <section className="deposit-main-grid">
        <DepositForm />
        <aside className="deposit-side">
          <div className="deposit-pool-stats" aria-label="Pool statistics">
            <div>
              <span>Ordinary NAV</span>
              <strong>{pool ? <Eth wei={pool.nav} digits={2} /> : "-"}</strong>
              <small>{pool ? `Share price ${eth(pool.sharePrice, 6)} ETH` : "-"}</small>
            </div>
            <div>
              <span>Listed items</span>
              <strong>{listed === undefined ? "-" : listed.toLocaleString("en-US")}</strong>
              <small>{listedBacking === undefined ? "-" : <Eth wei={listedBacking} digits={2} />} redeemable backing</small>
            </div>
            <div>
              <span>Entry contribution now</span>
              <strong>{pool ? percent(entryBps(pool.params, pool.nav), 2) : "-"}</strong>
              <small>of each deposit, goes to the GRAIL buckets</small>
            </div>
          </div>
          <PositionsList />
        </aside>
      </section>

      <details className="deposit-risk">
        <summary>
          Before you deposit <span>Risks and controls</span>
        </summary>
        <div>
          <Disclosures />
        </div>
      </details>

      <section className="deposit-withdraw" id="withdraw">
        <div className="deposit-section-intro">
          <p className="deposit-eyebrow">Withdraw</p>
          <h2>Take capital out.</h2>
          <p>Withdrawing burns shares for a claim at ordinary NAV.</p>
        </div>
        <div>
          <WithdrawForm />
          <ClaimsQueue />
        </div>
      </section>
    </main>
  );
}
