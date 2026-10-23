"use client";

import { useState } from "react";
import { useAccount, useBalance } from "wagmi";
import { roundAbi } from "../lib/abi/round";
import { duration, eth, parseEthInput, pct, utc } from "../lib/format";
import { ROUND_STATE, useChainTime, useRound } from "../lib/engine";
import { useDeployment } from "../Providers";
import { Eth, Kv, Stat } from "../components/Measure";
import { TxButton, TxLine, useTx } from "../components/Tx";

/** Plain-language explanation of each FoundingRound state. */
const STATE_NOTE: Record<number, string> = {
  0: "Open: contributions are accepted until the funding deadline, up to the target. If the target is not met by the deadline, every contributor can take their ETH back.",
  1: "Funded: the target is met. The treasury releases the escrow and starts the game within the launch window. If it does not, the round refunds.",
  2: "Released: the escrow has funded the game. Founder payments are credited here as they come in; claim yours below.",
  3: "Refunding: the round did not fund or launch in time, or was cancelled. Take your whole contribution back.",
};

/** A chain-time countdown to `at`, or "passed". */
function Countdown({ at, now }: { at: number; now: number | undefined }) {
  if (!now) return <>-</>;
  const left = at - now;
  return <>{left <= 0 ? "passed" : duration(left)}</>;
}

function Contribute() {
  const dep = useDeployment();
  const { address } = useAccount();
  const round = useRound().data;
  const balance = useBalance({ address, chainId: dep.chainId, query: { enabled: !!address } });
  const tx = useTx();
  const [amount, setAmount] = useState("");
  if (!round) return null;

  const value = parseEthInput(amount);
  const room = round.target > round.totalContributed ? round.target - round.totalContributed : 0n;
  const accepted = value ? (value < room ? value : room) : 0n;
  const belowMin = accepted > 0n && accepted < round.minContribution && accepted !== room;
  const over = value !== undefined && balance.data !== undefined && value > balance.data.value;
  const open = round.state === 0 && room > 0n;

  return (
    <div className="card">
      <h3 className="vault-h2">Contribute</h3>
      <p className="vault-note">
        The minimum is {eth(round.minContribution)} ETH, except the last contribution that fills the round. ETH above the
        room left is returned in the same transaction.
      </p>
      <div className="field-row">
        <input
          type="text"
          inputMode="decimal"
          placeholder="0.00"
          aria-label="Contribution amount in ETH"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
        />
        <span>ETH</span>
      </div>
      {value && (
        <>
          <Kv label="Accepted" value={<Eth wei={accepted} digits={5} />} />
          {value > accepted && <Kv label="Returned" value={<Eth wei={value - accepted} digits={5} />} />}
        </>
      )}
      {belowMin && <p className="error-line">Below the {eth(round.minContribution)} ETH minimum.</p>}
      {over && <p className="error-line">The amount is above the wallet balance.</p>}
      <TxButton
        tx={tx}
        label={!open ? "Contributions are closed" : "Contribute"}
        disabled={!open || !value || belowMin || over}
        onClick={() =>
          void tx.run(() =>
            tx.write({ address: dep.round!, abi: roundAbi, functionName: "contribute", value: value!, chainId: dep.chainId }),
          )
        }
      />
      <TxLine tx={tx} />
    </div>
  );
}

function MyStandingBeforeRelease() {
  const round = useRound().data;
  const refundTx = useTx();
  const dep = useDeployment();
  if (!round) return null;
  return (
    <div className="card">
      <h3 className="vault-h2">Your contribution</h3>
      <Kv label="Contributed" value={<Eth wei={round.myContribution} digits={5} />} strong />
      {round.state === 3 && (
        <>
          <p className="vault-note">The round is refunding. Take your whole contribution back.</p>
          <TxButton
            tx={refundTx}
            label="Refund"
            disabled={round.myContribution === 0n}
            onClick={() =>
              void refundTx.run(() =>
                refundTx.write({ address: dep.round!, abi: roundAbi, functionName: "refund", chainId: dep.chainId }),
              )
            }
          />
          <TxLine tx={refundTx} />
        </>
      )}
    </div>
  );
}

function MyStandingAfterRelease() {
  const round = useRound().data;
  const claimTx = useTx();
  const dep = useDeployment();
  if (!round) return null;
  return (
    <div className="card">
      <h3 className="vault-h2">Your entitlement</h3>
      <Kv label="Contributed" value={<Eth wei={round.myContribution} digits={5} />} />
      <Kv label="Credited so far" value={<Eth wei={round.myCredited} digits={5} />} />
      <Kv label="Claimed" value={<Eth wei={round.myClaimed} digits={5} />} />
      <Kv label="Claimable now" value={<Eth wei={round.myClaimable} digits={5} />} strong />
      <TxButton
        tx={claimTx}
        label="Claim"
        disabled={round.myClaimable === 0n}
        onClick={() =>
          void claimTx.run(() => claimTx.write({ address: dep.round!, abi: roundAbi, functionName: "claim", chainId: dep.chainId }))
        }
      />
      <TxLine tx={claimTx} />
    </div>
  );
}

function Terms({ capBps }: { capBps: number }) {
  const cap = (capBps / 10_000).toLocaleString("en-US", { maximumFractionDigits: 2 });
  return (
    <details className="vault-note">
      <summary>Terms and risks</summary>
      <ul className="disclosures">
        <li>
          Founders are credited up to a {cap}x ceiling on their contribution ({pct(capBps)} of each contributed wei). This
          is a cap on cumulative payments, not a promise of them.
        </li>
        <li>Payments come only from 65% of net coin-trading receipts and 50% of game earnings, and only while founders are owed.</li>
        <li>Principal is returned only in a wind-down, after player obligations are met. There is no guarantee the cap, or even the principal, is ever reached.</li>
        <li>No token is allocated to contributors. The entitlement is a claim on the two cash flows above, nothing else.</li>
        <li>GRAIL capital seeded from the round can be won by players and is then gone; only an unwon GRAIL fund returns to founders in a wind-down.</li>
        <li>The legal status of this entitlement is unresolved and may be an investment contract in some jurisdictions. It is not investment advice.</li>
      </ul>
    </details>
  );
}

/** `/fund`: the FoundingRound before release (target, committed, countdowns, contribute, refund) and
 *  after release (entitlement, distributed, claim). Countdowns use chain time, not the wall clock. */
export default function FundPage() {
  const dep = useDeployment();
  const round = useRound().data;
  const now = useChainTime().data;

  if (!dep.round) {
    return (
      <main className="vault-page">
        <section className="vault-hero">
          <h1 className="vault-headline">Fund</h1>
          <p className="vault-lede">No founding round is configured for this deployment.</p>
        </section>
      </main>
    );
  }

  const released = round ? round.state >= 2 : false;
  const remaining = round && round.target > round.totalContributed ? round.target - round.totalContributed : 0n;

  return (
    <main className="vault-page">
      <section className="vault-hero">
        <h1 className="vault-headline">Fund the engine</h1>
        <p className="vault-lede">
          Founders fund a conditional escrow that becomes the game&apos;s opening bankroll. {round ? STATE_NOTE[round.state] : "Reading the round."}
        </p>
      </section>

      {!round ? (
        <p className="vault-note">Reading the round.</p>
      ) : (
        <>
          <div className="stat-grid">
            <Stat label="State" value={ROUND_STATE[round.state]} />
            <Stat label="Target" value={<Eth wei={round.target} digits={2} />} sub="Hard cap" />
            <Stat
              label="Committed"
              value={<Eth wei={round.totalContributed} digits={2} />}
              sub={`${pct(round.target === 0n ? 0n : (round.totalContributed * 10_000n) / round.target)} of target`}
            />
            <Stat label="Remaining" value={<Eth wei={remaining} digits={2} />} />
          </div>

          {!released && (
            <div className="stat-grid">
              <Stat label="Funding deadline" value={<Countdown at={round.deadline} now={now} />} sub={utc(round.deadline)} />
              <Stat label="Launch deadline" value={<Countdown at={round.launchDeadline} now={now} />} sub={utc(round.launchDeadline)} />
              <Stat label="Your contribution" value={<Eth wei={round.myContribution} digits={4} />} />
            </div>
          )}

          <section className="vault-section two-col">
            {released ? <MyStandingAfterRelease /> : <Contribute />}
            {released ? (
              <div className="card">
                <h3 className="vault-h2">Distribution</h3>
                <Kv label="Entitlement ceiling" value={<Eth wei={round.entitlement} digits={4} />} />
                <Kv label="Total distributed" value={<Eth wei={round.totalDistributed} digits={4} />} />
                <Kv label="Remaining to the cap" value={<Eth wei={round.remaining} digits={4} />} strong />
              </div>
            ) : (
              <MyStandingBeforeRelease />
            )}
          </section>

          <section className="vault-section">
            <Terms capBps={round.capBps} />
          </section>
        </>
      )}
    </main>
  );
}
