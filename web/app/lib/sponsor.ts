"use client";

import { useQuery } from "@tanstack/react-query";
import { erc721Abi, type Address } from "viem";
import { usePublicClient } from "wagmi";
import { feeSplitAbi, shapesFeesAbi, sponsoredPrizeAbi } from "./abi/sponsor";
import { POLL_MS } from "./pool";
import type { SponsorRecord } from "./sponsorRecord";
import { useDeployment } from "../Providers";

export type DealState =
  | "awaiting"
  | "parked"
  | "hot"
  | "captured"
  | "held"
  | "unlisted"
  | "reclaimed"
  | "released"
  | "ended";

/** Terms and live state of one deal, read from the prize contract, its fee split, Shapes and the collection. */
export interface SponsorDeal {
  sponsor: Address;
  /** `FeeSplit.owner`: the operator. */
  owner: Address;
  pool: Address;
  parkedPriceWei: bigint;
  floorWei: bigint;
  decayWeiPerPull: bigint;
  /** Cap on the sponsor's payment, from the prize contract. */
  capWei: bigint;
  paidWei: bigint;
  /** False until the sponsor calls `stake()`. */
  staked: boolean;
  /** Unstaked, the prize is the pool's registrar, the sponsor owns the token and has approved the prize. */
  canStake: boolean;
  /** The collection lets the prize move the token: `approve(prize, id)` or `setApprovalForAll`. */
  approved: boolean;
  /** Seconds after staking until the sponsor may reclaim. */
  reclaimDelay: bigint;
  /** 0 until staked. */
  reclaimAfter: bigint;
  listingId: bigint;
  hot: boolean;
  active: boolean;
  captured: boolean;
  atFloor: boolean;
  locked: boolean;
  ownerBalance: bigint;
  sponsorBalance: bigint;
  /** Mint fees accrued in Shapes for the fee split, not yet forwarded. */
  feesOwedWei: bigint;
  feeRecipient: Address;
  tokenHolder?: Address;
  /** Timestamp of the latest block; the reclaim date is judged against chain time. */
  chainNow: bigint;
  state: DealState;
}

const same = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

/** The deal's stage. A deal that ended without a capture is told apart by who holds the token. */
export function dealState(d: Pick<SponsorDeal, "staked" | "listingId" | "active" | "captured" | "hot" | "tokenHolder" | "sponsor" | "owner" | "pool">, prize: Address): DealState {
  if (!d.staked) return "awaiting";
  if (d.captured) return "captured";
  if (d.active) return d.hot ? "hot" : "parked";
  if (same(d.tokenHolder, prize)) return "held";
  if (same(d.tokenHolder, d.pool)) return "unlisted";
  if (same(d.tokenHolder, d.sponsor)) return "reclaimed";
  if (same(d.tokenHolder, d.owner)) return "released";
  return "ended";
}

/** One multicall for the deal plus the latest block, polled with the pool. */
export function useSponsorDeal(rec: SponsorRecord | undefined) {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  return useQuery({
    queryKey: ["sponsor-deal", dep.chainId, rec?.prize.toLowerCase()],
    enabled: !!client && !!rec,
    refetchInterval: POLL_MS,
    queryFn: async (): Promise<SponsorDeal> => {
      const r = rec!;
      const prize = { address: r.prize, abi: sponsoredPrizeAbi } as const;
      const split = { address: r.feeSplit, abi: feeSplitAbi } as const;
      const m = await client!.multicall({
          allowFailure: false,
          contracts: [
            { ...prize, functionName: "sponsor" },
            { ...prize, functionName: "capWei" },
            { ...prize, functionName: "parkedPriceWei" },
            { ...prize, functionName: "floorWei" },
            { ...prize, functionName: "decayWeiPerPull" },
            { ...prize, functionName: "reclaimAfter" },
            { ...prize, functionName: "reclaimDelay" },
            { ...prize, functionName: "staked" },
            { ...prize, functionName: "canStake" },
            { ...prize, functionName: "listingId" },
            { ...prize, functionName: "phase" },
            { ...prize, functionName: "active" },
            { ...prize, functionName: "captured" },
            { ...prize, functionName: "atFloor" },
            { ...prize, functionName: "pool" },
            { ...split, functionName: "owner" },
            { ...split, functionName: "paidWei" },
            { ...split, functionName: "locked" },
            { ...split, functionName: "ownerBalance" },
            { ...split, functionName: "sponsorBalance" },
            { address: dep.shapes, abi: shapesFeesAbi, functionName: "feeRecipient" },
            { address: dep.shapes, abi: shapesFeesAbi, functionName: "feesOwedTo", args: [r.feeSplit] },
          ],
      });
      const collection = { address: r.collection, abi: erc721Abi } as const;
      const [block, tokenHolder, approvedFor, approvedAll] = await Promise.all([
        client!.getBlock(),
        // A burned or unminted token has no owner; the deal then reads as ended.
        client!.readContract({ address: r.collection, abi: erc721Abi, functionName: "ownerOf", args: [BigInt(r.tokenId)] }).catch(() => undefined),
        client!.readContract({ ...collection, functionName: "getApproved", args: [BigInt(r.tokenId)] }).catch(() => undefined),
        client!.readContract({ ...collection, functionName: "isApprovedForAll", args: [m[0], r.prize] }).catch(() => false),
      ]);
      const [sponsor, capWei, parkedPriceWei, floorWei, decayWeiPerPull, reclaimAfter, reclaimDelay, staked, canStake, listingId, phase, active, captured, atFloor, pool, owner, paidWei, locked, ownerBalance, sponsorBalance, feeRecipient, feesOwedWei] = m;
      const deal = {
        sponsor, owner, pool, parkedPriceWei, floorWei, decayWeiPerPull, capWei, paidWei, staked, canStake, reclaimDelay, reclaimAfter, listingId,
        hot: phase === 1, active, captured, atFloor, locked, ownerBalance, sponsorBalance, feesOwedWei, feeRecipient,
        tokenHolder, approved: same(approvedFor, r.prize) || approvedAll, chainNow: block.timestamp,
      };
      return { ...deal, state: dealState(deal, r.prize) };
    },
  });
}
