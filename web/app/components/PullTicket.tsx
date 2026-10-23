"use client";

import { drawOdds, sendValue, useQuote, usePool } from "../lib/pool";
import { Eth, Kv, percent } from "./Measure";

/** The ticket at the selected batch size, how it compares with the average redeemable value of a
 *  draw, and the list price markups the margin pays from. */
export function PullTicket({ count }: { count: number }) {
  const q = useQuote(count).data;
  const pool = usePool().data;
  if (!q || !pool) return null;
  const odds = drawOdds(pool.board, pool.grail);
  const atLeastTicketBps = odds.rows.filter((r) => r.backingWei >= q.fee).reduce((sum, r) => sum + r.chanceBps, 0n);
  const returnBps = q.fee > 0n ? (odds.averageBackingWei * 10_000n) / q.fee : 0n;
  return (
    <div className="card">
      <h3 className="vault-h2">Price of a draw</h3>
      <Kv label="FWA fee per pull" value={<Eth wei={q.fee} digits={5} />} strong />
      <Kv label="VRF fee per pull" value={<Eth wei={q.vrf} digits={5} />} />
      <Kv label={`Total for ${count}`} value={<Eth wei={q.total} digits={5} />} strong />
      <Kv label="Sent with the pull, excess refunded" value={<Eth wei={sendValue(q)} digits={5} />} />
      <Kv label="VRF fee quoted at" value={`${(Number(q.gasPrice) / 1e9).toFixed(2)} gwei`} />
      <p className="vault-note">
        The FWA fee is the base game price and already includes FWA&apos;s edge. The VRF fee is read live and can be zero. Wallet
        gas is extra and is never folded into these numbers, so there is no single all-in figure.
      </p>

      <h3 className="vault-h2" style={{ marginTop: 18 }}>
        FWA fee against redeemable value
      </h3>
      <Kv label="Average redeemable value per pull" value={<Eth wei={odds.averageBackingWei} digits={5} />} />
      <Kv label="Average value as a share of the fee" value={percent(returnBps)} />
      <Kv label="Chance a draw redeems for at least the fee" value={percent(atLeastTicketBps, 2)} />
      <p className="vault-note">
        Each Shape and Draw Pack redeems at Shapes for its backing at face. FWA weighs each listing by the inverse of its list price.
      </p>
    </div>
  );
}
