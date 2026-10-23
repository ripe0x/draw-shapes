"use client";

import { useQuery } from "@tanstack/react-query";
import { useAccount, usePublicClient, useReadContracts } from "wagmi";
import { decodeFunctionResult, encodeFunctionData, zeroAddress, type Address, type PublicClient } from "viem";
import { fwaCloneAbi } from "./abi/external";
import { lensAbi } from "./abi/lens";
import { poolAbi } from "./abi/pool";
import type { Deployment } from "./deployment";
import { eth, utc } from "./format";
import { useDeployment } from "../Providers";

export const POLL_MS = 12_000;
export const MAX_COUNT = 5;

/**
 * Every pool read a page needs, in one multicall polled every 12 seconds. The query key is the call
 * list, so every component that calls this hook shares one query. Lens supplies the views; `IPool`
 * getters supply the buckets Lens does not return.
 */
export function usePool() {
  const dep = useDeployment();
  const { address } = useAccount();
  const chainId = dep.chainId;
  const lens = { chainId, address: dep.lens, abi: lensAbi } as const;
  const pool = { chainId, address: dep.pool, abi: poolAbi } as const;
  return useReadContracts({
    allowFailure: false,
    contracts: [
      { ...lens, functionName: "nav" },
      { ...lens, functionName: "sharePrice" },
      { ...lens, functionName: "parameters" },
      { ...lens, functionName: "admission" },
      { ...lens, functionName: "board" },
      { ...lens, functionName: "grail" },
      { ...lens, functionName: "foreign" },
      { ...lens, functionName: "reopenStatus" },
      { ...lens, functionName: "settleDue" },
      { ...lens, functionName: "rotateDue" },
      { ...lens, functionName: "position", args: [address ?? zeroAddress] },
      { ...pool, functionName: "claims" },
      { ...pool, functionName: "totalShares" },
      { ...pool, functionName: "cash" },
      { ...pool, functionName: "backing" },
      { ...pool, functionName: "receivable" },
      { ...pool, functionName: "maintenance" },
      { ...pool, functionName: "maintenanceReceivable" },
      { ...pool, functionName: "listedCount" },
      { ...pool, functionName: "heldCount" },
      { ...pool, functionName: "boardNavCap" },
    ],
    query: {
      enabled: dep.present,
      refetchInterval: POLL_MS,
      select: ([nav, sharePrice, params, admission, board, grail, foreign, reopen, settleDue, rotateDue, position, claims, totalShares, cash, backing, receivable, maintenance, maintenanceReceivable, listedCount, heldCount, boardNavCap]) => ({
        nav,
        sharePrice,
        params,
        /** Deposit cap, the volume it follows, the room under it and the entry fee now. */
        admission,
        board,
        /** GRAIL fund, cycle, parameters and every GRAIL item. */
        grail,
        /** Foreign listings (sponsored NFT, treasury collectibles) with FWA weight share. */
        foreign,
        reopen,
        settleDue,
        rotateDue,
        position,
        /** Unpaid withdrawal claims in wei. */
        claims,
        totalShares,
        cash,
        backing,
        receivable,
        maintenance,
        maintenanceReceivable,
        listedCount,
        heldCount,
        /** The cap FWA weighting counts ordinary NAV against (engine `poolTarget`). */
        boardNavCap,
      }),
    },
  });
}

/** FWA `totalWeight()` of the pool's FWA clone, polled. Needed for exact "1 in N" odds that the
 *  Lens bps share rounds to zero for rare items. */
export function useFwaTotalWeight() {
  const dep = useDeployment();
  return useReadContracts({
    allowFailure: false,
    contracts: [{ chainId: dep.chainId, address: dep.fwaPool ?? zeroAddress, abi: fwaCloneAbi, functionName: "totalWeight" }],
    query: { enabled: dep.present && !!dep.fwaPool, refetchInterval: POLL_MS, select: ([w]) => w },
  });
}

/** Exact "1 in N draws" for a listing of list price `listPriceWei`, from FWA's raw weights
 *  (weight = 1e36 / listPrice, probability = weight / totalWeight). Returns undefined when it cannot
 *  be computed (no weight yet, or the item is unlisted). */
export function oneInFromWeight(listPriceWei: bigint, totalWeight: bigint | undefined): string | undefined {
  if (!totalWeight || totalWeight === 0n || listPriceWei === 0n) return undefined;
  const weight = weightOf(listPriceWei);
  if (weight === 0n) return undefined;
  const n = Number(totalWeight) / Number(weight);
  return `1 in ${Math.round(n).toLocaleString("en-US")}`;
}

/** Lens `claims()`: the unpaid claim queue from `claimHead`, read on the pages that list it. */
export function useClaimsQueue() {
  const dep = useDeployment();
  return useReadContracts({
    allowFailure: false,
    contracts: [{ chainId: dep.chainId, address: dep.lens, abi: lensAbi, functionName: "claims" }],
    query: { enabled: dep.present, refetchInterval: POLL_MS, select: ([c]) => c },
  });
}

export type PoolData = NonNullable<ReturnType<typeof usePool>["data"]>;
export type Row = PoolData["board"][number];
export type Grail = PoolData["grail"];
export type GrailItem = Grail["items"][number];

// ------------------------------------------------------------------ odds

/** FWA selection weight of one listing: 1e36 / price. */
const weightOf = (priceWei: bigint) => (priceWei > 0n ? 10n ** 36n / priceWei : 0n);

export interface OddsRow {
  key: string;
  /** Redeemable backing of one item. */
  backingWei: bigint;
  priceWei: bigint;
  listed: bigint;
  /** Chance a single pull draws an item of this row, in bps. */
  chanceBps: bigint;
  /** Shape, Draw Pack (rung count) or a GRAIL item. */
  kind: { shape: true } | { pack: number } | { grail: true };
}

/**
 * Selection odds of every listed row and listed GRAIL item, from the board's list prices and the
 * items' notionals under FWA's rule (weight 1e36 / price). `averageBackingWei` is the
 * weight-averaged redeemable backing of one draw.
 */
export function drawOdds(board: readonly Row[], grail: Grail) {
  const parts: Omit<OddsRow, "chanceBps">[] = [];
  board.forEach((r, i) => {
    if (r.listed === 0n || r.listingPrice === 0n) return;
    parts.push({
      key: `row-${i}`,
      backingWei: r.backingWei,
      priceWei: r.listingPrice,
      listed: r.listed,
      kind: r.rungs.length > 1 ? { pack: r.rungs.length } : { shape: true },
    });
  });
  grail.items.forEach((g) => {
    if (g.listingId === 0n || g.notional === 0n) return;
    parts.push({ key: `grail-${g.listingId}`, backingWei: g.backing, priceWei: g.notional, listed: 1n, kind: { grail: true } });
  });
  const weights = parts.map((p) => weightOf(p.priceWei) * p.listed);
  const total = weights.reduce((a, b) => a + b, 0n);
  const rows: OddsRow[] = parts
    .map((p, i) => ({ ...p, chanceBps: total === 0n ? 0n : (weights[i] * 10_000n) / total }))
    .sort((a, b) => (a.backingWei === b.backingWei ? 0 : a.backingWei < b.backingWei ? -1 : 1));
  const averageBackingWei =
    total === 0n ? 0n : parts.reduce((sum, p, i) => sum + weights[i] * p.backingWei, 0n) / total;
  const listedItems = parts.reduce((sum, p) => sum + p.listed, 0n);
  const listedBackingWei = parts.reduce((sum, p) => sum + p.listed * p.backingWei, 0n);
  const largestWei = parts.reduce((max, p) => (p.backingWei > max ? p.backingWei : max), 0n);
  return { rows, averageBackingWei, listedItems, listedBackingWei, largestWei };
}

/** Odds of one GRAIL item per pull, in bps, under the same rule as `drawOdds`. */
export function grailChanceBps(odds: ReturnType<typeof drawOdds>, listingId: bigint): bigint {
  return odds.rows.find((r) => r.key === `grail-${listingId}`)?.chanceBps ?? 0n;
}

// ------------------------------------------------------------------ quote

export interface Quote {
  fee: bigint;
  vrf: bigint;
  total: bigint;
  purchasable: boolean;
  reason: number;
  /** Gas price in wei the VRF fee was quoted at. */
  gasPrice: bigint;
}

async function fwaAddress(client: PublicClient, dep: Deployment): Promise<Address> {
  if (dep.fwaPool) return dep.fwaPool;
  const live = await client.readContract({ address: dep.pool, abi: poolAbi, functionName: "fwaPool" });
  if (live === zeroAddress) throw new Error("The FWA pool is not created yet.");
  return live;
}

/** FWA prices the VRF fee at the transaction gas price, so the quote's eth_call sets the gas price to
 *  the chain's current max fee plus 25 percent. */
export async function readQuote(client: PublicClient | undefined, dep: Deployment, count: number): Promise<Quote> {
  if (!client) throw new Error("No RPC client.");
  const fwa = await fwaAddress(client, dep);
  const base = await client
    .estimateFeesPerGas()
    .then((f) => f.maxFeePerGas)
    .catch(() => client.getGasPrice());
  const gasPrice = (base * 125n) / 100n;
  const [priced, lens] = await Promise.all([
    client.call({
      to: fwa,
      data: encodeFunctionData({ abi: fwaCloneAbi, functionName: "quoteAcquisitionPrice", args: [BigInt(count)] }),
      gasPrice,
    }),
    client.readContract({ address: dep.lens, abi: lensAbi, functionName: "quote", args: [BigInt(count)] }),
  ]);
  const [fee, vrf, total] = decodeFunctionResult({
    abi: fwaCloneAbi,
    functionName: "quoteAcquisitionPrice",
    args: [BigInt(count)],
    data: priced.data ?? "0x",
  });
  return { fee, vrf, total, purchasable: lens.purchasable, reason: lens.reason, gasPrice };
}

export function useQuote(count: number) {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  return useQuery({
    queryKey: ["quote", dep.chainId, dep.pool, count],
    queryFn: () => readQuote(client, dep, count),
    enabled: !!client && dep.present,
    refetchInterval: POLL_MS,
  });
}

/** Gas a pull uses, for the wallet balance check. */
export const PULL_GAS = 1_200_000n;

/** Sent value: the quoted total plus 10 percent. FWA refunds the excess in the same transaction. */
export const sendValue = (q: Quote) => (q.total * 110n) / 100n;

/** ETH a wallet needs for a pull: the sent value plus the pull's gas at the quoted price. */
export const neededWei = (q: Quote) => sendValue(q) + PULL_GAS * q.gasPrice;

/** EIP-1559 caps equal to the quoted gas price, so tx.gasprice never exceeds the quote and the
 *  sent value always covers the VRF fee. */
export function feeCaps(gasPrice: bigint) {
  const priority = gasPrice < 1_000_000_000n ? gasPrice : 1_000_000_000n;
  return { maxFeePerGas: gasPrice, maxPriorityFeePerGas: priority } as const;
}

/** Gas limit from the app's RPC estimate plus 20 percent. A reverting estimate throws with the
 *  decoded revert reason, and the transaction is not sent. */
export async function estimateGas(estimate: () => Promise<bigint>): Promise<{ gas: bigint }> {
  return { gas: ((await estimate()) * 12n) / 10n };
}

/** Quote, FWA slippage and inventory version read at send time so the transaction carries current
 *  values. The fee cap is 2 percent above the quoted fee. */
export async function readFresh(client: PublicClient | undefined, dep: Deployment, count: number) {
  if (!client) throw new Error("No RPC client.");
  const q = await readQuote(client, dep, count);
  const fwa = await fwaAddress(client, dep);
  const [slippage, version, block] = await Promise.all([
    client.readContract({ address: fwa, abi: fwaCloneAbi, functionName: "selectionSlippageBps" }),
    client.readContract({ address: fwa, abi: fwaCloneAbi, functionName: "inventoryVersion" }),
    // The pending block's timestamp is the next block's; the latest block's lags it between blocks.
    client.getBlock({ blockTag: "pending" }).catch(() => client.getBlock()),
  ]);
  // The deadline is 600 seconds after the later of chain time and wall time.
  const now = Math.max(Number(block.timestamp), Math.floor(Date.now() / 1000));
  return {
    q,
    slippage: BigInt(slippage),
    version,
    deadline: BigInt(now + 600),
    maxFee: (q.fee * 102n) / 100n,
    value: sendValue(q),
  };
}

// ------------------------------------------------------------------ pull state

export type PullState = { open: boolean; pill: string; tone: "warn" | "bad"; headline: string; sub?: string };

/** Whether pulls are open, from the lifecycle, the pause flag and the three reopen guards. */
export function pullState(pool: PoolData, poolAddress: Address): PullState {
  const p = pool.params;
  const r = pool.reopen;
  if (p.lifecycle === 0) {
    const at = Number(p.openingDeadlineAt);
    return {
      open: false,
      pill: "Opening",
      tone: "warn",
      headline: "Pulls start when the pool opens.",
      sub: at ? `The opening deadline is ${utc(at)}. Deposits are open now.` : "Deposits are open now.",
    };
  }
  if (p.lifecycle === 2) return { open: false, pill: "Exiting", tone: "bad", headline: "The pool is exiting.", sub: "Pulls and deposits are closed while exportStep runs." };
  if (p.lifecycle === 3) {
    const retired = p.exitDest.toLowerCase() === poolAddress.toLowerCase();
    return {
      open: false,
      pill: "Exported",
      tone: "bad",
      headline: retired ? "The pool is retired." : "The pool migrated to a successor.",
      sub: retired ? "Holders withdraw against cash at NAV." : "Holders claim successor shares with migrateHolder on the successor pool.",
    };
  }
  if (p.pullsPaused) return { open: false, pill: "Paused", tone: "bad", headline: "Pulls are paused by the admin." };
  if (!r.cooldownPassed) {
    return { open: false, pill: "Restocking", tone: "warn", headline: "FWA is between inventory updates.", sub: `Pulls resume at ${utc(r.purchasesResumeAt)}.` };
  }
  if (!r.solvent) {
    return {
      open: false,
      pill: "Settling",
      tone: "warn",
      headline: "Pulls wait until the pool's ETH covers its buckets.",
      sub: `Balance ${eth(r.balance)} ETH against ${eth(r.required)} ETH required.`,
    };
  }
  if (!r.boardDeep) {
    return {
      open: false,
      pill: "Restocking",
      tone: "warn",
      headline: "The board is restocking.",
      sub: `${r.listedCount} listed against ${r.unsettled} unsettled pulls plus ${r.concurrency} of headroom.`,
    };
  }
  return { open: true, pill: "Open", tone: "warn", headline: "Pull a Shape or a Draw Pack.", sub: `${pool.listedCount.toLocaleString("en-US")} items listed.` };
}
