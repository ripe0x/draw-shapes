"use client";

import { useAccount, useReadContract, useBlockNumber } from "wagmi";
import { deployment, lensAddresses } from "../lib/deployment";
import { lensAbi, farmAbi } from "../lib/abi";
import { engine } from "../lib/format";
import { NotDeployed } from "../components/NotDeployed";

const ZERO = "0x0000000000000000000000000000000000000000";

export default function Genesis() {
  const { address } = useAccount();
  const { data: block } = useBlockNumber({ watch: true });
  const { data: market } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "market", args: [lensAddresses], query: { enabled: deployment.deployed } });
  const { data: epochsN } = useReadContract({ address: deployment.farm, abi: farmAbi, functionName: "genesisEpochs", query: { enabled: deployment.deployed } });
  const cur = market ? market.currentEpoch : 0n;
  const to = cur + 1n;
  const from = to > 8n ? to - 8n : 0n;
  const { data: rows } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "epochs", args: [deployment.farm, address ?? ZERO, from, to], query: { enabled: deployment.deployed && !!market } });
  const endBlock = market?.genesisEndBlock;
  const blocksLeft = endBlock && block && endBlock < 2n ** 200n && endBlock > block ? endBlock - block : 0n;
  return (
    <>
      <h1>Genesis</h1>
      <p>{epochsN ? String(epochsN) : "21"} daily epochs of 7,200 blocks from the moment the game opens. Each epoch's
        ENGINE goes to that epoch's delivered pulls, pro rata (one unit per pull). An epoch becomes claimable once every
        pull made in it has settled. Emission tapers from 1.5× to 0.5× of the average day. Buybacks add to each day's pot.</p>
      <NotDeployed>
        <div className="grid">
          <div className="stat"><b>{market ? String(market.currentEpoch) : "…"}</b><span>current epoch</span></div>
          <div className="stat"><b>{blocksLeft ? `${blocksLeft} blocks` : endBlock && endBlock >= 2n ** 200n ? "not started" : "ended"}</b><span>until genesis end</span></div>
          <div className="stat"><b>{market ? (market.gated ? "closed" : "open") : "…"}</b><span>public buys on the canonical pool</span></div>
        </div>
        <h2>Recent epochs</h2>
        <table>
          <thead><tr><th>epoch</th><th>pot (ENGINE)</th><th>pulls</th><th>yours</th><th>your reward</th><th>status</th></tr></thead>
          <tbody>
            {(rows ?? []).slice().reverse().map((r) => (
              <tr key={String(r.epoch)}>
                <td>{String(r.epoch)}</td><td>{engine(r.pot)}</td><td>{String(r.units)}</td><td>{String(r.userUnits)}</td>
                <td>{engine(r.reward)}</td><td>{r.claimed ? "claimed" : r.isFinal ? "final" : "open"}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="note">ENGINE can also be bought and sold elsewhere (it is an ordinary ERC-20); only the canonical pool's
          public buys are closed during genesis. Sells are never closed.</p>
      </NotDeployed>
    </>
  );
}
