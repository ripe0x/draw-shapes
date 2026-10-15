"use client";

import { useCyclingFwairPfp } from "./fwairPfpArt";
import { PassArt } from "./PassArt";

/** The call to action while the sponsor slot is open. */
export function SponsorCtaBand() {
  const art = useCyclingFwairPfp();

  return (
    <div className="sponsor-band">
      <button className="sponsor-pill sponsor-pill-invert">
        <span>Sponsor and create pool</span>
        <span aria-hidden>→</span>
      </button>
      <div className="sponsor-band-art">
        <PassArt image={art.image} name={art.name} tokenId={art.tokenId} />
      </div>
    </div>
  );
}
