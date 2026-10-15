// Hand-written from the public functions of src/sponsor/SponsoredPrize.sol, src/sponsor/FeeSplit.sol and Shapes.
/** `SponsoredPrize.phase()` returns 0 while Parked and 1 while Hot. */
export const sponsoredPrizeAbi = [
  {"type":"function","name":"phase","inputs":[],"outputs":[{"name":"","type":"uint8"}],"stateMutability":"view"},
  {"type":"function","name":"reclaimAfter","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"feeSplit","inputs":[],"outputs":[{"name":"","type":"address"}],"stateMutability":"view"},
  {"type":"function","name":"sponsor","inputs":[],"outputs":[{"name":"","type":"address"}],"stateMutability":"view"},
  {"type":"function","name":"pool","inputs":[],"outputs":[{"name":"","type":"address"}],"stateMutability":"view"},
  {"type":"function","name":"collection","inputs":[],"outputs":[{"name":"","type":"address"}],"stateMutability":"view"},
  {"type":"function","name":"capWei","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"tokenId","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"parkedPriceWei","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"floorWei","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"decayWeiPerPull","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"listingId","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"startedAt","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"captured","inputs":[],"outputs":[{"name":"","type":"bool"}],"stateMutability":"view"},
  {"type":"function","name":"atFloor","inputs":[],"outputs":[{"name":"","type":"bool"}],"stateMutability":"view"},
  {"type":"function","name":"active","inputs":[],"outputs":[{"name":"","type":"bool"}],"stateMutability":"view"},
  {"type":"function","name":"tick","inputs":[],"outputs":[],"stateMutability":"nonpayable"},
  {"type":"function","name":"reclaim","inputs":[],"outputs":[],"stateMutability":"nonpayable"},
  {"type":"function","name":"releaseHeld","inputs":[],"outputs":[],"stateMutability":"nonpayable"},
] as const;

export const feeSplitAbi = [
  {"type":"function","name":"paidWei","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"capWei","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"ownerBalance","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"sponsorBalance","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"owner","inputs":[],"outputs":[{"name":"","type":"address"}],"stateMutability":"view"},
  {"type":"function","name":"sponsor","inputs":[],"outputs":[{"name":"","type":"address"}],"stateMutability":"view"},
  {"type":"function","name":"prize","inputs":[],"outputs":[{"name":"","type":"address"}],"stateMutability":"view"},
  {"type":"function","name":"locked","inputs":[],"outputs":[{"name":"","type":"bool"}],"stateMutability":"view"},
  {"type":"function","name":"withdraw","inputs":[],"outputs":[],"stateMutability":"nonpayable"},
] as const;

/** The `Shapes` mint fee recipient and its accrued fees. */
export const shapesFeesAbi = [
  {"type":"function","name":"feeRecipient","inputs":[],"outputs":[{"name":"","type":"address"}],"stateMutability":"view"},
  {"type":"function","name":"feesOwedTo","inputs":[{"name":"recipient","type":"address"}],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
] as const;
