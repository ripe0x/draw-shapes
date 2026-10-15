"use client";

import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useAccount, useSwitchChain, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { evmNowTxUrl, formatTxError } from "../lib/errors";
import { useDeployment } from "../Providers";

/** One write flow: switches the wallet to the deployment chain, sends, waits for the receipt and
 *  refreshes the page queries once it lands. */
export function useTx() {
  const dep = useDeployment();
  const { address, chainId } = useAccount();
  const { switchChainAsync } = useSwitchChain();
  const { writeContractAsync } = useWriteContract();
  const queryClient = useQueryClient();
  const [hash, setHash] = useState<`0x${string}`>();
  const [error, setError] = useState<unknown>();
  const [busy, setBusy] = useState(false);
  const receipt = useWaitForTransactionReceipt({ hash, chainId: dep.chainId });

  useEffect(() => {
    // Token images are fixed per token, so they stay cached.
    if (receipt.isSuccess) void queryClient.invalidateQueries({ predicate: (q) => q.queryKey[0] !== "token-image" });
  }, [receipt.isSuccess, queryClient]);

  async function run(send: () => Promise<`0x${string}`>) {
    setHash(undefined);
    setError(undefined);
    setBusy(true);
    try {
      if (chainId !== dep.chainId) await switchChainAsync({ chainId: dep.chainId });
      setHash(await send());
    } catch (e) {
      setError(e);
    } finally {
      setBusy(false);
    }
  }

  function reset() {
    setHash(undefined);
    setError(undefined);
  }

  const pending = busy || (!!hash && receipt.isLoading);
  return { account: address, write: writeContractAsync, run, reset, hash, error: error ?? receipt.error, pending, receipt };
}

export type Tx = ReturnType<typeof useTx>;

/** Transaction link, confirmation state and decoded revert reason of one `useTx` flow. */
export function TxLine({ tx }: { tx: Tx }) {
  const dep = useDeployment();
  return (
    <>
      {tx.hash && (
        <p className="tx-line">
          <a href={evmNowTxUrl(tx.hash, dep.chainId)} target="_blank" rel="noreferrer">
            {tx.receipt.isSuccess ? "Confirmed" : tx.receipt.isError ? "Failed" : "Pending"}: view transaction
          </a>
        </p>
      )}
      {tx.error ? <p className="error-line">{formatTxError(tx.error)}</p> : null}
    </>
  );
}

/** A button wired to one `useTx` flow. Disabled until a wallet is connected. */
export function TxButton({
  tx,
  label,
  onClick,
  disabled,
  outline,
  className,
}: {
  tx: Tx;
  label: string;
  onClick: () => void;
  disabled?: boolean;
  outline?: boolean;
  className?: string;
}) {
  return (
    <button
      type="button"
      className={className ?? (outline ? "btn-outline" : "btn-filled")}
      disabled={!tx.account || tx.pending || disabled}
      onClick={onClick}
    >
      {tx.pending ? "Working" : label}
    </button>
  );
}
