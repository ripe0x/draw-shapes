"use client";

import { durationDaysHours } from "./format";

/** Returns the locked FWAIR PFP to the recorded sponsor. Callable by anyone once
 *  sponsorRewardsActive is false. */
export function SponsorRelease({
  sponsorRewardsActive,
  scheduledEndAt,
  chainNow,
  heldInCore,
}: {
  sponsorRewardsActive: boolean | undefined;
  scheduledEndAt: bigint | undefined;
  chainNow: number | undefined;
  /** A sponsorship is recorded and the pass has yet to be returned. */
  heldInCore: boolean;
}) {
  const remaining = scheduledEndAt != null && chainNow != null
    ? Math.max(0, Number(scheduledEndAt) - chainNow)
    : undefined;
  const canRelease = heldInCore && sponsorRewardsActive === false;
  const big =
    !heldInCore || sponsorRewardsActive == null
      ? "—"
      : sponsorRewardsActive && remaining != null
        ? durationDaysHours(remaining)
        : "Ready";
  const note = !heldInCore
    ? "Shows the time left once a pass is locked."
    : canRelease
      ? "Release open to anyone. The pass goes to the recorded sponsor."
      : "Available once the FWAIR beta ends.";

  return (
    <div>
      <div className="sponsor-label">Take the pass back</div>
      <div className="sponsor-big">{big}</div>
      <button className="sponsor-pill sponsor-pill-small" disabled={!canRelease}>
        Release pass
      </button>
      <div className="sponsor-note">{note}</div>
    </div>
  );
}
