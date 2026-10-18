"use client";

import type { ReactNode } from "react";
import type { Address } from "viem";
import { mainnet } from "wagmi/chains";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { erc721Abi } from "viem";
import { useAccount, useEnsName } from "wagmi";
import { evmNowAddressUrl } from "../lib/errors";
import { short } from "../lib/format";
import { useForeignImage } from "../lib/foreign";
import { useCyclingPunkArt } from "../lib/punkArt";
import { sponsorOfferAbi, sponsoredPrizeAbi } from "../lib/abi/sponsor";
import type { OfferRecord } from "../lib/offer";
import { type OfferView, type SponsorDeal, useStakeGate, useTakeGate } from "../lib/sponsor";
import type { SponsorRecord } from "../lib/sponsorRecord";
import { useDeployment } from "../Providers";
import { CollectionName } from "./SponsoredPrizes";
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

/** Square tile with one token's image. */
export function TokenSquare({ collection, tokenId }: { collection: Address; tokenId: bigint }) {
  const src = useForeignImage(collection, tokenId).data;
  return (
    <div className="sponsor-punk" aria-label={`Token ${tokenId.toString()}`}>
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

/** A sponsor as a link: the ENS name on mainnet, else the short address. */
export function SponsorName({ address }: { address: Address }) {
  const dep = useDeployment();
  const ens = useEnsName({ address, chainId: mainnet.id, query: { enabled: dep.chainId === mainnet.id } });
  return (
    <a href={evmNowAddressUrl(address, dep.chainId)} target="_blank" rel="noreferrer">
      {ens.data ?? short(address)}
    </a>
  );
}

/** Band for a deal: the prize, its state, the sponsor (ENS on mainnet, else the short
 *  address) and the prize art. Without a `tokenId` the heading is the collection name and the
 *  art cycles through the collection. `children` render under the state line. */
export function SponsorTakenBand({
  collection,
  tokenId,
  sponsor,
  state,
  children,
}: {
  collection: Address;
  tokenId?: bigint;
  sponsor: Address;
  state: string;
  children?: ReactNode;
}) {
  return (
    <div className="sponsor-band sponsor-band-with-art">
      <div>
        <h2>
          <CollectionName collection={collection} />
          {tokenId !== undefined && ` #${tokenId.toString()}`}
        </h2>
        <p className="sponsor-band-line">
          {state}
          <br />
          Sponsor <SponsorName address={sponsor} />
        </p>
        {children}
      </div>
      <div className="sponsor-band-art">
        {tokenId === undefined ? <CyclingPunk collection={collection} /> : <TokenSquare collection={collection} tokenId={tokenId} />}
      </div>
    </div>
  );
}

const same = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

/** Selectable tiles of the sponsor's tokens of `collection`; a single token shows as one plain tile. */
export function SponsorPunkPicker({ collection, tokens, selected, onPick }: { collection: Address; tokens: bigint[]; selected?: bigint; onPick: (id: bigint) => void }) {
  const many = tokens.length > 1;
  return (
    <div className="sponsor-passes" role={many ? "radiogroup" : undefined} aria-label={many ? "Token to stake" : undefined}>
      {tokens.map((id) => (
        <PunkTile key={id.toString()} collection={collection} tokenId={id} selected={id === selected} selectable={many} onPick={() => onPick(id)} />
      ))}
    </div>
  );
}

function PunkTile({ collection, tokenId, selected, selectable, onPick }: { collection: Address; tokenId: bigint; selected: boolean; selectable: boolean; onPick: () => void }) {
  const art = (
    <div className="sponsor-tile-art">
      <TokenSquare collection={collection} tokenId={tokenId} />
    </div>
  );
  const label = `#${tokenId.toString()}${selected ? " · selected" : ""}`;
  if (!selectable) {
    return (
      <div className="sponsor-tile">
        {art}
        <div className="sponsor-tile-label">{label}</div>
      </div>
    );
  }
  return (
    <button type="button" role="radio" aria-checked={selected} className={`sponsor-tile sponsor-tile-pick${selected ? " is-selected" : ""}`} onClick={onPick}>
      {art}
      <div className="sponsor-tile-label">{label}</div>
    </button>
  );
}

/** Stake panel of a deal awaiting its sponsor: connect, then for the selected token approve the
 *  prize contract (step 1 of 2) and call `stake(tokenId)` (step 2 of 2). `tokens` are the sponsor
 *  wallet's tokens of the collection, undefined while unread. A landed transaction refetches the deal. */
export function SponsorStakePanel({ record, deal, tokens, selected }: { record: SponsorRecord; deal: SponsorDeal; tokens?: bigint[]; selected?: bigint }) {
  const dep = useDeployment();
  const { address } = useAccount();
  const approve = useTx();
  const stake = useTx();
  const isSponsor = same(address, deal.sponsor);
  const gate = useStakeGate(record, deal.sponsor, selected).data;
  const id = selected?.toString();

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
  if (!tokens) {
    return (
      <div className="sponsor-stake">
        <p className="sponsor-band-line">Reading this wallet.</p>
      </div>
    );
  }
  if (selected === undefined) {
    return (
      <div className="sponsor-stake">
        <p className="sponsor-band-line">
          This wallet holds no <CollectionName collection={record.collection} />.
        </p>
      </div>
    );
  }
  if (!gate?.approved) {
    return (
      <div className="sponsor-stake">
        <TxButton
          tx={approve}
          label={`Approve punk #${id}`}
          className="sponsor-pill sponsor-pill-invert"
          disabled={!gate}
          onClick={() =>
            void approve.run(() => approve.write({ address: record.collection, abi: erc721Abi, chainId: dep.chainId, functionName: "approve", args: [record.prize, selected] }))
          }
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
        disabled={!gate.canStake}
        onClick={() => void stake.run(() => stake.write({ address: record.prize, abi: sponsoredPrizeAbi, chainId: dep.chainId, functionName: "stake", args: [selected] }))}
      />
      <p className="sponsor-band-line">
        {gate.canStake
          ? "Step 2 of 2. This transaction moves the token to the pool, locks the fee split and sets the reclaim date."
          : "Waiting for the operator to enable this deal."}
      </p>
      <TxLine tx={stake} />
    </div>
  );
}

/** Why `take` is unavailable, from the offer's terms and open slots; undefined when the offer accepts takes. */
export function offerBlock(o: OfferView): string | undefined {
  if (!o.terms.enabled) return "The offer is closed.";
  if (o.freeSlots === 0) return "The offer is full. A slot opens when a deal is paid.";
  return undefined;
}

/** Take panel of the standing offer: connect, then for the selected token approve the offer contract
 *  (step 1 of 2) and call `take(collection, tokenId)` (step 2 of 2). `tokens` are the connected wallet's
 *  tokens of the collection, undefined while unread. A landed transaction refetches the offer. */
export function OfferTakePanel({ record, offer, tokens, selected }: { record: OfferRecord; offer: OfferView; tokens?: bigint[]; selected?: bigint }) {
  const dep = useDeployment();
  const { address } = useAccount();
  const approve = useTx();
  const take = useTx();
  const gate = useTakeGate(record, address, selected).data;
  const id = selected?.toString();
  const line = (text: ReactNode) => (
    <div className="sponsor-stake">
      <p className="sponsor-band-line">{text}</p>
    </div>
  );

  if (!address) {
    return (
      <div className="sponsor-stake">
        <ConnectButton.Custom>
          {({ mounted, openConnectModal }) => (
            <button type="button" className="sponsor-pill sponsor-pill-invert" disabled={!mounted} onClick={openConnectModal}>
              Connect a wallet <span aria-hidden>→</span>
            </button>
          )}
        </ConnectButton.Custom>
      </div>
    );
  }
  if (!tokens) return line("Reading this wallet.");
  if (selected === undefined)
    return line(
      <>
        This wallet holds no <CollectionName collection={record.collection} />.
      </>,
    );
  if (!gate?.approved) {
    return (
      <div className="sponsor-stake">
        <TxButton
          tx={approve}
          label={`Approve punk #${id}`}
          className="sponsor-pill sponsor-pill-invert"
          disabled={!gate}
          onClick={() =>
            void approve.run(() => approve.write({ address: record.collection, abi: erc721Abi, chainId: dep.chainId, functionName: "approve", args: [record.offer, selected] }))
          }
        />
        <p className="sponsor-band-line">Step 1 of 2. Approval lets the offer contract move this one token when you send the next transaction.</p>
        <TxLine tx={approve} />
      </div>
    );
  }
  const block = offerBlock(offer);
  return (
    <div className="sponsor-stake">
      <TxButton
        tx={take}
        label={`Take punk #${id}`}
        className="sponsor-pill sponsor-pill-invert"
        disabled={!gate.canTake || !!block}
        onClick={() => void take.run(() => take.write({ address: record.offer, abi: sponsorOfferAbi, chainId: dep.chainId, functionName: "take", args: [record.collection, selected] }))}
      />
      <p className="sponsor-band-line">
        {block ??
          (gate.canTake
            ? "Step 2 of 2. This transaction moves the token to the pool, joins the fee queue and sets the reclaim date."
            : "The offer cannot take this punk now. The pool may be at its listing cap.")}
      </p>
      <TxLine tx={take} />
    </div>
  );
}
