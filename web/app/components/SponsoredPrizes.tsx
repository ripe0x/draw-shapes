"use client";

import { useState } from "react";
import type { Address } from "viem";
import { drawOdds, usePool, type ForeignItem } from "../lib/pool";
import { oneInOf, useCollectionName, useForeignImage, useSponsorTerms } from "../lib/foreign";
import { eth, short, utc } from "../lib/format";
import { Eth, Stat } from "./Measure";

/** A foreign token's image in the 5:7 card box, or a neutral placeholder when `tokenURI` gives none. */
export function ForeignArt({ collection, tokenId }: Pick<ForeignItem, "collection" | "tokenId">) {
  const art = useForeignImage(collection, tokenId);
  const [broken, setBroken] = useState(false);
  const src = art.data && !broken ? art.data : undefined;
  return (
    <div className="shape-art" style={{ width: "100%" }} aria-label={`Token ${tokenId.toString()}`}>
      {src && (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={src} alt="" referrerPolicy="no-referrer" style={{ width: "100%", height: "100%", objectFit: "contain" }} onError={() => setBroken(true)} />
      )}
    </div>
  );
}

/** The collection's name, or its shortened address while unread. */
export function CollectionName({ collection }: { collection: Address }) {
  return <>{useCollectionName(collection).data ?? short(collection)}</>;
}

/** One card per foreign listing: art, collection, token id, list price, odds per pull and, for a
 *  `SponsoredPrize` controller, whether the price is parked or falling. Renders nothing without one. */
export function SponsoredPrizes({ detail = false }: { detail?: boolean }) {
  const pool = usePool().data;
  if (!pool || pool.foreign.length === 0) return null;
  const odds = drawOdds(pool.board, pool.grail, pool.foreign);
  return (
    <>
      {pool.foreign.map((f) => (
        <PrizeCard key={f.listingId.toString()} item={f} oneIn={oneInOf(odds.rows.find((r) => r.key === `foreign-${f.listingId}`)?.weight ?? 0n, odds.total)} detail={detail} />
      ))}
    </>
  );
}

function PrizeCard({ item, oneIn, detail }: { item: ForeignItem; oneIn: string; detail: boolean }) {
  const name = useCollectionName(item.collection).data;
  const terms = useSponsorTerms(item.controller).data;
  return (
    <div className="card grail-card">
      <h3 className="vault-h2">Sponsored prize</h3>
      <div className="grail-art">
        <ForeignArt collection={item.collection} tokenId={item.tokenId} />
      </div>
      <div className="stat-grid grail-stats">
        <Stat label="Collection" value={name ?? "-"} />
        <Stat label="Token" value={`#${item.tokenId.toString()}`} />
        <Stat label="List price" value={<Eth wei={item.notional} digits={4} />} />
        <Stat label="Odds per pull" value={oneIn} />
      </div>
      {terms && (
        <p className="vault-note">
          {terms.parked ? "Parked until the sponsor is paid" : "Price falls every pull"}.
          {detail && terms.parked && ` Paid ${eth(terms.paidWei, 4)} of ${eth(terms.capWei, 4)} ETH. The sponsor can reclaim it from ${utc(terms.reclaimAfter)}.`}
          {detail && !terms.parked && ` The sponsor was paid ${eth(terms.paidWei, 4)} ETH.`}
        </p>
      )}
    </div>
  );
}
