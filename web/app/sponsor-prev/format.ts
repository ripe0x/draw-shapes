/** Formats wei as ETH with up to `digits` fraction digits, trimming trailing zeros. */
export function eth(wei: bigint, digits = 4): string {
  const n = Number(wei) / 1e18;
  return n.toLocaleString("en-US", { maximumFractionDigits: digits, minimumFractionDigits: 0 });
}

/** Converts a probability expressed in WAD (1e18 = 100%) to "1 in N" odds. Returns "-" for zero.
 *  N keeps one decimal place below 10 ("1 in 1.1") and rounds to an integer at or above 10
 *  ("1 in 2,398"), since a fractional digit on a large N reads as false precision. */
export function oddsOneInN(probabilityWad: bigint): string {
  if (probabilityWad <= 0n) return "-";
  const WAD = 10n ** 18n;
  const n = Number(WAD) / Number(probabilityWad);
  const digits = n < 10 ? 1 : 0;
  return `1 in ${n.toLocaleString("en-US", { maximumFractionDigits: digits, minimumFractionDigits: digits })}`;
}

/** Truncates an address to 0x1234...abcd for display. */
export function short(address: string): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

/** Formats a duration in seconds as "Xm Ys" or "Xh Ym", clamped to zero. */
export function duration(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
}

/** Formats an onchain Unix timestamp in an exact, locale-independent UTC form. */
export function timestampUtc(seconds: bigint): string {
  return new Date(Number(seconds) * 1000).toISOString().replace("T", " ").replace(".000Z", " UTC");
}

/** Formats a duration in seconds as "Xd Yh", clamped to zero. For countdowns measured in days
 *  (beta window), where `duration()`'s hour/minute granularity is too fine to read at a glance. */
export function durationDaysHours(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const days = Math.floor(s / 86400);
  const hours = Math.floor((s % 86400) / 3600);
  if (days === 0) return duration(s);
  return `${days}d ${hours}h`;
}

export function bpsToPercent(bps: number): string {
  return `${(bps / 100).toLocaleString("en-US", { maximumFractionDigits: 2 })}%`;
}

export function evmNowAddressUrl(address: string, chainId: number): string {
  return `https://evm.now/address/${address}?chainId=${chainId}`;
}
