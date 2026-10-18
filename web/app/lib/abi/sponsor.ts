// Hand-written from the public functions of src/sponsor/SponsoredPrize.sol, src/sponsor/FeeSplit.sol and Shapes.
/** `reclaimAfter()` and `tokenId()` read 0 until `stake(tokenId)`. `SponsoredPrize.phase()` returns 0 while Parked and 1 while Hot. */
export const sponsoredPrizeAbi = [
  {"type":"function","name":"phase","inputs":[],"outputs":[{"name":"","type":"uint8"}],"stateMutability":"view"},
  {"type":"function","name":"stake","inputs":[{"name":"tokenId","type":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},
  {"type":"function","name":"staked","inputs":[],"outputs":[{"name":"","type":"bool"}],"stateMutability":"view"},
  {"type":"function","name":"canStake","inputs":[{"name":"tokenId","type":"uint256"}],"outputs":[{"name":"","type":"bool"}],"stateMutability":"view"},
  {"type":"function","name":"reclaimDelay","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"event","name":"Staked","inputs":[{"name":"listingId","type":"uint256","indexed":true},{"name":"tokenId","type":"uint256","indexed":true}],"anonymous":false},
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

const offerDealComponents = [
  {"name":"sponsor","type":"address"},
  {"name":"collection","type":"address"},
  {"name":"tokenId","type":"uint256"},
  {"name":"listingId","type":"uint256"},
  {"name":"capWei","type":"uint256"},
  {"name":"paidWei","type":"uint256"},
  {"name":"takenAt","type":"uint256"},
  {"name":"reclaimAfter","type":"uint256"},
  {"name":"listedAtPull","type":"uint256"},
  {"name":"hotFromPull","type":"uint256"},
  {"name":"hotStarted","type":"bool"},
  {"name":"captured","type":"bool"},
  {"name":"released","type":"bool"},
  {"name":"atFloor","type":"bool"},
  {"name":"floorWei","type":"uint256"},
  {"name":"decayWeiPerPull","type":"uint256"},
  {"name":"parkedPriceWei","type":"uint256"},
] as const;

/** Hand-written from the `SponsorOffer` section of docs/SPONSOR.md. `phase(dealId)` returns 0 while Parked and 1 while Hot. A deal id is its index in `deals()`. */
export const sponsorOfferAbi = [
  {"type":"function","name":"setTerms","inputs":[{"name":"collection","type":"address"},{"name":"parkedPriceWei","type":"uint256"},{"name":"floorWei","type":"uint256"},{"name":"decayWeiPerPull","type":"uint256"},{"name":"reclaimDelay","type":"uint256"},{"name":"capWei","type":"uint256"},{"name":"maxOpen","type":"uint256"},{"name":"enabled","type":"bool"}],"outputs":[],"stateMutability":"nonpayable"},
  {"type":"function","name":"take","inputs":[{"name":"collection","type":"address"},{"name":"tokenId","type":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},
  {"type":"function","name":"withdraw","inputs":[],"outputs":[],"stateMutability":"nonpayable"},
  {"type":"function","name":"tick","inputs":[{"name":"dealId","type":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},
  {"type":"function","name":"reclaim","inputs":[{"name":"dealId","type":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},
  {"type":"function","name":"releaseHeld","inputs":[{"name":"dealId","type":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},
  {"type":"function","name":"rescue","inputs":[{"name":"dealId","type":"uint256"},{"name":"to","type":"address"}],"outputs":[],"stateMutability":"nonpayable"},
  {"type":"function","name":"deals","inputs":[],"outputs":[{"name":"","type":"tuple[]","components":offerDealComponents}],"stateMutability":"view"},
  {"type":"function","name":"deal","inputs":[{"name":"dealId","type":"uint256"}],"outputs":[{"name":"","type":"tuple","components":offerDealComponents}],"stateMutability":"view"},
  {"type":"function","name":"queue","inputs":[],"outputs":[{"name":"","type":"tuple[]","components":[{"name":"dealId","type":"uint256"},{"name":"sponsor","type":"address"},{"name":"remainingWei","type":"uint256"}]}],"stateMutability":"view"},
  {"type":"function","name":"expectedWaitWei","inputs":[{"name":"collection","type":"address"}],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"canTake","inputs":[{"name":"collection","type":"address"},{"name":"tokenId","type":"uint256"},{"name":"who","type":"address"}],"outputs":[{"name":"","type":"bool"}],"stateMutability":"view"},
  {"type":"function","name":"phase","inputs":[{"name":"dealId","type":"uint256"}],"outputs":[{"name":"","type":"uint8"}],"stateMutability":"view"},
  {"type":"function","name":"active","inputs":[{"name":"dealId","type":"uint256"}],"outputs":[{"name":"","type":"bool"}],"stateMutability":"view"},
  {"type":"function","name":"terms","inputs":[{"name":"collection","type":"address"}],"outputs":[{"name":"parkedPriceWei","type":"uint256"},{"name":"floorWei","type":"uint256"},{"name":"decayWeiPerPull","type":"uint256"},{"name":"reclaimDelay","type":"uint256"},{"name":"capWei","type":"uint256"},{"name":"maxOpen","type":"uint256"},{"name":"enabled","type":"bool"}],"stateMutability":"view"},
  {"type":"function","name":"balance","inputs":[{"name":"account","type":"address"}],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"owner","inputs":[],"outputs":[{"name":"","type":"address"}],"stateMutability":"view"},
  {"type":"event","name":"Taken","inputs":[{"name":"dealId","type":"uint256","indexed":true},{"name":"sponsor","type":"address","indexed":true},{"name":"collection","type":"address","indexed":true},{"name":"tokenId","type":"uint256","indexed":false},{"name":"listingId","type":"uint256","indexed":false}],"anonymous":false},
] as const;
