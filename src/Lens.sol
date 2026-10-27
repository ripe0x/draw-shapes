// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {IFWAPool} from "./interfaces/IFWA.sol";
import {FwaGame} from "./game/FwaGame.sol";
import {PrizeVault} from "./game/PrizeVault.sol";
import {Converter} from "./game/Converter.sol";
import {GenesisFarm} from "./token/GenesisFarm.sol";
import {KeeperFund} from "./treasury/KeeperFund.sol";
import {Buyback} from "./treasury/Buyback.sol";
import {SwapPolicy} from "./policy/SwapPolicy.sol";
import {ProtocolLiquidity} from "./token/ProtocolLiquidity.sol";

/// @title Lens
/// @notice Read-only aggregation for the site and the keeper. Holds nothing and changes nothing.
contract Lens {
    struct Addresses {
        FwaGame game;
        GenesisFarm farm;
        KeeperFund keeperFund;
        Buyback buyback;
        SwapPolicy swapPolicy;
        ProtocolLiquidity liquidity;
        PrizeVault vault;
        Converter converter;
    }

    struct GameView {
        address pool;
        bool acquisitionsEnabled;
        bool admissible;
        bool opened;
        bool paused;
        bool retiring;
        bool retired;
        uint256 liveListings;
        uint256 boardRows;
        uint256 liveRows;
        uint256 seenSeq;
        uint256 openRequests;
        uint256 lastIssuedSeq;
        uint256 unsettled;
        uint256 quoteFee; // per pull, FWA fee (what weighs in genesis)
        uint256 quoteVrf; // per pull, charged separately by FWA's VRF service (at the caller's gas price)
        uint256 inventoryVersion;
        uint256 purchasesResumeAt;
        uint256 promoListing;
        uint256 promoEndBlock;
    }

    /// @notice The game's books. Every figure is cumulative since launch unless named otherwise.
    struct AccountsView {
        uint256 capitalIn; // vault funding into the game (opening capital, trading fees, contributions)
        uint256 cash;
        uint256 inventoryBacking;
        uint256 inventoryCost;
        uint256 replacementsOwed;
        uint256 opsOwed;
        uint256 exposure;
        uint256 protectedCash;
        uint256 distributable;
        uint256 turnover; // ordinary gameplay: ticket ETH of delivered pulls
        uint256 promoTurnover; // the part of turnover seen while a promotion was live
        uint256 pullsBooked;
        uint256 revenue;
        uint256 prizeExpense;
        uint256 opsAccrued;
        uint256 opsReturned;
        int256 profit; // realised; negative while losses are carried
        uint256 distributed;
        uint256 promoBudget;
        uint256 promoFunded;
        uint256 promoSpent;
        uint256 promoProceeds;
        uint256 promoReleased;
    }

    struct FundingView {
        uint256 tradingFees; // ENGINE trading fees received by the vault (capital)
        uint256 contributions; // other ETH sent to the vault (capital)
        uint256 vaultBalance;
        uint256 promotionsFunded;
        uint256 profitReceived; // profit the buyback received
        uint256 buybackSpent; // ETH spent on profit-funded buys
        uint256 engineBurned; // ENGINE burned by the buyback
        uint256 conversions;
        uint256 conversionEthIn; // player conversion purchases, reported apart from buybacks
        uint256 conversionEngineOut;
        uint256 conversionBonus;
    }

    struct Listing {
        uint256 listingId;
        uint256 row;
        uint256 backing;
        uint256 price;
        uint256 probability; // 1e18 = certain; current FWA weights
    }

    struct EpochView {
        uint256 epoch;
        uint256 allocationCap;
        uint256 rateCap; // ENGINE per 1 ETH of eligible ticket ETH
        uint256 weight;
        uint256 pot;
        uint256 userWeight;
        uint256 reward;
        bool isFinal;
        bool finalized;
        bool claimed;
    }

    struct WorkView {
        uint256 syncable; // requests waiting to be seen plus open requests
        uint256 unlistedRows;
        uint256 syncAge;
        bool admissionChange;
        bool buybackReady;
        uint256 buybackSlice;
        bool buybackPriceOk;
        uint256[] finalizable;
        bool bonusRetireReady;
        uint256 keeperFundAvailable;
    }

    struct MarketView {
        bool gated;
        uint256 genesisEndBlock;
        uint256 currentEpoch;
        uint256 feeBps;
        uint256 snipeFeeBps;
        uint160 sqrtPriceX96;
        uint256 enginePerEth; // 18 decimals, spot
    }

    function game(Addresses calldata a) public view returns (GameView memory v) {
        FwaGame g = a.game;
        IFWAPool p = g.pool();
        v.pool = address(p);
        v.opened = g.opened();
        v.paused = g.paused();
        v.retiring = g.retiring();
        v.retired = g.retired();
        v.liveListings = g.liveCount();
        v.boardRows = g.board().rowCount();
        v.liveRows = _popcount(g.liveRows());
        v.seenSeq = g.seenSeq();
        v.openRequests = g.openCount();
        v.promoListing = g.promoListing();
        v.promoEndBlock = g.promoEndBlock();
        if (address(p) != address(0)) {
            v.admissible = g.admissible();
            v.acquisitionsEnabled = p.localPurchasesEnabled();
            v.lastIssuedSeq = p.lastIssuedSequence();
            v.unsettled = p.unsettledAcquisitionCount();
            if (p.totalWeight() != 0) (v.quoteFee, v.quoteVrf,) = p.quoteAcquisitionPrice(1);
            v.inventoryVersion = p.inventoryVersion();
            v.purchasesResumeAt = p.purchasesResumeAt();
        }
    }

    function accounts(FwaGame g) public view returns (AccountsView memory v) {
        v.capitalIn = g.capitalIn();
        v.cash = g.cash();
        v.inventoryBacking = g.inventoryBacking();
        v.inventoryCost = g.inventoryCost();
        v.replacementsOwed = g.replacementsOwed();
        v.opsOwed = g.opsOwed();
        v.exposure = g.exposure();
        v.protectedCash = g.protectedCash();
        v.distributable = g.distributable();
        v.turnover = g.turnover();
        v.promoTurnover = g.promoTurnover();
        v.pullsBooked = g.pullsBooked();
        v.revenue = g.revenue();
        v.prizeExpense = g.prizeExpense();
        v.opsAccrued = g.opsAccrued();
        v.opsReturned = g.opsReturned();
        v.profit = g.profit();
        v.distributed = g.distributed();
        v.promoBudget = g.promoBudget();
        v.promoFunded = g.promoFunded();
        v.promoSpent = g.promoSpent();
        v.promoProceeds = g.promoProceeds();
        v.promoReleased = g.promoReleased();
    }

    function funding(Addresses calldata a) external view returns (FundingView memory v) {
        v.tradingFees = a.vault.tradingFees();
        v.contributions = a.vault.contributions();
        v.vaultBalance = address(a.vault).balance;
        v.promotionsFunded = a.vault.promotionsFunded();
        v.profitReceived = a.buyback.profitReceived();
        v.buybackSpent = a.buyback.totalSpent();
        v.engineBurned = a.buyback.totalBurned();
        v.conversions = a.converter.conversions();
        v.conversionEthIn = a.converter.totalEthIn();
        v.conversionEngineOut = a.converter.totalEngineOut();
        v.conversionBonus = a.converter.totalBonus();
    }

    /// @notice The current inventory: every live listing with its price and its probability under FWA's current
    ///         weights (inverse to price).
    function inventory(FwaGame g) external view returns (Listing[] memory out) {
        IFWAPool p = g.pool();
        uint256 n = g.liveCount();
        out = new Listing[](n);
        uint256 total = address(p) == address(0) ? 0 : p.totalWeight();
        for (uint256 i; i < n; ++i) {
            uint256 id = g.liveAt(i);
            (, uint80 backing,, uint16 row,,) = g.items(id);
            (,,,, uint256 weight, uint256 price,, IFWAPool.ListingStatus st) = p.listings(id);
            out[i] = Listing(id, row, backing, price, st == IFWAPool.ListingStatus.Active && total != 0 ? FPM.fullMulDiv(weight, 1e18, total) : 0);
        }
    }

    /// @notice The modelled target board: each row's backing, listing price and probability with every row listed.
    function targetBoard(FwaGame g)
        external
        view
        returns (uint256[] memory backing, uint256[] memory price, uint256[] memory probability)
    {
        uint256 n = g.board().rowCount();
        uint256 fee = g.shapes().mintFee();
        backing = new uint256[](n);
        price = new uint256[](n);
        probability = new uint256[](n);
        uint256 inv;
        for (uint256 r; r < n; ++r) {
            (, uint96 b) = g.board().rowAt(r);
            backing[r] = b;
            price[r] = g.pricing().listPrice(0, b, b + fee);
            inv += 1e36 / price[r];
        }
        for (uint256 r; r < n; ++r) {
            probability[r] = FPM.fullMulDiv(1e36 / price[r], 1e18, inv);
        }
    }

    /// @notice Genesis state for `user` over `[from, to)`.
    function epochs(GenesisFarm farm, address user, uint256 from, uint256 to)
        external
        view
        returns (EpochView[] memory out)
    {
        out = new EpochView[](to - from);
        for (uint256 e = from; e < to; ++e) {
            EpochView memory v = out[e - from];
            v.epoch = e;
            v.allocationCap = farm.allocationCap(e);
            v.rateCap = farm.rateCapOf(e);
            v.weight = farm.epochWeight(e);
            v.pot = farm.potOf(e);
            v.userWeight = farm.userWeight(e, user);
            v.reward = farm.rewardOf(e, user);
            v.isFinal = farm.isFinal(e);
            v.finalized = farm.isFinalized(e);
            v.claimed = farm.claimed(e, user);
        }
    }

    /// @notice Unclaimed final rewards of `user` over `[from, to)` and the epochs to pass to `claim`.
    function claimable(GenesisFarm farm, address user, uint256 from, uint256 to)
        external
        view
        returns (uint256 total, uint256[] memory epochList)
    {
        uint256[] memory tmp = new uint256[](to - from);
        uint256 n;
        for (uint256 e = from; e < to; ++e) {
            if (farm.claimed(e, user) || !farm.isFinal(e)) continue;
            uint256 r = farm.rewardOf(e, user);
            if (r == 0) continue;
            total += r;
            tmp[n++] = e;
        }
        epochList = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            epochList[i] = tmp[i];
        }
    }

    function market(Addresses calldata a) public view returns (MarketView memory v) {
        v.gated = a.swapPolicy.gated();
        v.genesisEndBlock = a.farm.genesisEndBlock();
        v.currentEpoch = a.farm.currentEpoch();
        v.feeBps = a.swapPolicy.feeBps();
        v.snipeFeeBps = a.swapPolicy.snipeFeeBps();
        if (a.liquidity.launched()) {
            v.sqrtPriceX96 = a.liquidity.sqrtPriceX96();
            v.enginePerEth = FPM.fullMulDiv(uint256(v.sqrtPriceX96) * uint256(v.sqrtPriceX96), 1e18, 1 << 192);
        }
    }

    /// @notice Spot estimate of a conversion of a Shape of `backing`: ENGINE out (before price impact) and the bonus at
    ///         the current bonus rate.
    function conversionQuote(Addresses calldata a, uint256 backing)
        external
        view
        returns (uint256 engineOut, uint256 bonus, bool bonusCovered)
    {
        MarketView memory m = market(a);
        engineOut = backing * m.enginePerEth / 1e18;
        bonus = engineOut * a.converter.bonusBps() / 10_000;
        bonusCovered = a.farm.bonusPool() >= bonus;
    }

    /// @notice Keeper work available now, with ages in seconds.
    function work(Addresses calldata a) external view returns (WorkView memory w) {
        FwaGame g = a.game;
        IFWAPool p = g.pool();
        if (address(p) != address(0)) {
            uint64 last = p.lastIssuedSequence();
            uint64 seen = g.seenSeq();
            w.syncable = (last >= seen ? last - seen + 1 : 0) + g.openCount();
            w.admissionChange = !g.retiring() && g.opened()
                && (!g.paused() && g.admissible()) != p.localPurchasesEnabled();
        }
        uint256 rows = g.board().rowCount();
        w.unlistedRows = rows - _popcount(g.liveRows() & ((rows >= 256 ? 0 : (uint256(1) << rows)) - 1));
        w.syncAge = block.timestamp - g.lastSyncAt();
        w.buybackSlice = a.buyback.nextSlice();
        w.buybackReady = w.buybackSlice != 0 && block.timestamp >= a.buyback.lastRunAt() + a.buyback.minSpacing();
        if (a.liquidity.launched()) w.buybackPriceOk = a.buyback.priceOk();
        GenesisFarm f = a.farm;
        if (f.openBlock() != 0) {
            uint256 cur = f.currentEpoch();
            uint256 end = cur < 21 ? cur : 21;
            uint256[] memory tmp = new uint256[](end);
            uint256 n;
            for (uint256 e; e < end; ++e) {
                if (!f.isFinalized(e) && f.isFinal(e)) tmp[n++] = e;
            }
            w.finalizable = new uint256[](n);
            for (uint256 i; i < n; ++i) {
                w.finalizable[i] = tmp[i];
            }
            w.bonusRetireReady = !f.bonusRetired() && block.number >= f.genesisEndBlock();
        }
        w.keeperFundAvailable = a.keeperFund.available(false);
    }

    function _popcount(uint256 x) internal pure returns (uint256 c) {
        while (x != 0) {
            x &= x - 1;
            ++c;
        }
    }
}
