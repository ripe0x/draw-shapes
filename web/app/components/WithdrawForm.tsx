"use client";

import { useState } from "react";
import { parseEther } from "viem";
import { useAccount } from "wagmi";
import { poolAbi } from "../lib/abi/pool";
import { usePool } from "../lib/pool";
import { useDeployment } from "../Providers";
import { Eth } from "./Measure";
import { TxButton, TxLine, useTx } from "./Tx";

/** Wei as an editable ETH string, at most 6 fraction digits. */
const ethInput = (wei: bigint) => (Number(wei) / 1e18).toFixed(6).replace(/\.?0+$/, "");

/** Burns shares for a claim at ordinary NAV. The pool pays min(claim, cash) at once and queues the rest. */
export function WithdrawForm() {
  const dep = useDeployment();
  const { address } = useAccount();
  const pool = usePool().data;
  const tx = useTx();
  // Text the holder typed or dragged to; undefined selects the whole position.
  const [amountEth, setAmountEth] = useState<string | undefined>(undefined);
  // After a confirmed withdrawal the form returns to the whole remaining position.
  const [doneHash, setDoneHash] = useState<string>();
  if (tx.receipt.isSuccess && tx.hash && tx.hash !== doneHash) {
    setDoneHash(tx.hash);
    setAmountEth(undefined);
  }

  const heldShares = pool?.position.shares ?? 0n;
  const maxWei = pool?.position.valueWei ?? 0n;
  let amountWei = maxWei;
  let validAmount = true;
  if (amountEth !== undefined) {
    try {
      amountWei = parseEther(amountEth);
      validAmount = amountEth.trim() !== "" && amountWei > 0n;
    } catch {
      validAmount = false;
    }
  }
  const atMax = amountEth === undefined || (maxWei > 0n && amountWei >= maxWei);
  const requestedShares = !validAmount || maxWei === 0n ? 0n : atMax ? heldShares : (heldShares * amountWei) / maxWei;
  const claimWei = pool && pool.totalShares > 0n ? (requestedShares * pool.nav) / pool.totalShares : 0n;
  const cash = pool?.cash ?? 0n;
  const paidNow = claimWei < cash ? claimWei : cash;
  const sliderPermille = atMax || maxWei === 0n ? 1000 : Number((amountWei * 1000n) / maxWei);
  const onSlide = (permille: number) =>
    setAmountEth(permille >= 1000 ? undefined : ethInput((maxWei * BigInt(permille)) / 1000n));

  return (
    <div className="card withdraw-card">
      <div className="withdraw-card-head">
        <div>
          <h3>Withdraw</h3>
          <p>Cash pays first. The remainder joins the claims queue and is paid in request order.</p>
        </div>
        {claimWei > 0n && (
          <div className="withdraw-estimate">
            <span>Claim at NAV</span>
            <strong>
              <Eth wei={claimWei} />
            </strong>
          </div>
        )}
      </div>

      <div className="withdraw-request-grid">
        <div className="withdraw-amount">
          <label htmlFor="withdraw-amount-eth">Value at NAV to withdraw</label>
          <span className="withdraw-eth-input">
            <input
              id="withdraw-amount-eth"
              inputMode="decimal"
              value={amountEth ?? (maxWei > 0n ? ethInput(maxWei) : "")}
              onChange={(event) => setAmountEth(event.target.value)}
              aria-label="ETH to withdraw"
            />
            ETH
          </span>
          <input
            type="range"
            min={0}
            max={1000}
            step={1}
            value={sliderPermille}
            disabled={maxWei === 0n}
            onChange={(event) => onSlide(Number(event.target.value))}
            aria-label="Share of your position to withdraw"
          />
          {pool && maxWei === 0n && (
            <span className="withdraw-note">{address ? "This wallet holds no shares." : "Connect a wallet to see your shares."}</span>
          )}
        </div>
        <div className="withdraw-timing">
          <span>Pool cash</span>
          <strong>{pool ? <Eth wei={cash} /> : "-"}</strong>
          <span>Paid now from cash</span>
          <strong>
            <Eth wei={paidNow} />
          </strong>
          <span>Joins the claims queue</span>
          <strong>
            <Eth wei={claimWei - paidNow} />
          </strong>
        </div>
      </div>

      <div className="withdraw-primary">
        <TxButton
          tx={tx}
          label={address ? "Withdraw" : "Connect a wallet to withdraw"}
          disabled={requestedShares === 0n}
          onClick={() =>
            void tx.run(() =>
              tx.write({ address: dep.pool, abi: poolAbi, functionName: "withdraw", args: [requestedShares], chainId: dep.chainId }),
            )
          }
        />
      </div>
      <TxLine tx={tx} />
    </div>
  );
}
