import { parseAbi } from "viem";

const addrs =
  "struct Addresses { address game; address farm; address keeperFund; address buyback; address swapPolicy; address liquidity; address vault; address converter; }";

export const lensAbi = parseAbi([
  addrs,
  "struct GameView { address pool; bool acquisitionsEnabled; bool admissible; bool opened; bool paused; bool retiring; bool retired; uint256 liveListings; uint256 boardRows; uint256 liveRows; uint256 seenSeq; uint256 openRequests; uint256 lastIssuedSeq; uint256 unsettled; uint256 quoteFee; uint256 quoteVrf; uint256 inventoryVersion; uint256 purchasesResumeAt; uint256 promoListing; uint256 promoEndBlock; }",
  "struct AccountsView { uint256 capitalIn; uint256 cash; uint256 inventoryBacking; uint256 inventoryCost; uint256 replacementsOwed; uint256 opsOwed; uint256 exposure; uint256 protectedCash; uint256 distributable; uint256 turnover; uint256 promoTurnover; uint256 pullsBooked; uint256 revenue; uint256 prizeExpense; uint256 opsAccrued; uint256 opsReturned; int256 profit; uint256 distributed; uint256 promoBudget; uint256 promoFunded; uint256 promoSpent; uint256 promoProceeds; uint256 promoReleased; }",
  "struct FundingView { uint256 tradingFees; uint256 contributions; uint256 vaultBalance; uint256 promotionsFunded; uint256 profitReceived; uint256 buybackSpent; uint256 engineBurned; uint256 conversions; uint256 conversionEthIn; uint256 conversionEngineOut; uint256 conversionBonus; }",
  "struct Listing { uint256 listingId; uint256 row; uint256 backing; uint256 price; uint256 probability; }",
  "struct MarketView { bool gated; uint256 genesisEndBlock; uint256 currentEpoch; uint256 feeBps; uint256 snipeFeeBps; uint160 sqrtPriceX96; uint256 enginePerEth; }",
  "struct EpochView { uint256 epoch; uint256 allocationCap; uint256 rateCap; uint256 weight; uint256 pot; uint256 userWeight; uint256 reward; bool isFinal; bool finalized; bool claimed; }",
  "function game(Addresses a) view returns (GameView)",
  "function accounts(address g) view returns (AccountsView)",
  "function funding(Addresses a) view returns (FundingView)",
  "function inventory(address g) view returns (Listing[])",
  "function targetBoard(address g) view returns (uint256[] backing, uint256[] price, uint256[] probability)",
  "function market(Addresses a) view returns (MarketView)",
  "function epochs(address farm, address user, uint256 from, uint256 to) view returns (EpochView[])",
  "function claimable(address farm, address user, uint256 from, uint256 to) view returns (uint256 total, uint256[] epochList)",
  "function conversionQuote(Addresses a, uint256 backing) view returns (uint256 engineOut, uint256 bonus, bool bonusCovered)",
]);

export const poolAbi = parseAbi([
  "function quoteAcquisitionPrice(uint256 count) view returns (uint256 fee, uint256 vrf, uint256 total)",
  "function inventoryVersion() view returns (uint256)",
  "function selectionSlippageBps() view returns (uint256)",
  "function acquire(address purchaser, uint256 maxAcquisitionFee, uint256 minWeightedValue, uint256 maxNegativeSlippageBps, uint256 expectedInventoryVersion, uint256 deadline) payable returns (uint256)",
  "function acquireBatch(address purchaser, uint256 count, uint256 maxAcquisitionFee, uint256 minWeightedValue, uint256 maxNegativeSlippageBps, uint256 expectedInventoryVersion, uint256 deadline) payable returns (uint256[])",
  "function acquisitionRefundCredit(address) view returns (uint256)",
  "function withdrawAcquisitionRefund() returns (uint256)",
  "event NFTAllocated(uint256 indexed requestId, uint256 indexed listingId, address indexed purchaser, address depositor, uint256 price, uint256 randomWord)",
]);

export const farmAbi = parseAbi([
  "function claim(uint256[] epochs) returns (uint256)",
  "function currentEpoch() view returns (uint256)",
  "function openBlock() view returns (uint256)",
  "function bonusPool() view returns (uint256)",
  "function totalClaimed() view returns (uint256)",
  "function totalBurned() view returns (uint256)",
  "function totalPots() view returns (uint256)",
  "function rateCap() view returns (uint256)",
  "function genesisBudget() view returns (uint256)",
]);

export const converterAbi = parseAbi([
  "function convertible(uint256 listingId) view returns (bool ok, address collection, uint256 tokenId)",
  "function convert(uint256 listingId, uint256 minEngineOut, bool allowNoBonus) returns (uint256 engineOut, uint256 bonus)",
  "function bonusBps() view returns (uint256)",
]);

export const shapesAbi = parseAbi([
  "function ownerOf(uint256) view returns (address)",
  "function valueOf(uint256) view returns (uint256)",
  "function getApproved(uint256) view returns (address)",
  "function approve(address to, uint256 tokenId)",
]);

export const erc20Abi = parseAbi(["function totalSupply() view returns (uint256)", "function balanceOf(address) view returns (uint256)"]);

