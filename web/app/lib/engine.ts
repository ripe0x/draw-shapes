"use client";

import { useQuery } from "@tanstack/react-query";
import { useAccount, usePublicClient, useReadContracts } from "wagmi";
import { zeroAddress } from "viem";
import { erc20Abi } from "./abi/external";
import { roundAbi } from "./abi/round";
import { sponsorshipAbi } from "./abi/sponsorship";
import { treasuryAbi } from "./abi/treasury";
import { POLL_MS } from "./pool";
import { useDeployment } from "../Providers";

/** `FoundingRound.State` in declaration order. */
export const ROUND_STATE = ["Open", "Funded", "Released", "Refunding"] as const;

/**
 * The latest block timestamp of the deployment chain, polled. The local fork is time-warped, so all
 * countdowns use this instead of the wall clock.
 */
export function useChainTime() {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  return useQuery({
    queryKey: ["chain-time", dep.chainId],
    enabled: !!client && dep.present,
    refetchInterval: POLL_MS,
    queryFn: async () => Number((await client!.getBlock()).timestamp),
  });
}

/** Every FoundingRound read a page needs, in one multicall, for the round and the connected wallet. */
export function useRound() {
  const dep = useDeployment();
  const { address } = useAccount();
  const round = { chainId: dep.chainId, address: dep.round ?? zeroAddress, abi: roundAbi } as const;
  const me = address ?? zeroAddress;
  return useReadContracts({
    allowFailure: false,
    contracts: [
      { ...round, functionName: "state" },
      { ...round, functionName: "target" },
      { ...round, functionName: "totalContributed" },
      { ...round, functionName: "deadline" },
      { ...round, functionName: "launchDeadline" },
      { ...round, functionName: "minContribution" },
      { ...round, functionName: "capBps" },
      { ...round, functionName: "entitlement" },
      { ...round, functionName: "totalDistributed" },
      { ...round, functionName: "remaining" },
      { ...round, functionName: "released" },
      { ...round, functionName: "contributionOf", args: [me] },
      { ...round, functionName: "creditedOf", args: [me] },
      { ...round, functionName: "claimedOf", args: [me] },
      { ...round, functionName: "claimable", args: [me] },
    ],
    query: {
      enabled: dep.present && !!dep.round,
      refetchInterval: POLL_MS,
      select: ([state, target, totalContributed, deadline, launchDeadline, minContribution, capBps, entitlement, totalDistributed, remaining, released, myContribution, myCredited, myClaimed, myClaimable]) => ({
        state: Number(state),
        target,
        totalContributed,
        deadline: Number(deadline),
        launchDeadline: Number(launchDeadline),
        minContribution,
        capBps: Number(capBps),
        entitlement,
        totalDistributed,
        remaining,
        released,
        myContribution,
        myCredited,
        myClaimed,
        myClaimable,
      }),
    },
  });
}

export type RoundData = NonNullable<ReturnType<typeof useRound>["data"]>;

/** Every EngineTreasury read a page needs, in one multicall. */
export function useTreasury() {
  const dep = useDeployment();
  const t = { chainId: dep.chainId, address: dep.treasury ?? zeroAddress, abi: treasuryAbi } as const;
  return useReadContracts({
    allowFailure: false,
    contracts: [
      { ...t, functionName: "totals" },
      { ...t, functionName: "reserve" },
      { ...t, functionName: "reserveTarget" },
      { ...t, functionName: "prizeBudget" },
      { ...t, functionName: "buybackFund" },
      { ...t, functionName: "basis" },
      { ...t, functionName: "coverageOwed" },
      { ...t, functionName: "maintenanceTarget" },
      { ...t, functionName: "maintenanceFloor" },
      { ...t, functionName: "poolTarget" },
      { ...t, functionName: "activated" },
      { ...t, functionName: "windingDown" },
      { ...t, functionName: "settled" },
      { ...t, functionName: "dormant" },
      { ...t, functionName: "coinSkimBps" },
      { ...t, functionName: "coinBountyBps" },
      { ...t, functionName: "sponsorShareBps" },
      { ...t, functionName: "maxSponsorShareBps" },
      { ...t, functionName: "bid" },
      { ...t, functionName: "poolKey" },
      { ...t, functionName: "coin" },
    ],
    query: {
      enabled: dep.present && !!dep.treasury,
      refetchInterval: POLL_MS,
      select: ([totals, reserve, reserveTarget, prizeBudget, buybackFund, basis, coverageOwed, maintenanceTarget, maintenanceFloor, poolTarget, activated, windingDown, settled, dormant, coinSkimBps, coinBountyBps, sponsorShareBps, maxSponsorShareBps, bid, poolKey, coin]) => ({
        totals,
        reserve,
        reserveTarget,
        prizeBudget,
        buybackFund,
        basis,
        coverageOwed,
        maintenanceTarget,
        maintenanceFloor,
        poolTarget,
        activated,
        windingDown,
        settled,
        dormant,
        coinSkimBps: Number(coinSkimBps),
        coinBountyBps: Number(coinBountyBps),
        sponsorShareBps: Number(sponsorShareBps),
        maxSponsorShareBps: Number(maxSponsorShareBps),
        bid,
        poolKey,
        coin,
      }),
    },
  });
}

export type TreasuryData = NonNullable<ReturnType<typeof useTreasury>["data"]>;

/** ENGINE coin ERC-20 metadata and supply, from the record's `coin`. */
export function useCoin() {
  const dep = useDeployment();
  const coin = { chainId: dep.chainId, address: dep.coin ?? zeroAddress, abi: erc20Abi } as const;
  return useReadContracts({
    allowFailure: true,
    contracts: [
      { ...coin, functionName: "name" },
      { ...coin, functionName: "symbol" },
      { ...coin, functionName: "decimals" },
      { ...coin, functionName: "totalSupply" },
    ],
    query: {
      enabled: dep.present && !!dep.coin,
      refetchInterval: POLL_MS,
      select: ([name, symbol, decimals, totalSupply]) => ({
        name: name.result as string | undefined,
        symbol: symbol.result as string | undefined,
        decimals: decimals.result as number | undefined,
        totalSupply: totalSupply.result as bigint | undefined,
      }),
    },
  });
}

/** Every PrizeSponsorship read a page needs, in one multicall. Enabled only when a sponsorship is
 *  deployed. */
export function useSponsorship() {
  const dep = useDeployment();
  const s = { chainId: dep.chainId, address: dep.sponsorship ?? zeroAddress, abi: sponsorshipAbi } as const;
  return useReadContracts({
    allowFailure: false,
    contracts: [
      { ...s, functionName: "sponsor" },
      { ...s, functionName: "collection" },
      { ...s, functionName: "treasury" },
      { ...s, functionName: "listPriceWei" },
      { ...s, functionName: "capWei" },
      { ...s, functionName: "reclaimDelay" },
      { ...s, functionName: "tokenId" },
      { ...s, functionName: "listingId" },
      { ...s, functionName: "stakedAt" },
      { ...s, functionName: "reclaimAfter" },
      { ...s, functionName: "paid" },
      { ...s, functionName: "claimed" },
      { ...s, functionName: "won" },
      { ...s, functionName: "reclaimed" },
      { ...s, functionName: "completed" },
      { ...s, functionName: "active" },
      { ...s, functionName: "owed" },
    ],
    query: {
      enabled: dep.present && !!dep.sponsorship,
      refetchInterval: POLL_MS,
      select: ([sponsor, collection, treasury, listPriceWei, capWei, reclaimDelay, tokenId, listingId, stakedAt, reclaimAfter, paid, claimed, won, reclaimed, completed, active, owed]) => ({
        sponsor,
        collection,
        treasury,
        listPriceWei,
        capWei,
        reclaimDelay: Number(reclaimDelay),
        tokenId,
        listingId,
        stakedAt: Number(stakedAt),
        reclaimAfter: Number(reclaimAfter),
        paid,
        claimed,
        won,
        reclaimed,
        completed,
        active,
        owed,
      }),
    },
  });
}

export type SponsorshipData = NonNullable<ReturnType<typeof useSponsorship>["data"]>;
