"use client";

import { drawOdds, grailChanceBps, TRACK, usePool, type Grail } from "../lib/pool";
import { eth } from "../lib/format";
import { useDeployment } from "../Providers";
import { Eth, Kv, oneIn, Stat } from "./Measure";
import { TokenArt } from "./TokenArt";

/** Both GRAIL tracks as two cards: the pack's art, backing, list notional, odds per pull, pulls since
 *  the last list and the track's bucket. GRAIL buckets and backing sit outside ordinary NAV. */
export function GrailBoard({ detail = false }: { detail?: boolean }) {
  const pool = usePool().data;
  if (!pool) return null;
  const odds = drawOdds(pool.board, pool.grails);
  return (
    <>
      {pool.grails.map((g, t) => (
        <GrailCard key={t} track={t as 0 | 1} g={g} chanceBps={grailChanceBps(odds, t as 0 | 1)} detail={detail} />
      ))}
    </>
  );
}

function GrailCard({ track, g, chanceBps, detail }: { track: 0 | 1; g: Grail; chanceBps: bigint; detail: boolean }) {
  const dep = useDeployment();
  const listed = g.listingId !== 0n;
  const progress = g.targetWei === 0n ? 0 : Math.min(100, Number((g.backing * 100n) / g.targetWei));
  return (
    <div className="card grail-card" data-track={TRACK[track].toLowerCase()}>
      <h3 className="vault-h2">{TRACK[track]} GRAIL</h3>
      {g.packId !== 0n && (
        <div className="grail-art">
          <TokenArt token={{ collection: dep.drawPacks, tokenId: g.packId }} />
        </div>
      )}
      <div className="stat-grid grail-stats">
        <Stat label="Backing" value={<Eth wei={g.backing} digits={3} />} sub={`Target ${eth(g.targetWei, 3)} ETH`} />
        <Stat label="List notional" value={listed ? <Eth wei={g.notional} digits={4} /> : "Not listed"} />
        <Stat label="Odds per pull" value={listed ? oneIn(chanceBps) : "Not listed"} />
        <Stat label="Pulls since list" value={g.pullsSinceList.toLocaleString("en-US")} />
      </div>
      <progress className="grail-progress" max={100} value={progress} aria-label={`${TRACK[track]} GRAIL backing toward target`}>
        {progress}%
      </progress>
      <Kv label="Bucket" value={<Eth wei={g.bucket} digits={4} />} />
      {detail && (
        <>
          <Kv label="Growth step" value={<Eth wei={g.stepWei} digits={3} />} />
          <Kv label="List price share of backing" value={`${(Number(g.listBps) / 100).toLocaleString("en-US")}%`} />
          <Kv label="Price drop per pull" value={<Eth wei={g.decayWeiPerPull} digits={5} />} />
          <Kv label="Price floor" value={<Eth wei={g.floorWei} digits={4} />} />
          <Kv label="Receivable" value={<Eth wei={g.receivable} digits={4} />} />
          <Kv label="Listing" value={listed ? `#${g.listingId.toString()}` : "None"} />
        </>
      )}
      <p className="vault-note">
        {listed
          ? `Listed at ${eth(g.notional, 4)} ETH for ${eth(g.backing, 3)} ETH of backing. ` +
            (g.notional > g.floorWei
              ? `Settle lowers the price by ${eth(g.decayWeiPerPull, 5)} ETH per pull, down to the ${eth(g.floorWei, 4)} ETH floor.`
              : `The price is at or below the ${eth(g.floorWei, 4)} ETH floor and holds there.`)
          : g.backing > 0n
            ? "The pack is held and lists at the next settle."
            : "The track mints a pack once its bucket covers a growth step and the mint fees."}
      </p>
    </div>
  );
}
