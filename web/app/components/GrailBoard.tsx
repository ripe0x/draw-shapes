"use client";

import { drawOdds, grailChanceBps, usePool, type Grail, type GrailItem } from "../lib/pool";
import { eth } from "../lib/format";
import { Eth, Kv, oneIn, Stat } from "./Measure";
import { TokenArt } from "./TokenArt";

/** The GRAIL fund and cycle as one card, then one card per GRAIL item: art, backing, list price, odds
 *  per pull and pulls since the last list. The fund and the items sit outside ordinary NAV. */
export function GrailBoard({ detail = false }: { detail?: boolean }) {
  const pool = usePool().data;
  if (!pool) return null;
  const odds = drawOdds(pool.board, pool.grail, pool.foreign);
  return (
    <>
      <CycleCard g={pool.grail} detail={detail} />
      {pool.grail.items.map((it) => (
        <ItemCard key={`${it.collection}-${it.tokenId}`} g={pool.grail} item={it} chanceBps={grailChanceBps(odds, it.listingId)} />
      ))}
    </>
  );
}

function CycleCard({ g, detail }: { g: Grail; detail: boolean }) {
  const building = g.items.filter((it) => !it.done).reduce((max, it) => (it.backing > max ? it.backing : max), 0n);
  const progress = g.targetWei === 0n ? 0 : Math.min(100, Number((building * 100n) / g.targetWei));
  return (
    <div className="card grail-card">
      <h3 className="vault-h2">GRAIL, cycle {g.cycleId.toString()}</h3>
      <div className="stat-grid grail-stats">
        <Stat label="Fund" value={<Eth wei={g.fund} digits={4} />} />
        <Stat label="Target" value={<Eth wei={g.targetWei} digits={3} />} sub={`Next cycle ${eth(g.nextTargetWei, 3)} ETH`} />
        <Stat label="Largest item building" value={<Eth wei={building} digits={3} />} />
        <Stat label="Items" value={g.items.length.toLocaleString("en-US")} />
      </div>
      <progress className="grail-progress" max={100} value={progress} aria-label="Largest GRAIL item toward the target">
        {progress}%
      </progress>
      {detail && (
        <>
          <Kv label="List price share of backing" value={`${(Number(g.listBps) / 100).toLocaleString("en-US")}%`} />
          <Kv label="Price drop per pull" value={<Eth wei={g.decayWeiPerPull} digits={5} />} />
          <Kv label="Piece price floor" value={<Eth wei={g.pieceFloorWei} digits={4} />} />
          <Kv label="Price floor" value={<Eth wei={g.floorWei} digits={4} />} />
          <Kv label="Receivable" value={<Eth wei={g.receivable} digits={4} />} />
        </>
      )}
      <p className="vault-note">
        The fund mints 1 ETH pieces, and merges build them up to the target. A listed item&apos;s price falls by{" "}
        {eth(g.decayWeiPerPull, 5)} ETH per pull, down to its floor.
      </p>
    </div>
  );
}

function ItemCard({ g, item, chanceBps }: { g: Grail; item: GrailItem; chanceBps: bigint }) {
  const listed = item.listingId !== 0n;
  return (
    <div className="card grail-card">
      <h3 className="vault-h2">{item.done ? "Completed GRAIL" : "GRAIL item"}</h3>
      <div className="grail-art">
        <TokenArt token={{ collection: item.collection, tokenId: item.tokenId }} />
      </div>
      <div className="stat-grid grail-stats">
        <Stat label="Backing" value={<Eth wei={item.backing} digits={3} />} />
        <Stat label="List price" value={listed ? <Eth wei={item.notional} digits={4} /> : "Not listed"} />
        <Stat label="Odds per pull" value={listed ? oneIn(chanceBps) : "Not listed"} />
        <Stat label="Pulls since list" value={(g.pulls - item.listedAtPull).toLocaleString("en-US")} />
      </div>
      <p className="vault-note">
        {listed
          ? `Listed at ${eth(item.notional, 4)} ETH for ${eth(item.backing, 3)} ETH of backing. Settle lowers the price by ${eth(g.decayWeiPerPull, 5)} ETH per pull toward its floor.`
          : "The item is held and lists at the next rotate."}
      </p>
    </div>
  );
}
