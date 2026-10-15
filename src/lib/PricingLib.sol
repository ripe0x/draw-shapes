// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib as FP} from "solady/utils/FixedPointMathLib.sol";
import {Denominations} from "shapes/lib/Denominations.sol";

/// @title PricingLib
/// @notice Pure math for the mix table, replacement row choice, entry fee, listing price, GRAIL
///         notional and share accounting.
/// @dev Divisions round down unless the function name or its notice says otherwise. Products use
///      `FixedPointMathLib` full precision multiply-divide.
library PricingLib {
    uint256 internal constant BPS = 10_000;
    /// @notice FWA `INVERSE_WEIGHT_NUMERATOR`. Selection weight is `NUM / notional`.
    uint256 internal constant NUM = 1e36;

    error ZeroPrice();
    error PriceTooHigh();
    error ZeroDivisor();
    error EmptyRow();

    /// @notice One mix table row. `rungs` holds Shapes ladder rung indices (`Denominations`
    ///         indices). One rung is a Shape, two or more rungs are a Draw Pack. `shareBps` is the
    ///         row's weight share of the board.
    struct MixRow {
        uint8[] rungs;
        uint16 shareBps;
    }

    // ------------------------------------------------------------------ mix table

    /// @notice Backing of one token built from `row`: the sum of its rung amounts.
    /// @dev Reverts `EmptyRow` for a row without rungs and `Denominations.DenominationIndexOutOfRange`
    ///      for a rung index outside the ladder.
    function rowBacking(MixRow memory row) internal pure returns (uint256 backingWei) {
        uint256 length = row.rungs.length;
        if (length == 0) revert EmptyRow();
        for (uint256 i; i < length; ++i) {
            backingWei += Denominations.amountAt(row.rungs[i]);
        }
    }

    /// @notice Whether `row` is a Draw Pack (two or more rungs).
    function isPack(MixRow memory row) internal pure returns (bool) {
        return row.rungs.length >= 2;
    }

    /// @notice Target board items for one row: `items * shareBps / 10_000`, rounded up. Callers
    ///         pass `boardItems()` as `items`.
    function rowDepth(uint256 items, uint256 shareBps) internal pure returns (uint256) {
        return FP.fullMulDivUp(items, shareBps, BPS);
    }

    /// @notice Inputs of `chooseRow` for one mix row. `count` is the listed, held and queued items
    ///         of the row, `target` its `rowDepth`, `single` whether it is a one rung Shape row.
    struct RowState {
        uint256 shareBps;
        uint256 count;
        uint256 target;
        uint256 backingWei;
        bool single;
    }

    /// @notice Row that replaces a captured listing, drawn from the hash `h`.
    /// @dev 1. Deficit draw: row weight is `shareBps * (BPS + restoreK * deficit * BPS / target) / BPS`
    ///         with `deficit = max(target - count, 0)`, drawn by `uint256(h) % sum`.
    ///      2. Surprise: when `(uint256(h) >> 64) % BPS < surpriseBps`, the candidates are the single
    ///         rung rows below their target with at least 5 times the drawn row's backing. The three of lowest backing
    ///         (lowest index on a tie) take the weights 60, 30 and 10, cut to the candidate count and
    ///         drawn by `(uint256(h) >> 128) % 100` scaled to the weight sum.
    ///      3. Band: a row with `count >= max(target + 1, ceil(target * (BPS + bandBps) / BPS))` is
    ///         replaced by the row of largest deficit (lowest index on a tie). When no row is below
    ///         its target the step 1 row stands.
    ///      `fallbackRow` is returned when every share is zero. `type(uint256).max` is returned
    ///      when no row is below its target: the capture is not replaced.
    function chooseRow(
        bytes32 h,
        RowState[] memory rows,
        uint256 restoreK,
        uint256 surpriseBps,
        uint256 bandBps,
        uint256 fallbackRow
    ) internal pure returns (uint256 chosen, bool surprise) {
        uint256 n = rows.length;
        uint256[] memory weight = new uint256[](n);
        uint256 total;
        bool anyBelow;
        for (uint256 i; i < n; ++i) {
            RowState memory r = rows[i];
            if (r.count < r.target) anyBelow = true;
            uint256 boost = r.target > r.count ? restoreK * (r.target - r.count) * BPS / r.target : 0;
            weight[i] = r.shareBps * (BPS + boost) / BPS;
            total += weight[i];
        }
        if (total == 0) return (fallbackRow, false);
        if (!anyBelow) return (type(uint256).max, false);
        uint256 pick = uint256(h) % total;
        uint256 drawn;
        for (; drawn < n; ++drawn) {
            if (pick < weight[drawn]) break;
            pick -= weight[drawn];
        }

        chosen = drawn;
        if ((uint256(h) >> 64) % BPS < surpriseBps) {
            (chosen, surprise) = _surprise(h, rows, drawn);
        }

        RowState memory c = rows[chosen];
        uint256 cap = (c.target * (BPS + bandBps) + BPS - 1) / BPS;
        if (cap < c.target + 1) cap = c.target + 1;
        if (c.count >= cap) {
            uint256 bestDeficit;
            uint256 bestRow = type(uint256).max;
            for (uint256 i; i < n; ++i) {
                if (rows[i].target > rows[i].count && rows[i].target - rows[i].count > bestDeficit) {
                    bestDeficit = rows[i].target - rows[i].count;
                    bestRow = i;
                }
            }
            chosen = bestRow == type(uint256).max ? drawn : bestRow;
            surprise = false;
        }
    }

    /// @dev Surprise step of `chooseRow`. Returns `drawn` and false when no candidate exists.
    function _surprise(bytes32 h, RowState[] memory rows, uint256 drawn)
        private
        pure
        returns (uint256 row, bool picked)
    {
        uint256 minBacking = rows[drawn].backingWei * 5;
        uint256[3] memory candidates;
        uint256 m;
        uint256 lastBacking;
        uint256 lastIndex;
        for (; m < 3; ++m) {
            uint256 best = type(uint256).max;
            for (uint256 i; i < rows.length; ++i) {
                RowState memory r = rows[i];
                if (!r.single || r.backingWei < minBacking || r.count >= r.target) continue;
                if (m != 0 && (r.backingWei < lastBacking || (r.backingWei == lastBacking && i <= lastIndex))) {
                    continue;
                }
                if (best == type(uint256).max || r.backingWei < rows[best].backingWei) best = i;
            }
            if (best == type(uint256).max) break;
            candidates[m] = best;
            lastBacking = rows[best].backingWei;
            lastIndex = best;
        }
        if (m == 0) return (drawn, false);
        uint256 sum = m == 1 ? 60 : (m == 2 ? 90 : 100);
        uint256 x = ((uint256(h) >> 128) % 100) * sum / 100;
        uint256 acc;
        for (uint256 j; j < m; ++j) {
            acc += j == 0 ? 60 : (j == 1 ? 30 : 10);
            if (x < acc) return (candidates[j], true);
        }
    }

    // ------------------------------------------------------------------ entry fee

    /// @notice Entry fee in bps: `paybackDays` days of depositor yield, clamped to
    ///         `[floorBps, capBps]`. Daily yield in bps of NAV is `premiumBps * dailyVolumeWei /
    ///         navWei`, and zero when `navWei` is zero. The product is divided once, after the
    ///         multiplication by `paybackDays`.
    function entryFeeBps(
        uint256 premiumBps,
        uint256 dailyVolumeWei,
        uint256 navWei,
        uint256 floorBps,
        uint256 capBps,
        uint256 paybackDays
    ) internal pure returns (uint256) {
        uint256 fee = navWei == 0 ? 0 : FP.fullMulDiv(premiumBps * paybackDays, dailyVolumeWei, navWei);
        if (fee < floorBps) return floorBps;
        return fee < capBps ? fee : capBps;
    }

    /// @notice Part of a deposit routed to the GRAIL buckets at `feeBps`.
    function entryContribution(uint256 valueWei, uint256 feeBps) internal pure returns (uint256) {
        return FP.fullMulDiv(valueWei, feeBps, BPS);
    }

    // ------------------------------------------------------------------ listing price

    /// @notice FWA list price of an ordinary token:
    ///         `backing * (10_000 + premiumBps + maintenanceBps + feedBps + mintLine) / 10_000`.
    /// @param mintLine The `mintLineBps` value for the token.
    function listingPrice(
        uint256 backingWei,
        uint256 premiumBps,
        uint256 maintenanceBps,
        uint256 feedBps,
        uint256 mintLine
    ) internal pure returns (uint256) {
        return FP.fullMulDiv(backingWei, BPS + premiumBps + maintenanceBps + feedBps + mintLine, BPS);
    }

    /// @notice Replacement mint fee as bps of the token's backing, rounded up so the line covers
    ///         the fee.
    function mintLineBps(uint256 mintFeeWei, uint256 backingWei) internal pure returns (uint256) {
        if (backingWei == 0) revert ZeroDivisor();
        return FP.fullMulDivUp(mintFeeWei, BPS, backingWei);
    }

    // ------------------------------------------------------------------ selection weight

    /// @notice FWA selection weight for a list price.
    function weightOf(uint256 notionalWei) internal pure returns (uint256 weight) {
        if (notionalWei == 0) revert ZeroPrice();
        weight = NUM / notionalWei;
        if (weight == 0) revert PriceTooHigh();
    }

    // ------------------------------------------------------------------ GRAIL

    /// @notice GRAIL list price: `backing * listBps / 10_000`.
    function grailNotional(uint256 backingWei, uint256 listBps) internal pure returns (uint256) {
        return FP.fullMulDiv(backingWei, listBps, BPS);
    }

    /// @notice GRAIL list price after decay:
    ///         `max(floorWei, notionalWei - decayWeiPerPull * pullsSinceList)`.
    function decayedNotional(uint256 notionalWei, uint256 decayWeiPerPull, uint256 pullsSinceList, uint256 floorWei)
        internal
        pure
        returns (uint256)
    {
        uint256 decay = decayWeiPerPull * pullsSinceList;
        if (decay >= notionalWei) return floorWei;
        uint256 decayed = notionalWei - decay;
        return decayed > floorWei ? decayed : floorWei;
    }

    // ------------------------------------------------------------------ shares

    /// @notice Shares minted for `assetsWei` added to a pool of ordinary NAV `navWei`. Equal to
    ///         `assetsWei` when `totalShares` is zero. Rounds down.
    function sharesFor(uint256 assetsWei, uint256 navWei, uint256 totalShares) internal pure returns (uint256) {
        if (totalShares == 0) return assetsWei;
        if (navWei == 0) revert ZeroDivisor();
        return FP.fullMulDiv(assetsWei, totalShares, navWei);
    }

    /// @notice Claim of `shares` against ordinary NAV `navWei`. Rounds down.
    function claimFor(uint256 shares, uint256 navWei, uint256 totalShares) internal pure returns (uint256) {
        if (totalShares == 0) revert ZeroDivisor();
        return FP.fullMulDiv(shares, navWei, totalShares);
    }
}
