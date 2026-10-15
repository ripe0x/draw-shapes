"use client";

import { useAccount } from "wagmi";
import { usePool, useClaimsQueue } from "../lib/pool";
import { Eth, Kv, Stat, percent, shares } from "./Measure";

/** The connected wallet's shares, value at ordinary NAV, share of the pool and queued claims. */
export function PositionsList() {
  const { address } = useAccount();
  const pool = usePool().data;
  const queue = useClaimsQueue().data?.queue;

  if (!address) {
    return (
      <div className="card deposit-position-card">
        <h3 className="vault-h2">Your position</h3>
        <p className="vault-note">Connect a wallet to see your shares.</p>
      </div>
    );
  }

  const me = address.toLowerCase();
  const queued = queue?.filter((c) => c.to.toLowerCase() === me).reduce((sum, c) => sum + c.amount, 0n);
  const poolShareBps = pool && pool.totalShares > 0n ? (pool.position.shares * 10_000n) / pool.totalShares : 0n;

  return (
    <div className="card deposit-position-card">
      <div className="deposit-position-head">
        <h3 className="vault-h2">Your position</h3>
        <a href="#withdraw">Manage →</a>
      </div>
      <div className="deposit-position-values">
        <Stat label="Shares" value={pool ? shares(pool.position.shares) : "-"} />
        <Stat label="Value at NAV" value={pool ? <Eth wei={pool.position.valueWei} /> : "-"} />
      </div>
      <Kv label="Share of the pool" value={pool ? percent(poolShareBps, 2) : "-"} />
      <Kv label="Your queued claims" value={queued === undefined ? "-" : <Eth wei={queued} />} />
    </div>
  );
}
