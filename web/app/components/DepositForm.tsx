"use client";

import { useState } from "react";
import { parseEther } from "viem";
import { useAccount, useBalance } from "wagmi";
import { poolAbi } from "../lib/abi/pool";
import { eth, utc } from "../lib/format";
import { usePool, type PoolData } from "../lib/pool";
import { useDeployment } from "../Providers";
import { Kv, percent, shares } from "./Measure";
import { TxButton, TxLine, useTx } from "./Tx";

/** A positive ETH amount from user text, or undefined when the text is empty, zero or malformed. */
export function parseEthInput(text: string): bigint | undefined {
  try {
    const v = text.trim() ? parseEther(text.trim()) : undefined;
    return v && v > 0n ? v : undefined;
  } catch {
    return undefined;
  }
}

/** Why `deposit()` reverts at the current state, or undefined when deposits are open. */
function closedReason(pool: PoolData): string | undefined {
  const { lifecycle, depositsPaused } = pool.params;
  const { depositsOpenAt, navCap } = pool.admission;
  if (lifecycle === 2) return "Closed, the pool is exiting";
  if (lifecycle === 3) return "Closed, the pool has exported";
  if (depositsPaused) return "Paused by the admin";
  // `admission.open` is computed on chain, so the founder window is judged by chain time.
  if (lifecycle === 1 && !pool.admission.open && pool.nav < navCap) {
    return `Deposits open ${utc(depositsOpenAt)}`;
  }
  if (pool.nav >= navCap) return "Closed, ordinary NAV has reached the NAV cap";
  if (pool.totalShares > 0n && pool.nav === 0n) return "Closed, ordinary NAV is zero";
  return undefined;
}

/** ETH deposit into the pool: entry contribution and share estimate at current ordinary NAV. */
export function DepositForm() {
  const dep = useDeployment();
  const { address } = useAccount();
  const balance = useBalance({ address, chainId: dep.chainId, query: { enabled: Boolean(address) } });
  const pool = usePool().data;
  const tx = useTx();
  const [amount, setAmount] = useState("");

  const value = parseEthInput(amount);
  const closed = pool ? closedReason(pool) : undefined;
  const rateBps = pool ? pool.admission.contributionBps : 0n;
  const contribution = value ? (value * rateBps) / 10_000n : 0n;
  const net = value ? value - contribution : 0n;
  const newShares = !pool || !value ? 0n : pool.totalShares === 0n ? net : pool.nav > 0n ? (net * pool.totalShares) / pool.nav : 0n;
  const overBalance = value !== undefined && balance.data !== undefined && value > balance.data.value;

  return (
    <div className="card deposit-action-card">
      <h3 className="vault-h2">Add capital</h3>
      <p className="vault-note">
        Shares are priced at ordinary NAV when the transaction lands. Shares are nontransferable and redeem through a
        withdrawal.
      </p>
      {pool ? (
        <>
          <div className="deposit-pending-total" aria-label="Deposit state">
            <span>Deposits</span>
            <strong>{closed ?? "Open"}</strong>
            <small>
              Ordinary NAV {eth(pool.nav, 2)} ETH, NAV cap {eth(pool.admission.navCap, 2)} ETH, room{" "}
              {eth(pool.admission.headroom, 2)} ETH
            </small>
          </div>
          <div className="field deposit-amount-field">
            <div className="deposit-amount-label">
              <span>ETH amount</span>
              <span>{balance.data ? `Balance ${eth(balance.data.value)} ETH` : ""}</span>
            </div>
            <div className="deposit-amount-input">
              <input
                type="text"
                inputMode="decimal"
                placeholder="0.00"
                aria-label="Deposit amount in ETH"
                value={amount}
                onChange={(event) => setAmount(event.target.value)}
              />
              <span>ETH</span>
            </div>
            <Kv label="Entry contribution, share of the deposit" value={percent(rateBps, 2)} />
            <Kv
              label="Entry contribution target"
              value={`${pool.params.paybackDays} days of depositor yield, ${percent(pool.params.floorBps, 2)} to ${percent(pool.params.capBps, 2)}`}
            />
            {value && (
              <>
                <Kv label="Entry contribution, goes to the GRAIL fund" value={`${eth(contribution, 6)} ETH`} />
                <Kv label="Value at NAV after the contribution" value={`${eth(net, 6)} ETH`} />
                <Kv label="Estimated shares" value={shares(newShares, 6)} strong />
              </>
            )}
            {overBalance && <p className="error-line">The amount is above the wallet balance.</p>}
            <TxButton
              tx={tx}
              className="btn-filled deposit-submit"
              label={!address ? "Connect a wallet to deposit" : closed ? "Deposits are closed" : "Deposit"}
              disabled={!value || !!closed || overBalance}
              onClick={() =>
                void tx.run(() =>
                  tx.write({ address: dep.pool, abi: poolAbi, functionName: "deposit", value: value!, chainId: dep.chainId }),
                )
              }
            />
          </div>
          <TxLine tx={tx} />
        </>
      ) : (
        <p className="vault-note">Reading the pool.</p>
      )}
    </div>
  );
}
