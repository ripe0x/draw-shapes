"use client";

import { useEffect, useMemo, useState } from "react";
import meta from "../../public/fwair-prev/meta.json";

const SUPPLY = 111;
const CYCLE_MS = 1_000;
const CYCLE_COUNT = 10;
/** Comparison route: only ids 1 to 10 have image files under public/fwair-prev. */
const FIXTURE_IMAGES = 10;
const names = meta as Record<string, string>;

/** Static art for one FWAIR PFP: the collection is immutable, so the images live in public/fwair
 *  (scripts/fwair-assets.mjs) and the page never reads IPFS at runtime. */
export function fwairPfpArt(tokenId: bigint) {
  const id = tokenId.toString();
  return { tokenId, name: names[id] ?? `FWAir PFP #${id}`, image: `/fwair-prev/${id}.jpg` };
}

/** Ten passes per page load, #1 first and nine drawn at random after it, cycling every few
 *  seconds. `pool` (a holder's own passes) replaces the random draw. */
export function useCyclingFwairPfp(pool?: bigint[]) {
  const poolKey = pool && pool.length > 0 ? pool.map(String).join(",") : "";
  const [drawn] = useState(() => drawIds());
  const ids = useMemo(() => (poolKey ? poolKey.split(",").map((v) => BigInt(v)) : drawn), [poolKey, drawn]);
  const [index, setIndex] = useState(0);

  useEffect(() => {
    if (ids.length <= 1) return;
    const timer = setInterval(() => setIndex((i) => i + 1), CYCLE_MS);
    return () => clearInterval(timer);
  }, [ids.length]);

  return fwairPfpArt(ids[index % ids.length]);
}

/** Draws from the ids present in meta.json, so a partial asset set still cycles cleanly. */
function drawIds(): bigint[] {
  const rest = Object.keys(names)
    .map((id) => BigInt(id))
    .filter((id) => id !== 1n && id <= BigInt(SUPPLY) && id <= BigInt(FIXTURE_IMAGES));
  for (let i = rest.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [rest[i], rest[j]] = [rest[j], rest[i]];
  }
  return [1n, ...rest.slice(0, CYCLE_COUNT - 1)];
}
