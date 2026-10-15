"use client";

import Link from "next/link";
import type { ReactNode } from "react";
import { useAccount } from "wagmi";
import { feeSplitAbi, sponsoredPrizeAbi } from "../lib/abi/sponsor";
import { evmNowAddressUrl } from "../lib/errors";
import { oneInOf } from "../lib/foreign";
import { eth, short, utc } from "../lib/format";
import { drawOdds, usePool } from "../lib/pool";
import { type DealState, type SponsorDeal, useSponsorDeal } from "../lib/sponsor";
import type { SponsorRecord } from "../lib/sponsorRecord";
import { useDeployment } from "../Providers";
import { CollectionName, ForeignArt } from "./SponsoredPrizes";
import { type Tx, TxButton, TxLine, useTx } from "./Tx";

/** Contact for a prize offer. The owner replaces this text. */
const CONTACT = "[contact to be added]";

const same = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

function badgeText(deal: SponsorDeal | undefined, loading: boolean, listPrice?: bigint): string {
  if (!deal) return loading ? "Reading" : "Unavailable";
  const paid = `${eth(deal.paidWei, 4)} of ${eth(deal.capWei, 4)} ETH`;
  const text: Record<DealState, string> = {
    unstarted: "Agreed, not started",
    parked: `Parked, paid ${paid}`,
    hot: `Hot, price ${eth(listPrice ?? deal.parkedPriceWei, 4)} ETH`,
    captured: "Captured",
    held: "Token held, release pending",
    unlisted: "Unlisted, rescue pending",
    reclaimed: "Reclaimed",
    released: "Released",
    ended: "Ended",
  };
  return text[deal.state];
}

export function SponsorPage({ record }: { record?: SponsorRecord }) {
  const dep = useDeployment();
  const { address } = useAccount();
  const pool = usePool().data;
  const query = useSponsorDeal(record);
  const deal = query.data;

  const item = deal && pool ? pool.foreign.find((f) => f.listingId === deal.listingId && f.listingId !== 0n) : undefined;
  const listPrice = item && item.notional !== 0n ? item.notional : undefined;
  const odds = pool ? drawOdds(pool.board, pool.grail, pool.foreign) : undefined;
  const weight = odds?.rows.find((r) => item && r.key === `foreign-${item.listingId}`)?.weight ?? 0n;
  const badge = record ? badgeText(deal, query.isLoading, listPrice) : "No deal";

  return (
    <main className="sponsor-page">
      <section className="sponsor-hero">
        <span className="sponsor-kicker">One prize, one sponsor</span>
        <h1>Sponsor Draw Shapes</h1>
        <p>
          Lend a prize to the board. The pool lists your token, and you earn from the operator&apos;s Shapes mint fees up to the cap. Once the
          cap is paid, the prize goes hot on the board and its price falls with every settled pull.
        </p>
        <span className="sponsor-badge">{badge}</span>
      </section>

      {query.error && <p className="error-line">Could not read the deal: {query.error.message}</p>}

      {!record && (
        <div className="sponsor-band">
          <div>
            <h2>No deal yet</h2>
            <p>This deployment has no sponsored prize. A deal appears here once its record is published.</p>
          </div>
        </div>
      )}

      {record && deal && (
        <>
          <div className="sponsor-band">
            <div>
              <h2>
                <CollectionName collection={record.collection} /> #{record.tokenId}
              </h2>
              <dl className="sponsor-facts">
                <div><dt>List price</dt><dd>{listPrice !== undefined ? `${eth(listPrice, 4)} ETH` : deal.state === "unstarted" ? `${eth(deal.parkedPriceWei, 4)} ETH at start` : "-"}</dd></div>
                <div><dt>Odds per pull</dt><dd>{listPrice !== undefined ? oneInOf(weight, odds?.total ?? 0n) : "-"}</dd></div>
                <div><dt>Phase</dt><dd>{phaseText(deal)}</dd></div>
              </dl>
            </div>
            <div className="sponsor-band-art">
              <ForeignArt collection={record.collection} tokenId={BigInt(record.tokenId)} />
            </div>
          </div>

          <section className="sponsor-section">
            <div className="sponsor-label">Terms</div>
            <div className="sponsor-rows">
              <Row label="Parked price" value={`${eth(deal.parkedPriceWei, 4)} ETH`} />
              <Row label="Floor" value={`${eth(deal.floorWei, 4)} ETH`} />
              <Row label="Decay per pull" value={`${eth(deal.decayWeiPerPull, 6)} ETH per settled pull once hot`} />
              <Row label="Cap" value={`${eth(deal.capWei, 4)} ETH of mint fees`} />
              <Row label="Paid so far" value={`${eth(deal.paidWei, 4)} ETH`} strong />
              <Row label="Reclaim from" value={utc(deal.reclaimAfter)} />
              <Row label="Sponsor" value={<Addr address={deal.sponsor} chainId={dep.chainId} />} />
              <Row label="Operator" value={<Addr address={deal.owner} chainId={dep.chainId} />} />
              <Row label="Controller" value={<Addr address={record.prize} chainId={dep.chainId} />} />
              <Row label="Fee split" value={<Addr address={record.feeSplit} chainId={dep.chainId} />} />
            </div>
          </section>

          <section className="sponsor-section">
            <div className="sponsor-section-head">
              <div className="sponsor-label">Onchain status</div>
              <span className="sponsor-badge">{badge}</span>
            </div>
            <div className="sponsor-rows">
              <Row label="Pool" value={<Addr address={dep.pool} chainId={dep.chainId} />} />
              <Row label="Listing" value={listingText(deal, pool ? (item ? item.notional : null) : undefined)} />
              <Row
                label="Shapes fee recipient"
                value={same(deal.feeRecipient, record.feeSplit) ? "The fee split" : `Not the fee split (${short(deal.feeRecipient)})`}
                strong={!same(deal.feeRecipient, record.feeSplit)}
              />
              <Row label="Accrued in Shapes" value={`${eth(deal.feesOwedWei, 6)} ETH`} />
              <Row label="Fee split" value={deal.locked ? "Locked" : "Unlocked"} />
              <Row label="Token holder" value={holderText(deal, record.prize, dep.fwaPool)} />
              {deal.hot && <Row label="Price floor" value={deal.atFloor ? "Reached" : "Falling"} />}
              <Row label="Operator balance" value={`${eth(deal.ownerBalance, 6)} ETH`} />
              <Row label="Sponsor balance" value={`${eth(deal.sponsorBalance, 6)} ETH`} strong />
            </div>
          </section>

          <Actions record={record} deal={deal} account={address} />
        </>
      )}

      <section className="sponsor-section">
        <div className="sponsor-label">Lend your prize</div>
        <div className="sponsor-steps">
          <Step n="01">Agree the terms with the operator: list price, cap, floor, decay per pull and the reclaim date.</Step>
          <Step n="02">Hand the token to the pool admin.</Step>
          <Step n="03">The admin registers the token in the pool as a foreign listing.</Step>
          <Step n="04">The operator starts the deal. The fee split locks and payments begin.</Step>
        </div>
        <p className="sponsor-note">A permissionless offer, where a sponsor lists a token without the admin, is planned.</p>
        <p className="sponsor-note">Contact: {CONTACT}</p>
      </section>

      <section className="sponsor-section">
        <div className="sponsor-label">How it works</div>
        <div className="sponsor-steps">
          <Step n="01">The pool lists the token at the parked price. Each pull draws it with a chance set by that price.</Step>
          <Step n="02">The operator&apos;s Shapes mint fees go to the sponsor until the cap is paid. Withdrawals come from the fee split.</Step>
          <Step n="03">At the cap the token turns hot. Its price falls with every settled pull toward the floor and the sponsor has no further claim.</Step>
          <Step n="04">A pull that draws the token captures it. The ticket FWA pays for it goes to the GRAIL fund.</Step>
        </div>
      </section>

      <p className="sponsor-fine">
        A capture while the deal is parked ends the sponsor&apos;s payments at the amount paid. The token goes to the winner and the rest of the
        cap is left unpaid. After the reclaim date, while the token is unwon and the cap unpaid, the sponsor may reclaim it. The sponsor keeps
        what was paid, the rest of the cap is forfeited and mint fees return to the operator. Each withdrawal pays its caller. Anyone can advance
        the hot price. <Link href="/pull">See the live pool.</Link>
      </p>
    </main>
  );
}

function phaseText(d: SponsorDeal): string {
  if (d.state === "parked") return "Parked";
  if (d.state === "hot") return "Hot";
  if (d.state === "unstarted") return "Not started";
  return d.hot ? "Hot at the end" : "Parked at the end";
}

/** `notional` is undefined while the pool is unread and null when the pool lists no such entry. */
function listingText(d: SponsorDeal, notional?: bigint | null): string {
  if (d.listingId === 0n) return "Not registered";
  if (notional === undefined) return `#${d.listingId}`;
  if (notional === null) return `#${d.listingId} · not on the board`;
  return notional === 0n ? `#${d.listingId} · unlisted on FWA` : `#${d.listingId} · listed on FWA at ${eth(notional, 4)} ETH`;
}

function holderText(d: SponsorDeal, prize: string, fwaPool?: string): string {
  const h = d.tokenHolder;
  if (!h) return "Unknown";
  if (same(h, d.pool)) return "The pool";
  if (same(h, fwaPool)) return "The FWA pool";
  if (same(h, prize)) return "The prize contract";
  if (same(h, d.sponsor)) return "The sponsor";
  if (same(h, d.owner)) return "The operator";
  return short(h);
}

function Addr({ address, chainId }: { address: string; chainId: number }) {
  return (
    <a href={evmNowAddressUrl(address, chainId)} target="_blank" rel="noreferrer">
      {short(address)}
    </a>
  );
}

function Row({ label, value, strong = false }: { label: string; value: ReactNode; strong?: boolean }) {
  return (
    <div className="sponsor-row">
      <span>{label}</span>
      <b className={strong ? "is-strong" : ""}>{value}</b>
    </div>
  );
}

function Step({ n, children }: { n: string; children: ReactNode }) {
  return (
    <div className="sponsor-step">
      <span>{n}</span>
      <p>{children}</p>
    </div>
  );
}

/** Actions by the connected wallet's role: sponsor, operator (fee split owner) or neither. */
function Actions({ record, deal, account }: { record: SponsorRecord; deal: SponsorDeal; account?: `0x${string}` }) {
  const dep = useDeployment();
  const isSponsor = same(account, deal.sponsor);
  const isOwner = same(account, deal.owner);
  const balance = (isOwner ? deal.ownerBalance : 0n) + (isSponsor ? deal.sponsorBalance : 0n);
  const held = deal.state === "held";
  const parked = deal.state === "parked";
  const reclaimable = parked && deal.chainNow >= deal.reclaimAfter;
  const prize = { address: record.prize, abi: sponsoredPrizeAbi, chainId: dep.chainId } as const;
  const split = { address: record.feeSplit, abi: feeSplitAbi, chainId: dep.chainId } as const;
  const showRelease = isSponsor || (isOwner && deal.hot);
  const canAdvance = deal.state === "hot" && !deal.atFloor;

  return (
    <section className="sponsor-section">
      <div className="sponsor-label">Actions</div>
      {!isSponsor && !isOwner && (
        <p className="sponsor-note">
          {account ? "This wallet is neither the sponsor nor the operator." : "Connect the sponsor or operator wallet to reclaim, release or withdraw."}
        </p>
      )}
      <div className="sponsor-actions">
        {(isSponsor || isOwner) && (
          <Action
            label="Fee split balance"
            big={`${eth(balance, 6)} ETH`}
            button="Withdraw"
            disabled={balance === 0n}
            send={(tx) => tx.write({ ...split, functionName: "withdraw" })}
            note={isOwner && isSponsor ? "Pays the operator and sponsor balances to this wallet." : "Pays this wallet's balance in the fee split."}
          />
        )}
        {isSponsor && (
          <Action
            label="Reclaim"
            big={parked ? (reclaimable ? "Ready" : `From ${utc(deal.reclaimAfter)}`) : "Parked only"}
            button="Reclaim token"
            disabled={!reclaimable}
            send={(tx) => tx.write({ ...prize, functionName: "reclaim" })}
            note="Returns the token to the sponsor. Payments end at the amount paid and the rest of the cap is forfeited."
          />
        )}
        {showRelease && (
          <Action
            label="Release held"
            big={held ? "Ready" : "Nothing held"}
            button="Release held"
            disabled={!held}
            send={(tx) => tx.write({ ...prize, functionName: "releaseHeld" })}
            note="Sends a token held by the prize contract to the sponsor while parked and to the operator once hot."
          />
        )}
      </div>
      {canAdvance && (
        <div className="sponsor-advance">
          <Action
            label="Advance price"
            button="Advance price"
            send={(tx) => tx.write({ ...prize, functionName: "tick" })}
            note="Anyone can call this. The pool accepts one reprice per rotate interval, so a call inside the interval leaves the price unchanged."
          />
        </div>
      )}
    </section>
  );
}

function Action({
  label,
  big,
  button,
  disabled,
  send,
  note,
}: {
  label: string;
  big?: string;
  button: string;
  disabled?: boolean;
  send: (tx: Tx) => Promise<`0x${string}`>;
  note: string;
}) {
  const tx = useTx();
  return (
    <div>
      <div className="sponsor-label">{label}</div>
      {big && <div className="sponsor-big">{big}</div>}
      <TxButton tx={tx} label={button} className="sponsor-pill sponsor-pill-small" disabled={disabled} onClick={() => void tx.run(() => send(tx))} />
      <p className="sponsor-note">{note}</p>
      <TxLine tx={tx} />
    </div>
  );
}
