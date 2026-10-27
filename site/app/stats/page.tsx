"use client";

import { useEffect, useState } from "react";
import { usePublicClient, useReadContract } from "wagmi";
import { deployment, lensAddresses } from "../lib/deployment";
import { lensAbi, erc20Abi, poolAbi } from "../lib/abi";
import { eth, engine, pct } from "../lib/format";
import { NotDeployed } from "../components/NotDeployed";

const on = { enabled: deployment.deployed, refetchInterval: 30_000 };

type Win = { block: bigint; tx: string; purchaser: string; listingId: bigint; price: bigint };

/** The pool's most recent allocations, read from FWA's own `NFTAllocated` events (each verifiable on chain). */
function useRecentWins() {
  const client = usePublicClient();
  const [wins, setWins] = useState<Win[]>([]);
  useEffect(() => {
    if (!client || !deployment.deployed) return;
    (async () => {
      const head = await client.getBlockNumber();
      const from = head > 50_000n ? head - 50_000n : BigInt(deployment.blockNumber ?? 0);
      const logs = await client.getContractEvents({ address: deployment.fwaPool, abi: poolAbi, eventName: "NFTAllocated", fromBlock: from });
      setWins(logs.slice(-15).reverse().map((l) => ({
        block: l.blockNumber, tx: l.transactionHash, purchaser: l.args.purchaser!, listingId: l.args.listingId!, price: l.args.price!,
      })));
    })().catch(() => setWins([]));
  }, [client]);
  return wins;
}

export default function Stats() {
  const { data: game } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "game", args: [lensAddresses], query: on });
  const { data: acc } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "accounts", args: [deployment.game], query: on });
  const { data: fund } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "funding", args: [lensAddresses], query: on });
  const { data: market } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "market", args: [lensAddresses], query: on });
  const { data: supply } = useReadContract({ address: deployment.engine, abi: erc20Abi, functionName: "totalSupply", query: on });
  const wins = useRecentWins();
  const unsubsidized = acc ? acc.turnover - acc.promoTurnover : undefined;
  const promoNet = acc ? acc.promoSpent - acc.promoProceeds : undefined;
  return (
    <>
      <h1>Stats</h1>
      <p>Figures read from the contracts. Gameplay turnover is ticket ETH of delivered pulls (FWA fee, without the VRF fee).
        Profit is realised: owner proceeds less the cost of the prizes won and the operating allocation, with losses
        carried forward. Only profit the game has earned and can spare above its protected cash goes to the buyback.
        ENGINE gives no claim on any of this ETH.</p>
      <NotDeployed>
        <h2>Gameplay</h2>
        <div className="grid">
          <div className="stat"><b>{eth(acc?.turnover, 3)}</b><span>gameplay turnover (ETH)</span></div>
          <div className="stat"><b>{eth(unsubsidized, 3)}</b><span>unsubsidized play (no promotion live)</span></div>
          <div className="stat"><b>{eth(acc?.promoTurnover, 3)}</b><span>play while a promotion was live</span></div>
          <div className="stat"><b>{acc ? String(acc.pullsBooked) : "…"}</b><span>pulls booked</span></div>
          <div className="stat"><b>{game ? `${game.liveRows}/${game.boardRows}` : "…"}</b><span>board rows listed</span></div>
          <div className="stat"><b>{game ? (game.acquisitionsEnabled ? "open" : "closed") : "…"}</b><span>new pulls</span></div>
        </div>
        <h2>Funding and results</h2>
        <div className="grid">
          <div className="stat"><b>{eth(fund?.tradingFees, 3)}</b><span>ENGINE trading fees received (capital)</span></div>
          <div className="stat"><b>{eth(acc?.capitalIn, 3)}</b><span>capital into the game</span></div>
          <div className="stat"><b>{acc ? (Number(acc.profit) / 1e18).toFixed(4) : "…"}</b><span>realised game profit (ETH)</span></div>
          <div className="stat"><b>{eth(acc?.distributed, 4)}</b><span>profit sent to the buyback</span></div>
          <div className="stat"><b>{eth(acc?.distributable, 4)}</b><span>distributable now</span></div>
          <div className="stat"><b>{eth(acc?.protectedCash, 3)}</b><span>protected cash (replacements, operating, reserve, exposure)</span></div>
          <div className="stat"><b>{eth(acc?.cash, 3)}</b><span>cash</span></div>
          <div className="stat"><b>{eth(acc?.inventoryBacking, 3)}</b><span>prize backing held</span></div>
        </div>
        <h2>Buyback and conversions</h2>
        <div className="grid">
          <div className="stat"><b>{eth(fund?.buybackSpent, 4)}</b><span>ETH spent on profit-funded buys</span></div>
          <div className="stat"><b>{engine(fund?.engineBurned)}</b><span>ENGINE burned by the buyback</span></div>
          <div className="stat"><b>{eth(fund?.conversionEthIn, 4)}</b><span>player conversion purchases (ETH)</span></div>
          <div className="stat"><b>{fund ? String(fund.conversions) : "…"}</b><span>conversions</span></div>
          <div className="stat"><b>{engine(supply)}</b><span>ENGINE supply</span></div>
          <div className="stat"><b>{pct(market?.feeBps)}{market && market.snipeFeeBps > 0n ? ` + ${pct(market.snipeFeeBps)}` : ""}</b><span>swap fee</span></div>
        </div>
        <h2>Promotions</h2>
        <div className="grid">
          <div className="stat"><b>{eth(acc?.promoFunded, 3)}</b><span>funded</span></div>
          <div className="stat"><b>{eth(promoNet !== undefined && promoNet > 0n ? promoNet : 0n, 4)}</b><span>net spent (prizes won less their proceeds)</span></div>
          <div className="stat"><b>{eth(acc?.promoBudget, 3)}</b><span>budget left</span></div>
        </div>
        <h2>Recent verified wins</h2>
        <table>
          <thead><tr><th>block</th><th>purchaser</th><th>listing</th><th>listing price</th></tr></thead>
          <tbody>
            {wins.map((w) => (
              <tr key={w.tx + String(w.listingId)}><td>{String(w.block)}</td><td>{w.purchaser.slice(0, 10)}…</td>
                <td>{String(w.listingId)}</td><td>{eth(w.price, 4)} ETH</td></tr>
            ))}
          </tbody>
        </table>
        <p className="note">From FWA's NFTAllocated events over the last ~7 days of blocks; each row links to a VRF-selected allocation on chain.</p>
      </NotDeployed>
    </>
  );
}
