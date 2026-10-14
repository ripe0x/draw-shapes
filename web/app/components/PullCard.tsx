"use client";

import { useState } from "react";
import { useAccount, useBalance, usePublicClient } from "wagmi";
import { poolAbi } from "../lib/abi/pool";
import { formatTxError } from "../lib/errors";
import { eth } from "../lib/format";
import { estimateGas, feeCaps, MAX_COUNT, neededWei, pullState, readFresh, useQuote, usePool } from "../lib/pool";
import { usePulls } from "../lib/pulls";
import { useDeployment } from "../Providers";
import { Eth } from "./Measure";
import { PullBatchView, SealedPacks } from "./PullReveal";
import { TxLine, useTx } from "./Tx";

/**
 * The pull card: pool state, batch size, price and the pull button, then the batch it sent in place
 * of the button. `variant` picks the hero or panel chrome; state, copy and behavior match on both.
 */
export function PullCard({
  variant,
  count: countProp,
  onCount,
}: {
  variant: "hero" | "panel";
  /** Batch size held by the parent, so a sibling price panel reads the same quote. */
  count?: number;
  onCount?: (n: number) => void;
}) {
  const dep = useDeployment();
  const { address, chainId: walletChain } = useAccount();
  const client = usePublicClient({ chainId: dep.chainId });
  const pool = usePool().data;
  const tx = useTx();
  const pulls = usePulls();
  const [ownCount, setOwnCount] = useState(1);
  const count = countProp ?? ownCount;
  const setCount = onCount ?? setOwnCount;
  const quote = useQuote(count);
  const q = quote.data;
  const balance = useBalance({ address, chainId: dep.chainId, query: { refetchInterval: 12_000 } });
  const [shown, setShown] = useState<`0x${string}`>();

  const maxCount = pool ? Math.min(MAX_COUNT, Number(pool.params.maxBatch) || 1) : 1;
  const counts = Array.from({ length: maxCount }, (_, i) => i + 1);
  const state = pool ? pullState(pool, dep.pool) : undefined;

  function pull() {
    return tx.run(async () => {
      const f = await readFresh(client, dep, count);
      const req = {
        address: dep.pool,
        abi: poolAbi,
        functionName: "acquireBatch",
        args: [address!, BigInt(count), f.maxFee, 0n, f.slippage, f.version, f.deadline],
        value: f.value,
      } as const;
      // The VRF fee scales with the transaction's gas price, so the quoted price caps the wallet's
      // fee; the sent value then covers it and FWA refunds the excess.
      const caps = feeCaps(f.q.gasPrice);
      const gas = await estimateGas(() => client!.estimateContractGas({ ...req, account: address!, ...caps }));
      const hash = await tx.write({ ...req, chainId: dep.chainId, ...caps, ...gas });
      setShown(hash);
      return hash;
    });
  }

  function again() {
    tx.reset();
    setShown(undefined);
  }

  const cardClass = variant === "hero" ? "pull-card pull-card-hero" : "pull-card pull-card-panel";
  const batch = shown ? pulls.data?.batches.find((b) => b.tx === shown) : undefined;

  // A sent pull: sealed cards until its `Pulled` log is read, then its cards.
  if (shown || (tx.pending && !tx.error)) {
    // wagmi reports a reverted receipt as an error carrying the revert reason.
    const reverted = tx.receipt.isError || tx.receipt.data?.status === "reverted";
    return (
      <div className={cardClass}>
        <h3 className="vault-h2">Your pull{count > 1 ? "s" : ""}</h3>
        {reverted ? (
          <div className="pack pack-broken">
            <p className="pack-title">The pull reverted</p>
            <p className="vault-note">The sent ETH stayed in the wallet. The gas is spent.</p>
          </div>
        ) : batch && pulls.data ? (
          <PullBatchView batch={batch} cards={pulls.data.cards} fresh={new Set(pulls.data.fresh)} />
        ) : (
          <SealedPacks count={count} sent={!!tx.hash} />
        )}
        <TxLine tx={tx} />
        {(batch || reverted) && (
          <div className="pack-again">
            <button type="button" className="landing-pull-btn" onClick={again}>
              <span>{reverted ? "Try again" : "Pull again"}</span>
              <span aria-hidden>→</span>
            </button>
          </div>
        )}
      </div>
    );
  }

  const wrongNetwork = !!address && walletChain !== undefined && walletChain !== dep.chainId;
  const need = q ? neededWei(q) : 0n;
  const short = !!address && !wrongNetwork && !!balance.data && !!q && balance.data.value < need;

  let label: string;
  let disabled = true;
  if (!state) label = "Reading the pool";
  else if (!state.open) label = state.headline;
  else if (!q) label = "Pricing this batch";
  else if (!q.purchasable) label = "This batch size is unavailable";
  else if (!address) label = "Connect a wallet to pull";
  else if (short) label = "Not enough ETH";
  else {
    label = `Pull ${count} for ${eth(q.total, 5)} ETH`;
    disabled = false;
  }

  return (
    <div className={cardClass}>
      {state && (
        <>
          {!state.open && (
            <div className="pull-status-row">
              <span className={`landing-pill is-${state.tone}`}>
                <span className="landing-pill-dot" />
                {state.pill}
              </span>
            </div>
          )}
          <div className="pull-status-headline">{state.headline}</div>
          {state.sub && <div className="pull-status-sub">{state.sub}</div>}
        </>
      )}

      {variant === "panel" && q && state?.open && (
        <div className="pull-price">
          <p className="vault-note">
            <strong>{eth(q.total, 5)} ETH</strong> for {count} {count === 1 ? "pull" : "pulls"}: a <Eth wei={q.fee} digits={5} /> ticket plus a{" "}
            <Eth wei={q.vrf} digits={5} /> VRF fee per pull, quoted at {(Number(q.gasPrice) / 1e9).toFixed(2)} gwei. The wallet sends 10% more and
            FWA refunds the excess in the same transaction.
          </p>
        </div>
      )}

      {state?.open && counts.length > 1 && (
        <div className="pull-quantity" role="group" aria-label="Number of pulls">
          <span className="pull-quantity-label">How many pulls?</span>
          <div className="pull-quantity-options">
            {counts.map((n) => (
              <button key={n} type="button" className={count === n ? "is-selected" : undefined} aria-pressed={count === n} onClick={() => setCount(n)}>
                {n}
              </button>
            ))}
          </div>
        </div>
      )}

      <div className="pull-cta">
        <button
          type="button"
          className={variant === "hero" ? "landing-pull-btn" : "btn-filled"}
          disabled={disabled || tx.pending}
          onClick={() => void pull()}
        >
          <span>{tx.pending ? "Confirm in your wallet" : label}</span>
          {variant === "hero" && <span aria-hidden>→</span>}
        </button>
      </div>
      {short && q && (
        <p className="pull-status-footer">
          The wallet holds {eth(balance.data!.value)} ETH. This pull needs about {eth(need)} ETH with gas.
        </p>
      )}
      {wrongNetwork && <p className="pull-status-footer">The wallet switches to the pool&apos;s network when you pull.</p>}
      {quote.error && <p className="error-line">The quote failed: {formatTxError(quote.error)}</p>}
      <TxLine tx={tx} />
    </div>
  );
}
