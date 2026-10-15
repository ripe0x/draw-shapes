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
 * `NEXT_PUBLIC_SPONSOR` is a JSON object or a path (relative to `web/`) to the deal record. Without
 * it the record sits beside the deployment record: `<NEXT_PUBLIC_DEPLOYMENT minus .json>-sponsor.json`
 * for a path, else `../deployments/<chainId>-sponsor.json`. Read per request. Undefined when there is
 * no valid record, which the page shows as no deal.
 */
export function getSponsorRecord(): SponsorRecord | undefined {
  const source = process.env.NEXT_PUBLIC_SPONSOR?.trim();
  const deployment = process.env.NEXT_PUBLIC_DEPLOYMENT?.trim();
  try {
    let text = source;
    if (!source?.startsWith("{")) {
      const rel =
        source ||
        (deployment && !deployment.startsWith("{") && deployment.endsWith(".json")
          ? deployment.replace(/\.json$/, "-sponsor.json")
          : join("..", "deployments", `${getDeployment().chainId}-sponsor.json`));
      const file = isAbsolute(rel) ? rel : join(/*turbopackIgnore: true*/ process.cwd(), rel);
      text = readFileSync(/*turbopackIgnore: true*/ file, "utf8");
    }
    const r = JSON.parse(text as string);
    if (!isAddress(r.feeSplit) || !isAddress(r.prize) || !isAddress(r.collection)) return undefined;
    return { feeSplit: r.feeSplit, prize: r.prize, collection: r.collection };
  } catch {
    return undefined;
  }
}
