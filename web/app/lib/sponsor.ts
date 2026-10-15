"use client";

import { useQuery } from "@tanstack/react-query";
import { erc721Abi, parseAbi, type Address } from "viem";
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
