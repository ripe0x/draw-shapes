"use client";

import { useAccount, useReadContract, useBlockNumber } from "wagmi";
import { deployment, lensAddresses } from "../lib/deployment";
import { lensAbi } from "../lib/abi";
import { eth, engine } from "../lib/format";
import { NotDeployed } from "../components/NotDeployed";

const ZERO = "0x0000000000000000000000000000000000000000";

export default function Genesis() {
  const { address } = useAccount();
  const { data: block } = useBlockNumber({ watch: true });
  const { data: market } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "market", args: [lensAddresses], query: { enabled: deployment.deployed } });
  const cur = market ? market.currentEpoch : 0n;
  const to = cur + 1n > 21n ? 21n : cur + 1n;
  const from = to > 8n ? to - 8n : 0n;
  const { data: rows } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "epochs", args: [deployment.farm, address ?? ZERO, from, to], query: { enabled: deployment.deployed && !!market } });
  const endBlock = market?.genesisEndBlock;
  const started = endBlock !== undefined && endBlock < 2n ** 200n;
  const blocksLeft = started && block && endBlock > block ? endBlock - block : 0n;
  return (
    <>
      <h1>Genesis</h1>
      <p>21 daily epochs of 7,200 blocks from the block the game opens, ending at a fixed block nobody can move. Each epoch's
        ENGINE goes to that epoch's delivered pulls, pro rata by ticket ETH (the FWA fee paid; the VRF fee, gas, refunded or
        undelivered pulls, conversions and transfers count nothing, and winning never reduces it). An epoch pays the lesser
        of its allocation cap and its eligible ticket ETH times its rate cap, so a small pull earns its rate, never a whole
        day's pot. The first 14 epochs are steady; the last 7 step down to 87.5%, 75%, …, 12.5% of a steady epoch on both
        caps. What an epoch does not pay is burned when it becomes final. Requests made before the end keep their epoch;
        requests at or after the end block earn nothing. Claims open as epochs become final and never expire.</p>
      <NotDeployed>
        <div className="grid">
          <div className="stat"><b>{market ? String(market.currentEpoch) : "…"}</b><span>current epoch</span></div>
          <div className="stat"><b>{started ? String(endBlock) : "not started"}</b><span>genesis end block</span></div>
          <div className="stat"><b>{started ? (blocksLeft ? `${blocksLeft} blocks` : "ended") : "…"}</b><span>until genesis end</span></div>
          <div className="stat"><b>{market ? (market.gated ? "closed" : "open") : "…"}</b><span>public buys on the canonical pool (reopen at the end block by themselves)</span></div>
        </div>
        <h2>Recent epochs</h2>
        <table>
          <thead><tr><th>epoch</th><th>allocation cap</th><th>rate cap (per ETH)</th><th>eligible ETH</th><th>pot</th><th>your ETH</th><th>your reward</th><th>status</th></tr></thead>
          <tbody>
            {(rows ?? []).slice().reverse().map((r) => (
              <tr key={String(r.epoch)}>
                <td>{String(r.epoch)}</td><td>{engine(r.allocationCap)}</td><td>{engine(r.rateCap)}</td><td>{eth(r.weight, 4)}</td>
                <td>{engine(r.pot)}</td><td>{eth(r.userWeight, 4)}</td><td>{engine(r.reward)}</td>
                <td>{r.claimed ? "claimed" : r.finalized ? "final, pot fixed" : r.isFinal ? "final" : "open"}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="note">ENGINE can also be bought and sold elsewhere (it is an ordinary ERC-20); only the canonical pool's
          public buys are closed during genesis. Sells are never closed. Rewards are not a return on anything and their
          value is not promised.</p>
      </NotDeployed>
    </>
  );
}
