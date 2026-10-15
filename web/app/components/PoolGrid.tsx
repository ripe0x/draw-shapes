"use client";

import { useListedItems, type ListedItem } from "../lib/art";
import { eth } from "../lib/format";
import { usePool } from "../lib/pool";
import { useDeployment } from "../Providers";
import { TokenArt } from "./TokenArt";

/** Art tiles drawn at most; the rest of the board collapses into count lines. */
const MAX_TILES = 40;

const byValueDesc = (a: ListedItem, b: ListedItem) => (a.valueWei === b.valueWei ? 0 : a.valueWei > b.valueWei ? -1 : 1);
const kindOf = (i: ListedItem) => `${i.valueWei}-${i.pack}`;

/**
 * Every active FWA listing of the pool, largest redeemable value first, as art tiles. The smallest
 * value class collapses into a count line when larger ones exist, and items past `MAX_TILES` collapse
 * the same way. Listings come from `useListedItems`, which reads FWA's live listing range.
 */
export function PoolGrid() {
  const dep = useDeployment();
  const pool = usePool().data;
  // Sponsored prizes list on the same FWA pool and show on their own card.
  const listed = useListedItems().data?.filter((i) => [dep.shapes, dep.drawPacks].some((a) => a.toLowerCase() === i.collection.toLowerCase()));
  if (!listed || listed.length === 0) return null;

  const sorted = [...listed].sort(byValueDesc);
  const smallest = sorted[sorted.length - 1].valueWei;
  const large = sorted.filter((i) => i.valueWei > smallest);
  const tiles = (large.length ? large : sorted).slice(0, MAX_TILES);
  const shown = new Set(tiles.map((t) => t.listingId));
  const rest = new Map<string, { item: ListedItem; count: number }>();
  for (const i of sorted) {
    if (shown.has(i.listingId)) continue;
    const k = kindOf(i);
    rest.set(k, { item: rest.get(k)?.item ?? i, count: (rest.get(k)?.count ?? 0) + 1 });
  }
  const grailListings = new Set(pool?.grail.items.flatMap((g) => (g.listingId !== 0n ? [g.listingId] : [])));

  return (
    <div id="pool">
      <div className="landing-pool-header">
        <h2 className="landing-pool-title">What&apos;s in the pool</h2>
        <div className="landing-pool-count">{listed.length.toLocaleString("en-US")} listed</div>
      </div>
      <div className="landing-pool-body">
        <div className="landing-grid-col">
          <div className="landing-prize-grid">
            {tiles.map((t) => (
              <div key={t.listingId.toString()} className="landing-grid-tile">
                <TokenArt token={t} />
                <div className="landing-grid-value">
                  {eth(t.valueWei)} ETH
                  {grailListings.has(t.listingId) && <span className="landing-grid-tag"> GRAIL</span>}
                </div>
              </div>
            ))}
          </div>
          {[...rest.values()].map(({ item, count }) => (
            <div key={kindOf(item)} className="landing-commons-line">
              <span className="landing-commons-count">{count.toLocaleString("en-US")} more</span>
              <span>
                {eth(item.valueWei)} ETH {item.pack ? "Draw Pack" : "Shape"}
                {count === 1 ? "" : "s"}
              </span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
