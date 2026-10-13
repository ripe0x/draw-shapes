"use client";

import { useState } from "react";
import { useAccount, usePublicClient, useReadContracts } from "wagmi";
import { zeroAddress, type Address, type ContractFunctionParameters, type PublicClient } from "viem";
import { fwaCloneAbi, shapesAbi } from "./lib/abi/external";
import { lensAbi } from "./lib/abi/lens";
import { poolAbi } from "./lib/abi/pool";
import { eth, QUOTE_REASON } from "./lib/format";
import type { Deployment } from "./lib/deployment";
import { useDeployment } from "./Providers";
import { TxButton, TxStatus, useTx } from "./components/Tx";

const COUNTS = [1, 2, 3, 4, 5];
const POLL_MS = 12_000;

interface Quote {
  fee: bigint;
  vrf: bigint;
  total: bigint;
  purchasable: boolean;
  reason: number;
}

/** Quote, FWA slippage and inventory version are read at send time so the transaction carries
 *  current values. */
async function readFresh(client: PublicClient | undefined, dep: Deployment, count: number) {
  if (!client) throw new Error("No RPC client.");
  let fwa: Address | undefined = dep.fwaPool;
  if (!fwa) {
    const live = await client.readContract({ address: dep.pool, abi: poolAbi, functionName: "fwaPool" });
    if (live === zeroAddress) throw new Error("The FWA pool is not created yet.");
    fwa = live;
  }
  const [q, slippage, version, block] = await Promise.all([
    client.readContract({ address: dep.lens, abi: lensAbi, functionName: "quote", args: [BigInt(count)] }),
    client.readContract({ address: fwa, abi: fwaCloneAbi, functionName: "selectionSlippageBps" }),
    client.readContract({ address: fwa, abi: fwaCloneAbi, functionName: "inventoryVersion" }),
    client.getBlock(),
  ]);
  // The chain clock can trail wall time on a local fork, so the later of the two sets the deadline.
  const now = Math.max(Number(block.timestamp), Math.floor(Date.now() / 1000));
  return { q, slippage: BigInt(slippage), version, deadline: BigInt(now + 300), maxFee: (q.fee * 102n) / 100n };
}

export default function Landing() {
  const dep = useDeployment();
  const { address } = useAccount();
  const client = usePublicClient({ chainId: dep.chainId });
  const tx = useTx();
  const [count, setCount] = useState(1);
  const [idText, setIdText] = useState("");
  const [ids, setIds] = useState<bigint[]>([]);
  const owner = address ?? zeroAddress;
  const chainId = dep.chainId;

  // Loosely typed because the Shape reads vary with the entered ids; results are cast below.
  const contracts: ContractFunctionParameters[] = [
    { address: dep.lens, abi: lensAbi, functionName: "quote", args: [BigInt(count)] },
    { address: dep.shapes, abi: shapesAbi, functionName: "balanceOf", args: [owner] },
    { address: dep.shapes, abi: shapesAbi, functionName: "isApprovedForAll", args: [owner, dep.pool] },
    ...ids.flatMap((id) => [
      { address: dep.shapes, abi: shapesAbi, functionName: "ownerOf", args: [id] },
      { address: dep.shapes, abi: shapesAbi, functionName: "backingOf", args: [id] },
    ]),
  ];
  const read = useReadContracts({
    contracts: contracts.map((c) => ({ ...c, chainId })),
    query: { refetchInterval: POLL_MS },
  });

  const quote = read.data?.[0]?.result as Quote | undefined;
  const balance = (read.data?.[1]?.result as bigint | undefined) ?? 0n;
  const approved = read.data?.[2]?.result === true;
  const shapes = ids.map((id, i) => ({
    id,
    owned: (read.data?.[3 + 2 * i]?.result as string | undefined)?.toLowerCase() === address?.toLowerCase(),
    backing: (read.data?.[4 + 2 * i]?.result as bigint | undefined) ?? 0n,
  }));
  const usable = shapes.filter((s) => s.owned);
  const covered = usable.reduce((sum, s) => sum + s.backing, 0n);

  function pull() {
    return tx.run(async () => {
      const f = await readFresh(client, dep, count);
      return tx.write({
        address: dep.pool,
        abi: poolAbi,
        functionName: "acquireBatch",
        args: [address!, BigInt(count), f.maxFee, 0n, f.slippage, f.version, f.deadline],
        value: f.q.total,
        chainId,
      });
    });
  }

  function pullWithShapes() {
    return tx.run(async () => {
      const f = await readFresh(client, dep, count);
      return tx.write({
        address: dep.pool,
        abi: poolAbi,
        functionName: "pullWithShapes",
        args: [usable.map((s) => s.id), BigInt(count), f.maxFee, f.deadline],
        value: f.q.total > covered ? f.q.total - covered : 0n,
        chainId,
      });
    });
  }

  function approve() {
    return tx.run(() =>
      tx.write({ address: dep.shapes, abi: shapesAbi, functionName: "setApprovalForAll", args: [dep.pool, true], chainId }),
    );
  }

  function checkIds() {
    const parsed = idText.split(/[\s,]+/).filter(Boolean).flatMap((s) => (/^\d+$/.test(s) ? [BigInt(s)] : []));
    setIds([...new Set(parsed)]);
  }

  return (
    <>
      <section>
        <h1>Pull a Shape</h1>
        <p className="note">
          Each pull buys one listing from the pool at the FWA ticket price. The ticket is quoted by the Lens.
        </p>
        <div className="row" role="group" aria-label="Pulls">
          {COUNTS.map((n) => (
            <button key={n} type="button" className="btn outline" aria-pressed={count === n} onClick={() => setCount(n)}>
              {n}
            </button>
          ))}
        </div>
        {read.isLoading && <p className="note">Reading the quote.</p>}
        {read.error && <p className="error">The Lens quote failed: {read.error.message}</p>}
        {quote && (
          <>
            <dl className="kv">
              <dt>Fee</dt>
              <dd>{eth(quote.fee, 6)} ETH</dd>
              <dt>VRF fee</dt>
              <dd>{eth(quote.vrf, 6)} ETH</dd>
              <dt>Total for {count}</dt>
              <dd className="strong">{eth(quote.total, 6)} ETH</dd>
              <dt>Purchasable</dt>
              <dd>{quote.purchasable ? "Yes" : `No (${QUOTE_REASON[quote.reason]})`}</dd>
            </dl>
            <div className="row">
              <TxButton tx={tx} label={`Pull ${count}`} onClick={() => void pull()} disabled={!quote.purchasable} />
              {!address && <span className="note">Connect a wallet to pull.</span>}
            </div>
          </>
        )}
        <TxStatus tx={tx} />
      </section>

      {balance > 0n && (
        <section>
          <h2>Pull with Shapes</h2>
          <p className="note">
            The wallet holds {balance.toString()} Shapes. Enter token ids; the Shapes cover part of the ticket and
            the wallet pays the rest.
          </p>
          <div className="row">
            <input
              value={idText}
              onChange={(e) => setIdText(e.target.value)}
              placeholder="Token ids, comma separated"
              aria-label="Shape token ids"
            />
            <button type="button" className="btn outline" onClick={checkIds}>
              Check
            </button>
          </div>
          {shapes.length > 0 && (
            <table>
              <thead>
                <tr>
                  <th>Token</th>
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
          )}
          <div className="row">
            {!approved && <TxButton tx={tx} label="Approve Shapes" outline onClick={() => void approve()} />}
            <TxButton
              tx={tx}
              label={`Pull ${count} with ${usable.length} Shapes`}
              onClick={() => void pullWithShapes()}
              disabled={!approved || usable.length === 0 || !quote?.purchasable}
            />
          </div>
        </section>
      )}
    </>
  );
}
