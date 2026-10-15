"use client";

import { useQuery } from "@tanstack/react-query";
import { decodeFunctionResult, encodeFunctionData, erc721Abi, parseAbi, type Address } from "viem";
import { usePublicClient } from "wagmi";
import { decodeDataJson } from "./art";
import { feeSplitAbi, sponsoredPrizeAbi } from "./abi/sponsor";
import { short } from "./format";
import { useDeployment } from "../Providers";

/** Wrapped Cryptopunks on Ethereum mainnet. A mainnet fork serves the same address. */
export const WRAPPED_PUNKS: Address = "0xb7F7F6C52F2e2fdb1963Eab30438024864c313F6";
/** CryptoPunksData on Ethereum mainnet: the original punk art by index. */
const PUNKS_DATA: Address = "0x16F5A35647D6F03D5D3da7b35409D65ba03aF3B2";
const punksDataAbi = parseAbi(["function punkImageSvg(uint16 index) view returns (string)"]);
const SVG_PREFIX = "data:image/svg+xml;utf8,";

type Client = NonNullable<ReturnType<typeof usePublicClient>>;

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

/** The original punk art for Wrapped Cryptopunks token `tokenId`, without the wrapper ribbon of its `tokenURI`
 *  image. Each read is its own eth_call: the SVG render is gas heavy and aggregated multicalls run out of gas. The SVG is percent-encoded so `#` colours survive in a data URL. */
async function punkImage(client: Client, tokenId: bigint): Promise<string> {
  const { data } = await client.call({
    to: PUNKS_DATA,
    data: encodeFunctionData({ abi: punksDataAbi, functionName: "punkImageSvg", args: [Number(tokenId)] }),
    batch: false,
  });
  const svg = decodeFunctionResult({ abi: punksDataAbi, functionName: "punkImageSvg", data: data ?? "0x" });
  if (!svg.startsWith(SVG_PREFIX)) throw new Error("No image");
  return SVG_PREFIX + encodeURIComponent(svg.slice(SVG_PREFIX.length));
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

/** Query options for one foreign token's image, read once and kept. An error means no usable image. */
export const foreignImageQuery = (client: Client | undefined, chainId: number, collection: Address, tokenId: bigint) => ({
  queryKey: ["foreign-image", chainId, collection.toLowerCase(), tokenId.toString()],
  enabled: !!client,
  staleTime: Infinity,
  gcTime: Infinity,
  retry: 1,
  queryFn: async () =>
    collection.toLowerCase() === WRAPPED_PUNKS.toLowerCase()
      ? punkImage(client!, tokenId)
      : imageFrom(await client!.readContract({ address: collection, abi: erc721Abi, functionName: "tokenURI", args: [tokenId] })),
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
