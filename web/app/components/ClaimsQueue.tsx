"use client";

import { useAccount } from "wagmi";
import { poolAbi } from "../lib/abi/pool";
import { short, utc } from "../lib/format";
import { useClaimsQueue } from "../lib/pool";
import { useDeployment } from "../Providers";
import { Eth, Kv } from "./Measure";
import { TxButton, TxLine, useTx } from "./Tx";

/** Entries shown, matching the 20 claims one `payClaims` call pays. */
const SHOWN = 20;

/** Unpaid withdrawal claims in request order. Any wallet can call `payClaims`. */
export function ClaimsQueue() {
  const dep = useDeployment();
  const { address } = useAccount();
  const claims = useClaimsQueue().data;
  const tx = useTx();
  const me = address?.toLowerCase();

  return (
    <div className="card">
      <h3 className="vault-h2">Claims queue</h3>
      <p className="vault-note">
        Queued claims are paid from cash in request order, up to 20 per call. Any wallet can call it.
      </p>
      <Kv label="Unpaid claims" value={claims ? <Eth wei={claims.unpaidTotal} /> : "-"} />
      <Kv label="Pool cash" value={claims ? <Eth wei={claims.cash} /> : "-"} />
      <Kv label="Queued claims" value={claims ? claims.queue.length.toLocaleString("en-US") : "-"} />
      {claims && claims.queue.length > 0 && (
        <div className="table-scroll">
          <table className="odds-table">
            <thead>
              <tr>
                <th>#</th>
                <th>Holder</th>
                <th>Unpaid claim</th>
                <th>Requested</th>
              </tr>
            </thead>
            <tbody>
              {claims.queue.slice(0, SHOWN).map((c, i) => (
                <tr key={i} className={c.to.toLowerCase() === me ? "is-mine" : undefined}>
                  <td>{(claims.head + BigInt(i)).toString()}</td>
                  <td>{short(c.to)}</td>
                  <td>
                    <Eth wei={c.amount} digits={6} />
                  </td>
                  <td>{utc(c.requestedAt)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {claims && claims.queue.length > SHOWN && (
        <p className="stat-sub">{(claims.queue.length - SHOWN).toLocaleString("en-US")} more queued.</p>
      )}
      <div className="field">
        <TxButton
          tx={tx}
          label="Pay claims"
          outline
          disabled={!claims?.queue.length}
          onClick={() => void tx.run(() => tx.write({ address: dep.pool, abi: poolAbi, functionName: "payClaims", chainId: dep.chainId }))}
        />
      </div>
      <TxLine tx={tx} />
    </div>
  );
}
