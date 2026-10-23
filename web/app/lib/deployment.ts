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
  // Engine contracts. Each is absent when its record key is missing or the zero address, so a page
  // that needs one renders the "not deployed yet" state rather than reading a dead address.
  treasury?: Address;
  round?: Address;
  coin?: Address;
  sponsorship?: Address;
  poolManager?: Address;
  adminModule?: Address;
  listingModule?: Address;
  gitCommit?: string;
  openingDeadlineAt?: number;
  /** Block the pool was deployed in; event scans start here. */
  blockNumber: number;
}

const CHAIN_IDS = [31337, 11155111, 1];
const ZERO = "0x0000000000000000000000000000000000000000" as const;

function missing(chainId: number): Deployment {
  return { present: false, chainId, pool: ZERO, lens: ZERO, shapes: ZERO, drawPacks: ZERO, blockNumber: 0 };
}

/** A record address, or undefined when it is missing or the zero placeholder. */
const addr = (v: unknown): Address | undefined => (typeof v === "string" && v !== ZERO ? (v as Address) : undefined);

/**
 * `NEXT_PUBLIC_DEPLOYMENT` is a JSON object or a path (relative to `web/`) to a record written by
 * `script/deploy.sh` or `script/EngineDeployer`. Without it the app reads
 * `../deployments/<NEXT_PUBLIC_CHAIN_ID>.json` (default 31337; 11155111 and 1 are the other chains).
 * Read per request, so a record written after the build is picked up. The engine record adds the
 * treasury, round, coin, sponsorship and module keys; the older pool-only record still works.
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
    return {
      present: true,
      chainId: Number(r.chainId ?? chainId),
      pool: r.pool,
      lens: r.lens,
      shapes: r.shapes,
      drawPacks: r.drawPacks,
      fwaPool: addr(r.fwaPool),
      treasury: addr(r.treasury),
      round: addr(r.round),
      coin: addr(r.coin),
      sponsorship: addr(r.sponsorship),
      poolManager: addr(r.poolManager),
      adminModule: addr(r.adminModule),
      listingModule: addr(r.listingModule),
      gitCommit: typeof r.gitCommit === "string" ? r.gitCommit : undefined,
      blockNumber: Number(r.blockNumber ?? 0),
      openingDeadlineAt: r.openingDeadlineAt ? Number(r.openingDeadlineAt) : undefined,
    };
  } catch {
    return missing(chainId);
  }
}
