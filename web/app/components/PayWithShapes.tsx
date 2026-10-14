"use client";

import { useState } from "react";
import { useAccount, useBalance, usePublicClient, useReadContracts } from "wagmi";
import { zeroAddress, type ContractFunctionParameters } from "viem";
import { shapesAbi } from "../lib/abi/external";
import { poolAbi } from "../lib/abi/pool";
import { eth } from "../lib/format";
import { estimateGas, feeCaps, POLL_MS, PULL_GAS, pullState, readFresh, sendValue, usePool, useQuote } from "../lib/pool";
import { useDeployment } from "../Providers";
import { Eth } from "./Measure";
import { TxButton, TxLine, useTx } from "./Tx";

/**
 * `pullWithShapes`: Shapes the wallet owns pay part of the batch. A Shape at a single-rung mix value
 * stays in the pool as a held item while cash covers it; any other Shape is redeemed at Shapes. The
 * wallet sends the rest.
 */
export function PayWithShapes({ count }: { count: number }) {
  const dep = useDeployment();
  const { address } = useAccount();
  const client = usePublicClient({ chainId: dep.chainId });
  const tx = useTx();
  const approveTx = useTx();
  const q = useQuote(count).data;
  const pool = usePool().data;
  const ethBalance = useBalance({ address, chainId: dep.chainId, query: { refetchInterval: POLL_MS } });
  const [idText, setIdText] = useState("");
  const [ids, setIds] = useState<bigint[]>([]);
  const owner = address ?? zeroAddress;
  const chainId = dep.chainId;

  // Loosely typed because the Shape reads vary with the entered ids; results are cast below.
  const contracts: ContractFunctionParameters[] = [
    { address: dep.shapes, abi: shapesAbi, functionName: "balanceOf", args: [owner] },
    { address: dep.shapes, abi: shapesAbi, functionName: "isApprovedForAll", args: [owner, dep.pool] },
    ...ids.flatMap((id) => [
      { address: dep.shapes, abi: shapesAbi, functionName: "ownerOf", args: [id] },
      { address: dep.shapes, abi: shapesAbi, functionName: "backingOf", args: [id] },
    ]),
  ];
  const read = useReadContracts({
    contracts: contracts.map((c) => ({ ...c, chainId })),
    query: { refetchInterval: POLL_MS, enabled: !!address },
  });
  const balance = (read.data?.[0]?.result as bigint | undefined) ?? 0n;
  const approved = read.data?.[1]?.result === true;
  const shapes = ids.map((id, i) => ({
    id,
    owned: (read.data?.[2 + 2 * i]?.result as string | undefined)?.toLowerCase() === address?.toLowerCase(),
    backing: (read.data?.[3 + 2 * i]?.result as bigint | undefined) ?? 0n,
  }));
  const usable = shapes.filter((s) => s.owned);
  const covered = usable.reduce((sum, s) => sum + s.backing, 0n);
  const sent = q ? sendValue(q) : 0n;
  const rest = sent > covered ? sent - covered : 0n;
  const state = pool ? pullState(pool, dep.pool) : undefined;
  const short = !!q && !!ethBalance.data && ethBalance.data.value < rest + PULL_GAS * q.gasPrice;

  if (!address || balance === 0n) return null;

  function checkIds() {
    const parsed = idText.split(/[\s,]+/).filter(Boolean).flatMap((s) => (/^\d+$/.test(s) ? [BigInt(s)] : []));
    setIds([...new Set(parsed)]);
  }

  function pull() {
    return tx.run(async () => {
      const f = await readFresh(client, dep, count);
      const req = {
        address: dep.pool,
        abi: poolAbi,
        functionName: "pullWithShapes",
        args: [usable.map((s) => s.id), BigInt(count), f.maxFee, f.deadline],
        value: f.value > covered ? f.value - covered : 0n,
      } as const;
      const caps = feeCaps(f.q.gasPrice);
      const gas = await estimateGas(() => client!.estimateContractGas({ ...req, account: address!, ...caps }));
      return tx.write({ ...req, chainId, ...caps, ...gas });
    });
  }

  return (
    <div className="card">
      <h3 className="vault-h2">Pay with Shapes</h3>
      <p className="vault-note">
        The wallet holds {balance.toString()} {balance === 1n ? "Shape" : "Shapes"}. Enter token ids: their backing pays part of a batch of {count}{" "}
        and the wallet sends the rest. Any excess returns to the wallet.
      </p>
      <div className="field-row">
        <input value={idText} onChange={(e) => setIdText(e.target.value)} placeholder="Token ids, comma separated" aria-label="Shape token ids" />
        <button type="button" className="btn-outline" onClick={checkIds}>
          Check
        </button>
      </div>
      {shapes.length > 0 && (
        <div className="table-scroll">
          <table className="odds-table">
            <thead>
              <tr>
                <th>Shape</th>
                <th>Owned</th>
                <th>Backing</th>
              </tr>
            </thead>
            <tbody>
              {shapes.map((s) => (
                <tr key={s.id.toString()}>
                  <td>#{s.id.toString()}</td>
                  <td>{s.owned ? "Yes" : "No"}</td>
                  <td>{eth(s.backing)} ETH</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {usable.length > 0 && q && (
        <p className="vault-note coverage-line">
          {usable.length} {usable.length === 1 ? "Shape covers" : "Shapes cover"} <Eth wei={covered} /> of the <Eth wei={sent} digits={5} /> sent
          value. The wallet sends <Eth wei={rest} digits={5} />.
        </p>
      )}
      <div className="row-actions">
        {!approved && (
          <TxButton
            tx={approveTx}
            label="Approve Shapes"
            outline
            onClick={() =>
              void approveTx.run(() =>
                approveTx.write({ address: dep.shapes, abi: shapesAbi, functionName: "setApprovalForAll", args: [dep.pool, true], chainId }),
              )
            }
          />
        )}
        <TxButton
          tx={tx}
          label={`Pull ${count} with ${usable.length} ${usable.length === 1 ? "Shape" : "Shapes"}`}
          onClick={() => void pull()}
          disabled={!approved || usable.length === 0 || !q?.purchasable || !state?.open || short}
        />
      </div>
      {state && !state.open && <p className="pull-status-footer">{state.headline}</p>}
      {short && <p className="pull-status-footer">The wallet needs about {eth(rest + PULL_GAS * q!.gasPrice)} ETH for the rest and gas.</p>}
      <TxLine tx={approveTx} />
      <TxLine tx={tx} />
    </div>
  );
}
