"use client";

import { eth } from "./format";

/** Pays accrued sponsor revenue to the recorded sponsor. */
export function SponsorWithdraw({ sponsorRevenue }: { sponsorRevenue: bigint | undefined }) {
  const amount = sponsorRevenue != null ? `${eth(sponsorRevenue)} ETH` : "...";

  return (
    <div>
      <div className="sponsor-label">Withdraw</div>
      <div className="sponsor-big">{amount}</div>
      <button className="sponsor-pill sponsor-pill-small" disabled={!sponsorRevenue}>
        {sponsorRevenue ? `Withdraw ${amount}` : "Withdraw earnings"}
      </button>
      <div className="sponsor-note">Payment goes to the recorded sponsor whoever sends the transaction.</div>
    </div>
  );
}
