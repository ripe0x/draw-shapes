// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib as FP} from "solady/utils/FixedPointMathLib.sol";
import {Denominations} from "shapes/lib/Denominations.sol";
import {Histogram, Skim} from "../PoolStore.sol";

/// @title PricingLib
/// @notice Pure math for FWA weight conversion, the (backing, notional) histogram, the rolling
///         worst case expected pass-through, ticket sizing and the pull waterfall.
/// @dev Rule ids (ECO-V) refer to docs/ECONOMIC_SPEC.md. Divisions round down unless the function
///      name says otherwise. Products use `FixedPointMathLib` full precision multiply-divide so
///      intermediates never overflow before the final divide.
library PricingLib {
    uint256 internal constant BPS = 10_000;
    /// @notice FWA `INVERSE_WEIGHT_NUMERATOR`. Selection weight is `NUM / notional`.
    uint256 internal constant NUM = 1e36;

    /// @notice Rungs of the notional ladder. Every listed notional is one of these.
    uint256 internal constant NOTIONAL_COUNT = 24;
    /// @notice Rungs of the backing rung table. Every binned backing is one of these.
    uint256 internal constant NATIVE_BACKING_COUNT = 9;
    uint256 internal constant BACKING_COUNT = 20;
    /// @notice Twelve exact multi-Shape backing classes; eleven add a unique off-ladder backing and
    ///         the 0.10 ETH recipe shares its native backing class. The 1.00 ETH recipe (two 0.50
    ///         Shapes) also shares a native class, index 4, and has no entry in this list.
    uint256 internal constant PACK_RECIPE_COUNT = 12;
    uint256 internal constant LISTED_CLASS_COUNT = BACKING_COUNT;

    /// @notice Backing rung indices ordered by ascending amount, one byte per position, lowest
    ///         amount in the least significant byte.
    /// @dev Native Shapes keep indices 0..8. The fixed off-ladder pack totals use 9..19 and this
    ///      constant interleaves them by amount for liquidation walks.
    uint256 internal constant BACKING_BY_AMOUNT = 0x0008070605041003130f120e0d020c0b01110a0900;

    error ZeroPrice();
    error PriceTooHigh();
    error ZeroDivisor();
    error UnsupportedNotional(uint256 notionalWei);
    error UnsupportedBacking(uint256 backingWei);
    error BackingRungOutOfRange(uint256 index);
    error PackClassOutOfRange(uint256 index);
    error RemovalExceedsInventory(uint256 removals, uint256 listed);

    /// @notice One GRAND listing in the removal walk: its weight is what its removal takes
    ///         out of W and orders it against the other game listings.
    struct GameListing {
        uint256 weight;
    }

    /// @notice Independent prefixes used by the safe relaxed request bound.
    /// @dev Index zero is always zero. Later entries are cumulative sums for the selected count.
    struct EvBoundPrefixes {
        uint256[] gameWeight;
        uint256[] vaultWeight;
        uint256[] vaultCost;
        uint256 backingCap;
    }

    // ------------------------------------------------------------------ backing rung table

    /// @notice Amount of one fixed native or reviewed pack backing class.
    function backingAt(uint256 index) internal pure returns (uint256) {
        if (index < NATIVE_BACKING_COUNT) return Denominations.amountAt(index);
        uint256 unit = Denominations.UNIT;
        if (index == 9) return 2 * unit;
        if (index == 10) return 3 * unit;
        if (index == 11) return 6 * unit;
        if (index == 12) return 7 * unit;
        if (index == 13) return 11 * unit;
        if (index == 14) return 12 * unit;
        if (index == 15) return 20 * unit;
        if (index == 16) return 70 * unit;
        if (index == 17) return 4 * unit;
        if (index == 18) return 15 * unit;
        if (index == 19) return 30 * unit;
        revert BackingRungOutOfRange(index);
    }

    /// @notice Whether a vault-owned Held record is listed on the board. Legacy boards reserve
    ///         native 0.01 Shapes for pack composition. Merge-mode boards compose exact packs
    ///         during construction and pass `packsActive = false`, allowing 0.01 prizes to list.
    function isBoardListable(address collection, address shapes, uint256 backingWei, bool packsActive)
        internal
        pure
        returns (bool)
    {
        return !(packsActive && collection == shapes && backingWei == backingAt(0));
    }

    /// @notice Index of a backing rung.
    /// @return index The rung index, meaningful only when `ok` is true.
    /// @return ok Whether `backingWei` is one of the rung amounts.
    function backingIndexOf(uint256 backingWei) internal pure returns (uint256 index, bool ok) {
        (index, ok) = Denominations.indexOf(backingWei);
        if (ok) return (index, true);
        for (uint256 rung = NATIVE_BACKING_COUNT; rung < BACKING_COUNT; ++rung) {
            if (backingWei == backingAt(rung)) return (rung, true);
        }
        return (0, false);
    }

    /// @notice Index of a backing rung, reverting when off the table.
    function requireBackingIndexOf(uint256 backingWei) internal pure returns (uint256 index) {
        bool ok;
        (index, ok) = backingIndexOf(backingWei);
        if (!ok) revert UnsupportedBacking(backingWei);
    }

    /// @notice Backing rung index at `position` counting up from the smallest amount.
    function backingRungByAmount(uint256 position) internal pure returns (uint256) {
        if (position >= BACKING_COUNT) revert BackingRungOutOfRange(position);
        return (BACKING_BY_AMOUNT >> (position * 8)) & 0xff;
    }

    /// @notice Every backing rung amount, by rung index.
    function backingRungs() internal pure returns (uint256[] memory amountsWei) {
        amountsWei = new uint256[](BACKING_COUNT);
        for (uint256 i; i < BACKING_COUNT; ++i) {
            amountsWei[i] = backingAt(i);
        }
    }

    /// @notice Total backing of one reviewed pack backing class.
    /// @dev Classes are ordered by backing: 0.02, 0.03, 0.04, 0.06, 0.07, 0.10, 0.11, 0.12, 0.15,
    ///      0.20, 0.30 and 0.70 ETH. The 1.00 ETH recipe lists in native class 4 and is not a class here.
    function packBackingAt(uint256 recipe) internal pure returns (uint256) {
        uint256 unit = Denominations.UNIT;
        if (recipe == 0) return 2 * unit;
        if (recipe == 1) return 3 * unit;
        if (recipe == 2) return 4 * unit;
        if (recipe == 3) return 6 * unit;
        if (recipe == 4) return 7 * unit;
        if (recipe == 5) return 10 * unit;
        if (recipe == 6) return 11 * unit;
        if (recipe == 7) return 12 * unit;
        if (recipe == 8) return 15 * unit;
        if (recipe == 9) return 20 * unit;
        if (recipe == 10) return 30 * unit;
        if (recipe == 11) return 70 * unit;
        revert PackClassOutOfRange(recipe);
    }

    // ------------------------------------------------------------------ notional ladder

    /// @notice Amount of a notional ladder rung. Rungs 4 through 20 are the backing rung table in
    ///         the same order; rungs 0 through 3 extend below it for deeply discounted listings.
    /// @dev The four discount rungs are fractions of the smallest denomination, so they scale with
    ///      the compiled ladder and stay below the backing table on either one. On the mainnet
    ///      ladder they are 0.0001, 0.0005, 0.001 and 0.005 ETH.
    function notionalAt(uint256 index) internal pure returns (uint256) {
        if (index < 4) return discountAt(index);
        if (index < NOTIONAL_COUNT) return backingAt(index - 4);
        revert UnsupportedNotional(index);
    }

    /// @dev Amount of one of the four notional rungs below the backing table, as a fraction of the
    ///      smallest denomination. Every denomination is a whole multiple of `Denominations.UNIT`
    ///      and `UNIT` equals denomination 0, so each division is exact.
    function discountAt(uint256 index) private pure returns (uint256) {
        uint256 unit = Denominations.amountAt(0);
        if (index == 0) return unit / 100;
        if (index == 1) return unit / 20;
        if (index == 2) return unit / 10;
        return unit / 2;
    }

    /// @notice Index of a notional ladder rung.
    /// @return index The rung index, meaningful only when `ok` is true.
    /// @return ok Whether `notionalWei` is one of the ladder amounts.
    function notionalIndexOf(uint256 notionalWei) internal pure returns (uint256 index, bool ok) {
        for (uint256 rung; rung < 4; ++rung) {
            if (notionalWei == discountAt(rung)) return (rung, true);
        }
        (uint256 backingRung, bool backingOk) = backingIndexOf(notionalWei);
        if (backingOk) return (backingRung + 4, true);
        return (0, false);
    }

    /// @notice Index of a notional ladder rung, reverting when off the ladder.
    function requireNotionalIndexOf(uint256 notionalWei) internal pure returns (uint256 index) {
        bool ok;
        (index, ok) = notionalIndexOf(notionalWei);
        if (!ok) revert UnsupportedNotional(notionalWei);
    }

    /// @notice FWA selection weight for a notional price (ECO-V1).
    function weightOf(uint256 notionalWei) internal pure returns (uint256 weight) {
        if (notionalWei == 0) revert ZeroPrice();
        weight = NUM / notionalWei;
        if (weight == 0) revert PriceTooHigh();
    }

    // ------------------------------------------------------------------ histogram

    /// @notice Add one vault-owned normal listing to the histogram.
    /// @dev Its backing enters `weightedBackingWei`, the EV_pass numerator, and its weight enters
    ///      `totalWeight`, the selection denominator W.
    function addToHistogram(Histogram storage h, uint256 backingWei, uint256 notionalWei, uint256 weight)
        internal
    {
        uint256 b = requireBackingIndexOf(backingWei);
        uint256 n = requireNotionalIndexOf(notionalWei);
        h.counts[b][n]++;
        h.backingCounts[b]++;
        h.vaultCount++;
        h.totalCount++;
        h.totalWeight += weight;
        h.weightedBackingWei += FP.fullMulDiv(backingWei, weight, 1);
        unchecked {
            ++h.version;
        }
    }

    /// @notice Remove one vault-owned normal listing from the histogram.
    function removeFromHistogram(Histogram storage h, uint256 backingWei, uint256 notionalWei, uint256 weight)
        internal
    {
        uint256 b = requireBackingIndexOf(backingWei);
        uint256 n = requireNotionalIndexOf(notionalWei);
        h.counts[b][n]--;
        h.backingCounts[b]--;
        h.vaultCount--;
        h.totalCount--;
        h.totalWeight -= weight;
        h.weightedBackingWei -= FP.fullMulDiv(backingWei, weight, 1);
        unchecked {
            ++h.version;
        }
    }

    /// @notice Largest backing among listed vault-owned native Shapes and reviewed packs.
    function maxVaultBacking(Histogram storage h) internal view returns (uint256 largestWei) {
        for (uint256 i; i < BACKING_COUNT; ++i) {
            if (h.backingCounts[i] != 0) {
                uint256 backingWei = backingAt(i);
                if (backingWei > largestWei) largestWei = backingWei;
            }
        }
    }

    /// @notice Add one GRAND listing to the selection denominator (S25).
    /// @dev A grail carries no EV_pass basis, so only the count and the weight move. Its notional
    ///      is its backing, or a clock's value below it, and is generally off the notional ladder,
    ///      so it is never binned.
    function addGameListing(Histogram storage h, uint256 weight) internal {
        addGameListing(h, weight, 0);
    }

    function addGameListing(Histogram storage h, uint256 weight, uint256 backingWei) internal {
        h.gameWeightedBackingWei += backingWei * weight;
        h.gameWeightByBacking[backingWei] += weight;
        h.totalCount++;
        h.totalWeight += weight;
        unchecked {
            ++h.version;
        }
    }

    /// @notice Remove one GRAND listing from the selection denominator.
    function removeGameListing(Histogram storage h, uint256 weight) internal {
        removeGameListing(h, weight, 0);
    }

    function removeGameListing(Histogram storage h, uint256 weight, uint256 backingWei) internal {
        h.gameWeightedBackingWei -= backingWei * weight;
        h.gameWeightByBacking[backingWei] -= weight;
        h.totalCount--;
        h.totalWeight -= weight;
        unchecked {
            ++h.version;
        }
    }

    /// @notice Expected pass-through of the listed inventory as it stands (ECO-V2, S25).
    /// @dev `sum over vault-owned listings of backing_i * w_i` over `W`, the sum of every listed
    ///      weight. GRAND listings enter the denominator alone, so a GRAND selection costs
    ///      the vault nothing and the ticket does not price one. Zero when nothing is listed.
    function evPass(uint256 weightedBackingWei, uint256 totalWeight) internal pure returns (uint256) {
        if (totalWeight == 0) return 0;
        return weightedBackingWei / totalWeight;
    }

    /// @notice Safe expected pass-through bound across a rolling removal horizon (ECO-V3).
    /// @dev `removals` is the count of selections that may land before the one being priced:
    ///      earlier outstanding requests plus the earlier items of this batch (the horizon is
    ///      `q + batch - 1` at the call site). The maximum of EV_pass over the removal path is
    ///      returned.
    ///
    ///      For every split `g + o <= removals`, the bound independently removes the `g` heaviest
    ///      game weights, the `o` heaviest vault weights and the `o` cheapest vault backing costs.
    ///      A real `o`-listing vault subset cannot remove more weight or less cost, so each relaxed
    ///      ratio bounds every real subset with that split. Taking the maximum floor ratio over
    ///      every split therefore bounds the whole horizon without assuming a greedy removal path.
    ///
    ///      The vault prefixes scan the fixed backing/notional histogram and retain at most
    ///      `removals` entries; multiplicities come directly from each bin. Work depends on the
    ///      fixed histogram dimensions and the live removal horizon, never the listed NFT count.
    function evPassMax(Histogram storage h, uint256 removals, GameListing[] memory gameListings)
        public
        view
        returns (uint256 maxEvWei)
    {
        if (h.totalWeight == 0) revert ZeroDivisor();
        if (removals >= h.totalCount) revert RemovalExceedsInventory(removals, h.totalCount);

        maxEvWei = h.weightedBackingWei / h.totalWeight;
        if (removals == 0) return maxEvWei;

        EvBoundPrefixes memory p = _evBoundPrefixes(h, removals, gameListings);
        uint256 gameLimit = p.gameWeight.length - 1;
        uint256 vaultLimit = p.vaultWeight.length - 1;

        for (uint256 g; g <= gameLimit; ++g) {
            uint256 maxVault = removals - g;
            if (maxVault > vaultLimit) maxVault = vaultLimit;
            for (uint256 o; o <= maxVault; ++o) {
                uint256 removedWeight = p.gameWeight[g] + p.vaultWeight[o];
                uint256 candidateWei;
                if (removedWeight >= h.totalWeight) {
                    candidateWei = p.backingCap;
                } else {
                    candidateWei = (h.weightedBackingWei - p.vaultCost[o]) / (h.totalWeight - removedWeight);
                }
                if (candidateWei > maxEvWei) maxEvWei = candidateWei;
            }
        }
    }

    /// @notice Conservative total-payout bound over every prefix of the removal horizon.
    /// @dev Game weights may be rounded up. Omitting their removed backing cost relaxes the
    ///      numerator upward. Independent ordinary weight/cost prefixes cover every subset.
    function allPrizeEvPassMax(
        Histogram storage h,
        uint256 removals,
        GameListing[] memory games,
        uint256 maxBackingWei
    ) public view returns (uint256 maxEvWei) {
        if (h.totalWeight == 0) revert ZeroDivisor();
        if (removals >= h.totalCount) revert RemovalExceedsInventory(removals, h.totalCount);
        uint256 numerator = h.weightedBackingWei + h.gameWeightedBackingWei;
        maxEvWei = FP.divUp(numerator, h.totalWeight);
        if (removals == 0) return maxEvWei;
        EvBoundPrefixes memory p = _evBoundPrefixes(h, removals, games);
        for (uint256 g; g < p.gameWeight.length; ++g) {
            uint256 limit = removals - g;
            if (limit >= p.vaultWeight.length) limit = p.vaultWeight.length - 1;
            for (uint256 o; o <= limit; ++o) {
                uint256 removed = p.gameWeight[g] + p.vaultWeight[o];
                uint256 candidate = removed >= h.totalWeight
                    ? maxBackingWei
                    : FP.divUp(numerator - p.vaultCost[o], h.totalWeight - removed);
                if (candidate > maxBackingWei) candidate = maxBackingWei;
                if (candidate > maxEvWei) maxEvWei = candidate;
            }
        }
    }

    /// @dev Builds the three exact multiplicity prefixes used by `evPassMax`. `gameListings` is
    ///      already descending by weight from `CustodyOps.gameListings`. Vault weights and costs
    ///      each retain only the relevant `removals` entries while scanning nonempty backing rows.
    function _evBoundPrefixes(Histogram storage h, uint256 removals, GameListing[] memory gameListings)
        private
        view
        returns (EvBoundPrefixes memory p)
    {
        uint256 gameLimit = removals < gameListings.length ? removals : gameListings.length;
        p.gameWeight = new uint256[](gameLimit + 1);
        for (uint256 i; i < gameLimit; ++i) {
            p.gameWeight[i + 1] = p.gameWeight[i] + gameListings[i].weight;
        }

        uint256 vaultLimit = removals < h.vaultCount ? removals : h.vaultCount;
        uint256[] memory highestWeights = new uint256[](vaultLimit);
        uint256[] memory lowestCosts = new uint256[](vaultLimit);
        uint256 weightFilled;
        uint256 costFilled;

        for (uint256 b; b < BACKING_COUNT; ++b) {
            if (h.backingCounts[b] == 0) continue;
            uint256 backingWei = backingAt(b);
            if (backingWei > p.backingCap) p.backingCap = backingWei;

            for (uint256 n; n < NOTIONAL_COUNT; ++n) {
                uint256 count = h.counts[b][n];
                if (count == 0) continue;

                uint256 take = count < vaultLimit ? count : vaultLimit;
                uint256 weight = weightOf(notionalAt(n));
                uint256 costWei = FP.fullMulDiv(backingWei, weight, 1);
                for (uint256 copy; copy < take; ++copy) {
                    weightFilled = _insertHighest(highestWeights, weightFilled, weight);
                    costFilled = _insertLowest(lowestCosts, costFilled, costWei);
                }
            }
        }

        if (weightFilled != vaultLimit || costFilled != vaultLimit) {
            revert RemovalExceedsInventory(removals, h.totalCount);
        }
        p.vaultWeight = new uint256[](vaultLimit + 1);
        p.vaultCost = new uint256[](vaultLimit + 1);
        for (uint256 i; i < vaultLimit; ++i) {
            p.vaultWeight[i + 1] = p.vaultWeight[i] + highestWeights[i];
            p.vaultCost[i + 1] = p.vaultCost[i] + lowestCosts[i];
        }
    }

    /// @dev Retains the largest `values.length` inputs in descending order.
    function _insertHighest(uint256[] memory values, uint256 filled, uint256 value)
        private
        pure
        returns (uint256)
    {
        uint256 length = values.length;
        uint256 at;
        if (filled < length) {
            at = filled;
            while (at != 0 && value > values[at - 1]) {
                values[at] = values[at - 1];
                --at;
            }
            values[at] = value;
            return filled + 1;
        }
        if (length == 0 || value <= values[length - 1]) return filled;

        at = length - 1;
        while (at != 0 && value > values[at - 1]) {
            values[at] = values[at - 1];
            --at;
        }
        values[at] = value;
        return filled;
    }

    /// @dev Retains the smallest `values.length` inputs in ascending order. `filled` counts the
    ///      initialized prefix and never exceeds the array length.
    function _insertLowest(uint256[] memory values, uint256 filled, uint256 value)
        private
        pure
        returns (uint256)
    {
        uint256 length = values.length;
        uint256 at;
        if (filled < length) {
            at = filled;
            while (at != 0 && value < values[at - 1]) {
                values[at] = values[at - 1];
                --at;
            }
            values[at] = value;
            return filled + 1;
        }
        if (length == 0 || value >= values[length - 1]) return filled;

        at = length - 1;
        while (at != 0 && value < values[at - 1]) {
            values[at] = values[at - 1];
            --at;
        }
        values[at] = value;
        return filled;
    }

    // ------------------------------------------------------------------ ticket

    /// @notice Maintenance held above the reserve floor (ECON-04).
    function maintenanceSurplus(uint256 maintenanceWei, uint256 floorWei)
        internal
        pure
        returns (uint256 surplusWei)
    {
        if (maintenanceWei > floorWei) surplusWei = maintenanceWei - floorWei;
    }

    /// @notice FWA protocol take on one pull: half of the edge above the base price (ECO-V4).
    /// @dev Mirrors FWA `_completeNFTDelivery`: `protocolAmount = (paidFee - basePrice) / 2`.
    function protocolSplit(uint256 paidFeeWei, uint256 basePriceWei)
        internal
        pure
        returns (uint256 protocolAmountWei, uint256 ownerAmountWei)
    {
        if (basePriceWei > paidFeeWei) revert ZeroDivisor();
        protocolAmountWei = (paidFeeWei - basePriceWei) / 2;
        ownerAmountWei = paidFeeWei - protocolAmountWei;
    }

    /// @notice Recover the exact request base FWA used from its returned fee and live edge.
    /// @dev FWA computes `floor(base * (BPS + edgeBps) / BPS)`. The multiplier is at least one,
    ///      so adjacent integer bases produce distinct fees and rounding the inverse up recovers
    ///      the unique base. This remains exact at both the zero and maximum factory edge.
    function fwaBaseFromFee(uint256 feeWei, uint256 edgeBps) internal pure returns (uint256) {
        return FP.fullMulDivUp(feeWei, BPS, BPS + edgeBps);
    }

    /// @notice Part of one pull's cost the skim divisor applies to (ECO-V5).
    /// @dev The greater of `EV_pass_max + protocolTake` and the floor that keeps the ticket at or
    ///      above the FWA acquire fee. `protocolTake` is FWA's half of the purchase edge; the owner
    ///      half returns to custody and credits vault cash, reimbursing the front (DEC-189). The
    ///      mint line and the pack component line are outside this floor and added after the skim
    ///      divisor (`ticketWithLines`). The active controller applies this rule in
    ///      `ticketFloorWei`; custody prices the ticket from the floor that call returns.
    ///
    ///      The acquire fee binds the ticket because custody forwards it to the pool out of the
    ///      ticket and keeps `ticket - fwaFee` as escrow. FWA prices the fee off the harmonic mean
    ///      of the notionals, so inventory listed far above its backing can put the fee above the
    ///      cost terms; without this floor that escrow would underflow. The fee floor is the
    ///      smallest floor whose ticket, `floor / (1 - skim) + mintFee`, exceeds `fwaFeeWei`, so the
    ///      escrow stays positive.
    function ticketFloor(
        uint256 evPassMaxWei,
        uint256 protocolTakeWei,
        uint256 fwaFeeWei,
        uint256 mintFeeWei,
        uint256 skimBps
    ) internal pure returns (uint256 floorWei) {
        floorWei = evPassMaxWei + protocolTakeWei;
        uint256 targetWei = fwaFeeWei + 1;
        if (targetWei > mintFeeWei) {
            if (skimBps >= BPS) revert ZeroDivisor();
            uint256 feeFloorWei = FP.fullMulDivUp(targetWei - mintFeeWei, BPS - skimBps, BPS);
            if (feeFloorWei > floorWei) floorWei = feeFloorWei;
        }
    }

    /// @notice Ticket share that leaves the floor intact once the skim is taken (ECO-V6).
    /// @dev `floor / (1 - skim)`, rounded up. Reverts `ZeroDivisor` when the skim reaches 100%.
    function ticketFromFloor(uint256 floorWei, uint256 skimBps) internal pure returns (uint256) {
        if (skimBps >= BPS) revert ZeroDivisor();
        return FP.fullMulDivUp(floorWei, BPS, BPS - skimBps);
    }

    /// @notice Full ticket: the floor grossed up for the skim, plus the lines the skim does not
    ///         apply to (the Shapes mint fee and the pack component fee).
    function ticketWithLines(uint256 floorWei, uint256 skimBps, uint256 lineWei)
        internal
        pure
        returns (uint256)
    {
        return ticketFromFloor(floorWei, skimBps) + lineWei;
    }

    /// @notice Total skim in basis points: operator plus every controller slice.
    function totalSkimBps(Skim memory skim, uint16 operatorBps) internal pure returns (uint256) {
        return
            uint256(operatorBps) + skim.maintenanceBps + skim.premiumBps + skim.grailFeedBps + skim.reserveBps;
    }

    // ------------------------------------------------------------------ waterfall

    /// @notice Inputs to the pull waterfall at delivery completion (ECO-V8).
    struct WaterfallInput {
        uint256 ticketWei;
        uint256 gameEscrowWei;
        uint256 ownerAmountWei;
        uint256 evPassWei;
        uint256 mintFeeWei;
        uint16 operatorBps;
        uint16 builderBps;
        Skim skim;
    }

    /// @notice Waterfall allocation result (ECO-V8).
    struct WaterfallOutput {
        uint256 vaultCash;
        uint256 grailFeed;
        uint256 operator;
        uint256 builder;
        uint256 maintenance;
        uint256 reserve;
        uint256 mintFeeReserve;
        uint256 shortfall;
    }

    /// @notice Split one settled pull across the vault and the skim buckets (ECO-V8, R13).
    /// @dev `R = gameEscrowWei + ownerAmountWei` is what custody actually holds for this pull once
    ///      FWA's owner half is harvested. `mintFeeWei` is the ticket's mint and pack component
    ///      lines, which the skim divisor excludes: premium, GRAIL and maintenance use
    ///      `ticketWei - mintFeeWei`. The operator line is `operatorBps` of the full ticket (DEC-235);
    ///      the owner half of the edge stays in `R` and reaches vault cash. Allocation order is
    ///      operator, builder, grail feed, maintenance, the controller reserve line (`reserveBps`
    ///      of the base), then the pull's own mint-fee line (`mintFeeReserve`, DEC-88: booked
    ///      apart from vault cash so a replacement mint's fee draws from the pool every settled
    ///      pull feeds, not from the rung's own notional budget), each capped by what remains; the
    ///      remainder is vault cash, which therefore carries `EV_pass + premium` plus any rounding
    ///      dust.
    ///      `shortfall` is the part of the wanted slices `R` could not cover. The sum of every
    ///      output field except `shortfall` equals `R` exactly.
    function waterfall(WaterfallInput memory input) internal pure returns (WaterfallOutput memory out) {
        uint256 remaining = input.gameEscrowWei + input.ownerAmountWei;

        uint256 baseWei = input.ticketWei > input.mintFeeWei ? input.ticketWei - input.mintFeeWei : 0;
        uint256 wantOperator = FP.fullMulDiv(input.ticketWei, input.operatorBps, BPS);
        uint256 wantGrail = FP.fullMulDiv(baseWei, input.skim.grailFeedBps, BPS);
        uint256 wantMaintenance = FP.fullMulDiv(baseWei, input.skim.maintenanceBps, BPS);
        uint256 wantReserve = FP.fullMulDiv(baseWei, input.skim.reserveBps, BPS);

        uint256 alloc = wantOperator < remaining ? wantOperator : remaining;
        (out.operator, out.builder) = operatorSplit(alloc, input.builderBps);
        remaining -= alloc;

        alloc = wantGrail < remaining ? wantGrail : remaining;
        out.grailFeed = alloc;
        remaining -= alloc;

        alloc = wantMaintenance < remaining ? wantMaintenance : remaining;
        out.maintenance = alloc;
        remaining -= alloc;

        alloc = wantReserve < remaining ? wantReserve : remaining;
        out.reserve = alloc;
        remaining -= alloc;

        uint256 wanted = wantOperator + wantGrail + wantMaintenance + wantReserve;
        uint256 allocated = out.operator + out.builder + out.grailFeed + out.maintenance + out.reserve;
        out.shortfall = wanted - allocated;

        // The pull's own mint-fee line, carved out of the remainder ahead of vault cash so it
        // lands in the mint-fee reserve instead (DEC-88). Not a skim want: it is added to the
        // ticket outside the skim divisor (`PricingLib.ticketWithLines`), not as a bps share, so
        // it is taken off the top rather than competing with the skim slices above for a share
        // of `remaining`.
        alloc = input.mintFeeWei < remaining ? input.mintFeeWei : remaining;
        out.mintFeeReserve = alloc;
        remaining -= alloc;

        out.vaultCash = remaining;
    }

    /// @notice Builder receives its configured share of the gross operator allocation;
    ///         rounding remainder belongs to the operator.
    function operatorSplit(uint256 gross, uint16 builderBps)
        internal
        pure
        returns (uint256 operator, uint256 builder)
    {
        builder = gross * builderBps / BPS;
        operator = gross - builder;
    }

    // ------------------------------------------------------------------ shares

    /// @notice Virtual shares offsetting the share ledger (INV-V5). The offset is 1 wei to 1e6
    ///         shares, so a donation before the first deposit cannot round it to zero shares.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    /// @notice Virtual assets offsetting the share ledger (INV-V5).
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Shares minted for `assetsWei` added to a vault worth `navWei` before the deposit.
    /// @dev Rounds down, so a deposit never mints more than its NAV share.
    function sharesForAssets(uint256 assetsWei, uint256 navWei, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return FP.fullMulDiv(assetsWei, totalShares + VIRTUAL_SHARES, navWei + VIRTUAL_ASSETS);
    }

    /// @notice Assets `shares` claim against a vault worth `navWei`.
    /// @dev Rounds down, so redemptions never pay more than the claim.
    function assetsForShares(uint256 shares, uint256 navWei, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return FP.fullMulDiv(shares, navWei + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }
}
