"use client";

import { eth, LIFECYCLE } from "../lib/format";
import { drawOdds, useQuote, usePool } from "../lib/pool";
import { Eth, Stat, percent, shares } from "./Measure";

/** The pool's headline numbers: ordinary NAV, the one-pull ticket against its average redeemable
 *  value, the board and the lifecycle. */
export function VaultStats() {
  const pool = usePool().data;
  const quote = useQuote(1).data;
  if (!pool) return null;
  const odds = drawOdds(pool.board, pool.grail);
  const p = pool.params;
  const returnBps = quote && quote.fee > 0n ? (odds.averageBackingWei * 10_000n) / quote.fee : undefined;
  return (
    <div className="stat-grid">
      <Stat
        label="Ordinary NAV"
        value={<Eth wei={pool.nav} digits={2} />}
        sub={`Share price ${eth(pool.sharePrice, 6)} ETH, ${shares(pool.totalShares, 2)} shares`}
      />
      <Stat
        label="Ticket per pull"
        value={quote ? <Eth wei={quote.fee} digits={5} /> : "-"}
        sub={
          returnBps === undefined
            ? undefined
            : `Average redeemable value ${percent(returnBps)} of the ticket, VRF and gas excluded`
        }
      />
      <Stat
        label="Listed items"
        value={pool.listedCount.toLocaleString("en-US")}
        sub={`${pool.heldCount.toLocaleString("en-US")} held, ${eth(odds.listedBackingWei, 2)} ETH listed backing`}
      />
      <Stat
        label="Lifecycle"
        value={LIFECYCLE[p.lifecycle]}
        sub={`Pulls ${p.pullsPaused ? "paused" : "on"}, deposits ${p.depositsPaused ? "paused" : "on"}`}
      />
    </div>
  );
}
