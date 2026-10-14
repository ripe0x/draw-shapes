"use client";

import { useQueries, useQuery, useQueryClient } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import type { Address } from "viem";
import { fwaCloneAbi, packsAbi, shapesAbi } from "./abi/external";
import { useDeployment } from "../Providers";

/** First `image` field of a data-URI JSON `tokenURI`, restricted to data:image URIs. */
export function imageOf(uri: string): string {
  const m = /^data:application\/json(;base64)?,(.*)$/s.exec(uri);
  if (!m) throw new Error("Unsupported tokenURI");
  const text = m[1] ? new TextDecoder().decode(Uint8Array.from(atob(m[2]), (c) => c.charCodeAt(0))) : decodeURIComponent(m[2]);
  const image = JSON.parse(text).image;
  if (typeof image !== "string" || !image.startsWith("data:image/")) throw new Error("No inline image");
  return image;
}

export interface Token {
  collection: Address;
  tokenId: bigint;
}

const imageQuery = (client: ReturnType<typeof usePublicClient>, chainId: number, packs: Address, t: Token) => ({
  queryKey: ["token-image", chainId, t.collection.toLowerCase(), t.tokenId.toString()],
  queryFn: async () =>
    imageOf(
      await client!.readContract({
        address: t.collection,
        abi: t.collection.toLowerCase() === packs.toLowerCase() ? packsAbi : shapesAbi,
        functionName: "tokenURI",
        args: [t.tokenId],
      }),
    ),
  enabled: !!client,
  staleTime: Infinity,
  gcTime: Infinity,
  retry: 1,
});

/** The token's on-chain image from `tokenURI`, read once per token and cached without expiry. */
export function useTokenImage(token: Token | undefined) {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  return useQuery({
    ...imageQuery(client, dep.chainId, dep.drawPacks, token ?? { collection: dep.shapes, tokenId: 0n }),
    enabled: !!client && !!token,
  });
}

/** Loaded images of `tokens`, in order, skipping any still loading or failed. */
export function useTokenImages(tokens: readonly Token[]): string[] {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  const results = useQueries({ queries: tokens.map((t) => imageQuery(client, dep.chainId, dep.drawPacks, t)) });
  return results.flatMap((r) => (r.data ? [r.data] : []));
}

export interface ListedItem extends Token {
  listingId: bigint;
  pack: boolean;
  priceWei: bigint;
  /** Backing of a Shape, value of a Draw Pack: the ETH it redeems for. */
  valueWei: bigint;
}

/** Listing ids read per multicall. */
const CHUNK = 400n;

interface ListedScan {
  /** `nextListingId` at the scan. Ids below it are either known active or inactive. */
  next: bigint;
  items: ListedItem[];
}

type FwaClient = NonNullable<ReturnType<typeof usePublicClient>>;
type RawListing = Omit<ListedItem, "pack" | "valueWei">;

/** Active listings among `ids`, read in `CHUNK` multicalls. */
async function activeAmong(client: FwaClient, fwa: Address, ids: bigint[]): Promise<RawListing[]> {
  const out: RawListing[] = [];
  for (let i = 0; i < ids.length; i += Number(CHUNK)) {
    const part = ids.slice(i, i + Number(CHUNK));
    const rows = await client.multicall({
      allowFailure: true,
      contracts: part.map((id) => ({ address: fwa, abi: fwaCloneAbi, functionName: "listings", args: [id] }) as const),
    });
    rows.forEach((r, j) => {
      if (r.status === "success" && r.result[7] === 1) out.push({ listingId: part[j], collection: r.result[0], tokenId: r.result[3], priceWei: r.result[5] });
    });
  }
  return out;
}

const range = (from: bigint, to: bigint) => Array.from({ length: Number(to > from ? to - from : 0n) }, (_, i) => from + BigInt(i));

// ponytail: the first read is O(nextListingId) when an early listing is still active; an indexer or a
// Lens listing view replaces the walk.
/**
 * Every active FWA listing with its token's redeemable value. The first read walks back from
 * `nextListingId` until it holds `activeListingCount` listings; later reads cover the new ids and
 * recheck the known active ones, once a minute.
 */
export function useListedItems() {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  const queryClient = useQueryClient();
  const key = ["listed-items", dep.chainId, dep.fwaPool] as const;
  return useQuery({
    queryKey: key,
    enabled: !!client && !!dep.fwaPool,
    staleTime: 60_000,
    refetchInterval: 60_000,
    select: (d: ListedScan) => d.items,
    queryFn: async (): Promise<ListedScan> => {
      const fwa = dep.fwaPool!;
      const c = client!;
      const [next, activeCount] = await Promise.all([
        c.readContract({ address: fwa, abi: fwaCloneAbi, functionName: "nextListingId" }),
        c.readContract({ address: fwa, abi: fwaCloneAbi, functionName: "activeListingCount" }),
      ]);
      const prior = queryClient.getQueryData<ListedScan>(key);
      let active: RawListing[];
      if (prior && prior.next <= next) {
        active = await activeAmong(c, fwa, [...prior.items.map((i) => i.listingId), ...range(prior.next, next)]);
      } else {
        active = [];
        for (let hi = next; hi > 0n && BigInt(active.length) < activeCount; hi -= CHUNK) {
          active.push(...(await activeAmong(c, fwa, range(hi > CHUNK ? hi - CHUNK : 0n, hi))));
        }
      }
      // Values carry over by listing id; new listings read `backingOf` or `valueOf`.
      const known = new Map(prior?.items.map((i) => [i.listingId, i.valueWei]));
      const packs = dep.drawPacks.toLowerCase();
      const fresh = active.filter((a) => !known.has(a.listingId));
      const values = await c.multicall({
        allowFailure: true,
        contracts: fresh.map((a) =>
          a.collection.toLowerCase() === packs
            ? ({ address: a.collection, abi: packsAbi, functionName: "valueOf", args: [a.tokenId] } as const)
            : ({ address: a.collection, abi: shapesAbi, functionName: "backingOf", args: [a.tokenId] } as const),
        ),
      });
      fresh.forEach((a, i) => known.set(a.listingId, values[i].status === "success" ? (values[i].result as bigint) : 0n));
      return {
        next,
        items: active.map((a) => ({ ...a, pack: a.collection.toLowerCase() === packs, valueWei: known.get(a.listingId) ?? 0n })),
      };
    },
  });
}
