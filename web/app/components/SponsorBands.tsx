"use client";

import type { ReactNode } from "react";
import type { Address } from "viem";
import { mainnet } from "wagmi/chains";
import { useEnsName } from "wagmi";
import { evmNowAddressUrl } from "../lib/errors";
import { short } from "../lib/format";
import { useCyclingPunkArt } from "../lib/punkArt";
import { useDeployment } from "../Providers";
import { CollectionName, ForeignArt } from "./SponsoredPrizes";

/** Square tile showing one token of `collection` at a time, cycling through a random sample. */
export function CyclingPunk({ collection }: { collection?: Address }) {
  const src = useCyclingPunkArt(collection);
  return (
    <div className="sponsor-punk" aria-hidden>
      {/* eslint-disable-next-line @next/next/no-img-element */}
      {src && <img src={src} alt="" referrerPolicy="no-referrer" />}
    </div>
  );
}

/** Call to action while the deployment has no deal: the ask, a pill to the lend steps, rotating art. */
export function SponsorCtaBand() {
  return (
    <div className="sponsor-band sponsor-band-with-art">
      <div>
        <h2>No deal yet</h2>
        <p>Want your punk on the board? Terms below, then get in touch.</p>
        <a className="sponsor-pill sponsor-pill-invert" href="#lend">
          Lend your prize <span aria-hidden>→</span>
        </a>
      </div>
      <div className="sponsor-band-art">
        <CyclingPunk />
      </div>
    </div>
  );
}

/** Band for a recorded deal: the prize, its state, the sponsor (ENS on mainnet, else the short
 *  address) and the prize art. `children` render under the state line. */
export function SponsorTakenBand({
  collection,
  tokenId,
  sponsor,
  state,
  children,
}: {
  collection: Address;
  tokenId: bigint;
  sponsor: Address;
  state: string;
  children?: ReactNode;
}) {
  const dep = useDeployment();
  const ens = useEnsName({ address: sponsor, chainId: mainnet.id, query: { enabled: dep.chainId === mainnet.id } });
  return (
    <div className="sponsor-band sponsor-band-with-art">
      <div>
        <h2>
          <CollectionName collection={collection} /> #{tokenId.toString()}
        </h2>
        <p className="sponsor-band-line">
          {state}
          <br />
          Sponsor{" "}
          <a href={evmNowAddressUrl(sponsor, dep.chainId)} target="_blank" rel="noreferrer">
            {ens.data ?? short(sponsor)}
          </a>
        </p>
        {children}
      </div>
      <div className="sponsor-band-art">
        <ForeignArt collection={collection} tokenId={tokenId} />
      </div>
    </div>
  );
}
