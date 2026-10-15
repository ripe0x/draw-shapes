"use client";

import { fwairPfpArt } from "./fwairPfpArt";
import { CHAIN_ID } from "./fixture";
import { evmNowAddressUrl, short } from "./format";
import { PassArt } from "./PassArt";

/** Band shown once a sponsorship is recorded: the sponsor, the pass title from its metadata, the
 *  lock state, and the pass art on the right. */
export function SponsorTakenBand({ sponsor, tokenId, state }: { sponsor: string; tokenId: bigint; state: string }) {
  const art = fwairPfpArt(tokenId);
  const title = art.name;

  return (
    <div className="sponsor-band">
      <div className="sponsor-band-title">Slot taken</div>
      <div className="sponsor-band-line">
        {title} · {state}
        <br />
        Sponsor{" "}
        <a href={evmNowAddressUrl(sponsor, CHAIN_ID)} target="_blank" rel="noreferrer">
          {short(sponsor)}
        </a>
      </div>
      <div className="sponsor-band-art">
        <PassArt image={art.image} name={title} tokenId={tokenId} />
      </div>
    </div>
  );
}
