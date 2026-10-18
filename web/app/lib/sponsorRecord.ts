import { readFileSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { isAddress, type Address } from "viem";
import { getDeployment } from "./deployment";

/** One sponsored prize deal, written by `script/DeploySponsor.s.sol`. */
export interface SponsorRecord {
  feeSplit: Address;
  prize: Address;
  collection: Address;
}

/**
 * Reads a record file or JSON object. `envVar` is a JSON object or a path (relative to `web/`).
 * Without it the record sits beside the deployment record: `<NEXT_PUBLIC_DEPLOYMENT minus .json>-<suffix>.json`
 * for a path, else `../deployments/<chainId>-<suffix>.json`. Read per request. Undefined when the file
 * or JSON is invalid.
 */
export function readRecord(envVar: string, suffix: string): Record<string, string> | undefined {
  const source = process.env[envVar]?.trim();
  const deployment = process.env.NEXT_PUBLIC_DEPLOYMENT?.trim();
  try {
    let text = source;
    if (!source?.startsWith("{")) {
      const rel =
        source ||
        (deployment && !deployment.startsWith("{") && deployment.endsWith(".json")
          ? deployment.replace(/\.json$/, `-${suffix}.json`)
          : join("..", "deployments", `${getDeployment().chainId}-${suffix}.json`));
      const file = isAbsolute(rel) ? rel : join(/*turbopackIgnore: true*/ process.cwd(), rel);
      text = readFileSync(/*turbopackIgnore: true*/ file, "utf8");
    }
    return JSON.parse(text as string);
  } catch {
    return undefined;
  }
}

/** `NEXT_PUBLIC_SPONSOR` overrides the path. Undefined when there is no valid record, which the page shows as no deal. */
export function getSponsorRecord(): SponsorRecord | undefined {
  const r = readRecord("NEXT_PUBLIC_SPONSOR", "sponsor");
  if (!r || !isAddress(r.feeSplit) || !isAddress(r.prize) || !isAddress(r.collection)) return undefined;
  return { feeSplit: r.feeSplit, prize: r.prize, collection: r.collection };
}
