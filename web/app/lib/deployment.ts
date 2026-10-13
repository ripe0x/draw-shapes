import { readFileSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import type { Address } from "viem";

export interface Deployment {
  /** False when no record was found. Pages then render the missing-deployment notice. */
  present: boolean;
  chainId: number;
  pool: Address;
  lens: Address;
  shapes: Address;
  drawPacks: Address;
  /** Absent until the admin creates the FWA pool. */
  fwaPool?: Address;
  openingDeadlineAt?: number;
}

const CHAIN_IDS = [31337, 11155111, 1];
const ZERO = "0x0000000000000000000000000000000000000000" as const;

function missing(chainId: number): Deployment {
  return { present: false, chainId, pool: ZERO, lens: ZERO, shapes: ZERO, drawPacks: ZERO };
}

/**
 * `NEXT_PUBLIC_DEPLOYMENT` is a JSON object or a path (relative to `web/`) to a record written by
 * `script/deploy.sh`. Without it the app reads `../deployments/<NEXT_PUBLIC_CHAIN_ID>.json`
 * (default 31337; 11155111 and 1 are the other chains). Read per request, so a record written
 * after the build is picked up.
 */
export function getDeployment(): Deployment {
  const source = process.env.NEXT_PUBLIC_DEPLOYMENT?.trim();
  const envChain = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 31337);
  const chainId = CHAIN_IDS.includes(envChain) ? envChain : 31337;
  try {
    const file = source
      ? isAbsolute(source)
        ? source
        : join(/*turbopackIgnore: true*/ process.cwd(), source)
      : join(/*turbopackIgnore: true*/ process.cwd(), "..", "deployments", `${chainId}.json`);
    const text = source?.startsWith("{") ? source : readFileSync(/*turbopackIgnore: true*/ file, "utf8");
    const r = JSON.parse(text);
    if (!r.pool || !r.lens) return missing(chainId);
    const fwaPool = r.fwaPool && r.fwaPool !== ZERO ? (r.fwaPool as Address) : undefined;
    return {
      present: true,
      chainId: Number(r.chainId ?? chainId),
      pool: r.pool,
      lens: r.lens,
      shapes: r.shapes,
      drawPacks: r.drawPacks,
      fwaPool,
      openingDeadlineAt: r.openingDeadlineAt ? Number(r.openingDeadlineAt) : undefined,
    };
  } catch {
    return missing(chainId);
  }
}
