// Copies deployments/<NEXT_PUBLIC_DEPLOYMENT>.json (default 1) into the bundle. Without a record (before mainnet
// deployment) it writes a placeholder with zero addresses, and the site says it is not deployed yet.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const name = process.env.NEXT_PUBLIC_DEPLOYMENT || "1";
const src = fileURLToPath(new URL(`../../deployments/${name}.json`, import.meta.url));
const out = fileURLToPath(new URL("../app/lib/deployment.generated.json", import.meta.url));
const zero = "0x0000000000000000000000000000000000000000";
const keys = ["game", "farm", "treasury", "keeperFund", "buyback", "grailFund", "swapPolicy", "liquidity", "engine",
  "lens", "converter", "fwaPool", "vault", "shapes", "timelock"];
let rec = { chainId: Number(name) || 1, deployed: false };
if (existsSync(src)) {
  rec = { ...JSON.parse(readFileSync(src, "utf8")), deployed: true };
} else {
  for (const k of keys) rec[k] = zero;
}
writeFileSync(out, JSON.stringify(rec, null, 2));
console.log(`deployment: ${existsSync(src) ? src : "placeholder (not deployed)"}`);
