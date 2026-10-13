"use client";

import { useReadContracts } from "wagmi";
import { formatEther } from "viem";
import { lensAbi } from "../lib/abi/lens";
import { poolAbi } from "../lib/abi/pool";
import { evmNowAddressUrl } from "../lib/errors";
import { eth, LIFECYCLE, oddsOneIn, pct, ROTATE_TRIGGER, SETTLE_TRIGGER, short, utc } from "../lib/format";
import { useDeployment } from "../Providers";
import { TxButton, TxStatus, useTx } from "../components/Tx";

const WEI_KEYS = new Set(["navCap", "tipWei", "referenceWei"]);
const TIME_KEYS = new Set(["lastRotateAt", "lastRefundAt", "openingDeadlineAt"]);

export default function Protocol() {
  const dep = useDeployment();
  const settleTx = useTx();
  const rotateTx = useTx();
  const claimsTx = useTx();
  const chainId = dep.chainId;
  const lens = { chainId, address: dep.lens, abi: lensAbi } as const;
  const pool = { chainId, address: dep.pool, abi: poolAbi } as const;

  const read = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...lens, functionName: "board" },
      { ...lens, functionName: "grail", args: [0] },
      { ...lens, functionName: "grail", args: [1] },
      { ...lens, functionName: "nav" },
      { ...lens, functionName: "sharePrice" },
      { ...lens, functionName: "parameters" },
      { ...lens, functionName: "settleDue" },
      { ...lens, functionName: "rotateDue" },
      { ...lens, functionName: "reopenStatus" },
      { ...pool, functionName: "cash" },
      { ...pool, functionName: "backing" },
      { ...pool, functionName: "receivable" },
      { ...pool, functionName: "claims" },
      { ...pool, functionName: "maintenance" },
      { ...pool, functionName: "maintenanceReceivable" },
      { ...pool, functionName: "totalShares" },
      { ...pool, functionName: "listedCount" },
      { ...pool, functionName: "heldCount" },
    ],
    query: { refetchInterval: 12_000 },
  });

  if (read.isLoading) return <p className="note">Reading the pool.</p>;
  if (!read.data) return <p className="error">{read.error?.message ?? "No data."}</p>;
  const [
    board,
    minor,
    major,
    nav,
    sharePrice,
    params,
    settleDue,
    rotateDue,
    reopen,
    cash,
    backing,
    receivable,
    claims,
    maintenance,
    maintenanceReceivable,
    totalShares,
    listedCount,
    heldCount,
  ] = read.data;

  const { feeSplit, curve, ...flat } = params;
  const paramRows = Object.entries({ ...flat, ...feeSplit, ...curve });
  const fmt = (key: string, v: unknown): React.ReactNode => {
    if (typeof v === "boolean") return v ? "yes" : "no";
    if (typeof v === "string")
      return (
        <a href={evmNowAddressUrl(v, chainId)} target="_blank" rel="noreferrer">
          {short(v)}
        </a>
      );
    if (key === "lifecycle") return LIFECYCLE[v as number];
    if (typeof v === "bigint") return WEI_KEYS.has(key) ? `${eth(v, 6)} ETH` : TIME_KEYS.has(key) ? utc(v) : v.toString();
    return String(v);
  };

  return (
    <>
      <section>
        <h1>Protocol</h1>
        <dl className="kv">
          <dt>Lifecycle</dt>
          <dd>{LIFECYCLE[params.lifecycle]}</dd>
          <dt>settleDue</dt>
          <dd>{SETTLE_TRIGGER[settleDue]}</dd>
          <dt>rotateDue</dt>
          <dd>{ROTATE_TRIGGER[rotateDue]}</dd>
          <dt>Next rotate after</dt>
          <dd>{utc(params.lastRotateAt + params.rotateInterval)}</dd>
          <dt>Listed / held items</dt>
          <dd>
            {listedCount.toString()} / {heldCount.toString()}
          </dd>
        </dl>
        <div className="row">
          <TxButton
            tx={settleTx}
            label="settle(20)"
            onClick={() => void settleTx.run(() => settleTx.write({ ...pool, functionName: "settle", args: [20n] }))}
          />
          <TxButton
            tx={rotateTx}
            label="rotate()"
            onClick={() => void rotateTx.run(() => rotateTx.write({ ...pool, functionName: "rotate" }))}
          />
          <TxButton
            tx={claimsTx}
            label="payClaims()"
            onClick={() => void claimsTx.run(() => claimsTx.write({ ...pool, functionName: "payClaims" }))}
          />
        </div>
        <TxStatus tx={settleTx} />
        <TxStatus tx={rotateTx} />
        <TxStatus tx={claimsTx} />
      </section>

      <section>
        <h2>Pull guards</h2>
        <dl className="kv">
          <dt>Live</dt>
          <dd>{reopen.live ? "yes" : "no"}</dd>
          <dt>Pulls open</dt>
          <dd>{reopen.pullsOpen ? "yes" : "no"}</dd>
          <dt>Cooldown passed</dt>
          <dd>
            {reopen.cooldownPassed ? "yes" : "no"} (resumes {utc(reopen.purchasesResumeAt)})
          </dd>
          <dt>Solvent</dt>
          <dd>
            {reopen.solvent ? "yes" : "no"} (balance {eth(reopen.balance, 6)}, required {eth(reopen.required, 6)} ETH)
          </dd>
          <dt>Board deep</dt>
          <dd>
            {reopen.boardDeep ? "yes" : "no"} (listed {reopen.listedCount.toString()}, unsettled{" "}
            {reopen.unsettled.toString()} + concurrency {reopen.concurrency.toString()})
          </dd>
        </dl>
      </section>

      <section>
        <h2>Board</h2>
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Row</th>
                <th>Share</th>
                <th>Backing</th>
                <th>List price</th>
                <th>Items</th>
                <th>Listed</th>
                <th>Target</th>
              </tr>
            </thead>
            <tbody>
              {board.map((r, i) => (
                <tr key={i}>
                  <td>
                    {i}: {r.rungs.length > 1 ? `${r.rungs.length}-rung pack` : "Shape"}
                  </td>
                  <td>{pct(r.shareBps)}</td>
                  <td>{eth(r.backingWei)} ETH</td>
                  <td>{eth(r.listingPrice, 5)} ETH</td>
                  <td>{r.count.toString()}</td>
                  <td>{r.listed.toString()}</td>
                  <td>{r.target.toString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section>
        <h2>GRAIL tracks</h2>
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Track</th>
                <th>Backing</th>
                <th>Notional</th>
                <th>Target</th>
                <th>Bucket</th>
                <th>Receivable</th>
                <th>Pulls since list</th>
                <th>Listing</th>
                <th>Odds per pull</th>
              </tr>
            </thead>
            <tbody>
              {[minor, major].map((g, t) => (
                <tr key={t}>
                  <td>{t === 0 ? "Minor" : "Major"}</td>
                  <td>{eth(g.backing, 6)} ETH</td>
                  <td>{eth(g.notional, 6)} ETH</td>
                  <td>{eth(g.targetWei, 4)} ETH</td>
                  <td>{eth(g.bucket, 6)} ETH</td>
                  <td>{eth(g.receivable, 6)} ETH</td>
                  <td>{g.pullsSinceList.toString()}</td>
                  <td>{g.listingId === 0n ? "unlisted" : `#${g.listingId}`}</td>
                  <td>{oddsOneIn(g.weightBps)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section>
        <h2>Buckets and NAV</h2>
        <dl className="kv">
          <dt>cash</dt>
          <dd>{eth(cash, 6)} ETH</dd>
          <dt>backing</dt>
          <dd>{eth(backing, 6)} ETH</dd>
          <dt>receivable</dt>
          <dd>{eth(receivable, 6)} ETH</dd>
          <dt>claims</dt>
          <dd>-{eth(claims, 6)} ETH</dd>
          <dt>Ordinary NAV</dt>
          <dd className="strong">{eth(nav, 6)} ETH</dd>
          <dt>Share price</dt>
          <dd>
            {eth(sharePrice, 6)} ETH ({formatEther(totalShares)} shares)
          </dd>
          <dt>maintenance</dt>
          <dd>
            {eth(maintenance, 6)} ETH (receivable {eth(maintenanceReceivable, 6)})
          </dd>
          <dt>GRAIL buckets</dt>
          <dd>
            {eth(minor.bucket, 6)} minor, {eth(major.bucket, 6)} major ETH
          </dd>
        </dl>
      </section>

      <section>
        <h2>Parameters</h2>
        <dl className="kv">
          {paramRows.map(([key, v]) => (
            <div className="kv-pair" key={key}>
              <dt>{key}</dt>
              <dd>{fmt(key, v)}</dd>
            </div>
          ))}
        </dl>
      </section>
    </>
  );
}
