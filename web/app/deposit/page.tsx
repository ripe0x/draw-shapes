"use client";

import { useState } from "react";
import { useAccount, useReadContracts } from "wagmi";
import { formatEther, parseEther, zeroAddress } from "viem";
import { lensAbi } from "../lib/abi/lens";
import { poolAbi } from "../lib/abi/pool";
import { eth, LIFECYCLE, pct, short, utc } from "../lib/format";
import { useDeployment } from "../Providers";
import { TxButton, TxStatus, useTx } from "../components/Tx";

function parseAmount(text: string): bigint | undefined {
  try {
    const v = text.trim() ? parseEther(text.trim()) : undefined;
    return v && v > 0n ? v : undefined;
  } catch {
    return undefined;
  }
}

export default function Deposit() {
  const dep = useDeployment();
  const { address } = useAccount();
  const depositTx = useTx();
  const withdrawTx = useTx();
  const claimsTx = useTx();
  const [amount, setAmount] = useState("");
  const [shareText, setShareText] = useState("");
  const chainId = dep.chainId;
  const lens = { chainId, address: dep.lens, abi: lensAbi } as const;

  const read = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...lens, functionName: "position", args: [address ?? zeroAddress] },
      { ...lens, functionName: "nav" },
      { ...lens, functionName: "sharePrice" },
      { ...lens, functionName: "claims" },
      { ...lens, functionName: "parameters" },
      { chainId, address: dep.pool, abi: poolAbi, functionName: "totalShares" },
    ],
    query: { refetchInterval: 12_000 },
  });

  if (read.isLoading) return <p className="note">Reading the pool.</p>;
  if (!read.data) return <p className="error">{read.error?.message ?? "No data."}</p>;
  const [position, nav, sharePrice, claims, params, totalShares] = read.data;

  const { baseBps, slopeBps, capBps, referenceWei } = params.curve;
  const entryBps = BigInt(Math.min(Number(capBps), Number(baseBps) + Number((BigInt(slopeBps) * nav) / referenceWei)));
  const value = parseAmount(amount);
  const contribution = value ? (value * entryBps) / 10_000n : 0n;
  const newShares = value ? (totalShares === 0n ? value - contribution : ((value - contribution) * totalShares) / nav) : 0n;

  const shares = parseAmount(shareText);
  const claimValue = shares && totalShares > 0n ? (shares * nav) / totalShares : 0n;

  const depositOpen = params.lifecycle < 2 && !params.depositsPaused && nav < params.navCap;

  return (
    <>
      <section>
        <h1>Deposit</h1>
        <dl className="kv">
          <dt>Lifecycle</dt>
          <dd>{LIFECYCLE[params.lifecycle]}</dd>
          <dt>Ordinary NAV</dt>
          <dd>{eth(nav, 6)} ETH</dd>
          <dt>NAV cap</dt>
          <dd>{eth(params.navCap)} ETH</dd>
          <dt>Share price</dt>
          <dd>{eth(sharePrice, 6)} ETH</dd>
          <dt>Total shares</dt>
          <dd>{formatEther(totalShares)}</dd>
          <dt>Entry contribution rate</dt>
          <dd>{pct(entryBps)}</dd>
          <dt>Deposits</dt>
          <dd>{params.depositsPaused ? "Paused" : depositOpen ? "Open" : "Closed"}</dd>
        </dl>
        <div className="row">
          <input value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="ETH to deposit" inputMode="decimal" aria-label="Deposit amount in ETH" />
          <TxButton
            tx={depositTx}
            label="Deposit"
            disabled={!value || !depositOpen}
            onClick={() =>
              void depositTx.run(() =>
                depositTx.write({ address: dep.pool, abi: poolAbi, functionName: "deposit", value: value!, chainId }),
              )
            }
          />
        </div>
        {value && (
          <p className="note">
            Contribution {eth(contribution, 6)} ETH to the GRAIL buckets. Estimated shares {formatEther(newShares)}.
          </p>
        )}
        <TxStatus tx={depositTx} />
      </section>

      <section>
        <h2>Position</h2>
        <dl className="kv">
          <dt>Shares</dt>
          <dd>{formatEther(position.shares)}</dd>
          <dt>Value at NAV</dt>
          <dd>{eth(position.valueWei, 6)} ETH</dd>
        </dl>
        <div className="row">
          <input value={shareText} onChange={(e) => setShareText(e.target.value)} placeholder="Shares to withdraw" inputMode="decimal" aria-label="Shares to withdraw" />
          <button type="button" className="btn outline" onClick={() => setShareText(formatEther(position.shares))}>
            Max
          </button>
          <TxButton
            tx={withdrawTx}
            label="Withdraw"
            disabled={!shares || shares > position.shares}
            onClick={() =>
              void withdrawTx.run(() =>
                withdrawTx.write({ address: dep.pool, abi: poolAbi, functionName: "withdraw", args: [shares!], chainId }),
              )
            }
          />
        </div>
        {shares && <p className="note">Claim at NAV {eth(claimValue, 6)} ETH. Cash pays first; the remainder joins the claims queue.</p>}
        <TxStatus tx={withdrawTx} />
      </section>

      <section>
        <h2>Claims queue</h2>
        <dl className="kv">
          <dt>Unpaid</dt>
          <dd>{eth(claims.unpaidTotal, 6)} ETH</dd>
          <dt>Cash</dt>
          <dd>{eth(claims.cash, 6)} ETH</dd>
          <dt>Queue head</dt>
          <dd>{claims.head.toString()}</dd>
        </dl>
        {claims.queue.length > 0 && (
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>Holder</th>
                <th>Amount</th>
                <th>Requested</th>
              </tr>
            </thead>
            <tbody>
              {claims.queue.map((c, i) => (
                <tr key={i} className={c.to.toLowerCase() === address?.toLowerCase() ? "mine" : undefined}>
                  <td>{(claims.head + BigInt(i)).toString()}</td>
                  <td>{short(c.to)}</td>
                  <td>{eth(c.amount, 6)} ETH</td>
                  <td>{utc(c.requestedAt)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <div className="row">
          <TxButton
            tx={claimsTx}
            label="Pay claims"
            onClick={() => void claimsTx.run(() => claimsTx.write({ address: dep.pool, abi: poolAbi, functionName: "payClaims", chainId }))}
          />
        </div>
        <TxStatus tx={claimsTx} />
      </section>
    </>
  );
}
