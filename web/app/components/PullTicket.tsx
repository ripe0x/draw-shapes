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
  const s = pool.params.feeSplit;
  return (
    <div className="card">
      <h3 className="vault-h2">Price</h3>
      <Kv label="Ticket per pull" value={<Eth wei={q.fee} digits={5} />} strong />
      <Kv label="VRF fee per pull" value={<Eth wei={q.vrf} digits={5} />} />
      <Kv label={`Total for ${count}`} value={<Eth wei={q.total} digits={5} />} strong />
      <Kv label="Sent with the pull, excess refunded" value={<Eth wei={sendValue(q)} digits={5} />} />
      <Kv label="VRF fee quoted at" value={`${(Number(q.gasPrice) / 1e9).toFixed(2)} gwei`} />

      <h3 className="vault-h2" style={{ marginTop: 18 }}>
        Ticket against redeemable value
      </h3>
      <Kv label="Average redeemable value per pull" value={<Eth wei={odds.averageBackingWei} digits={5} />} />
      <Kv label="Average value as a share of the ticket" value={percent(returnBps)} />
      <Kv label="Chance a draw redeems for at least the ticket" value={percent(atLeastTicketBps, 2)} />
      <p className="vault-note">
        Ticket only: the VRF fee and gas are excluded. Each Shape and Draw Pack redeems at Shapes for its backing at face.
      </p>

      <h3 className="vault-h2" style={{ marginTop: 18 }}>
        List price markups
      </h3>
      <Kv label="Depositor premium" value={`${percent(s.premiumBps, 2)} of backing`} />
      <Kv label="Maintenance" value={`${percent(s.maintenanceBps, 2)} of backing`} />
      <Kv label="GRAIL feed" value={`${percent(s.feedBps, 2)} of backing`} />
      <p className="vault-note">
        Each list price is the item&apos;s backing plus these markups and its replacement mint fee. FWA pays the pool the ticket less half the
        gap to the harmonic mean list price. The margin over the item&apos;s backing first repays the mint fee, then splits pro rata across
        the three markups.
      </p>
    </div>
  );
}
