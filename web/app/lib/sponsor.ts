"use client";

import { useQuery } from "@tanstack/react-query";
import { erc721Abi, parseAbi, zeroAddress, type Address } from "viem";
import { usePublicClient } from "wagmi";
import { feeSplitAbi, shapesFeesAbi, sponsorOfferAbi, sponsoredPrizeAbi } from "./abi/sponsor";
import type { OfferRecord } from "./offer";
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
  /** The staked token; undefined until `stake(tokenId)`. */
  tokenId?: bigint;
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
            { ...prize, functionName: "tokenId" },
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
      const [sponsor, capWei, parkedPriceWei, floorWei, decayWeiPerPull, reclaimAfter, reclaimDelay, staked, stakedId, listingId, phase, active, captured, atFloor, pool, owner, paidWei, locked, ownerBalance, sponsorBalance, feeRecipient, feesOwedWei] = m;
      const tokenId = staked ? stakedId : undefined;
      const [block, tokenHolder] = await Promise.all([
        client!.getBlock(),
        // A burned or unminted token has no owner; the deal then reads as ended.
        tokenId === undefined ? undefined : client!.readContract({ address: r.collection, abi: erc721Abi, functionName: "ownerOf", args: [tokenId] }).catch(() => undefined),
      ]);
      const deal = {
        sponsor, owner, pool, parkedPriceWei, floorWei, decayWeiPerPull, capWei, paidWei, staked, tokenId, reclaimDelay, reclaimAfter, listingId,
        hot: phase === 1, active, captured, atFloor, locked, ownerBalance, sponsorBalance, feesOwedWei, feeRecipient,
        tokenHolder, chainNow: block.timestamp,
      };
      return { ...deal, state: dealState(deal, r.prize) };
    },
  });
}

const enumerableAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function tokenOfOwnerByIndex(address, uint256) view returns (uint256)",
]);
const WALLET_TOKEN_CAP = 24;

/** Up to 24 token ids of `collection` (ERC-721 Enumerable) held by `owner`, in one multicall. */
export function useWalletTokens(collection: Address | undefined, owner: Address | undefined) {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  return useQuery({
    queryKey: ["wallet-tokens", dep.chainId, collection?.toLowerCase(), owner?.toLowerCase()],
    enabled: !!client && !!collection && !!owner,
    refetchInterval: POLL_MS,
    queryFn: async (): Promise<bigint[]> => {
      const c = { address: collection!, abi: enumerableAbi } as const;
      const balance = await client!.readContract({ ...c, functionName: "balanceOf", args: [owner!] });
      const n = Math.min(Number(balance), WALLET_TOKEN_CAP);
      return client!.multicall({
        allowFailure: false,
        contracts: Array.from({ length: n }, (_, i) => ({ ...c, functionName: "tokenOfOwnerByIndex", args: [owner!, BigInt(i)] }) as const),
      });
    },
  });
}

/** Whether the prize may move token `id` of the sponsor (`approve(prize, id)` or `setApprovalForAll`)
 *  and whether `canStake(id)` holds. A prize contract without `canStake(uint256)` reads as false. */
export function useStakeGate(rec: SponsorRecord, sponsor: Address, id: bigint | undefined) {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  return useQuery({
    queryKey: ["stake-gate", dep.chainId, rec.prize.toLowerCase(), sponsor.toLowerCase(), id?.toString()],
    enabled: !!client && id !== undefined,
    refetchInterval: POLL_MS,
    queryFn: async () => {
      const token = { address: rec.collection, abi: erc721Abi } as const;
      const [approvedFor, approvedAll, canStake] = await Promise.all([
        client!.readContract({ ...token, functionName: "getApproved", args: [id!] }).catch(() => undefined),
        client!.readContract({ ...token, functionName: "isApprovedForAll", args: [sponsor, rec.prize] }).catch(() => false),
        client!.readContract({ address: rec.prize, abi: sponsoredPrizeAbi, functionName: "canStake", args: [id!] }).catch(() => false),
      ]);
      return { approved: same(approvedFor, rec.prize) || approvedAll, canStake };
    },
  });
}

export type OfferDealState = "parked" | "hot" | "captured" | "held" | "unlisted" | "reclaimed" | "released" | "ended";

/** One deal of the standing offer: the contract struct, its phase and who holds the token. */
export interface OfferDeal {
  /** Index in `deals()`. */
  id: bigint;
  sponsor: Address;
  collection: Address;
  tokenId: bigint;
  listingId: bigint;
  capWei: bigint;
  paidWei: bigint;
  takenAt: bigint;
  reclaimAfter: bigint;
  captured: boolean;
  released: boolean;
  atFloor: boolean;
  active: boolean;
  hot: boolean;
  holder?: Address;
  state: OfferDealState;
}

export interface OfferView {
  terms: { parkedPriceWei: bigint; floorWei: bigint; decayWeiPerPull: bigint; reclaimDelay: bigint; capWei: bigint; maxOpen: bigint; enabled: boolean };
  owner: Address;
  /** Unpaid deals in fee order. */
  queue: { dealId: bigint; sponsor: Address; remainingWei: bigint }[];
  /** Fees ahead of a take made now. */
  expectedWaitWei: bigint;
  /** `maxOpen` minus the unpaid deals. */
  freeSlots: number;
  /** Queued deals and the connected wallet's deals, by id. */
  deals: OfferDeal[];
  /** `balance(account)`: the connected wallet's withdrawable fees. */
  balance: bigint;
  /** Timestamp of the latest block; the reclaim date is judged against chain time. */
  chainNow: bigint;
}

/** The stage of a deal. A deal that ended without a capture is told apart by who holds the token. */
function offerDealState(d: { active: boolean; hot: boolean; captured: boolean; released: boolean; holder?: Address; sponsor: Address }, offer: Address, pool: Address): OfferDealState {
  if (d.captured) return "captured";
  if (d.active) return d.hot ? "hot" : "parked";
  if (same(d.holder, offer)) return "held";
  if (same(d.holder, pool)) return "unlisted";
  if (d.released) return "released";
  if (same(d.holder, d.sponsor)) return "reclaimed";
  return "ended";
}

/** Terms, queue and the deals that matter to `account`, polled with the pool. Deal ids are indexes of `deals()`. */
export function useOffer(rec: OfferRecord | undefined, account: Address | undefined) {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  return useQuery({
    queryKey: ["offer", dep.chainId, rec?.offer.toLowerCase(), account?.toLowerCase()],
    enabled: !!client && !!rec,
    refetchInterval: POLL_MS,
    queryFn: async (): Promise<OfferView> => {
      const r = rec!;
      const offer = { address: r.offer, abi: sponsorOfferAbi } as const;
      const [[terms, all, queue, expectedWaitWei, owner, balance], block] = await Promise.all([
        client!.multicall({
          allowFailure: false,
          contracts: [
            { ...offer, functionName: "terms", args: [r.collection] },
            { ...offer, functionName: "deals" },
            { ...offer, functionName: "queue" },
            { ...offer, functionName: "expectedWaitWei", args: [r.collection] },
            { ...offer, functionName: "owner" },
            { ...offer, functionName: "balance", args: [account ?? zeroAddress] },
          ],
        }),
        client!.getBlock(),
      ]);
      const [parkedPriceWei, floorWei, decayWeiPerPull, reclaimDelay, capWei, maxOpen, enabled] = terms;
      const queued = new Set(queue.map((q) => q.dealId));
      const ids = all.map((_, i) => BigInt(i)).filter((id) => queued.has(id) || same(all[Number(id)].sponsor, account));
      const calls = ids.flatMap((id) => [
        { ...offer, functionName: "phase", args: [id] } as const,
        { ...offer, functionName: "active", args: [id] } as const,
        { address: r.collection, abi: erc721Abi, functionName: "ownerOf", args: [all[Number(id)].tokenId] } as const,
      ]);
      const extra = await client!.multicall({ allowFailure: true, contracts: calls });
      const deals = ids.map((id, i): OfferDeal => {
        const d = all[Number(id)];
        const [phase, active, holder] = extra.slice(i * 3, i * 3 + 3);
        const part = { active: active.result === true, hot: phase.result === 1, captured: d.captured, released: d.released, holder: holder.result as Address | undefined, sponsor: d.sponsor };
        return {
          id, sponsor: d.sponsor, collection: d.collection, tokenId: d.tokenId, listingId: d.listingId, capWei: d.capWei, paidWei: d.paidWei,
          takenAt: d.takenAt, reclaimAfter: d.reclaimAfter, captured: d.captured, released: d.released, atFloor: d.atFloor,
          active: part.active, hot: part.hot, holder: part.holder, state: offerDealState(part, r.offer, dep.pool),
        };
      });
      return {
        terms: { parkedPriceWei, floorWei, decayWeiPerPull, reclaimDelay, capWei, maxOpen, enabled },
        owner, queue: [...queue], expectedWaitWei, deals, balance, chainNow: block.timestamp,
        freeSlots: Math.max(0, Number(maxOpen) - queue.length),
      };
    },
  });
}

/** Whether the offer may move token `id` of `who` (`approve(offer, id)` or `setApprovalForAll`) and whether `canTake` holds. */
export function useTakeGate(rec: OfferRecord, who: Address | undefined, id: bigint | undefined) {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  return useQuery({
    queryKey: ["take-gate", dep.chainId, rec.offer.toLowerCase(), who?.toLowerCase(), id?.toString()],
    enabled: !!client && !!who && id !== undefined,
    refetchInterval: POLL_MS,
    queryFn: async () => {
      const token = { address: rec.collection, abi: erc721Abi } as const;
      const [approvedFor, approvedAll, canTake] = await Promise.all([
        client!.readContract({ ...token, functionName: "getApproved", args: [id!] }).catch(() => undefined),
        client!.readContract({ ...token, functionName: "isApprovedForAll", args: [who!, rec.offer] }).catch(() => false),
        client!.readContract({ address: rec.offer, abi: sponsorOfferAbi, functionName: "canTake", args: [rec.collection, id!, who!] }).catch(() => false),
      ]);
      return { approved: same(approvedFor, rec.offer) || approvedAll, canTake };
    },
  });
}
