// Hand-written from the public functions of src/sponsor/SponsoredPrize.sol and src/sponsor/FeeSplit.sol.
/** `SponsoredPrize.phase()` returns 0 while Parked and 1 while Hot. */
export const sponsoredPrizeAbi = [
  {"type":"function","name":"phase","inputs":[],"outputs":[{"name":"","type":"uint8","internalType":"enum SponsoredPrize.Phase"}],"stateMutability":"view"},
  {"type":"function","name":"reclaimAfter","inputs":[],"outputs":[{"name":"","type":"uint256","internalType":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"feeSplit","inputs":[],"outputs":[{"name":"","type":"address","internalType":"contract FeeSplit"}],"stateMutability":"view"},
] as const;

export const feeSplitAbi = [
  {"type":"function","name":"paidWei","inputs":[],"outputs":[{"name":"","type":"uint256","internalType":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"capWei","inputs":[],"outputs":[{"name":"","type":"uint256","internalType":"uint256"}],"stateMutability":"view"},
] as const;
