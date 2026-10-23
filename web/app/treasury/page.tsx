"use client";

import { useState } from "react";
import { encodeAbiParameters, keccak256, parseEther, zeroAddress, type Address } from "viem";
import { treasuryAbi } from "../lib/abi/treasury";
import { evmNowAddressUrl } from "../lib/errors";
import { eth, parseEthInput, pct, short } from "../lib/format";
import { useCoin, useRound, useTreasury } from "../lib/engine";
import { usePool } from "../lib/pool";
import { useDeployment } from "../Providers";
import { Eth, Kv, Stat } from "../components/Measure";
import { TxButton, TxLine, useTx } from "../components/Tx";

/** An address link: Etherscan on mainnet, evm.now elsewhere. */
function AddressLink({ address }: { address: Address }) {
  const dep = useDeployment();
  if (address === zeroAddress) return <>None</>;
  const href = dep.chainId === 1 ? `https://etherscan.io/address/${address}` : evmNowAddressUrl(address, dep.chainId);
  return (
    <a href={href} target="_blank" rel="noreferrer">
      {short(address)}
    </a>
  );
}

const POOL_KEY_TYPE = [
  {
    type: "tuple",
    components: [
      { name: "currency0", type: "address" },
      { name: "currency1", type: "address" },
      { name: "fee", type: "uint24" },
      { name: "tickSpacing", type: "int24" },
      { name: "hooks", type: "address" },
    ],
  },
] as const;

type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };

/** The v4 pool id is `keccak256(abi.encode(poolKey))`. */
function poolIdOf(k: PoolKey): `0x${string}` {
  return keccak256(encodeAbiParameters(POOL_KEY_TYPE, [k]));
}

function Keepers() {
  const dep = useDeployment();
  const collectTx = useTx();
  const harvestTx = useTx();
  const coverTx = useTx();
  const boostTx = useTx();
  const buybackTx = useTx();
  const [maxEth, setMaxEth] = useState("");
  const [minOut, setMinOut] = useState("");
  const target = { chainId: dep.chainId, address: dep.treasury!, abi: treasuryAbi } as const;

  const maxEthWei = parseEthInput(maxEth);
  let minOutUnits: bigint | undefined;
  try {
    minOutUnits = minOut.trim() ? parseEther(minOut.trim()) : 0n;
  } catch {
    minOutUnits = undefined;
  }

  return (
    <div className="card">
      <h3 className="vault-h2">Keeper calls</h3>
      <p className="vault-note">
        Anyone can call these. They move booked flows along: collect new trading receipts, harvest game earnings, refill
        coverage from the reserve, send the spare prize budget to the GRAIL, and buy back and burn the coin.
      </p>
      <div className="row-actions">
        <TxButton tx={collectTx} label="Collect fees" onClick={() => void collectTx.run(() => collectTx.write({ ...target, functionName: "collectFees" }))} />
        <TxButton tx={harvestTx} label="Harvest" outline onClick={() => void harvestTx.run(() => harvestTx.write({ ...target, functionName: "harvest" }))} />
        <TxButton tx={coverTx} label="Maintain coverage" outline onClick={() => void coverTx.run(() => coverTx.write({ ...target, functionName: "maintainCoverage" }))} />
        <TxButton tx={boostTx} label="Boost GRAIL" outline onClick={() => void boostTx.run(() => boostTx.write({ ...target, functionName: "boostGrail" }))} />
      </div>
      <TxLine tx={collectTx} />
      <TxLine tx={harvestTx} />
      <TxLine tx={coverTx} />
      <TxLine tx={boostTx} />

      <h3 className="vault-h2" style={{ marginTop: 18 }}>
        Buy back and burn
      </h3>
      <div className="field-row">
        <input type="text" inputMode="decimal" placeholder="Max ETH in (0 = all available)" aria-label="Max ETH in" value={maxEth} onChange={(e) => setMaxEth(e.target.value)} />
        <span>ETH</span>
      </div>
      <div className="field-row">
        <input type="text" inputMode="decimal" placeholder="Min coin out" aria-label="Minimum coin out" value={minOut} onChange={(e) => setMinOut(e.target.value)} />
        <span>coin</span>
      </div>
      <p className="vault-note">Min coin out is your slippage floor. 0 accepts any price and risks a bad fill; set it from the current market.</p>
      <TxButton
        tx={buybackTx}
        label="Buyback"
        disabled={minOutUnits === undefined}
        onClick={() =>
          void buybackTx.run(() =>
            buybackTx.write({ ...target, functionName: "buyback", args: [maxEthWei ?? 0n, minOutUnits ?? 0n] }),
          )
        }
      />
      <TxLine tx={buybackTx} />
    </div>
  );
}

/** `/treasury`: the ENGINE coin and its market terms, the treasury totals and buckets, pool earnings,
 *  GRAIL, the founders' outstanding entitlement, a standing collectible bid, status and keeper calls. */
export default function TreasuryPage() {
  const dep = useDeployment();
  const t = useTreasury().data;
  const pool = usePool().data;
  const round = useRound().data;
  const coin = useCoin().data;

  if (!dep.treasury) {
    return (
      <main className="vault-page">
        <section className="vault-hero">
          <h1 className="vault-headline">Treasury</h1>
          <p className="vault-lede">No treasury is configured for this deployment.</p>
        </section>
      </main>
    );
  }

  const key = t?.poolKey as PoolKey | undefined;
  const pendingEarnings = t && pool && pool.nav > t.basis ? pool.nav - t.basis : 0n;
  const status = !t ? "" : t.settled ? "Wound down" : t.windingDown ? "Winding down" : t.activated ? "Active" : "Not activated";

  return (
    <main className="vault-page">
      <section className="vault-hero">
        <h1 className="vault-headline">Treasury</h1>
        <p className="vault-lede">
          The protocol treasury is the only shareholder and admin of the pool, the bounty recipient of the ENGINE coin&apos;s
          trading fees, and the payer of founder distributions, sponsor compensation, GRAIL boosts and coin buybacks.
        </p>
      </section>

      {!t ? (
        <p className="vault-note">Reading the treasury.</p>
      ) : (
        <>
          <div className="stat-grid">
            <Stat label="Status" value={status} sub={t.activated && !t.settled ? (t.dormant ? "Dormant: anyone can wind down" : "Live") : undefined} />
            <Stat label="Reserve" value={<Eth wei={t.reserve} digits={3} />} sub={`of ${eth(t.reserveTarget, 2)} ETH target`} />
            <Stat label="Prize budget" value={<Eth wei={t.prizeBudget} digits={3} />} sub="Boosted into the GRAIL" />
            <Stat label="Buyback fund" value={<Eth wei={t.buybackFund} digits={3} />} sub="Buys and burns the coin" />
          </div>

          <section className="vault-section two-col">
            <div className="card">
              <h3 className="vault-h2">ENGINE coin and market</h3>
              <Kv label="Coin" value={<AddressLink address={dep.coin ?? zeroAddress} />} />
              <Kv label="Symbol" value={coin?.symbol ?? "-"} />
              <Kv label="Total supply" value={coin?.totalSupply !== undefined && coin.decimals !== undefined ? `${(Number(coin.totalSupply) / 10 ** coin.decimals).toLocaleString("en-US")} ${coin.symbol ?? ""}` : "-"} />
              {key && (
                <>
                  <Kv label="Pool hooks" value={<AddressLink address={key.hooks} />} />
                  <Kv label="Pool fee / spacing" value={`${key.fee} pips, ${key.tickSpacing}`} />
                  <Kv label="Pool id" value={<span title={poolIdOf(key)}>{short(poolIdOf(key))}</span>} />
                </>
              )}
              <h3 className="vault-h2" style={{ marginTop: 18 }}>Fee terms (measured)</h3>
              <Kv label="Skim on each buy and sell" value={pct(t.coinSkimBps)} />
              <Kv label="Bounty share to the treasury" value={pct(t.coinBountyBps)} />
              <p className="vault-note">
                The skim is {pct(t.coinSkimBps)} of the ETH side of every trade; the treasury receives {pct(t.coinBountyBps)} of
                it ({((t.coinSkimBps * t.coinBountyBps) / 1e8 * 100).toFixed(2)}% of volume), the Artcoins protocol the rest.
                All fees arrive as ETH.
              </p>
            </div>

            <div className="card">
              <h3 className="vault-h2">Buckets</h3>
              <Kv label="Reserve" value={<>{eth(t.reserve, 4)} / {eth(t.reserveTarget, 2)} ETH</>} />
              <Kv label="Prize budget" value={<Eth wei={t.prizeBudget} digits={4} />} />
              <Kv label="Buyback fund" value={<Eth wei={t.buybackFund} digits={4} />} />
              <Kv label="Basis (pool principal)" value={<Eth wei={t.basis} digits={4} />} />
              <Kv label="Coverage owed" value={<Eth wei={t.coverageOwed} digits={4} />} />
              <h3 className="vault-h2" style={{ marginTop: 18 }}>Pool</h3>
              <Kv label="Ordinary NAV" value={pool ? <Eth wei={pool.nav} digits={4} /> : "-"} />
              <Kv label="Pending earnings (NAV - basis)" value={<Eth wei={pendingEarnings} digits={4} />} strong />
              <Kv label="Maintenance" value={pool ? <Eth wei={pool.maintenance} digits={4} /> : "-"} />
              <Kv label="GRAIL fund" value={pool ? <Eth wei={pool.grail.fund} digits={4} /> : "-"} />
              <Kv label="GRAIL items" value={pool ? pool.grail.items.length.toLocaleString("en-US") : "-"} />
            </div>
          </section>

          <section className="vault-section two-col">
            <div className="card">
              <h3 className="vault-h2">Founders</h3>
              {round ? (
                <>
                  <Kv label="Outstanding to the cap" value={<Eth wei={round.remaining} digits={4} />} strong />
                  <Kv label="Entitlement ceiling" value={<Eth wei={round.entitlement} digits={4} />} />
                  <Kv label="Distributed so far" value={<Eth wei={round.totalDistributed} digits={4} />} />
                  <Kv label="From trading" value={<Eth wei={t.totals.foundersFromTrading} digits={4} />} />
                  <Kv label="From earnings" value={<Eth wei={t.totals.foundersFromEarnings} digits={4} />} />
                  <Kv label="From wind-down" value={<Eth wei={t.totals.foundersFromWindDown} digits={4} />} />
                </>
              ) : (
                <p className="vault-note">No founding round is configured.</p>
              )}
            </div>

            <div className="card">
              <h3 className="vault-h2">Collectible bid</h3>
              {t.bid[3] ? (
                <>
                  <Kv label="Token id" value={`#${t.bid[0].toString()}`} />
                  <Kv label="Bid price" value={<Eth wei={t.bid[1]} digits={4} />} />
                  <Kv label="List price once bought" value={<Eth wei={t.bid[2]} digits={4} />} />
                  <Kv label="Funded from prize budget" value={<>{eth(t.prizeBudget, 4)} / {eth(t.bid[1], 4)} ETH</>} strong />
                </>
              ) : (
                <p className="vault-note">No collectible bid is open.</p>
              )}
            </div>
          </section>

          <section className="vault-section two-col">
            <div className="card">
              <h3 className="vault-h2">Lifetime totals</h3>
              <Kv label="Trading received" value={<Eth wei={t.totals.tradingReceived} digits={4} />} />
              <Kv label="Earnings received" value={<Eth wei={t.totals.earningsReceived} digits={4} />} />
              <Kv label="Sponsor paid" value={<Eth wei={t.totals.sponsorPaid} digits={4} />} />
              <Kv label="GRAIL boosted" value={<Eth wei={t.totals.grailBoosted} digits={4} />} />
              <Kv label="Collectibles bought" value={<Eth wei={t.totals.collectiblesBought} digits={4} />} />
              <Kv label="Maintenance funded" value={<Eth wei={t.totals.maintenanceFunded} digits={4} />} />
              <Kv label="Pool repaired" value={<Eth wei={t.totals.poolRepaired} digits={4} />} />
              <Kv label="Principal returned" value={<Eth wei={t.totals.principalReturned} digits={4} />} />
              <Kv label="Buyback ETH spent" value={<Eth wei={t.totals.buybackEthSpent} digits={4} />} />
              <Kv
                label="Coin bought / burned"
                value={coin?.decimals !== undefined ? `${(Number(t.totals.coinBought) / 10 ** coin.decimals).toLocaleString("en-US")} / ${(Number(t.totals.coinBurned) / 10 ** coin.decimals).toLocaleString("en-US")}` : `${t.totals.coinBought.toString()} / ${t.totals.coinBurned.toString()}`}
              />
            </div>
            <Keepers />
          </section>
        </>
      )}
    </main>
  );
}
