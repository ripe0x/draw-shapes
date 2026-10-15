import { isAddress, type Address } from "viem";
import { readRecord } from "./sponsorRecord";

/** The standing offer, written by the `SponsorOffer` deploy as `deployments/<chainId>-offer.json`. */
export interface OfferRecord {
  offer: Address;
  collection: Address;
}

/** `NEXT_PUBLIC_OFFER` overrides the path. Undefined when there is no valid record; the page then uses the per-deal record. */
export function getOfferRecord(): OfferRecord | undefined {
  const r = readRecord("NEXT_PUBLIC_OFFER", "offer");
  if (!r || !isAddress(r.offer) || !isAddress(r.collection)) return undefined;
  return { offer: r.offer, collection: r.collection };
}
