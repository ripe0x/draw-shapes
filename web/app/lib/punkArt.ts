"use client";

import { useEffect, useState } from "react";
import { useQueries, useQuery } from "@tanstack/react-query";
import { parseAbi, type Address } from "viem";
import { usePublicClient } from "wagmi";
import { foreignImageQuery } from "./foreign";
import { useDeployment } from "../Providers";

/** Wrapped Cryptopunks on Ethereum mainnet. A mainnet fork serves the same address. */
export const WRAPPED_PUNKS: Address = "0xb7F7F6C52F2e2fdb1963Eab30438024864c313F6";

const SAMPLE_SIZE = 10;
const CYCLE_MS = 1_500;
const enumerableAbi = parseAbi(["function totalSupply() view returns (uint256)", "function tokenByIndex(uint256) view returns (uint256)"]);

/** Up to `SAMPLE_SIZE` distinct indexes below `supply`. */
function sampleIndexes(supply: number): bigint[] {
  const picked = new Set<number>();
  while (picked.size < Math.min(SAMPLE_SIZE, supply)) picked.add(Math.floor(Math.random() * supply));
  return [...picked].map(BigInt);
}

/**
 * Image of one token at a time from `collection` (an ERC-721 with enumerable extension, default
 * Wrapped Cryptopunks), cycling every 1.5 seconds through ten tokens drawn at random once per
 * session. Token ids come from `totalSupply` and `tokenByIndex`; each image goes through the
 * foreign token loader and stays cached. Cycling starts once two images have loaded; before that
 * the first loaded image shows. Undefined while none has loaded.
 */
export function useCyclingPunkArt(collection: Address = WRAPPED_PUNKS): string | undefined {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  const ids = useQuery({
    queryKey: ["punk-art-ids", dep.chainId, collection.toLowerCase()],
    enabled: !!client,
    staleTime: Infinity,
    gcTime: Infinity,
    retry: 1,
    queryFn: async () => {
      const supply = await client!.readContract({ address: collection, abi: enumerableAbi, functionName: "totalSupply" });
      return client!.multicall({
        allowFailure: false,
        contracts: sampleIndexes(Number(supply)).map((i) => ({ address: collection, abi: enumerableAbi, functionName: "tokenByIndex", args: [i] }) as const),
      });
    },
  });
  const images = useQueries({ queries: (ids.data ?? []).map((id) => foreignImageQuery(client, dep.chainId, collection, id)) })
    .flatMap((r) => (r.data ? [r.data] : []));

  const [tick, setTick] = useState(0);
  const cycling = images.length >= 2;
  useEffect(() => {
    if (!cycling) return;
    const timer = setInterval(() => setTick((t) => t + 1), CYCLE_MS);
    return () => clearInterval(timer);
  }, [cycling]);

  return images.length > 0 ? images[(cycling ? tick : 0) % images.length] : undefined;
}
