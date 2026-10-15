"use client";

import { useState } from "react";
import { fwairPfpArt } from "./fwairPfpArt";
import { short } from "./format";
import { PassArt } from "./PassArt";

/** Wallet view: every FWAIR PFP in the connected wallet is selectable. Fixture: three passes, none
 *  approved, so the band shows step 1 of 2. */
const TOKEN_IDS = [1n, 2n, 3n];
const SALT = "0x0000000000000000000000000000000000000000000000000000000000000000";

export function SponsorPfpList({
  launchReady,
  inventoryWindowOpen,
  openingCountdown,
}: {
  launchReady: boolean;
  inventoryWindowOpen: boolean;
  openingCountdown: string;
}) {
  const [picked, setPicked] = useState<bigint | undefined>();
  const selected = picked ?? TOKEN_IDS[0];
  const many = TOKEN_IDS.length > 1;
  const selectedArt = fwairPfpArt(selected);

  return (
    <div>
      <div className="sponsor-band">
        {!inventoryWindowOpen ? (
          <button className="sponsor-pill sponsor-pill-invert" disabled>
            <span>Launch opens in {openingCountdown}</span>
            <span aria-hidden>→</span>
          </button>
        ) : (
          <button className="sponsor-pill sponsor-pill-invert">
            <span>{`Approve pass #${selected.toString()}`}</span>
            <span aria-hidden>→</span>
          </button>
        )}
        <div className="sponsor-band-line">
          {!inventoryWindowOpen
            ? "Supplier inventory is being collected onchain. Approval and launch unlock together when the 24-hour window closes."
            : !launchReady
              ? "FWA has not enabled beta pool creation yet. Your pass stays in your wallet."
              : "Step 1 of 2. Approval lets the contract move this one pass when you send the next transaction."}
        </div>
        <div className="sponsor-band-art">
          <PassArt image={selectedArt.image} name={selectedArt.name} tokenId={selected} />
        </div>
      </div>

      <div className="sponsor-passes" role={many ? "radiogroup" : undefined} aria-label={many ? "Pass to lock" : undefined}>
        {TOKEN_IDS.map((tokenId) => {
          const pass = fwairPfpArt(tokenId);
          const isSel = tokenId === selected;
          const label = `${pass.name}${isSel ? " · selected" : ""}`;
          return (
            <button
              key={tokenId.toString()}
              type="button"
              role="radio"
              aria-checked={isSel}
              className={`sponsor-tile sponsor-tile-pick${isSel ? " is-selected" : ""}`}
              onClick={() => setPicked(tokenId)}
            >
              <div className="sponsor-tile-art">
                <PassArt image={pass.image} name={pass.name} tokenId={tokenId} />
              </div>
              <div className="sponsor-tile-label">{label}</div>
            </button>
          );
        })}
      </div>

      <div className="sponsor-note" style={{ marginTop: 20, maxWidth: "none" }}>
        Salt {short(SALT)}
      </div>
    </div>
  );
}
