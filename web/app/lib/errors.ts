import { formatAbiItem } from "viem/utils";
import { toFunctionSelector } from "viem";
import { poolAbi } from "./abi/pool";
import { roundAbi } from "./abi/round";
import { sponsorshipAbi } from "./abi/sponsorship";
import { treasuryAbi } from "./abi/treasury";

/** 4-byte selector -> error name, from every ABI whose reverts the UI surfaces. Lets a bare
 *  `custom error 0x........` from the RPC read as its name (e.g. NothingToDo, NotReady). */
const ERROR_NAMES: Record<string, string> = {};
for (const abi of [treasuryAbi, roundAbi, sponsorshipAbi, poolAbi]) {
  for (const item of abi) {
    if (item.type === "error") {
      try {
        ERROR_NAMES[toFunctionSelector(formatAbiItem(item))] = item.name;
      } catch {
        // Ignore an error fragment viem cannot format.
      }
    }
  }
}

/** Replaces any 4-byte selector the ABIs know with its error name, in place in `text`. */
function nameSelectors(text: string): string {
  return text.replace(/0x[0-9a-fA-F]{8}\b/g, (sel) => {
    const name = ERROR_NAMES[sel.toLowerCase() as keyof typeof ERROR_NAMES];
    return name ? `${name} (${sel})` : sel;
  });
}

/** Joins shortMessage, metaMessages and details along a viem error's cause chain. The top-level
 *  message of a failed transaction is generic; the revert reason is nested. */
export function formatTxError(err: unknown): string {
  const parts: string[] = [];
  let cur: unknown = err;
  for (let depth = 0; cur && depth < 6; depth++) {
    if (!(cur instanceof Error)) {
      parts.push(String(cur));
      break;
    }
    const e = cur as Error & { shortMessage?: string; metaMessages?: string[]; details?: string; cause?: unknown };
    if (e.shortMessage) parts.push(e.shortMessage);
    if (e.metaMessages?.length) parts.push(...e.metaMessages);
    if (e.details) parts.push(e.details);
    cur = e.cause;
  }
  const joined = parts.length ? [...new Set(parts)].join(" ") : err instanceof Error ? err.message : "Unknown error.";
  return nameSelectors(joined);
}

export function evmNowTxUrl(hash: string, chainId: number): string {
  return `https://evm.now/tx/${hash}?chainId=${chainId}`;
}

export function evmNowAddressUrl(address: string, chainId: number): string {
  return `https://evm.now/address/${address}?chainId=${chainId}`;
}
