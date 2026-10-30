import { formatEther } from "viem";

export const eth = (wei?: bigint, digits = 4) => (wei === undefined ? "…" : Number(formatEther(wei)).toFixed(digits));
export const engine = (wei?: bigint) =>
  wei === undefined ? "…" : Number(formatEther(wei)).toLocaleString(undefined, { maximumFractionDigits: 0 });
export const pct = (bps?: bigint | number) => (bps === undefined ? "…" : `${(Number(bps) / 100).toFixed(2)} %`);
