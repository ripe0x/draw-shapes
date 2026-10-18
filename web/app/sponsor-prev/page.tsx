"use client";

import { Suspense } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { SponsorPfpList } from "./SponsorPfpList";
import { SponsorWithdraw } from "./SponsorWithdraw";
import { SponsorRelease } from "./SponsorRelease";
import { SponsorTakenBand } from "./SponsorTakenBand";
import { SponsorCtaBand } from "./SponsorCtaBand";
import { ShapeArt } from "./ShapeArt";
import { bpsToPercent, durationDaysHours, eth, evmNowAddressUrl, short } from "./format";
import { CHAIN_ID, SHAPES_ADDRESS, ZERO, openStatus, takenStatus } from "./fixture";
import sampleShapes from "./shapes.json";
import "./prev.css";

const SAMPLE_SHAPE_SVG = Object.values(sampleShapes as Record<string, string>)[0];

/** Operator share of the ticket (ECO-20 launch default, operatorBps = 400). The sponsor rate is
 *  this times the live sponsor share. */
const OPERATOR_BPS = 400n;
const BPS = 10_000n;
/** Ticket floor (ECO-20 pullFloorWei). Used for the rate examples until a pool exists to quote. */
const PULL_FLOOR_WEI = 20_000_000_000_000_000n;

export default function SponsorPrevPage() {
  return (
    <Suspense>
      <PrevSponsor />
    </Suspense>
  );
}

function PrevSponsor() {
  const params = useSearchParams();
  const status = params.get("taken") === "1" ? takenStatus : openStatus;
  // ?wallet=1 shows the connected-wallet pass picker for the open state.
  const address = params.get("wallet") === "1" ? "0x0000000000000000000000000000000000000001" : undefined;
  const sponsorship = status.betaSponsorship;
  const hasSponsorship = !!sponsorship && sponsorship.depositor !== ZERO;
  const poolExists = !!status.fwaPool && status.fwaPool !== ZERO;
  const chainNow = status.chainTimestamp != null ? Number(status.chainTimestamp) : undefined;

  const shareBps = status.sponsorShareOfOperatorBps;
  const shareText = shareBps != null ? bpsToPercent(shareBps) : "...";
  const rateBps = shareBps != null ? (BigInt(shareBps) * OPERATOR_BPS) / BPS : undefined;
  // A pool with no open epoch quotes a zero ticket; treat that like no quote.
  const quotedTicketWei: bigint | undefined = undefined;
  const ticketWei = quotedTicketWei ?? PULL_FLOOR_WEI;
  const ticketPhrase = quotedTicketWei != null ? `about ${eth(quotedTicketWei)} ETH` : `at least ${eth(PULL_FLOOR_WEI)} ETH, the floor`;
  const perPullWei =
    ticketWei != null && shareBps != null ? (ticketWei * OPERATOR_BPS * BigInt(shareBps)) / (BPS * BPS) : undefined;

  const released = hasSponsorship && sponsorship!.released;
  const slotOpen = !hasSponsorship && !poolExists;
  const openingRemaining =
    status.poolOpeningTimestamp != null && chainNow != null
      ? Math.max(0, Number(status.poolOpeningTimestamp) - chainNow)
      : undefined;
  const inventoryWindowOpen = openingRemaining === 0;
  const openingCountdown = openingRemaining != null ? durationDaysHours(openingRemaining) : "...";
  const launchReady =
    inventoryWindowOpen &&
    status.factoryBetaAccess === true &&
    status.factoryPoolCreationEnabled === true &&
    status.pfpBetaActive === true;
  const betaRemaining =
    status.pfpBetaEndsAt != null && chainNow != null
      ? Math.max(0, Number(status.pfpBetaEndsAt) - chainNow)
      : undefined;
  const betaEndsDate =
    status.pfpBetaEndsAt != null ? new Date(Number(status.pfpBetaEndsAt) * 1000).toISOString().slice(0, 10) : "...";

  const badge = released
    ? "Released"
    : hasSponsorship && status.sponsorRewardsActive === false
      ? "Beta over"
      : hasSponsorship
        ? `Active · ${betaRemaining != null ? durationDaysHours(betaRemaining) : "..."} left`
        : slotOpen
          ? inventoryWindowOpen
            ? "Sponsor slot open"
            : `Inventory window · ${openingCountdown}`
          : "Pool already started";

  return (
    <div className="sponsor-prev">
      <div className="prev-banner">
        Temporary comparison: the previous FWAIR sponsor page with fixture data. Not wired to the chain.
      </div>
      <main className="sponsor-page">
        {hasSponsorship ? (
          <>
            <h1 className="sponsor-h1">{released ? "The pool is open. The pass is home." : "The pool is open."}</h1>
            <p className="sponsor-sub">
              FWAIR PFP #{sponsorship!.tokenId.toString()}, locked by {short(sponsorship!.depositor)}, created it. The
              sponsor takes {shareText} of the operator share on every pull until the FWAIR beta ends
              {released ? ", and the pass is back in their wallet." : ", then the pass comes back."}
            </p>
          </>
        ) : (
          <>
            <h1 className="sponsor-h1">Sponsor the pool</h1>
            <p className="sponsor-sub">
              Lock one FWAIR PFP into the Draw contract and initialize the custom pool. You take {shareText} of the
              operator share on every pull until the FWAIR beta ends, then the NFT is returned to you.
            </p>
          </>
        )}

        {status.error && <div className="error-box">Could not read sponsor state: {status.error.message}</div>}

        {slotOpen && address ? (
          <SponsorPfpList
            launchReady={launchReady}
            inventoryWindowOpen={inventoryWindowOpen}
            openingCountdown={openingCountdown}
          />
        ) : hasSponsorship ? (
          <SponsorTakenBand
            sponsor={sponsorship!.depositor}
            tokenId={sponsorship!.tokenId}
            state={
              released
                ? "returned to the sponsor"
                : status.sponsorRewardsActive === false
                  ? "beta over, release open to anyone"
                  : `locked · ${betaRemaining != null ? durationDaysHours(betaRemaining) : "..."} left`
            }
          />
        ) : slotOpen ? (
          <SponsorCtaBand />
        ) : (
          <div className="sponsor-band">
            <div className="sponsor-band-line">The pool was created without a sponsor, so the sponsor slot is closed.</div>
          </div>
        )}

        <section className="sponsor-section">
          <div className="sponsor-label">Terms</div>
          <div className="sponsor-rows">
            <Row label="Share" value={`${shareText} of the operator share`} />
            <Row label="Rate" value={rateBps != null ? `${bpsToPercent(Number(rateBps))} of every ticket` : "..."} />
            <Row label="Per pull" value={perPullWei != null ? `about ${eth(perPullWei, 6)} ETH` : "..."} />
            <Row label="Per 1,000 pulls" value={perPullWei != null ? `about ${eth(perPullWei * 1000n)} ETH` : "..."} strong />
            <Row
              label="Window"
              value={
                betaRemaining != null && betaRemaining > 0
                  ? `the FWAIR beta, ${durationDaysHours(betaRemaining)} left`
                  : "the FWAIR beta"
              }
            />
            <Row label="Slots" value="1 · first successful transaction" />
            <Row
              label="Launch opens"
              value={inventoryWindowOpen ? "Now" : `${openingCountdown} · after supplier deposits`}
            />
          </div>
          <div className="sponsor-note">
            A ticket is {ticketPhrase}. Beta volume is open, so pick the pull count you believe and multiply.
          </div>
        </section>

        <section className="sponsor-section">
          <div className="sponsor-label">The ask</div>
          <div className="sponsor-steps">
            <Step n="01">Approve the pass for the Draw contract.</Step>
            <Step n="02">Send one transaction that locks it and creates the FWA pool.</Step>
            <Step n="03">Withdraw earnings whenever you like.</Step>
            <Step n="04">Take the pass back when the beta ends.</Step>
          </div>
        </section>

        <section className="sponsor-section">
          <div className="sponsor-section-head">
            <div className="sponsor-label">Status</div>
            <span className="sponsor-badge">{status.isLoading ? "..." : badge}</span>
          </div>
          <div className="sponsor-rows">
            <Row
              label="Eligibility"
              value={
                hasSponsorship
                  ? `${short(sponsorship!.depositor)} · recorded sponsor`
                  : slotOpen
                    ? "Any FWAIR PFP holder"
                    : "No sponsor · pool already created"
              }
            />
            <Row
              label="Inventory window"
              value={inventoryWindowOpen ? "Closed · PFP launch available" : `${openingCountdown} remaining`}
            />
            <Row
              label="Pool"
              value={
                status.fwaPool && status.fwaPool !== ZERO
                  ? short(status.fwaPool)
                  : "Created by the sponsor’s transaction"
              }
            />
            {hasSponsorship && (
              <Row
                label="Pass"
                value={`#${sponsorship!.tokenId.toString()} · ${released ? "returned to sponsor" : "locked in Core"}`}
              />
            )}
            <Row label="Accrued earnings" value={status.sponsorRevenue != null ? `${eth(status.sponsorRevenue)} ETH` : "..."} />
            <Row
              label="FWAIR beta"
              value={
                status.pfpBetaActive == null
                  ? "..."
                  : status.pfpBetaActive
                    ? `${status.pfpCurrentBetaId} active · ${status.pfpActivationCount} / 111 · ends ${betaEndsDate}`
                    : "closed"
              }
            />
          </div>

          <div className="sponsor-actions">
            <SponsorWithdraw sponsorRevenue={status.sponsorRevenue} />
            <SponsorRelease
              sponsorRewardsActive={status.sponsorRewardsActive}
              scheduledEndAt={sponsorship?.scheduledEndAt}
              chainNow={chainNow}
              heldInCore={hasSponsorship && !released}
            />
          </div>

        </section>

        <section className="sponsor-section">
          <div className="sponsor-label">Why the terms hold</div>
          <div className="sponsor-reasons">
            <div>
              <b>One transaction. </b>
              <span>Approve first, then one transaction locks the pass and creates the pool. Everything after that runs automatically.</span>
            </div>
            <div>
              <b>A rate, in the contract. </b>
              <span>{shareText} of the operator share, snapshotted when each pull starts.</span>
            </div>
            <div>
              <b>The pass comes back. </b>
              <span>The lock ends with the beta, and the contract sends the pass to the recorded sponsor.</span>
            </div>
            <div>
              <b>Custody stays with you. </b>
              <span>The pass sits in your wallet until you send the transaction.</span>
            </div>
            <div>
              <b>Your cut is its own money. </b>
              <span>
                It comes out of the operator share. Player funds, Shape backing, supplier obligations and reserves
                each hold a separate balance.
              </span>
            </div>
            <div>
              <b>Earnings survive the lock. </b>
              <span>Withdraw during the beta, or long after the pass is home.</span>
            </div>
          </div>
        </section>

        <section className="sponsor-section sponsor-game">
          <div>
            <div className="sponsor-label">What Draw is</div>
            <p>
              A prize pool of Shapes, artworks that hold redeemable ETH. A player pays {ticketPhrase}, onchain
              randomness picks one Shape by price-weighted odds, and it transfers straight to their wallet.
            </p>
            <Link className="sponsor-game-link" href="/">
              See the game →
            </Link>
          </div>
          <ShapeArt tokenId={1n} svg={SAMPLE_SHAPE_SVG} width={132} />
        </section>

        <div className="sponsor-fine">
          <div>The share is set in the contract and snapshotted when each pull starts.</div>
          <div>The admin can change the share for future pulls, but cannot change a pull already in progress.</div>
          <div>The operator share is 4% of the ticket.</div>
          <div>Returning the pass is permissionless and pays out to the recorded sponsor address.</div>
          <div>A pull that refunds leaves the sponsor’s balance unchanged.</div>
        </div>
      </main>

      <footer className="sponsor-footer">
        <div className="sponsor-footer-links">
          <a href={evmNowAddressUrl(SHAPES_ADDRESS, CHAIN_ID)} target="_blank" rel="noreferrer">
            Shapes
          </a>
          <span>·</span>
          <a href={evmNowAddressUrl(status.pfpAddress, CHAIN_ID)} target="_blank" rel="noreferrer">
            FWAIR PFP
          </a>
        </div>
        <span>
          <Link href="/">Draw</Link> by{" "}
          <a href="https://twitter.com/ripe0x" target="_blank" rel="noreferrer">
            ripe
          </a>
        </span>
      </footer>
    </div>
  );
}

function Row({ label, value, strong = false }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="sponsor-row">
      <span className="sponsor-row-label">{label}</span>
      <span className={`sponsor-row-value${strong ? " is-strong" : ""}`}>{value}</span>
    </div>
  );
}

function Step({ n, children }: { n: string; children: React.ReactNode }) {
  return (
    <div className="sponsor-step">
      <span className="sponsor-step-n">{n}</span>
      <span>{children}</span>
    </div>
  );
}
