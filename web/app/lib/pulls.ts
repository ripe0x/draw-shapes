"use client";

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useAccount, usePublicClient } from "wagmi";
import { getAbiItem, zeroAddress, type Address, type PublicClient } from "viem";
import { fwaCloneAbi, packsAbi, shapesAbi } from "./abi/external";
import { poolAbi } from "./abi/pool";
import type { Deployment } from "./deployment";
import { useDeployment } from "../Providers";

const POLL_MS = 6_000;
/** Poll while the only open work is a delivered pack waiting for `settle` to book it. */
const BOOKING_POLL_MS = 30_000;
const pulledEvent = getAbiItem({ abi: poolAbi, name: "Pulled" });
const grailEvent = getAbiItem({ abi: poolAbi, name: "GrailCaptured" });
const capturedEvent = getAbiItem({ abi: poolAbi, name: "Captured" });

/** FWA `AcquisitionStatus` codes the UI branches on. */
export const ACQ = {
  None: 0,
  Pending: 1,
  Fulfilled: 2,
  Expired: 3,
  Refunded: 4,
  Ready: 5,
  TimedOut: 6,
  DeliveryPending: 7,
  DeliveryRefunded: 8,
} as const;
export const UNRESOLVED = new Set<number>([ACQ.None, ACQ.Pending, ACQ.Ready, ACQ.TimedOut, ACQ.DeliveryPending]);

export interface Item {
  collection: Address;
  tokenId: bigint;
  pack: boolean;
  /** Backing of a Shape, value of a Draw Pack: the ETH it redeems for at face. */
  value: bigint;
  /** True once `settle` booked the capture. Shapes need no booking check. */
  booked: boolean;
  /** GRAIL track the pack belonged to, once `settle` books the capture. */
  grail?: number;
}
export interface Card {
  id: bigint;
  status: number;
  /** Ticket paid for this pull, VRF fee excluded. */
  ticket: bigint;
  item?: Item;
}
export interface Batch {
  tx: `0x${string}`;
  block: bigint;
  count: bigint;
  fee: bigint;
  ids: readonly bigint[];
}
export interface PullsData {
  /** Last block scanned for `Pulled`. */
  scanned: bigint;
  batches: Batch[];
  cards: Record<string, Card>;
  /** Request ids seen moving from unresolved to delivered while the page was open. */
  fresh: string[];
}

/** Block span of one `getLogs` call, within the range caps of public RPCs. */
const LOG_SPAN = 50_000n;

/** `getLogs` over [from, to] in `LOG_SPAN` windows. */
async function logsIn<T>(from: bigint, to: bigint, read: (from: bigint, to: bigint) => Promise<T[]>): Promise<T[]> {
  const out: T[] = [];
  for (let a = from; a <= to; a += LOG_SPAN) out.push(...(await read(a, a + LOG_SPAN - 1n < to ? a + LOG_SPAN - 1n : to)));
  return out;
}

/** Scans `Pulled` for the wallet from the last scanned block, reads the requests still unresolved on
 *  the FWA pool and the newly delivered items. `prior` carries the earlier result. */
async function load(client: PublicClient, dep: Deployment, owner: Address, prior?: PullsData): Promise<PullsData> {
  const latest = await client.getBlockNumber();
  const base = prior && prior.scanned <= latest ? prior : undefined;
  const from = base ? base.scanned + 1n : BigInt(dep.blockNumber);
  const logs = await logsIn(from, latest, (a, b) =>
    client.getLogs({ address: dep.pool, event: pulledEvent, args: { purchaser: owner }, fromBlock: a, toBlock: b, strict: true }),
  );
  const batches = [
    ...(base?.batches ?? []),
    ...logs.map((l) => ({ tx: l.transactionHash, block: l.blockNumber, count: l.args.count, fee: l.args.fee, ids: l.args.requestIds })),
  ];
  const fee = new Map(batches.flatMap((b) => b.ids.map((id) => [id, b.fee] as const)));
  const blockOf = new Map(batches.flatMap((b) => b.ids.map((id) => [id, b.block] as const)));
  const ids = batches.flatMap((b) => b.ids);
  if (!ids.length) return { scanned: latest, batches, cards: {}, fresh: [] };

  // Settled cards carry over; only unresolved requests are read again.
  const cards: Record<string, Card> = {};
  for (const id of ids) {
    const was = base?.cards[id.toString()];
    cards[id.toString()] = was ? { ...was, item: was.item && { ...was.item } } : { id, status: ACQ.None, ticket: fee.get(id)! };
  }
  const reread = ids.filter((id) => UNRESOLVED.has(cards[id.toString()].status));
  const fwa = dep.fwaPool ?? (await client.readContract({ address: dep.pool, abi: poolAbi, functionName: "fwaPool" }));
  if (fwa === zeroAddress) throw new Error("The FWA pool is not created yet.");
  const acqs = reread.length
    ? await client.multicall({
        allowFailure: false,
        contracts: reread.map((id) => ({ address: fwa, abi: fwaCloneAbi, functionName: "acquisitions", args: [id] }) as const),
      })
    : [];
  reread.forEach((id, i) => {
    cards[id.toString()].status = acqs[i][4];
  });

  // Newly delivered requests: the listing, then its backing or value.
  const todo = reread.flatMap((id, i) => (acqs[i][4] === ACQ.Fulfilled ? [{ id, listingId: acqs[i][3] }] : []));
  if (todo.length) {
    const lists = await client.multicall({
      allowFailure: false,
      contracts: todo.map((t) => ({ address: fwa, abi: fwaCloneAbi, functionName: "listings", args: [t.listingId] }) as const),
    });
    const packs = lists.map((l) => l[0].toLowerCase() === dep.drawPacks.toLowerCase());
    const values = await client.multicall({
      allowFailure: false,
      contracts: lists.map((l, i) =>
        packs[i]
          ? ({ address: l[0], abi: packsAbi, functionName: "valueOf", args: [l[3]] } as const)
          : ({ address: l[0], abi: shapesAbi, functionName: "backingOf", args: [l[3]] } as const),
      ),
    });
    todo.forEach((t, i) => {
      cards[t.id.toString()].item = { collection: lists[i][0], tokenId: lists[i][3], pack: packs[i], value: values[i], booked: !packs[i] };
    });
  }

  // `settle` books a delivered pack as an ordinary capture or a GRAIL capture. Packs are rechecked
  // from their batch block until one of the two events names the request.
  const open = Object.values(cards).filter((c) => c.item && !c.item.booked);
  if (open.length) {
    const since = open.reduce((min, c) => (blockOf.get(c.id)! < min ? blockOf.get(c.id)! : min), latest);
    const requestId = open.map((c) => c.id);
    const [ordinary, grail] = await Promise.all([
      logsIn(since, latest, (a, b) => client.getLogs({ address: dep.pool, event: capturedEvent, args: { requestId }, fromBlock: a, toBlock: b, strict: true })),
      logsIn(since, latest, (a, b) => client.getLogs({ address: dep.pool, event: grailEvent, args: { requestId }, fromBlock: a, toBlock: b, strict: true })),
    ]);
    for (const l of ordinary) cards[l.args.requestId.toString()].item!.booked = true;
    for (const l of grail) Object.assign(cards[l.args.requestId.toString()].item!, { booked: true, grail: Number(l.args.track) });
  }

  const fresh = new Set(base?.fresh);
  for (const [key, c] of Object.entries(cards)) {
    const was = base?.cards[key];
    if (was && UNRESOLVED.has(was.status) && c.status === ACQ.Fulfilled) fresh.add(key);
  }
  return { scanned: latest, batches, cards, fresh: [...fresh] };
}

/** The connected wallet's pulls on this pool. Polls every 6 seconds while a pull is unresolved and
 *  every 30 seconds while a delivered pack awaits booking. */
export function usePulls() {
  const dep = useDeployment();
  const { address } = useAccount();
  const client = usePublicClient({ chainId: dep.chainId });
  const queryClient = useQueryClient();
  const key = ["pulls", dep.chainId, dep.pool, address] as const;
  return useQuery({
    queryKey: key,
    queryFn: () => load(client!, dep, address!, queryClient.getQueryData<PullsData>(key)),
    enabled: !!client && !!address && dep.present,
    refetchInterval: (q) => {
      const cards = Object.values(q.state.data?.cards ?? {});
      if (cards.some((c) => UNRESOLVED.has(c.status))) return POLL_MS;
      return cards.some((c) => c.item && !c.item.booked) ? BOOKING_POLL_MS : false;
    },
  });
}
