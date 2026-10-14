// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {Denominations} from "shapes/lib/Denominations.sol";

/// @notice Calls internal library functions through an external boundary so reverts are catchable.
contract PricingLibHarness {
    function rowBacking(PricingLib.MixRow memory row) external pure returns (uint256) {
        return PricingLib.rowBacking(row);
    }

    function mintLineBps(uint256 feeWei, uint256 backingWei) external pure returns (uint256) {
        return PricingLib.mintLineBps(feeWei, backingWei);
    }

    function weightOf(uint256 notionalWei) external pure returns (uint256) {
        return PricingLib.weightOf(notionalWei);
    }

    function sharesFor(uint256 assetsWei, uint256 navWei, uint256 totalShares) external pure returns (uint256) {
        return PricingLib.sharesFor(assetsWei, navWei, totalShares);
    }

    function claimFor(uint256 shares, uint256 navWei, uint256 totalShares) external pure returns (uint256) {
        return PricingLib.claimFor(shares, navWei, totalShares);
    }
}

contract PricingLibTest is Test {
    PricingLibHarness internal h;

    function setUp() public {
        h = new PricingLibHarness();
    }

    function _row(uint8 a, uint8 b, uint16 shareBps) internal pure returns (PricingLib.MixRow memory row) {
        row.rungs = new uint8[](2);
        row.rungs[0] = a;
        row.rungs[1] = b;
        row.shareBps = shareBps;
    }

    // ------------------------------------------------------------------ mix table

    function test_aShapeRowBacksTheRungAmountAndIsNotAPack() public pure {
        PricingLib.MixRow memory row;
        row.rungs = new uint8[](1);
        row.rungs[0] = 2;
        assertEq(PricingLib.rowBacking(row), Denominations.amountAt(2));
        assertFalse(PricingLib.isPack(row));
    }

    function test_aPackRowBacksTheSumOfItsRungs() public pure {
        PricingLib.MixRow memory row = _row(0, 3, 2_500);
        assertEq(PricingLib.rowBacking(row), Denominations.amountAt(0) + Denominations.amountAt(3));
        assertTrue(PricingLib.isPack(row));
    }

    function test_aRowWithoutRungsReverts() public {
        PricingLib.MixRow memory row;
        vm.expectRevert(PricingLib.EmptyRow.selector);
        h.rowBacking(row);
    }

    function test_aRungOutsideTheLadderReverts() public {
        PricingLib.MixRow memory row = _row(0, 9, 100);
        vm.expectRevert(abi.encodeWithSelector(Denominations.DenominationIndexOutOfRange.selector, 9));
        h.rowBacking(row);
    }

    function test_rowDepthIsMinItemsScaledByShare() public pure {
        assertEq(PricingLib.rowDepth(40, 2_500), 10);
        assertEq(PricingLib.rowDepth(40, 0), 0);
        assertEq(PricingLib.rowDepth(40, 10_000), 40);
    }

    function test_rowDepthRoundsUp() public pure {
        assertEq(PricingLib.rowDepth(10, 3_333), 4);
    }

    // ------------------------------------------------------------------ entry fee

    function test_theEntryFeeIsTheFloorWithoutVolume() public pure {
        assertEq(PricingLib.entryFeeBps(200, 0, 50 ether, 1_000, 2_500, 20), 1_000);
    }

    function test_theEntryFeeIsTheFloorWithoutNav() public pure {
        assertEq(PricingLib.entryFeeBps(200, 10 ether, 0, 1_000, 2_500, 20), 1_000);
    }

    function test_theEntryFeeIsPaybackDaysOfYieldInsideTheBand() public pure {
        // 200 bps of 6.25 ETH over 50 ETH is 25 bps a day; 20 days is 500 bps, below the floor.
        assertEq(PricingLib.entryFeeBps(200, 6.25 ether, 50 ether, 1_000, 2_500, 20), 1_000);
        // 200 bps of 15 ETH over 50 ETH is 60 bps a day; 20 days is 1,200 bps.
        assertEq(PricingLib.entryFeeBps(200, 15 ether, 50 ether, 1_000, 2_500, 20), 1_200);
    }

    function test_theEntryFeeIsCapped() public pure {
        assertEq(PricingLib.entryFeeBps(200, 100 ether, 50 ether, 1_000, 2_500, 20), 2_500);
        assertEq(PricingLib.entryFeeBps(200, type(uint128).max, 1, 1_000, 2_500, 20), 2_500);
    }

    function test_theEntryFeeDividesOnceAfterThePaybackProduct() public pure {
        // 200 * 20 * 1 / 7 = 571.4, not 20 * (200 * 1 / 7) = 560.
        assertEq(PricingLib.entryFeeBps(200, 1 ether, 7 ether, 0, 2_500, 20), 571);
    }

    function testFuzz_theEntryFeeStaysBetweenFloorAndCap(uint128 volume, uint128 nav) public pure {
        uint256 fee = PricingLib.entryFeeBps(200, volume, nav, 1_000, 2_500, 20);
        assertGe(fee, 1_000);
        assertLe(fee, 2_500);
    }

    function test_theContributionIsTheFeeShareOfTheDeposit() public pure {
        assertEq(PricingLib.entryContribution(10 ether, 1_100), 1.1 ether);
        assertEq(PricingLib.entryContribution(10 ether, 0), 0);
    }

    // ------------------------------------------------------------------ listing price

    function test_theListingPriceAddsEverySliceToTheBacking() public pure {
        // 1 ETH * (10_000 + 200 + 100 + 400 + 50) / 10_000
        assertEq(PricingLib.listingPrice(1 ether, 200, 100, 400, 50), 1.075 ether);
    }

    function test_theListingPriceWithNoSlicesIsTheBacking() public pure {
        assertEq(PricingLib.listingPrice(0.37 ether, 0, 0, 0, 0), 0.37 ether);
    }

    function test_theMintLineCoversTheMintFeeAndRoundsUp() public pure {
        assertEq(PricingLib.mintLineBps(0.0005 ether, 1 ether), 5);
        assertEq(PricingLib.mintLineBps(1, 3), 3_334);
        assertEq(PricingLib.mintLineBps(0, 1 ether), 0);
    }

    function test_theMintLineNeedsABacking() public {
        vm.expectRevert(PricingLib.ZeroDivisor.selector);
        h.mintLineBps(1, 0);
    }

    function testFuzz_theListingPriceCoversTheMintFee(uint64 backing, uint64 fee) public pure {
        vm.assume(backing != 0);
        uint256 line = PricingLib.mintLineBps(fee, backing);
        uint256 price = PricingLib.listingPrice(backing, 0, 0, 0, line);
        assertGe(price - backing, fee == 0 ? 0 : uint256(fee) - 1);
    }

    // ------------------------------------------------------------------ selection weight

    function test_weightIsTheInverseOfTheNotional() public pure {
        assertEq(PricingLib.weightOf(1 ether), PricingLib.NUM / 1 ether);
        assertEq(PricingLib.weightOf(0.5 ether), 2 * PricingLib.weightOf(1 ether));
    }

    function test_aZeroNotionalHasNoWeight() public {
        vm.expectRevert(PricingLib.ZeroPrice.selector);
        h.weightOf(0);
    }

    function test_aNotionalAboveTheNumeratorHasNoWeight() public {
        vm.expectRevert(PricingLib.PriceTooHigh.selector);
        h.weightOf(PricingLib.NUM + 1);
    }

    // ------------------------------------------------------------------ GRAIL

    function test_theGrailNotionalIsTheListShareOfTheBacking() public pure {
        assertEq(PricingLib.grailNotional(10 ether, 10_000), 10 ether);
        assertEq(PricingLib.grailNotional(10 ether, 12_500), 12.5 ether);
        assertEq(PricingLib.grailNotional(10 ether, 1), 0.001 ether);
    }

    function test_theNotionalDecaysPerPull() public pure {
        assertEq(PricingLib.decayedNotional(10 ether, 0.01 ether, 100, 1 ether), 9 ether);
        assertEq(PricingLib.decayedNotional(10 ether, 0.01 ether, 0, 1 ether), 10 ether);
    }

    function test_theDecayStopsAtTheFloor() public pure {
        assertEq(PricingLib.decayedNotional(10 ether, 0.01 ether, 10_000, 1 ether), 1 ether);
        assertEq(PricingLib.decayedNotional(10 ether, 0.01 ether, 900, 1 ether), 1 ether);
    }

    function test_aDecayLargerThanTheNotionalLandsOnTheFloor() public pure {
        assertEq(PricingLib.decayedNotional(1 ether, 1 ether, 5, 0.25 ether), 0.25 ether);
    }

    function testFuzz_theDecayedNotionalNeverFallsBelowTheFloor(
        uint96 notional,
        uint64 decay,
        uint32 pulls,
        uint96 floorWei
    ) public pure {
        assertGe(PricingLib.decayedNotional(notional, decay, pulls, floorWei), floorWei);
    }

    // ------------------------------------------------------------------ shares

    function test_theFirstDepositMintsSharesOneToOne() public pure {
        assertEq(PricingLib.sharesFor(5 ether, 0, 0), 5 ether);
    }

    function test_sharesAreProportionalToNav() public pure {
        assertEq(PricingLib.sharesFor(10 ether, 100 ether, 50 ether), 5 ether);
    }

    function test_sharesAgainstZeroNavRevert() public {
        vm.expectRevert(PricingLib.ZeroDivisor.selector);
        h.sharesFor(1 ether, 0, 1);
    }

    function test_aClaimIsTheNavShare() public pure {
        assertEq(PricingLib.claimFor(5 ether, 100 ether, 50 ether), 10 ether);
    }

    function test_aClaimWithoutSharesOutstandingReverts() public {
        vm.expectRevert(PricingLib.ZeroDivisor.selector);
        h.claimFor(1, 1 ether, 0);
    }

    function test_bothDirectionsRoundDown() public pure {
        // 3 * 11 / 7 = 4.71, 3 * 7 / 11 = 1.9
        assertEq(PricingLib.sharesFor(3, 7, 11), 4);
        assertEq(PricingLib.claimFor(3, 7, 11), 1);
    }

    function testFuzz_aClaimNeverExceedsNav(uint96 navWei, uint96 totalShares, uint96 shares) public pure {
        vm.assume(totalShares != 0 && shares <= totalShares);
        assertLe(PricingLib.claimFor(shares, navWei, totalShares), navWei);
    }
}
