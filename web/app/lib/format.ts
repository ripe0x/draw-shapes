import { formatEther } from "viem";

/** Wei as ETH, trimmed to `digits` fraction digits. */
export function eth(wei: bigint, digits = 4): string {
  return Number(formatEther(wei)).toLocaleString("en-US", { maximumFractionDigits: digits });
}

export function short(address: string): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

export function pct(bps: number | bigint): string {
  return `${(Number(bps) / 100).toLocaleString("en-US", { maximumFractionDigits: 2 })}%`;
}

/** Unix seconds as UTC, or a dash for zero. */
export function utc(seconds: bigint | number): string {
  const n = Number(seconds);
  return n ? new Date(n * 1000).toISOString().replace("T", " ").slice(0, 19) + " UTC" : "-";
}

export function duration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds >= 2 * 86_400) return `${(seconds / 86_400).toLocaleString("en-US", { maximumFractionDigits: 1 })}d`;
  return `${(seconds / 3600).toLocaleString("en-US", { maximumFractionDigits: 1 })}h`;
}

/** Selection probability in bps as "1 in N". */
export function oddsOneIn(bps: bigint): string {
  return bps === 0n ? "-" : `1 in ${(10_000 / Number(bps)).toLocaleString("en-US", { maximumFractionDigits: 1 })}`;
}

/** Contract enum names in declaration order (IPool.sol and Lens.sol). */
export const LIFECYCLE = ["Opening", "Live", "Exiting", "Exported"] as const;
export const SETTLE_TRIGGER = ["None", "Batch", "Age", "Thin", "Deep"] as const;
export const ROTATE_TRIGGER = ["None", "Claim", "GrailStep", "Held"] as const;
export const QUOTE_REASON = [
  "None",
  "NotLive",
  "Exiting",
  "PullsPaused",
  "InvalidCount",
  "CoolingDown",
  "Insolvent",
  "BoardTooThin",
] as const;
