"use client";

import { useAccount, useReadContract } from "wagmi";
import { fwaCloneAbi } from "../lib/abi/external";
import { useDeployment } from "../Providers";
import { Eth } from "./Measure";
import { TxButton, TxLine, useTx } from "./Tx";

/** The wallet's refund credit at the FWA pool (from slippage, timeouts or failed deliveries) and a
 *  button to withdraw it. FWA holds the credit; the VRF fee of a pull is never refunded. */
export function Refunds() {
  const dep = useDeployment();
  const { address } = useAccount();
  const tx = useTx();
  const credit = useReadContract({
    chainId: dep.chainId,
    address: dep.fwaPool,
    abi: fwaCloneAbi,
    functionName: "acquisitionRefundCredit",
    args: address ? [address] : undefined,
    query: { enabled: !!address && !!dep.fwaPool, refetchInterval: 12_000 },
  });
  if (!address || !dep.fwaPool) return null;
  const amount = credit.data ?? 0n;

  return (
    <div className="card">
      <h3 className="vault-h2">Refund credit</h3>
      <p className="vault-note">
        FWA credits a pull that was slipped, timed out or failed delivery. The credit waits at the FWA pool until you
        withdraw it. The VRF fee is spent when the request is made and is not refunded.
      </p>
      <p className="vault-note">
        Your credit: <strong><Eth wei={amount} digits={5} /></strong>
      </p>
      <TxButton
        tx={tx}
        label="Withdraw refund"
        disabled={amount === 0n}
        onClick={() => void tx.run(() => tx.write({ address: dep.fwaPool!, abi: fwaCloneAbi, functionName: "withdrawAcquisitionRefund", chainId: dep.chainId }))}
      />
      <TxLine tx={tx} />
    </div>
  );
}
