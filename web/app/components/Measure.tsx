"use client";

import { eth } from "../lib/format";

export function Kv({ label, value, strong = false }: { label: React.ReactNode; value: React.ReactNode; strong?: boolean }) {
  return (
    <div className="kv">
      <span className="kv-key">{label}</span>
      <span className={strong ? "kv-value is-strong" : "kv-value"}>{value}</span>
    </div>
  );
}

export function Stat({ label, value, sub }: { label: React.ReactNode; value: React.ReactNode; sub?: React.ReactNode }) {
  return (
    <div className="stat">
      <div className="stat-label">{label}</div>
      <div className="stat-value">{value}</div>
      {sub ? <div className="stat-sub">{sub}</div> : null}
    </div>
  );
}

/** Wei formatted as ETH. */
export function Eth({ wei, digits = 4 }: { wei: bigint; digits?: number }) {
  return <>{eth(wei, digits)} ETH</>;
}

/** Basis points as a percentage. */
export function percent(bps: bigint | number, digits = 1): string {
  return `${(Number(bps) / 100).toLocaleString("en-US", { maximumFractionDigits: digits, minimumFractionDigits: digits })}%`;
}

/** "1 in N" from a chance in basis points. */
export function oneIn(bps: bigint): string {
  if (bps <= 0n) return "under 1 in 10,000";
  const n = 10_000 / Number(bps);
  return `1 in ${n.toLocaleString("en-US", { maximumFractionDigits: n < 10 ? 1 : 0 })}`;
}

/** Shares as an 18-decimal amount. */
export function shares(amount: bigint, digits = 4): string {
  return (Number(amount) / 1e18).toLocaleString("en-US", { maximumFractionDigits: digits });
}
