"use client";

import type { ReactNode } from "react";
import type { Address } from "viem";
import { mainnet } from "wagmi/chains";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { erc721Abi } from "viem";
import { useAccount, useEnsName } from "wagmi";
import { evmNowAddressUrl } from "../lib/errors";
import { short } from "../lib/format";
import { useCyclingPunkArt } from "../lib/punkArt";
import { sponsoredPrizeAbi } from "../lib/abi/sponsor";
import type { SponsorDeal } from "../lib/sponsor";
import { useDeployment } from "../Providers";
import { CollectionName, ForeignArt } from "./SponsoredPrizes";
import { TxButton, TxLine, useTx } from "./Tx";

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

/** Call to action while the deployment has no deal: the ask, a pill to the stake steps, rotating art. */
export function SponsorCtaBand() {
  return (
    <div className="sponsor-band sponsor-band-with-art">
      <div>
        <h2>Put a punk on the board</h2>
        <p>Stake it as a prize. You earn from the operator&apos;s mint fees up to the cap, then it goes hot on the board.</p>
        <a className="sponsor-pill sponsor-pill-invert" href="#stake">
          Stake a prize <span aria-hidden>→</span>
        </a>
      </div>
      <div className="sponsor-band-art">
        <CyclingPunk />
      </div>
    </div>
  );
}

/** Band for a deal: the prize, its state, the sponsor (ENS on mainnet, else the short
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

const same = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

/** Stake panel of a deal awaiting its sponsor: connect, then approve the prize contract for the
 *  token (step 1 of 2) and call `stake()` (step 2 of 2). A landed transaction refetches the deal. */
export function SponsorStakePanel({ prize, collection, tokenId, deal }: { prize: Address; collection: Address; tokenId: bigint; deal: SponsorDeal }) {
  const dep = useDeployment();
  const { address } = useAccount();
  const approve = useTx();
  const stake = useTx();
  const isSponsor = same(address, deal.sponsor);
  const holds = same(deal.tokenHolder, deal.sponsor);
  const id = tokenId.toString();

  if (!address) {
    return (
      <div className="sponsor-stake">
        <ConnectButton.Custom>
          {({ mounted, openConnectModal }) => (
            <button type="button" className="sponsor-pill sponsor-pill-invert" disabled={!mounted} onClick={openConnectModal}>
              Connect the sponsor wallet <span aria-hidden>→</span>
            </button>
          )}
        </ConnectButton.Custom>
      </div>
    );
  }
  if (!isSponsor) {
    return (
      <div className="sponsor-stake">
        <p className="sponsor-band-line">This deal is for {short(deal.sponsor)}.</p>
      </div>
    );
  }
  if (!holds) {
    return (
      <div className="sponsor-stake">
        <p className="sponsor-band-line">This wallet does not hold token #{id}.</p>
      </div>
    );
  }
  if (!deal.approved) {
    return (
      <div className="sponsor-stake">
        <TxButton
          tx={approve}
          label={`Approve punk #${id}`}
          className="sponsor-pill sponsor-pill-invert"
          onClick={() => void approve.run(() => approve.write({ address: collection, abi: erc721Abi, chainId: dep.chainId, functionName: "approve", args: [prize, tokenId] }))}
        />
        <p className="sponsor-band-line">Step 1 of 2. Approval lets the prize contract move this one token when you send the next transaction.</p>
        <TxLine tx={approve} />
      </div>
    );
  }
  return (
    <div className="sponsor-stake">
      <TxButton
        tx={stake}
        label={`Stake punk #${id}`}
        className="sponsor-pill sponsor-pill-invert"
        disabled={!deal.canStake}
        onClick={() => void stake.run(() => stake.write({ address: prize, abi: sponsoredPrizeAbi, chainId: dep.chainId, functionName: "stake" }))}
      />
      <p className="sponsor-band-line">
        {deal.canStake
          ? "Step 2 of 2. This transaction moves the token to the pool, locks the fee split and sets the reclaim date."
          : "Waiting for the operator to enable this deal."}
      </p>
      <TxLine tx={stake} />
    </div>
  );
}
