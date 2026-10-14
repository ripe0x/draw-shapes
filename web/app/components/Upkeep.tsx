"use client";

import { poolAbi } from "../lib/abi/pool";
import { duration, eth, ROTATE_TRIGGER, SETTLE_TRIGGER, utc } from "../lib/format";
import { usePool } from "../lib/pool";
import { useDeployment } from "../Providers";
import { Kv } from "./Measure";
import { TxButton, TxLine, useTx } from "./Tx";

const yesNo = (v: boolean) => (v ? "yes" : "no");

/** Settle and rotate triggers, the reopen guards behind each pull, and the upkeep calls
 *  `settle`, `rotate` and `payClaims`. */
export function Upkeep() {
  const dep = useDeployment();
  const pool = usePool().data;
  const settleTx = useTx();
  const rotateTx = useTx();
  const claimsTx = useTx();
  if (!pool) return null;

  const { params: p, reopen, settleDue, rotateDue, claims } = pool;
  const target = { chainId: dep.chainId, address: dep.pool, abi: poolAbi } as const;

  const settleMeaning = [
    "No settle is due.",
    `${p.batchMin} or more replacements are queued.`,
    `The oldest queued replacement is ${duration(Number(p.batchMaxAge))} old.`,
    `Listed items minus unsettled acquisitions are fewer than ${p.concurrency + 5n}.`,
  ] as const;
  const rotateMeaning = [
    `No reason holds, or the rotate interval of ${duration(Number(p.rotateInterval))} has not passed since the last rotate.`,
    "The head queued claim is at least one rotate interval old.",
    "A GRAIL track below its target holds a bucket that covers a growth step and its mint fees.",
    "Settle may not list, and a held item exists or cash covers the head of the replacement queue.",
  ] as const;

  return (
    <div className="protocol-data-grid">
      <div className="card">
        <h3 className="vault-h2">Triggers</h3>
        <Kv label={`Settle due: ${SETTLE_TRIGGER[settleDue]}`} value={settleMeaning[settleDue]} />
        <Kv label={`Rotate due: ${ROTATE_TRIGGER[rotateDue]}`} value={rotateMeaning[rotateDue]} />
        <Kv label="Next rotate allowed" value={p.lastRotateAt === 0n ? "Any time a reason holds" : utc(p.lastRotateAt + p.rotateInterval)} />
        <h3 className="vault-h2" style={{ marginTop: 18 }}>
          Reopen guards for a pull
        </h3>
        <Kv label="Live" value={yesNo(reopen.live)} />
        <Kv label="Pulls open" value={yesNo(reopen.pullsOpen)} />
        <Kv
          label="Cooldown passed"
          value={`${yesNo(reopen.cooldownPassed)}, purchases resume ${utc(reopen.purchasesResumeAt)}`}
        />
        <Kv
          label="Solvent"
          value={`${yesNo(reopen.solvent)}, balance ${eth(reopen.balance, 4)} ETH against ${eth(reopen.required, 4)} ETH required`}
        />
        <Kv
          label="Board deep"
          value={`${yesNo(reopen.boardDeep)}, ${reopen.listedCount} listed against ${reopen.unsettled} unsettled plus ${reopen.concurrency} concurrency`}
        />
      </div>
      <div className="card">
        <h3 className="vault-h2">Upkeep calls</h3>
        <p className="vault-note">
          Anyone can call these. Settle and rotate refund the caller&apos;s gas from the maintenance bucket, up to its balance
          of {eth(pool.maintenance, 4)} ETH.
        </p>
        <div className="row-actions">
          <TxButton
            tx={settleTx}
            label="Settle"
            onClick={() => void settleTx.run(() => settleTx.write({ ...target, functionName: "settle", args: [20n] }))}
          />
          <TxButton
            tx={rotateTx}
            label="Rotate"
            outline
            disabled={rotateDue === 0}
            onClick={() => void rotateTx.run(() => rotateTx.write({ ...target, functionName: "rotate" }))}
          />
          <TxButton
            tx={claimsTx}
            label="Pay claims"
            outline
            disabled={claims === 0n}
            onClick={() => void claimsTx.run(() => claimsTx.write({ ...target, functionName: "payClaims" }))}
          />
        </div>
        <TxLine tx={settleTx} />
        <TxLine tx={rotateTx} />
        <TxLine tx={claimsTx} />
        <p className="vault-note">
          Settle books up to 20 FWA acquisitions per call. Unpaid claims total {eth(claims, 4)} ETH.
        </p>
      </div>
    </div>
  );
}
