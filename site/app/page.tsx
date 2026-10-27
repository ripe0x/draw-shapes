"use client";

import { useEffect, useState } from "react";
import { useAccount, useReadContract, useWriteContract, usePublicClient } from "wagmi";
import { deployment, lensAddresses } from "./lib/deployment";
import { lensAbi, poolAbi } from "./lib/abi";
import { eth, pct } from "./lib/format";
import { NotDeployed } from "./components/NotDeployed";
import { TxStatus } from "./components/Tx";
import { useTermsAcceptance } from "./lib/terms-acceptance";

type Tier = { backing: bigint; count: number; probability: bigint };

/** Groups listings or board rows by backing: how many, and their summed probability (1e18 = certain). */
function tiersOf(rows: { backing: bigint; probability: bigint }[]): Tier[] {
  const out: Tier[] = [];
  for (const r of rows) {
    const t = out.find((x) => x.backing === r.backing);
    if (t) {
      t.count += 1;
      t.probability += r.probability;
    } else {
      out.push({ backing: r.backing, count: 1, probability: r.probability });
    }
  }
  return out.sort((a, b) => (a.backing < b.backing ? -1 : 1));
}

export default function Play() {
  const { address } = useAccount();
  const { accepted } = useTermsAcceptance(deployment.chainId, address);
  const client = usePublicClient();
  const [count, setCount] = useState(1);
  const { data: game } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "game", args: [lensAddresses], query: { enabled: deployment.deployed, refetchInterval: 15_000 } });
  const { data: market } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "market", args: [lensAddresses], query: { enabled: deployment.deployed, refetchInterval: 15_000 } });
  const { data: inventory } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "inventory", args: [deployment.game], query: { enabled: deployment.deployed, refetchInterval: 30_000 } });
  const { data: target } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "targetBoard", args: [deployment.game], query: { enabled: deployment.deployed } });
  const { data: refund } = useReadContract({ address: deployment.fwaPool, abi: poolAbi, functionName: "acquisitionRefundCredit", args: [address ?? "0x0000000000000000000000000000000000000000"], query: { enabled: deployment.deployed && !!address } });
  const { writeContract, data: hash, error, isPending } = useWriteContract();
  const [quote, setQuote] = useState<{ fee: bigint; vrf: bigint } | undefined>();

  // FWA's VRF fee scales with the transaction's gas price (FWACloneVRFService.requestFee reads tx.gasprice), so the
  // quote is read at the current max fee per gas. FWA refunds anything sent above the exact cost.
  async function quoteNow(n: number) {
    if (!client) return undefined;
    const { maxFeePerGas } = await client.estimateFeesPerGas();
    const [fee, vrf, total] = await client.readContract({
      address: deployment.fwaPool, abi: poolAbi, functionName: "quoteAcquisitionPrice", args: [BigInt(n)], gasPrice: maxFeePerGas,
    } as Parameters<typeof client.readContract>[0]) as readonly [bigint, bigint, bigint];
    return { fee, vrf, total };
  }

  useEffect(() => {
    if (!deployment.deployed) return;
    quoteNow(1).then((q) => q && setQuote({ fee: q.fee, vrf: q.vrf })).catch(() => setQuote(undefined));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client, game?.inventoryVersion]);

  async function pull() {
    if (!address || !client) return;
    const q = await quoteNow(count);
    if (!q) return;
    const { fee, total } = q;
    const version = await client.readContract({ address: deployment.fwaPool, abi: poolAbi, functionName: "inventoryVersion" });
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
    if (count === 1) {
      writeContract({ address: deployment.fwaPool, abi: poolAbi, functionName: "acquire", args: [address, fee, 0n, 10_000n, version, deadline], value: total });
    } else {
      writeContract({ address: deployment.fwaPool, abi: poolAbi, functionName: "acquireBatch", args: [address, BigInt(count), fee, 0n, 10_000n, version, deadline], value: total });
    }
  }

  const open = game?.acquisitionsEnabled && !game?.retiring;
  const current = tiersOf((inventory ?? []).map((l) => ({ backing: l.backing, probability: l.probability })));
  const modelled = tiersOf((target?.[0] ?? []).map((b, i) => ({ backing: b, probability: target![2][i] })));
  return (
    <>
      <h1>Pull a Shape</h1>
      <p>Each pull draws one Shape from a board of {game ? String(game.liveListings) : "…"} with Chainlink VRF on an FWA V2
        pool. Bigger Shapes are rarer: odds are inverse to price. Every Shape holds its ETH and can be burned for it.
        During genesis every delivered pull earns ENGINE. Pulls made on FWA's own site count the same.</p>
      <NotDeployed>
        <div className="grid">
          <div className="stat"><b>{eth(quote?.fee ?? game?.quoteFee, 5)}</b><span>ETH per pull (prize draw)</span></div>
          <div className="stat"><b>{eth(quote?.vrf, 5)}</b><span>+ VRF fee at current gas</span></div>
          <div className="stat"><b>{game ? `${game.liveRows}/${game.boardRows}` : "…"}</b><span>board rows listed</span></div>
          <div className="stat"><b>{market ? (market.gated ? "closed" : "open") : "…"}</b><span>public ENGINE buys</span></div>
          <div className="stat"><b>{pct(market?.feeBps)}</b><span>ENGINE swap fee</span></div>
        </div>
        <div className="row">
          {[1, 5].map((n) => (
            <button key={n} className={count === n ? "btn-filled" : "btn-outline"} onClick={() => setCount(n)}>{n} pull{n > 1 ? "s" : ""}</button>
          ))}
          <button className="btn-filled" disabled={!address || accepted !== true || !open || isPending} onClick={pull}>
            {open ? "Pull" : "Game not open"}
          </button>
        </div>
        <TxStatus hash={hash} error={error} />
        <h2>Prizes</h2>
        <table>
          <thead><tr><th>Shape backing</th><th>listed now</th><th>chance now</th><th>modelled full board</th><th>modelled chance</th></tr></thead>
          <tbody>
            {modelled.map((m) => {
              const c = current.find((x) => x.backing === m.backing);
              return (
                <tr key={String(m.backing)}>
                  <td>{eth(m.backing, 2)} ETH</td><td>{c ? c.count : 0}</td><td>{c ? (Number(c.probability) / 1e16).toFixed(3) : "0.000"} %</td>
                  <td>{m.count}</td><td>{(Number(m.probability) / 1e16).toFixed(3)} %</td>
                </tr>
              );
            })}
          </tbody>
        </table>
        <p className="note">"Now" is the live FWA pool: when prizes have just been won and not yet replaced, the board is
          smaller and the chances shift until the next replacement window. The modelled board is the target the game
          refills to. Price per pull is set by FWA from the live board.</p>
        {refund && refund > 0n ? (
          <div className="row">
            <span>Refund waiting: {eth(refund, 5)} ETH (a pull that expired or was refunded).</span>
            <button className="btn-outline" onClick={() => writeContract({ address: deployment.fwaPool, abi: poolAbi, functionName: "withdrawAcquisitionRefund" })}>Withdraw</button>
          </div>
        ) : null}
        <p className="note">A pull costs more than the average prize is worth; the usual outcome is the smallest Shape.
          FWA's VRF fee pays the oracle callback and rises with gas prices: pull when gas is cheap.
          Your prize arrives in your wallet when the VRF word lands (usually within a minute).</p>
      </NotDeployed>
    </>
  );
}
