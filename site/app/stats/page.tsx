"use client";

import { useReadContract } from "wagmi";
import { deployment, lensAddresses } from "../lib/deployment";
import { lensAbi, erc20Abi, buybackAbi } from "../lib/abi";
import { eth, engine, pct } from "../lib/format";
import { NotDeployed } from "../components/NotDeployed";

const on = { enabled: deployment.deployed, refetchInterval: 30_000 };

export default function Stats() {
  const { data: game } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "game", args: [lensAddresses], query: on });
  const { data: market } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "market", args: [lensAddresses], query: on });
  const { data: table } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "treasuryTable", args: [deployment.treasury], query: on });
  const { data: supply } = useReadContract({ address: deployment.engine, abi: erc20Abi, functionName: "totalSupply", query: on });
  const { data: burned } = useReadContract({ address: deployment.buyback, abi: buybackAbi, functionName: "totalBurned", query: on });
  const { data: deposited } = useReadContract({ address: deployment.buyback, abi: buybackAbi, functionName: "totalDeposited", query: on });
  return (
    <>
      <h1>Stats</h1>
      <NotDeployed>
        <h2>Game</h2>
        <div className="grid">
          <div className="stat"><b>{eth(game?.nav, 3)}</b><span>game value (cash + prize backing)</span></div>
          <div className="stat"><b>{eth(game?.cash, 3)}</b><span>cash</span></div>
          <div className="stat"><b>{eth(game?.distributable, 4)}</b><span>above the reserve (may be distributed)</span></div>
          <div className="stat"><b>{eth(game?.grailReserve, 3)}</b><span>GRAIL reserve</span></div>
          <div className="stat"><b>{game ? `${game.liveListings}/${game.boardRows}` : "…"}</b><span>prizes listed</span></div>
          <div className="stat"><b>{game ? String(game.openRequests) : "…"}</b><span>pulls settling</span></div>
        </div>
        <h2>ENGINE</h2>
        <div className="grid">
          <div className="stat"><b>{engine(supply)}</b><span>supply</span></div>
          <div className="stat"><b>{engine(burned)}</b><span>burned by buybacks</span></div>
          <div className="stat"><b>{engine(deposited)}</b><span>bought back for players</span></div>
          <div className="stat"><b>{market ? engine(market.enginePerEth) : "…"}</b><span>ENGINE per ETH (spot)</span></div>
          <div className="stat"><b>{pct(market?.feeBps)}{market && market.snipeFeeBps > 0n ? ` + ${pct(market.snipeFeeBps)}` : ""}</b><span>swap fee</span></div>
        </div>
        <h2>Treasury table</h2>
        <table>
          <thead><tr><th>sink</th><th>share</th><th>allocated</th></tr></thead>
          <tbody>
            {table?.[0].map((s, i) => (
              <tr key={s}><td>{s === deployment.buyback ? "Buyback" : s === deployment.grailFund ? "GRAIL fund" : s}</td><td>{pct(table[1][i])}</td><td>{eth(table[2][i])}</td></tr>
            ))}
          </tbody>
        </table>
        <p className="note">Unallocated: {eth(table?.[3])} ETH. Governance (a timelock, no delay at launch) sets this table.</p>
      </NotDeployed>
    </>
  );
}
