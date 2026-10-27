// Minimal ABIs for the keeper's reads and writes.
import { parseAbi } from "viem";

export const lensAbi = parseAbi([
  "struct Addresses { address game; address farm; address keeperFund; address buyback; address swapPolicy; address liquidity; address vault; address converter; }",
  "struct WorkView { uint256 syncable; uint256 unlistedRows; uint256 syncAge; bool admissionChange; bool buybackReady; uint256 buybackSlice; bool buybackPriceOk; uint256[] finalizable; bool bonusRetireReady; uint256 keeperFundAvailable; }",
  "function work(Addresses a) view returns (WorkView)",
]);

export const gameAbi = parseAbi([
  "function sync(uint256 maxCount) returns (uint256)",
  "function lastMaintenanceAt() view returns (uint256)",
  "function maintenanceInterval() view returns (uint256)",
]);
export const buybackAbi = parseAbi([
  "function process(uint256 minOut) returns (uint256)",
  "function lastRunAt() view returns (uint256)",
]);
export const farmAbi = parseAbi([
  "function finalize(uint256[] epochs) returns (uint256)",
  "function retireBonus() returns (uint256)",
  "function genesisEndBlock() view returns (uint256)",
]);
