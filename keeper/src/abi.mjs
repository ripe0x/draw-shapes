// Minimal ABIs for the keeper's reads and writes.
import { parseAbi } from "viem";

export const lensAbi = parseAbi([
  "struct Addresses { address game; address farm; address treasury; address keeperFund; address buyback; address grailFund; address swapPolicy; address liquidity; }",
  "struct WorkView { uint256 syncable; uint256 unlistedRows; uint256 syncAge; uint256 unallocated; uint256 distributeAge; bool buybackReady; uint256 buybackSlice; uint256 grailOwed; bool retireUnearnedReady; uint256 keeperFundAvailable; }",
  "function work(Addresses a) view returns (WorkView)",
]);

export const gameAbi = parseAbi([
  "function sync(uint256 maxCount) returns (uint256)",
  "function lastMaintenanceAt() view returns (uint256)",
  "function maintenanceInterval() view returns (uint256)",
]);
export const treasuryAbi = parseAbi(["function distribute() returns (uint256)"]);
export const buybackAbi = parseAbi([
  "function process(uint256 minOut) returns (uint256)",
  "function lastRunAt() view returns (uint256)",
]);
export const grailFundAbi = parseAbi(["function process() returns (uint256)", "function lastRunAt() view returns (uint256)"]);
export const farmAbi = parseAbi(["function retireUnearned() returns (uint256)", "function genesisEndBlock() view returns (uint256)"]);
