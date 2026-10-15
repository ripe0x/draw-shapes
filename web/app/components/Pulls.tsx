"use client";

import { useAccount } from "wagmi";
import { fwaCloneAbi } from "../lib/abi/external";
import { poolAbi } from "../lib/abi/pool";
import { formatTxError } from "../lib/errors";
import { eth } from "../lib/format";
import { ACQ, usePulls } from "../lib/pulls";
import { useDeployment } from "../Providers";
import { PullBatchView } from "./PullReveal";
import { TxButton, TxLine, useTx } from "./Tx";

/** Batches listed, newest first. */
const SHOWN = 10;

/** The connected wallet's pulls, newest batch first, with the calls that move a pull along. */
export function Pulls() {
  const dep = useDeployment();
  const { address } = useAccount();
  const pulls = usePulls();
  const settleTx = useTx();
  const processTx = useTx();
  const data = pulls.data;
  const fresh = new Set(data?.fresh);
  const anyReady = !!data && Object.values(data.cards).some((c) => c.status === ACQ.Ready);

  return (
    <section className="vault-section" id="your-pulls">
      <h2 className="vault-h2">Your pulls</h2>
      {!address && <p className="vault-note">Connect a wallet to see its pulls.</p>}
      {address && pulls.isPending && <p className="vault-note">Reading pulls.</p>}
      {pulls.error && <p className="error-line">Reading pulls failed: {formatTxError(pulls.error)}</p>}
      {data && data.batches.length === 0 && <p className="vault-note">This wallet has no pulls on this pool yet.</p>}
      {data?.batches
        .slice(-SHOWN)
        .reverse()
        .map((b) => (
          <div key={b.tx} className="pull-batch">
            <p className="vault-note">
              Block {b.block.toString()}: {b.count.toString()} {b.count === 1n ? "pull" : "pulls"} at a {eth(b.fee, 5)} ETH ticket, plus the
              VRF fee.
            </p>
            <PullBatchView batch={b} cards={data.cards} fresh={fresh} />
          </div>
        ))}
      {data && data.batches.length > SHOWN && (
        <p className="vault-note">The latest {SHOWN} of {data.batches.length} batches.</p>
      )}
      <div className="row-actions">
        <TxButton
          tx={settleTx}
          label="Settle"
          outline
          onClick={() => void settleTx.run(() => settleTx.write({ address: dep.pool, abi: poolAbi, functionName: "settle", args: [20n], chainId: dep.chainId }))}
        />
        {anyReady && dep.fwaPool && (
          <TxButton
            tx={processTx}
            label="Process on FWA"
            outline
            onClick={() =>
              void processTx.run(() =>
                processTx.write({ address: dep.fwaPool!, abi: fwaCloneAbi, functionName: "processAcquisitions", args: [20n], chainId: dep.chainId }),
              )
            }
          />
        )}
      </div>
      <TxLine tx={settleTx} />
      <TxLine tx={processTx} />
      <p className="vault-note">
        FWA delivers a pull in the transaction that brings its randomness. Settle books the delivery on the pool, collects the proceeds and
        lists replacements when a batch is due; the pool refunds the caller&apos;s gas from maintenance when it lists. Process on FWA
        appears when a pull waits at Ready, the case FWA&apos;s callback leaves for a later call.
      </p>
    </section>
  );
}
