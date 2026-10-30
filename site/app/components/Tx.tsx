"use client";

import { useWaitForTransactionReceipt } from "wagmi";
import type { Hash } from "viem";

export function TxStatus({ hash, error }: { hash?: Hash; error?: Error | null }) {
  const { isLoading, isSuccess } = useWaitForTransactionReceipt({ hash });
  if (error) return <p className="err">{(error as { shortMessage?: string }).shortMessage ?? error.message}</p>;
  if (!hash) return null;
  return <p className="note">{isLoading ? "Waiting for confirmation…" : isSuccess ? "Confirmed." : "Sent."} {hash.slice(0, 10)}…</p>;
}
