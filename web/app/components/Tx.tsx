"use client";

import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useAccount, useSwitchChain, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { evmNowTxUrl, formatTxError } from "../lib/errors";
import { useDeployment } from "../Providers";

/** One write flow: switches the wallet to the deployment chain, sends, waits for the receipt and
 *  refreshes every page query once it lands. */
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
    if (receipt.isSuccess) void queryClient.invalidateQueries();
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

  const pending = busy || (!!hash && receipt.isLoading);
  return { account: address, write: writeContractAsync, run, hash, error: error ?? receipt.error, pending, receipt };
}

export type Tx = ReturnType<typeof useTx>;

/** Transaction link, confirmation state and decoded revert reason of one `useTx` flow. */
export function TxStatus({ tx }: { tx: Tx }) {
  const dep = useDeployment();
  return (
    <>
      {tx.hash && (
        <p className="note">
          <a href={evmNowTxUrl(tx.hash, dep.chainId)} target="_blank" rel="noreferrer">
            {tx.receipt.isSuccess ? "Confirmed" : tx.receipt.isError ? "Failed" : "Pending"}: view transaction
          </a>
        </p>
      )}
      {tx.error ? <p className="error">{formatTxError(tx.error)}</p> : null}
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
}: {
  tx: Tx;
  label: string;
  onClick: () => void;
  disabled?: boolean;
  outline?: boolean;
}) {
  return (
    <button
      type="button"
      className={outline ? "btn outline" : "btn"}
      disabled={!tx.account || tx.pending || disabled}
      onClick={onClick}
    >
      {tx.pending ? "Working" : label}
    </button>
  );
}
