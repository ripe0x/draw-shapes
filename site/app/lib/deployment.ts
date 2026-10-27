import record from "./deployment.generated.json";
import type { Address } from "viem";

export type Deployment = {
  chainId: number;
  deployed: boolean;
  blockNumber?: number;
  game: Address;
  farm: Address;
  treasury: Address;
  keeperFund: Address;
  buyback: Address;
  grailFund: Address;
  swapPolicy: Address;
  liquidity: Address;
  engine: Address;
  lens: Address;
  converter: Address;
  fwaPool: Address;
  vault: Address;
  shapes: Address;
  timelock: Address;
};

export const deployment = record as unknown as Deployment;

/** The struct Lens takes for its aggregated reads. */
export const lensAddresses = {
  game: deployment.game,
  farm: deployment.farm,
  treasury: deployment.treasury,
  keeperFund: deployment.keeperFund,
  buyback: deployment.buyback,
  grailFund: deployment.grailFund,
  swapPolicy: deployment.swapPolicy,
  liquidity: deployment.liquidity,
} as const;
