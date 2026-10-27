"use client";

import { useEffect, useState } from "react";
import { useAccount, usePublicClient, useReadContract, useWriteContract } from "wagmi";
import type { Address } from "viem";
import { deployment, lensAddresses } from "../lib/deployment";
import { converterAbi, lensAbi, poolAbi, shapesAbi } from "../lib/abi";
import { eth, pct } from "../lib/format";
import { NotDeployed } from "../components/NotDeployed";
import { TxStatus } from "../components/Tx";

type Prize = { listingId: bigint; tokenId: bigint; value: bigint };

/** Shapes this pool delivered to the connected wallet that it still holds and has not converted. */
function usePrizes(owner?: Address) {
  const client = usePublicClient();
  const [prizes, setPrizes] = useState<Prize[]>([]);
  useEffect(() => {
    if (!client || !owner || !deployment.deployed) return;
    (async () => {
      const logs = await client.getContractEvents({
        address: deployment.fwaPool, abi: poolAbi, eventName: "NFTAllocated", args: { purchaser: owner },
        fromBlock: BigInt(deployment.blockNumber ?? 0),
      });
      const out: Prize[] = [];
      for (const l of logs) {
        const listingId = l.args.listingId!;
        const [ok, , tokenId] = await client.readContract({ address: deployment.converter, abi: converterAbi, functionName: "convertible", args: [listingId] });
        if (!ok) continue;
        const holder = await client.readContract({ address: deployment.shapes, abi: shapesAbi, functionName: "ownerOf", args: [tokenId] }).catch(() => undefined);
        if (holder?.toLowerCase() !== owner.toLowerCase()) continue;
        const value = await client.readContract({ address: deployment.shapes, abi: shapesAbi, functionName: "valueOf", args: [tokenId] });
        out.push({ listingId, tokenId, value });
      }
      setPrizes(out);
    })().catch(() => setPrizes([]));
  }, [client, owner]);
  return prizes;
}

export default function Convert() {
  const { address } = useAccount();
  const prizes = usePrizes(address);
  const { data: bonus } = useReadContract({ address: deployment.converter, abi: converterAbi, functionName: "bonusBps", query: { enabled: deployment.deployed } });
  const { writeContract, data: hash, error, isPending } = useWriteContract();
  const client = usePublicClient();

  async function convert(p: Prize) {
    if (!client || !address) return;
    const approved = await client.readContract({ address: deployment.shapes, abi: shapesAbi, functionName: "getApproved", args: [p.tokenId] });
    if (approved.toLowerCase() !== deployment.converter.toLowerCase()) {
      writeContract({ address: deployment.shapes, abi: shapesAbi, functionName: "approve", args: [deployment.converter, p.tokenId] });
      return;
    }
    const [quote] = await client.readContract({ address: deployment.lens, abi: lensAbi, functionName: "conversionQuote", args: [lensAddresses, p.value] });
    const minOut = (quote * 95n) / 100n; // 5 % below the spot estimate
    writeContract({ address: deployment.converter, abi: converterAbi, functionName: "convert", args: [p.listingId, minOut, true] });
  }

  return (
    <>
      <h1>Convert a prize to ENGINE</h1>
      <p>Turn a Shape you won from this pool into ENGINE: the Shape is burned for its ETH, that ETH buys ENGINE with no
        swap fee, and a bonus of {pct(bonus)} is added from the bonus pool while it lasts. Anyone holding a delivered
        Shape may convert it, once. The first click approves the Shape; the second converts.</p>
      <NotDeployed>
        {!address ? <p className="note">Connect a wallet.</p> : prizes.length === 0 ? <p className="note">No convertible prizes found.</p> : (
          <table>
            <thead><tr><th>Shape</th><th>backing</th><th></th></tr></thead>
            <tbody>
              {prizes.map((p) => (
                <tr key={String(p.listingId)}>
                  <td>#{String(p.tokenId)}</td><td>{eth(p.value)} ETH</td>
                  <td><button className="btn-outline" disabled={isPending} onClick={() => convert(p)}>Convert</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <TxStatus hash={hash} error={error} />
        <p className="note">The ENGINE amount depends on the market price at execution; the site asks for at least 95 % of
          the spot estimate, so you can lose up to that much to price movement.</p>
      </NotDeployed>
    </>
  );
}
