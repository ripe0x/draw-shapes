/** Static stand-in for the previous page's chain reads (useSponsorStatus, useQuotePull,
 *  useInventory, useAccount). No wallet is connected in either state. */

export const CHAIN_ID = 1;
export const SHAPES_ADDRESS = "0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0";
export const FWAIR_PFP_ADDRESS = "0x29f1cBC8eccD64B0cE777f5Da45c72C47383a620";
export const SPONSOR_ADDRESS = "0x3a7B1C2d9E4f50861aB2c3D4e5F60718293a4B5c";
export const POOL_ADDRESS = "0x9c1D2e3F4a5B60718293A4b5C6d7E8f901a2B3c4";

const ZERO = "0x0000000000000000000000000000000000000000";
/** FWAIR beta 1 end, 2026-10-09T21:47:47Z. */
const BETA_ENDS_AT = 1791563267n;

export type Sponsorship = { depositor: string; tokenId: bigint; released: boolean; scheduledEndAt: bigint };

export type Status = {
  isLoading: boolean;
  error: { message: string } | null;
  betaSponsorship: Sponsorship | undefined;
  sponsorRewardsActive: boolean;
  sponsorShareOfOperatorBps: number;
  fwaPool: string | undefined;
  sponsorRevenue: bigint;
  pfpBetaActive: boolean;
  pfpBetaEndsAt: bigint;
  pfpCurrentBetaId: number;
  pfpActivationCount: number;
  factoryBetaAccess: boolean;
  factoryPoolCreationEnabled: boolean;
  factoryPoolCreationFee: bigint;
  poolOpeningTimestamp: bigint;
  chainTimestamp: bigint;
  pfpAddress: string;
};

/** Slot open, no sponsor recorded. Chain time sits 5d 3h before the beta end. */
export const openStatus: Status = {
  isLoading: false,
  error: null,
  betaSponsorship: undefined,
  sponsorRewardsActive: false,
  sponsorShareOfOperatorBps: 2000,
  fwaPool: undefined,
  sponsorRevenue: 0n,
  pfpBetaActive: true,
  pfpBetaEndsAt: BETA_ENDS_AT,
  pfpCurrentBetaId: 1,
  pfpActivationCount: 12,
  factoryBetaAccess: true,
  factoryPoolCreationEnabled: false,
  factoryPoolCreationFee: 0n,
  poolOpeningTimestamp: 0n,
  chainTimestamp: BETA_ENDS_AT - (5n * 86400n + 3n * 3600n),
  pfpAddress: FWAIR_PFP_ADDRESS,
};

/** Pass #1 locked by a sponsor, beta running, 0.0312 ETH accrued. */
export const takenStatus: Status = {
  ...openStatus,
  betaSponsorship: { depositor: SPONSOR_ADDRESS, tokenId: 1n, released: false, scheduledEndAt: BETA_ENDS_AT },
  sponsorRewardsActive: true,
  fwaPool: POOL_ADDRESS,
  sponsorRevenue: 31_200_000_000_000_000n,
  factoryPoolCreationEnabled: true,
};

export { ZERO };
