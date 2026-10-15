"use client";

import { drawOdds, usePool, type OddsRow } from "../lib/pool";
import { eth } from "../lib/format";
import { Eth, percent } from "./Measure";

function madeOf(row: OddsRow): string {
  if ("grail" in row.kind) return "GRAIL item";
  if ("foreign" in row.kind) return "Sponsored prize";
  if ("pack" in row.kind) return `Draw Pack of ${row.kind.pack} Shapes`;
  return "1 Shape";
}

/** Every listed row, listed GRAIL item and sponsored prize a pull can draw, with its listed count and chance per pull.
 *  Chances follow FWA's selection rule: each listing weighs 1e36 / its list price. */
export function OddsGlance() {
  const pool = usePool().data;
  if (!pool) return null;
  const odds = drawOdds(pool.board, pool.grail, pool.foreign);
  return (
    <div className="card">
      <h3 className="vault-h2">What a pull can draw</h3>
      <div className="table-scroll">
        <table className="odds-table">
          <thead>
            <tr>
              <th>Redeemable value</th>
              <th>Made of</th>
              <th>Listed</th>
              <th>Chance</th>
            </tr>
          </thead>
          <tbody>
            {odds.rows.map((row) => (
              <tr key={row.key}>
                <td>{"foreign" in row.kind ? "-" : `${eth(row.backingWei)} ETH`}</td>
                <td>{madeOf(row)}</td>
                <td>{row.listed.toLocaleString("en-US")}</td>
                <td>{percent(row.chanceBps, 2)}</td>
              </tr>
            ))}
            {odds.rows.length === 0 && (
              <tr>
                <td colSpan={4}>The board has no listings yet.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      {odds.rows.length > 0 && (
        <p className="vault-note">
          Average redeemable value per pull: <Eth wei={odds.averageBackingWei} />. Each Shape and Draw Pack redeems at Shapes for
          its backing at face. FWA weighs each listing by the inverse of its list price.
        </p>
      )}
    </div>
  );
}
