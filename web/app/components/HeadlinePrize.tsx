"use client";

import { short } from "../lib/format";
import { oneInFromWeight, useFwaTotalWeight, usePool } from "../lib/pool";
import { useDeployment } from "../Providers";
import { Eth, Stat } from "./Measure";
import { TokenArt } from "./TokenArt";

/**
 * The current headline prizes: the largest listed GRAIL item and, when the deal is active, the
 * sponsored NFT. Only listed or active prizes are shown, and the odds come from FWA's raw weights so
 * a rare item still reads a real "1 in N" where the Lens bps share rounds to zero.
 */
export function HeadlinePrize() {
  const dep = useDeployment();
  const pool = usePool().data;
  const totalWeight = useFwaTotalWeight().data;
  if (!pool) return null;

  // Largest listed GRAIL item by backing.
  const listedGrail = pool.grail.items.filter((g) => g.listingId !== 0n && g.notional !== 0n);
  const topGrail = listedGrail.reduce<typeof listedGrail[number] | undefined>(
    (max, g) => (!max || g.backing > max.backing ? g : max),
    undefined,
  );

  // The sponsored NFT, when it is a live foreign listing of the sponsorship contract.
  const sponsored =
    dep.sponsorship && pool.foreign
      ? pool.foreign.find((f) => f.controller.toLowerCase() === dep.sponsorship!.toLowerCase() && f.notional !== 0n)
      : undefined;

  if (!topGrail && !sponsored) return null;

  return (
    <div className="headline-prizes">
      {topGrail && (
        <div className="card">
          <h3 className="vault-h2">Top GRAIL prize</h3>
          <div className="grail-art">
            <TokenArt token={{ collection: topGrail.collection, tokenId: topGrail.tokenId }} />
          </div>
          <div className="stat-grid grail-stats">
            <Stat label="Backing" value={<Eth wei={topGrail.backing} digits={3} />} />
            <Stat label="List price" value={<Eth wei={topGrail.notional} digits={4} />} />
            <Stat label="Odds per draw" value={oneInFromWeight(topGrail.notional, totalWeight) ?? "-"} sub="draws" />
          </div>
        </div>
      )}
      {sponsored && (
        <div className="card">
          <h3 className="vault-h2">Sponsored prize</h3>
          <p className="vault-note">A lent {short(sponsored.collection)} NFT, token #{sponsored.tokenId.toString()}, listed as a headline prize.</p>
          <div className="stat-grid grail-stats">
            <Stat label="List price" value={<Eth wei={sponsored.notional} digits={4} />} />
            <Stat label="Odds per draw" value={oneInFromWeight(sponsored.notional, totalWeight) ?? "-"} sub="draws" />
          </div>
        </div>
      )}
    </div>
  );
}
