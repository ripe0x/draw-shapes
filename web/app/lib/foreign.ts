"use client";

import { useQuery } from "@tanstack/react-query";
import { erc721Abi, type Address } from "viem";
import { usePublicClient } from "wagmi";
import { decodeDataJson } from "./art";
import { feeSplitAbi, sponsoredPrizeAbi } from "./abi/sponsor";
import { short } from "./format";
import { useDeployment } from "../Providers";

const IPFS_GATEWAY = "https://ipfs.io/ipfs/";
const FETCH_MS = 8_000;

/** An https URL for `uri`: https stays, ipfs:// goes through a public gateway. Anything else is refused. */
function webUrl(uri: string): string {
  if (uri.startsWith("https://")) return uri;
  if (uri.startsWith("ipfs://")) return IPFS_GATEWAY + uri.slice(7).replace(/^ipfs\//, "");
  throw new Error("Unsupported URI");
}

/** Image URL from a foreign token's `tokenURI`: a data or https JSON document whose `image` is a
 *  data:image, https or ipfs URI. */
async function imageFrom(tokenUri: string): Promise<string> {
  const json = tokenUri.startsWith("data:")
    ? decodeDataJson(tokenUri)
    : await fetch(webUrl(tokenUri), { signal: AbortSignal.timeout(FETCH_MS) }).then((r) => {
        if (!r.ok) throw new Error(`Metadata ${r.status}`);
        return r.json() as Promise<{ image?: unknown }>;
      });
  const image = json.image;
  if (typeof image !== "string") throw new Error("No image");
  return image.startsWith("data:image/") ? image : webUrl(image);
}

/** The collection's `name()`, read once and kept. Falls back to the shortened address. */
export function useCollectionName(collection: Address) {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  return useQuery({
    queryKey: ["collection-name", dep.chainId, collection.toLowerCase()],
    enabled: !!client,
    staleTime: Infinity,
    gcTime: Infinity,
    retry: 1,
    queryFn: () => client!.readContract({ address: collection, abi: erc721Abi, functionName: "name" }).catch(() => short(collection)),
  });
}

type Client = NonNullable<ReturnType<typeof usePublicClient>>;

/** Query options for one foreign token's image, read once and kept. An error means no usable image. */
export const foreignImageQuery = (client: Client | undefined, chainId: number, collection: Address, tokenId: bigint) => ({
  queryKey: ["foreign-image", chainId, collection.toLowerCase(), tokenId.toString()],
  enabled: !!client,
  staleTime: Infinity,
  gcTime: Infinity,
  retry: 1,
  queryFn: async () => imageFrom(await client!.readContract({ address: collection, abi: erc721Abi, functionName: "tokenURI", args: [tokenId] })),
});

/** The foreign token's image, read once and kept. An error means no usable image. */
export function useForeignImage(collection: Address, tokenId: bigint) {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  return useQuery(foreignImageQuery(client, dep.chainId, collection, tokenId));
}

export interface SponsorTerms {
  /** True while the sponsor is owed mint fees: the listing stays at its parked price. */
  parked: boolean;
  reclaimAfter: bigint;
  paidWei: bigint;
  capWei: bigint;
}

/** `SponsoredPrize` terms of a foreign listing's controller, or null when the controller does not
 *  answer `phase`, `reclaimAfter` and `feeSplit` and the split does not answer `paidWei` and `capWei`. */
export function useSponsorTerms(controller: Address) {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  return useQuery({
    queryKey: ["sponsor-terms", dep.chainId, controller.toLowerCase()],
    enabled: !!client,
    staleTime: 30_000,
    refetchInterval: 60_000,
    queryFn: async (): Promise<SponsorTerms | null> => {
      const prize = { address: controller, abi: sponsoredPrizeAbi } as const;
      const a = await client!.multicall({
        allowFailure: true,
        contracts: [
          { ...prize, functionName: "phase" },
          { ...prize, functionName: "reclaimAfter" },
          { ...prize, functionName: "feeSplit" },
        ],
      });
      if (a[0].status !== "success" || a[1].status !== "success" || a[2].status !== "success") return null;
      const split = { address: a[2].result, abi: feeSplitAbi } as const;
      const b = await client!.multicall({
        allowFailure: true,
        contracts: [
          { ...split, functionName: "paidWei" },
          { ...split, functionName: "capWei" },
        ],
      });
      if (b[0].status !== "success" || b[1].status !== "success") return null;
      return { parked: a[0].result === 0, reclaimAfter: a[1].result, paidWei: b[0].result, capWei: b[1].result };
    },
  });
}

/** "1 in N" from a listing's weight against the total weight. Zero weight reads as under 1 in 1,000,000. */
export function oneInOf(weight: bigint, total: bigint): string {
  if (weight === 0n || total === 0n) return "under 1 in 1,000,000";
  const n = Number(total) / Number(weight);
  return n > 1_000_000 ? "under 1 in 1,000,000" : `1 in ${n.toLocaleString("en-US", { maximumFractionDigits: n < 10 ? 1 : 0 })}`;
}
