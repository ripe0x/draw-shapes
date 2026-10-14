"use client";

import { zeroAddress } from "viem";
import { evmNowAddressUrl } from "../lib/errors";
import { duration, eth, LIFECYCLE, pct, short, utc } from "../lib/format";
import { usePool } from "../lib/pool";
import { useDeployment } from "../Providers";
import { Kv } from "./Measure";

type Num = bigint | number;

/** Every field of `Lens.parameters`, in struct order, with the unit its value is shown in. */
export function ParamsDisclosure() {
  const dep = useDeployment();
  const p = usePool().data?.params;
  if (!p) return null;

  const address = (v: string) =>
    v === zeroAddress ? (
      "None"
    ) : (
      <a href={evmNowAddressUrl(v, dep.chainId)} target="_blank" rel="noreferrer">
        {short(v)}
      </a>
    );
  const yesNo = (v: boolean) => (v ? "yes" : "no");
  const wei = (v: bigint) => `${eth(v, 6)} ETH`;
  const bps = (v: Num) => pct(v);
  const secs = (v: Num) => duration(Number(v));
  const count = (v: Num) => v.toLocaleString("en-US");

  return (
    <details className="vault-note">
      <summary>Current parameters</summary>
      <Kv label="Shapes" value={address(p.shapes)} />
      <Kv label="Draw Packs" value={address(p.drawPacks)} />
      <Kv label="FWA factory" value={address(p.fwaFactory)} />
      <Kv label="FWA pool" value={address(p.fwaPool)} />
      <Kv label="Admin" value={address(p.admin)} />
      <Kv label="Predecessor pool" value={address(p.oldPool)} />
      <Kv label="Exit destination" value={address(p.exitDest)} />
      <Kv label="Lifecycle" value={LIFECYCLE[p.lifecycle]} />
      <Kv label="Pulls paused" value={yesNo(p.pullsPaused)} />
      <Kv label="Deposits paused" value={yesNo(p.depositsPaused)} />
      <Kv label="Depositor premium, of backing" value={bps(p.feeSplit.premiumBps)} />
      <Kv label="Maintenance, of backing" value={bps(p.feeSplit.maintenanceBps)} />
      <Kv label="GRAIL feed, of backing" value={bps(p.feeSplit.feedBps)} />
      <Kv label="Minor share of the feed" value={bps(p.feeSplit.minorShareBps)} />
      <Kv label="Entry fee floor" value={bps(p.floorBps)} />
      <Kv label="Entry fee cap" value={bps(p.capBps)} />
      <Kv label="Entry fee payback target (days of yield)" value={count(p.paybackDays)} />
      <Kv label="NAV cap floor" value={wei(p.navCapFloor)} />
      <Kv label="Turnover, daily fee volume over NAV" value={bps(p.turnoverBps)} />
      <Kv label="Founder window after open" value={secs(p.founderWindowSeconds)} />
      <Kv label="Rotate interval" value={secs(p.rotateInterval)} />
      <Kv label="Opening deadline length" value={secs(p.openingDeadline)} />
      <Kv label="Opening deadline at" value={utc(p.openingDeadlineAt)} />
      <Kv label="Board depth (items)" value={count(p.minItems)} />
      <Kv label="GRAIL probability cap" value={bps(p.grailProbCapBps)} />
      <Kv label="Settle batch minimum" value={count(p.batchMin)} />
      <Kv label="Settle batch max age" value={secs(p.batchMaxAge)} />
      <Kv label="Surprise chance" value={bps(p.surpriseBps)} />
      <Kv label="Restore factor" value={count(p.restoreK)} />
      <Kv label="Row band" value={bps(p.bandBps)} />
      <Kv label="Cash reserve of NAV" value={bps(p.reserveBps)} />
      <Kv label="Refund tip" value={wei(p.tipWei)} />
      <Kv label="List while paused" value={yesNo(p.listWhilePaused)} />
      <Kv label="Max batch" value={count(p.maxBatch)} />
      <Kv label="Concurrency" value={count(p.concurrency)} />
      <Kv label="Last rotate" value={utc(p.lastRotateAt)} />
      <Kv label="Last refund" value={utc(p.lastRefundAt)} />
    </details>
  );
}
