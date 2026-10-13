// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib as FP} from "solady/utils/FixedPointMathLib.sol";
import {Denominations} from "shapes/lib/Denominations.sol";

/// @title PricingLib
/// @notice Pure math for the mix table, entry curve, listing price, board depth, GRAIL notional
///         and share accounting.
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

    /// @notice Target board items for one row: `max(minItems, trailingPulls)` scaled by `shareBps`,
    ///         rounded up so the rows together cover the board target.
    function rowDepth(uint256 minItems, uint256 trailingPulls, uint256 shareBps) internal pure returns (uint256) {
        uint256 depth = minItems > trailingPulls ? minItems : trailingPulls;
        return FP.fullMulDivUp(depth, shareBps, BPS);
    }

    // ------------------------------------------------------------------ entry curve

    /// @notice Entry curve in bps: `min(capBps, baseBps + slopeBps * navWei / referenceWei)`.
    function entryCurveBps(uint256 navWei, uint256 baseBps, uint256 slopeBps, uint256 capBps, uint256 referenceWei)
        internal
        pure
        returns (uint256)
    {
        if (referenceWei == 0) revert ZeroDivisor();
        uint256 curve = baseBps + FP.fullMulDiv(slopeBps, navWei, referenceWei);
        return curve < capBps ? curve : capBps;
    }

    /// @notice Part of a deposit routed to the GRAIL buckets at `curveBps`.
    function entryContribution(uint256 valueWei, uint256 curveBps) internal pure returns (uint256) {
        return FP.fullMulDiv(valueWei, curveBps, BPS);
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
