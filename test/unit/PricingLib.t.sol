// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {Denominations} from "shapes/lib/Denominations.sol";
import {Histogram, Skim} from "../../src/PoolStore.sol";

/// @notice Holds a Histogram in storage so the library's storage-pointer functions are testable
///         exactly as custody calls them.
contract HistogramHarness {
    Histogram internal h;

    function add(uint256 backingWei, uint256 notionalWei, uint256 count) external {
        uint256 weight = PricingLib.weightOf(notionalWei);
        for (uint256 i; i < count; ++i) {
            PricingLib.addToHistogram(h, backingWei, notionalWei, weight);
        }
    }

    function remove(uint256 backingWei, uint256 notionalWei) external {
        PricingLib.removeFromHistogram(h, backingWei, notionalWei, PricingLib.weightOf(notionalWei));
    }

    function evPassMax(uint256 removals) external view returns (uint256) {
        return PricingLib.evPassMax(h, removals, new PricingLib.GameListing[](0));
    }

    /// @dev The rolling worst case with game-owned listings removed first: their removal takes
    ///      weight out of the denominator and leaves the EV basis alone (S25).
    function evPassMaxWithGrails(uint256 removals, uint256 grailNotionalWei, uint256 grailCount)
        external
        view
        returns (uint256)
    {
        PricingLib.GameListing[] memory game = new PricingLib.GameListing[](grailCount);
        for (uint256 i; i < grailCount; ++i) {
            game[i] = PricingLib.GameListing({weight: PricingLib.weightOf(grailNotionalWei)});
        }
        return PricingLib.evPassMax(h, removals, game);
    }

    /// @dev Adds a game-owned listing: weight into the selection denominator, nothing into the
    ///      EV basis.
    function addGame(uint256 notionalWei) external {
        PricingLib.addGameListing(h, PricingLib.weightOf(notionalWei));
    }

    /// @dev The rolling worst case against an arbitrary game listing set, for a test that builds
    ///      its own mixed inventory rather than a uniform one. `game` must already be sorted
    ///      descending by weight, the order `CustodyOps.gameListings` produces.
    function evPassMaxWithGameListings(uint256 removals, PricingLib.GameListing[] calldata game)
        external
        view
        returns (uint256)
    {
        return PricingLib.evPassMax(h, removals, game);
    }

    function evPass() external view returns (uint256) {
        return PricingLib.evPass(h.weightedBackingWei, h.totalWeight);
    }

    function totals() external view returns (uint256 count, uint256 weight, uint256 weightedBacking) {
        return (h.totalCount, h.totalWeight, h.weightedBackingWei);
    }

    function backingCountAt(uint256 index) external view returns (uint256) {
        return h.backingCounts[index];
    }

    function countAt(uint256 backingIndex, uint256 notionalIndex) external view returns (uint256) {
        return h.counts[backingIndex][notionalIndex];
    }

    function requireNotionalIndexOf(uint256 notionalWei) external pure returns (uint256) {
        return PricingLib.requireNotionalIndexOf(notionalWei);
    }

    function backingAt(uint256 index) external pure returns (uint256) {
        return PricingLib.backingAt(index);
    }

    function ticketFromFloor(uint256 floorWei, uint256 skimBps) external pure returns (uint256) {
        return PricingLib.ticketFromFloor(floorWei, skimBps);
    }

    function fwaBaseFromFee(uint256 feeWei, uint256 edgeBps) external pure returns (uint256) {
        return PricingLib.fwaBaseFromFee(feeWei, edgeBps);
    }
}

/// @notice The (backing, notional) histogram, the rolling worst case, the ticket floor and the
///         waterfall (ECO-V1 through ECO-V8).
contract PricingLibTest is Test {
    HistogramHarness internal h;

    function setUp() public {
        h = new HistogramHarness();
    }

    /// @dev Current FWA floors `base * (BPS + edge) / BPS`. For every supported edge, the
    ///      multiplier is at least one, so the rounded-up inverse recovers the unique base.
    function testFuzz_theFwaFeeInverseRecoversTheExactRequestBase(uint128 baseWei, uint16 edgeBps)
        public
        view
    {
        edgeBps = uint16(bound(edgeBps, 0, 1_000));
        uint256 feeWei = uint256(baseWei) * (10_000 + edgeBps) / 10_000;
        assertEq(h.fwaBaseFromFee(feeWei, edgeBps), uint256(baseWei));
    }

    // ------------------------------------------------------------------ ladder

    /// @dev Every rung amount round-trips to its own index.
    function test_theNotionalLadderRoundTrips() public pure {
        for (uint256 i; i < PricingLib.NOTIONAL_COUNT; ++i) {
            (uint256 index, bool ok) = PricingLib.notionalIndexOf(PricingLib.notionalAt(i));
            assertTrue(ok);
            assertEq(index, i);
        }

    }

    /// @dev Rungs 0 to 3 sit below the backing rung table and rungs 4 to 12 carry it in rung index
    ///      order, so a notional index is its backing rung index plus four.
    function test_theNotionalLadderExtendsBelowTheBackingRungTable() public pure {
        uint256 unit = Denominations.amountAt(0);
        assertEq(PricingLib.notionalAt(0), unit / 100);
        assertEq(PricingLib.notionalAt(1), unit / 20);
        assertEq(PricingLib.notionalAt(2), unit / 10);
        assertEq(PricingLib.notionalAt(3), unit / 2);
        assertLt(PricingLib.notionalAt(3), unit, "a discount rung reached the backing floor");
        for (uint256 rung; rung < PricingLib.BACKING_COUNT; ++rung) {
            assertEq(PricingLib.notionalAt(rung + 4), PricingLib.backingAt(rung));
        }
    }

    /// @dev The immutable launch backing domain is exactly the nine native Shapes denominations.
    function test_theBackingRungTableIsExactlyTheShapeDenominations() public pure {
        for (uint256 i; i < Denominations.COUNT; ++i) {
            assertEq(PricingLib.backingAt(i), Denominations.amountAt(i));
            (uint256 index, bool ok) = PricingLib.backingIndexOf(Denominations.amountAt(i));
            assertTrue(ok);
            assertEq(index, i);
        }

        uint256[] memory rungs = PricingLib.backingRungs();
        assertEq(rungs.length, PricingLib.BACKING_COUNT);
        for (uint256 i; i < rungs.length; ++i) {
            assertEq(rungs[i], PricingLib.backingAt(i));
        }
    }

    function test_unreviewedPackBackingValuesStayOutsideTheFixedDomain() public {
        uint256 unit = Denominations.UNIT;
        uint256[6] memory unsupported =
            [uint256(8 * unit), 9 * unit, 13 * unit, 25 * unit, 60 * unit, 110 * unit];
        for (uint256 i; i < unsupported.length; ++i) {
            (uint256 index, bool ok) = PricingLib.backingIndexOf(unsupported[i]);
            assertFalse(ok, "an unreviewed pack backing was accepted");
            assertEq(index, 0);
            vm.expectRevert(abi.encodeWithSelector(PricingLib.UnsupportedBacking.selector, unsupported[i]));
            h.add(unsupported[i], Denominations.amountAt(0), 1);
        }
        vm.expectRevert(abi.encodeWithSelector(PricingLib.BackingRungOutOfRange.selector, 20));
        h.backingAt(20);
    }

    function test_theBackingRungAmountOrderIsTheNativeOrder() public pure {
        uint256 previous;
        for (uint256 position; position < PricingLib.BACKING_COUNT; ++position) {
            uint256 amount = PricingLib.backingAt(PricingLib.backingRungByAmount(position));
            assertGt(amount, previous);
            previous = amount;
        }
    }

    /// @dev A2: a Shapes inventory bins at each denomination's unchanged native index.
    function test_aShapesOnlyInventoryBinsAtTheDenominationIndices() public {
        for (uint256 i; i < Denominations.COUNT; ++i) {
            uint256 amount = Denominations.amountAt(i);
            h.add(amount, amount, i + 1);
        }

        for (uint256 i; i < Denominations.COUNT; ++i) {
            uint256 amount = Denominations.amountAt(i);
            assertEq(h.backingCountAt(i), i + 1, "a denomination left its own rung");
            assertEq(h.countAt(i, PricingLib.requireNotionalIndexOf(amount)), i + 1);
        }
        uint256 weight;
        uint256 weightedBacking;
        uint256 count;
        for (uint256 i; i < Denominations.COUNT; ++i) {
            uint256 amount = Denominations.amountAt(i);
            weight += (i + 1) * PricingLib.weightOf(amount);
            weightedBacking += (i + 1) * amount * PricingLib.weightOf(amount);
            count += i + 1;
        }
        (uint256 totalCount, uint256 totalWeight, uint256 totalWeightedBacking) = h.totals();
        assertEq(totalCount, count);
        assertEq(totalWeight, weight);
        assertEq(totalWeightedBacking, weightedBacking);
        assertEq(h.evPass(), weightedBacking / weight);
        assertEq(h.evPassMax(0), weightedBacking / weight);
    }

    function test_anAmountOffTheLadderIsRejected() public {
        (, bool ok) = PricingLib.notionalIndexOf(0.037 ether);
        assertFalse(ok);
        vm.expectRevert(abi.encodeWithSelector(PricingLib.UnsupportedNotional.selector, uint256(0.037 ether)));
        h.requireNotionalIndexOf(0.037 ether);
    }

    function test_weightIsTheInverseOfTheNotional() public pure {
        assertEq(PricingLib.weightOf(0.05 ether), PricingLib.NUM / 0.05 ether);
        assertEq(PricingLib.weightOf(0.05 ether), 2e19);
    }

    // ------------------------------------------------------------------ histogram

    function test_addAndRemoveKeepEveryTotalExact() public {
        h.add(0.05 ether, 0.05 ether, 3);
        h.add(0.5 ether, 0.1 ether, 2);

        (uint256 count, uint256 weight, uint256 weightedBacking) = h.totals();
        assertEq(count, 5);
        assertEq(weight, 3 * PricingLib.weightOf(0.05 ether) + 2 * PricingLib.weightOf(0.1 ether));
        assertEq(
            weightedBacking,
            3 * 0.05 ether * PricingLib.weightOf(0.05 ether) + 2 * 0.5 ether * PricingLib.weightOf(0.1 ether)
        );
        assertEq(h.backingCountAt(PricingLib.requireBackingIndexOf(0.05 ether)), 3);
        assertEq(h.backingCountAt(PricingLib.requireBackingIndexOf(0.5 ether)), 2);

        h.remove(0.5 ether, 0.1 ether);
        (count,,) = h.totals();
        assertEq(count, 4);
        assertEq(h.backingCountAt(PricingLib.requireBackingIndexOf(0.5 ether)), 1);
    }

    function test_backingAndNotionalBinIndependently() public {
        // Same backing, two notionals: two bins in one backing row.
        h.add(0.5 ether, 0.5 ether, 1);
        h.add(0.5 ether, 0.1 ether, 1);
        uint256 rung = PricingLib.requireBackingIndexOf(0.5 ether);
        assertEq(h.backingCountAt(rung), 2);
        assertEq(h.countAt(rung, PricingLib.requireNotionalIndexOf(0.5 ether)), 1);
        assertEq(h.countAt(rung, PricingLib.requireNotionalIndexOf(0.1 ether)), 1);
    }

    // ------------------------------------------------------------------ EV_pass

    function test_evPassIsTheWeightedBackingOverTheWeight() public {
        h.add(0.05 ether, 0.05 ether, 4);
        assertEq(h.evPass(), 0.05 ether);

        // Adding a Shape worth ten times as much at its own backing raises the average.
        h.add(0.5 ether, 0.5 ether, 1);
        assertGt(h.evPass(), 0.05 ether);
        assertLt(h.evPass(), 0.5 ether);
    }

    function test_evPassMaxWithNoRemovalsIsEvPass() public {
        h.add(0.05 ether, 0.05 ether, 4);
        assertEq(h.evPassMax(0), h.evPass());
    }

    function test_removingMoreThanIsListedReverts() public {
        h.add(0.05 ether, 0.05 ether, 3);
        vm.expectRevert(abi.encodeWithSelector(PricingLib.RemovalExceedsInventory.selector, 3, 3));
        h.evPassMax(3);
    }

    function test_theWorstCaseTakesTheLowestBackingFirst() public {
        // Three cheap Shapes and one dear one, all listed at their backing.
        h.add(0.05 ether, 0.05 ether, 3);
        h.add(0.5 ether, 0.5 ether, 1);

        uint256 base = h.evPass();
        uint256 worstOne = h.evPassMax(1);
        uint256 worstTwo = h.evPassMax(2);

        // Taking a 0.05 out first lifts the average, and taking two lifts it further.
        assertGt(worstOne, base);
        assertGt(worstTwo, worstOne);
    }

    /// @dev A high-weight listing can have a large weight without a low backing, so ordering
    ///      removals by weight would take it first and report a
    ///      lower worst case than the inventory can actually produce.
    function test_aHighWeightListingIsNotRemovedBeforeACheaperOrdinaryOne() public {
        // Ordinary: backing 0.05 at notional 0.05, weight 2e19.
        h.add(0.05 ether, 0.05 ether, 2);
        // High-weight listing: backing 0.5 listed at 0.01, weight 1e20 -- five times the ordinary weight.
        h.add(0.5 ether, 0.01 ether, 1);

        assertGt(
            PricingLib.weightOf(0.01 ether),
            PricingLib.weightOf(0.05 ether),
            "the high-weight listing outweighs the ordinary ones"
        );

        uint256 lowestBackingFirst = h.evPassMax(1);

        // What removing the heaviest listing (the hot 0.5) would have reported.
        uint256 weightAll = 2 * PricingLib.weightOf(0.05 ether) + PricingLib.weightOf(0.01 ether);
        uint256 backingAll =
            2 * 0.05 ether * PricingLib.weightOf(0.05 ether) + 0.5 ether * PricingLib.weightOf(0.01 ether);
        uint256 heaviestFirst = (backingAll - 0.5 ether * PricingLib.weightOf(0.01 ether))
            / (weightAll - PricingLib.weightOf(0.01 ether));

        assertGt(lowestBackingFirst, heaviestFirst, "lowest backing first is the worse case");
        assertEq(heaviestFirst, 0.05 ether);
    }

    function test_atEqualBackingTheRelaxedPrefixesStillCoverTheExactRemoval() public {
        // Two listings at backing 0.05, one discounted to notional 0.01.
        h.add(0.05 ether, 0.05 ether, 1);
        h.add(0.05 ether, 0.01 ether, 1);
        h.add(0.5 ether, 0.5 ether, 1);

        uint256 worst = h.evPassMax(1);
        // Removing the heavier of the two 0.05 listings strips more below-average weight.
        uint256 weightAll = PricingLib.weightOf(0.05 ether) + PricingLib.weightOf(0.01 ether)
            + PricingLib.weightOf(0.5 ether);
        uint256 backingAll = 0.05 ether * PricingLib.weightOf(0.05 ether) + 0.05 ether
            * PricingLib.weightOf(0.01 ether) + 0.5 ether * PricingLib.weightOf(0.5 ether);
        uint256 removeHeavy = (backingAll - 0.05 ether * PricingLib.weightOf(0.01 ether))
            / (weightAll - PricingLib.weightOf(0.01 ether));
        uint256 removeLight = (backingAll - 0.05 ether * PricingLib.weightOf(0.05 ether))
            / (weightAll - PricingLib.weightOf(0.05 ether));

        assertGt(removeHeavy, removeLight);
        assertGe(worst, removeHeavy);
    }

    function test_theWorstCaseIsBoundedWorkWhateverTheInventorySize() public {
        h.add(0.05 ether, 0.05 ether, 700);
        h.add(0.5 ether, 0.5 ether, 700);
        uint256 gasBefore = gasleft();
        h.evPassMax(15);
        uint256 used = gasBefore - gasleft();
        // Fixed bins and a 15-removal prefix: the read cost does not scale with 1,400 listings.
        emit log_named_uint("evPassMax h=15 gas", used);
        assertLt(used, 1_000_000);
    }

    /// @dev One item of a small mixed inventory: a vault-owned listing at (backingWei,
    ///      notionalWei) or, when `isGame` is true, a game-owned listing whose weight comes from
    ///      `notionalWei` alone.
    struct RemovalItem {
        bool isGame;
        uint256 backingWei;
        uint256 notionalWei;
        uint256 weight;
    }

    /// @notice Exhaustive proof that `evPassMax(horizon)` bounds every removal subset of size up
    ///         to `horizon`, not only the greedy path the algorithm itself walks (F-04, TASK-V14).
    /// @dev A small mixed inventory: five vault listings across two backing rungs, two of them
    ///      discounted (heavier weight than their rung's plain listing), plus two game listings at
    ///      distinct notionals. For horizon 1 to 3, every subset of the seven items of size 1 to
    ///      `horizon` is removed by hand and the resulting actual EV (vault backing still weighted
    ///      over every remaining item's weight, game included) is checked against the bound. The
    ///      bound is computed once per horizon; the removed subset is arbitrary, not the specific
    ///      one `evPassMax`'s own greedy walk would choose.
    function test_theRollingBoundCoversEveryRemovalSubsetOnSmallMixedInventories() public {
        RemovalItem[7] memory items = [
            RemovalItem(false, 0.05 ether, 0.05 ether, PricingLib.weightOf(0.05 ether)),
            RemovalItem(false, 0.05 ether, 0.05 ether, PricingLib.weightOf(0.05 ether)),
            RemovalItem(false, 0.05 ether, 0.01 ether, PricingLib.weightOf(0.01 ether)),
            RemovalItem(false, 0.5 ether, 0.5 ether, PricingLib.weightOf(0.5 ether)),
            RemovalItem(false, 0.5 ether, 0.1 ether, PricingLib.weightOf(0.1 ether)),
            RemovalItem(true, 0, 0.01 ether, PricingLib.weightOf(0.01 ether)),
            RemovalItem(true, 0, 1 ether, PricingLib.weightOf(1 ether))
        ];

        uint256 totalWeight;
        uint256 vaultWeightedBackingWei;
        uint256 gameCount;
        for (uint256 i; i < items.length; ++i) {
            totalWeight += items[i].weight;
            if (items[i].isGame) {
                ++gameCount;
                h.addGame(items[i].notionalWei);
            } else {
                vaultWeightedBackingWei += items[i].backingWei * items[i].weight;
                h.add(items[i].backingWei, items[i].notionalWei, 1);
            }
        }

        // Sorted descending by weight, the order CustodyOps.gameListings produces and evPassMax
        // requires: the lighter-notional game listing (item 5, weight from 0.01 ether) outweighs
        // the heavier-notional one (item 6, weight from 1 ether).
        PricingLib.GameListing[] memory game = new PricingLib.GameListing[](gameCount);
        uint256 filled;
        for (uint256 i; i < items.length; ++i) {
            if (!items[i].isGame) continue;
            game[filled] = PricingLib.GameListing({weight: items[i].weight});
            ++filled;
        }
        assertGe(game[0].weight, game[1].weight, "the fixture's own game listings are not sorted");

        for (uint256 horizon = 1; horizon <= 3; ++horizon) {
            uint256 boundWei = h.evPassMaxWithGameListings(horizon, game);
            uint256 subsets = 1 << items.length;
            for (uint256 mask = 1; mask < subsets; ++mask) {
                uint256 size = _popCount(mask);
                if (size == 0 || size > horizon) continue;

                uint256 remainingWeight = totalWeight;
                uint256 remainingVaultWeightedBackingWei = vaultWeightedBackingWei;
                for (uint256 i; i < items.length; ++i) {
                    if ((mask >> i) & 1 == 0) continue;
                    remainingWeight -= items[i].weight;
                    if (!items[i].isGame) {
                        remainingVaultWeightedBackingWei -= items[i].backingWei * items[i].weight;
                    }
                }
                if (remainingWeight == 0) continue;

                uint256 actualEvWei = remainingVaultWeightedBackingWei / remainingWeight;
                assertGe(
                    boundWei, actualEvWei, "evPassMax missed a removal subset the greedy walk does not take"
                );
            }
        }
    }

    /// @dev Reduced native-board reproduction of the request at simulation sequence 1221. The
    ///      old local greedy walk returned 12,518,329,441,155,705 wei, below this exact maximum.
    function test_sequence1221UsesTheProvenSplitBound() public {
        uint256[5] memory counts = [uint256(350), 100, 9, 5, 0];
        PricingLib.GameListing[] memory game = _addNativeSequenceBoard(counts);

        assertEq(h.evPassMaxWithGameListings(4, game), 12_518_369_346_323_409);
    }

    /// @dev Reduced native-board reproduction of the request at simulation sequence 1396. The
    ///      old local greedy walk returned 12,504,820,139,921,776 wei, below this exact maximum.
    function test_sequence1396UsesTheProvenSplitBound() public {
        uint256[5] memory counts = [uint256(344), 105, 8, 0, 0];
        PricingLib.GameListing[] memory game = _addNativeSequenceBoard(counts);

        assertEq(h.evPassMaxWithGameListings(4, game), 12_504_830_784_519_405);
    }

    /// @notice Random native-ladder boards check every feasible horizon against an exhaustive
    ///         subset oracle. Eight items keep the oracle finite while exercising mixed ownership,
    ///         discounted notionals, multiplicities and exact integer-floor behavior.
    function testFuzz_theSplitBoundCoversEveryRemovalSubsetOnRandomNativeBoards(uint256 seed) public {
        uint256 count = 2 + (seed % 7);
        RemovalItem[8] memory items;
        uint256 gameCount;
        uint256 vaultCount;

        for (uint256 i; i < count; ++i) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, i)));
            bool isGame = entropy % 5 == 0;
            if (i + 1 == count && vaultCount == 0) isGame = false;
            uint256 notionalWei = PricingLib.notionalAt((entropy >> 8) % PricingLib.NOTIONAL_COUNT);
            uint256 backingWei;
            if (isGame) {
                ++gameCount;
            } else {
                backingWei = PricingLib.backingAt((entropy >> 16) % Denominations.COUNT);
                ++vaultCount;
            }
            items[i] = RemovalItem({
                isGame: isGame,
                backingWei: backingWei,
                notionalWei: notionalWei,
                weight: PricingLib.weightOf(notionalWei)
            });
        }

        PricingLib.GameListing[] memory game = new PricingLib.GameListing[](gameCount);
        uint256 filled;
        for (uint256 i; i < count; ++i) {
            if (items[i].isGame) {
                h.addGame(items[i].notionalWei);
                uint256 at = filled;
                while (at != 0 && game[at - 1].weight < items[i].weight) {
                    game[at] = game[at - 1];
                    --at;
                }
                game[at] = PricingLib.GameListing({weight: items[i].weight});
                ++filled;
            } else {
                h.add(items[i].backingWei, items[i].notionalWei, 1);
            }
        }

        for (uint256 horizon; horizon < count; ++horizon) {
            uint256 boundWei = h.evPassMaxWithGameListings(horizon, game);
            assertGe(boundWei, _exactSubsetMaximum(items, count, horizon));
        }
    }

    function _addNativeSequenceBoard(uint256[5] memory counts)
        private
        returns (PricingLib.GameListing[] memory game)
    {
        for (uint256 i; i < counts.length; ++i) {
            uint256 backingWei = PricingLib.backingAt(i);
            h.add(backingWei, backingWei, counts[i]);
        }

        uint256[7] memory gameNotionals =
            [uint256(0.05 ether), 0.1 ether, 0.1 ether, 0.5 ether, 0.5 ether, 1 ether, 1 ether];
        game = new PricingLib.GameListing[](gameNotionals.length);
        for (uint256 i; i < gameNotionals.length; ++i) {
            h.addGame(gameNotionals[i]);
            game[i] = PricingLib.GameListing({weight: PricingLib.weightOf(gameNotionals[i])});
        }
    }

    function _exactSubsetMaximum(RemovalItem[8] memory items, uint256 count, uint256 horizon)
        private
        pure
        returns (uint256 resultWei)
    {
        uint256 totalWeight;
        uint256 totalCost;
        for (uint256 i; i < count; ++i) {
            totalWeight += items[i].weight;
            if (!items[i].isGame) totalCost += items[i].backingWei * items[i].weight;
        }
        resultWei = totalCost / totalWeight;

        uint256 subsets = 1 << count;
        for (uint256 mask = 1; mask < subsets; ++mask) {
            if (_popCount(mask) > horizon) continue;
            uint256 removedWeight;
            uint256 removedCost;
            for (uint256 i; i < count; ++i) {
                if ((mask >> i) & 1 == 0) continue;
                removedWeight += items[i].weight;
                if (!items[i].isGame) removedCost += items[i].backingWei * items[i].weight;
            }
            uint256 candidateWei = (totalCost - removedCost) / (totalWeight - removedWeight);
            if (candidateWei > resultWei) resultWei = candidateWei;
        }
    }

    function _popCount(uint256 mask) private pure returns (uint256 count) {
        while (mask != 0) {
            count += mask & 1;
            mask >>= 1;
        }
    }

    // ------------------------------------------------------------------ ticket floor

    /// @dev DEC-189: the edge term is FWA's protocol half (2.5% of a 0.05 ether base).
    function test_theFloorSumsTheEvAndTheProtocolTake() public pure {
        assertEq(PricingLib.ticketFloor(0.05 ether, 0.00125 ether, 0, 0, 1_450), 0.05125 ether);
    }

    /// @dev The rule that changed after the simulator: FWA prices its acquire fee off the harmonic
    ///      mean of the notionals, so inventory listed far above its backing can put the fee above
    ///      the cost terms. Custody forwards that fee out of the ticket, so the floor must cover it.
    function test_theFloorRisesToTheSmallestFloorWhoseTicketCoversTheAcquireFee() public pure {
        uint256 largeFee = 0.2 ether;
        uint256 mintFee = 0.001 ether;
        assertGt(largeFee, 0.05 ether + 0.00125 ether);
        uint256 floorWei = PricingLib.ticketFloor(0.05 ether, 0.00125 ether, largeFee, mintFee, 1_450);
        assertEq(floorWei, ((largeFee + 1 - mintFee) * 8_550 + 9_999) / 10_000);
        assertGt(PricingLib.ticketWithLines(floorWei, 1_450, mintFee), largeFee);
        assertLe(PricingLib.ticketWithLines(floorWei - 1, 1_450, mintFee), largeFee);
    }

    function test_theAcquireFeeDoesNotLowerTheFloor() public pure {
        assertEq(
            PricingLib.ticketFloor(0.05 ether, 0.00125 ether, 0.001 ether, 0.001 ether, 1_450), 0.05125 ether
        );
        // At the standard edge the fee sits under the ticket the floor already produces.
        assertEq(
            PricingLib.ticketFloor(0.05 ether, 0.00125 ether, 0.0525 ether, 0.001 ether, 1_450), 0.05125 ether
        );
    }

    /// @dev The mint and pack component lines sit outside the skim divisor: the ticket is the
    ///      floor grossed up for the skim plus the lines, and the skim shares apply to the
    ///      grossed-up part only.
    function test_theMintLineSitsOutsideTheSkimDivisor() public pure {
        uint256 floorWei = 0.05125 ether;
        uint256 lineWei = 0.001 ether + 0.0004 ether;
        uint256 skimBps = 1_450;
        uint256 ticketWei = PricingLib.ticketWithLines(floorWei, skimBps, lineWei);
        assertEq(ticketWei, PricingLib.ticketFromFloor(floorWei, skimBps) + lineWei);
        assertEq(ticketWei - lineWei, (floorWei * 10_000 + 8_549) / 8_550);
        // A line inside the divisor would cost more by `line * skim / (1 - skim)`.
        assertLt(ticketWei, PricingLib.ticketFromFloor(floorWei + lineWei, skimBps));
        // The skim taken from the grossed-up part leaves the floor intact.
        uint256 baseWei = ticketWei - lineWei;
        assertGe(baseWei - baseWei * skimBps / 10_000, floorWei);
    }

    /// @dev The fee branch binds: the ticket sits one to a few wei above the FWA fee and the waterfall
    ///      still funds every line from the receipt (escrow plus the owner half FWA returns), which is
    ///      the ticket less the protocol take.
    function test_aFeeBoundTicketFundsTheWholeWaterfall() public pure {
        Skim memory skim = Skim({
            maintenanceBps: 150, premiumBps: 200, grailFeedBps: 450, grailMinorShareBps: 5000, reserveBps: 0
        });
        uint256 skimBps = PricingLib.totalSkimBps(skim, 150);
        uint256 evPass = 0.05 ether;
        uint256 feeWei = 0.2 ether;
        uint256 takeWei = (feeWei - 0.19 ether) / 2;
        uint256 lineWei = 0.001 ether;
        uint256 floorWei = PricingLib.ticketFloor(evPass, takeWei, feeWei, lineWei, skimBps);
        assertGt(floorWei, evPass + takeWei, "the fee branch did not bind");
        uint256 ticketWei = PricingLib.ticketWithLines(floorWei, skimBps, lineWei);
        assertGt(ticketWei, feeWei);
        assertLe(ticketWei - feeWei, 3, "the fee-bound ticket is not within rounding of the fee");

        PricingLib.WaterfallOutput memory out = PricingLib.waterfall(
            PricingLib.WaterfallInput({
                ticketWei: ticketWei,
                gameEscrowWei: ticketWei - feeWei,
                ownerAmountWei: feeWei - takeWei,
                evPassWei: evPass,
                mintFeeWei: lineWei,
                operatorBps: 150,
                builderBps: 0,
                skim: skim
            })
        );
        uint256 baseWei = ticketWei - lineWei;
        assertEq(out.shortfall, 0, "the waterfall starved");
        assertEq(out.mintFeeReserve, lineWei);
        assertGe(out.vaultCash, evPass, "vault cash fell under EV_pass");
        assertEq(out.operator, ticketWei * 150 / 10_000);
        assertEq(out.grailFeed, baseWei * 450 / 10_000);
        assertEq(out.maintenance, baseWei * 150 / 10_000);
        assertEq(
            out.vaultCash + out.grailFeed + out.operator + out.maintenance + out.mintFeeReserve,
            ticketWei - takeWei
        );
    }

    function test_theMaintenanceSliceIsTheDefaultPercentOfTheGrossedUpPart() public pure {
        Skim memory skim = Skim({
            maintenanceBps: 150, premiumBps: 200, grailFeedBps: 450, grailMinorShareBps: 5000, reserveBps: 0
        });
        uint256 lineWei = 0.0014 ether;
        uint256 ticketWei =
            PricingLib.ticketWithLines(0.05125 ether, PricingLib.totalSkimBps(skim, 200), lineWei);
        PricingLib.WaterfallOutput memory out = PricingLib.waterfall(
            PricingLib.WaterfallInput({
                ticketWei: ticketWei,
                gameEscrowWei: ticketWei - 0.0525 ether,
                ownerAmountWei: 0.05125 ether,
                evPassWei: 0.05 ether,
                mintFeeWei: lineWei,
                operatorBps: 200,
                builderBps: 0,
                skim: skim
            })
        );
        assertEq(out.maintenance, (ticketWei - lineWei) * 150 / 10_000);
        assertEq(out.mintFeeReserve, lineWei);
        assertEq(out.shortfall, 0);
    }

    function test_theTicketClearsTheFloorOnceTheSkimIsTaken() public pure {
        uint256 floorWei = 0.05 ether;
        uint256 ticketWei = PricingLib.ticketFromFloor(floorWei, 1_450);
        assertEq(ticketWei, (floorWei * 10_000 + 8_549) / 8_550);
        // What is left after the skim still covers the floor.
        assertGe(ticketWei - ticketWei * 1_450 / 10_000, floorWei);
    }

    function test_aFullSkimReverts() public {
        vm.expectRevert(PricingLib.ZeroDivisor.selector);
        h.ticketFromFloor(1 ether, 10_000);
    }

    function test_theTotalSkimAddsTheOperatorSlice() public pure {
        Skim memory skim = Skim({
            maintenanceBps: 50, premiumBps: 600, grailFeedBps: 300, grailMinorShareBps: 5000, reserveBps: 0
        });
        assertEq(PricingLib.totalSkimBps(skim, 200), 1_150);
    }

    function test_theTotalSkimIncludesTheReserveSlice() public pure {
        Skim memory skim = Skim({
            maintenanceBps: 50, premiumBps: 600, grailFeedBps: 300, grailMinorShareBps: 5000, reserveBps: 75
        });
        assertEq(PricingLib.totalSkimBps(skim, 200), 1_225);
    }

    function test_builderIsCarvedFromGrossOperatorAllocation() public pure {
        PricingLib.WaterfallOutput memory out = PricingLib.waterfall(
            PricingLib.WaterfallInput({
                ticketWei: 1 ether,
                gameEscrowWei: 1 ether,
                ownerAmountWei: 0,
                evPassWei: 0,
                mintFeeWei: 0,
                operatorBps: 2_000,
                builderBps: 2_500,
                skim: Skim({
                    maintenanceBps: 0, premiumBps: 0, grailFeedBps: 0, grailMinorShareBps: 5000, reserveBps: 0
                })
            })
        );
        assertEq(out.builder, 0.05 ether);
        assertEq(out.operator, 0.15 ether);
        assertEq(
            PricingLib.totalSkimBps(
                Skim({
                    maintenanceBps: 0, premiumBps: 0, grailFeedBps: 0, grailMinorShareBps: 5000, reserveBps: 0
                }),
                2_000
            ),
            2_000
        );
    }

    // ------------------------------------------------------------------ protocol split

    function test_theProtocolTakesHalfTheEdge() public pure {
        (uint256 protocolAmount, uint256 ownerAmount) = PricingLib.protocolSplit(0.0525 ether, 0.05 ether);
        assertEq(protocolAmount, 0.00125 ether);
        assertEq(ownerAmount, 0.0525 ether - 0.00125 ether);
        assertEq(protocolAmount + ownerAmount, 0.0525 ether);
    }

    // ------------------------------------------------------------------ waterfall

    function test_theWaterfallAllocatesEveryWeiItIsGiven() public pure {
        PricingLib.WaterfallOutput memory out = PricingLib.waterfall(
            PricingLib.WaterfallInput({
                ticketWei: 0.06 ether,
                gameEscrowWei: 0.0075 ether,
                ownerAmountWei: 0.05125 ether,
                evPassWei: 0.05 ether,
                mintFeeWei: 0.001 ether,
                operatorBps: 200,
                builderBps: 0,
                skim: Skim({
                    maintenanceBps: 50,
                    premiumBps: 600,
                    grailFeedBps: 300,
                    grailMinorShareBps: 5000,
                    reserveBps: 0
                })
            })
        );

        uint256 R = 0.0075 ether + 0.05125 ether;
        assertEq(out.vaultCash + out.grailFeed + out.operator + out.maintenance + out.mintFeeReserve, R);
        assertEq(out.operator, 0.06 ether * 200 / 10_000);
        assertEq(out.grailFeed, 0.059 ether * 300 / 10_000);
        assertEq(out.maintenance, 0.059 ether * 50 / 10_000);
        assertEq(out.shortfall, 0);
    }

    function _reserveInput(uint16 reserveBps, uint256 gameEscrowWei)
        private
        pure
        returns (PricingLib.WaterfallInput memory)
    {
        return PricingLib.WaterfallInput({
            ticketWei: 0.06 ether,
            gameEscrowWei: gameEscrowWei,
            ownerAmountWei: 0.05125 ether,
            evPassWei: 0.05 ether,
            mintFeeWei: 0.001 ether,
            operatorBps: 200,
            builderBps: 0,
            skim: Skim({
                maintenanceBps: 50,
                premiumBps: 600,
                grailFeedBps: 300,
                grailMinorShareBps: 5000,
                reserveBps: reserveBps
            })
        });
    }

    /// @dev The reserve line is `reserveBps` of the ticket less its mint line, taken from what vault
    ///      cash would receive.
    function test_theWaterfallCreditsTheReserveLineOutOfVaultCash() public pure {
        PricingLib.WaterfallOutput memory none = PricingLib.waterfall(_reserveInput(0, 0.0075 ether));
        PricingLib.WaterfallOutput memory withReserve = PricingLib.waterfall(_reserveInput(75, 0.0075 ether));

        uint256 reserveWei = 0.059 ether * 75 / 10_000;
        assertEq(none.reserve, 0);
        assertEq(withReserve.reserve, reserveWei);
        assertEq(withReserve.vaultCash, none.vaultCash - reserveWei);
        assertEq(withReserve.operator, none.operator);
        assertEq(withReserve.grailFeed, none.grailFeed);
        assertEq(withReserve.maintenance, none.maintenance);
        assertEq(withReserve.mintFeeReserve, none.mintFeeReserve);
        assertEq(withReserve.shortfall, 0);
        assertEq(
            withReserve.vaultCash + withReserve.grailFeed + withReserve.operator + withReserve.maintenance
                + withReserve.reserve + withReserve.mintFeeReserve,
            0.0075 ether + 0.05125 ether
        );
    }

    /// @dev A receipt that cannot cover every line leaves the reserve line what remains after the
    ///      operator, grail and maintenance lines, and reports the rest as shortfall.
    function test_aShortReceiptCapsTheReserveLine() public pure {
        PricingLib.WaterfallInput memory input = _reserveInput(75, 0);
        input.ownerAmountWei = 0.0035 ether;
        PricingLib.WaterfallOutput memory out = PricingLib.waterfall(input);

        uint256 paidEarlierWei = 0.06 ether * 200 / 10_000 + 0.059 ether * (300 + 50) / 10_000;
        assertEq(out.reserve, 0.0035 ether - paidEarlierWei);
        assertLt(out.reserve, 0.059 ether * 75 / 10_000);
        assertEq(out.vaultCash, 0);
        assertEq(out.mintFeeReserve, 0);
        assertGt(out.shortfall, 0);
    }

    function test_aShortReceiptIsReportedAsShortfallAndNeverOverdrawn() public pure {
        PricingLib.WaterfallOutput memory out = PricingLib.waterfall(
            PricingLib.WaterfallInput({
                ticketWei: 1 ether,
                gameEscrowWei: 0.001 ether,
                ownerAmountWei: 0,
                evPassWei: 0,
                mintFeeWei: 0,
                operatorBps: 200,
                builderBps: 0,
                skim: Skim({
                    maintenanceBps: 50,
                    premiumBps: 600,
                    grailFeedBps: 300,
                    grailMinorShareBps: 5000,
                    reserveBps: 0
                })
            })
        );

        assertEq(
            out.vaultCash + out.grailFeed + out.operator + out.maintenance + out.mintFeeReserve, 0.001 ether
        );
        assertEq(out.vaultCash, 0);
        assertGt(out.shortfall, 0);
    }

    // ------------------------------------------------------------------ operator line (ECON-04)

    /// @dev DEC-189: the operator line is `operatorBps` of the ticket. The owner half of the edge FWA
    ///      returns stays in the receipt and lands in vault cash.
    function test_theOwnerHalfOfTheEdgeReachesVaultCashNotTheOperator() public pure {
        uint256 fee = 0.0525 ether;
        uint256 base = 0.05 ether;
        (, uint256 ownerAmount) = PricingLib.protocolSplit(fee, base);
        assertEq(ownerAmount - base, 0.00125 ether);

        PricingLib.WaterfallOutput memory out = PricingLib.waterfall(
            PricingLib.WaterfallInput({
                ticketWei: 0.06 ether,
                gameEscrowWei: 0.06 ether - fee,
                ownerAmountWei: ownerAmount,
                evPassWei: 0.05 ether,
                mintFeeWei: 0.001 ether,
                operatorBps: 200,
                builderBps: 0,
                skim: Skim({
                    maintenanceBps: 25,
                    premiumBps: 200,
                    grailFeedBps: 450,
                    grailMinorShareBps: 5000,
                    reserveBps: 0
                })
            })
        );
        uint256 receipt = 0.06 ether - fee + ownerAmount;
        assertEq(out.operator, 0.06 ether * 200 / 10_000);
        assertEq(out.builder, 0);
        assertEq(
            out.vaultCash,
            receipt - out.operator - out.grailFeed - out.maintenance - out.mintFeeReserve,
            "the owner half did not reach vault cash"
        );
        assertEq(out.vaultCash + out.grailFeed + out.operator + out.maintenance + out.mintFeeReserve, receipt);
    }

    /// @dev Builder takes 25% of the 2% operator line; the operator receives the remainder.
    function test_builderAndOperatorSplitTheOperatorLine() public pure {
        PricingLib.WaterfallOutput memory out = PricingLib.waterfall(
            PricingLib.WaterfallInput({
                ticketWei: 1 ether,
                gameEscrowWei: 0.5 ether,
                ownerAmountWei: 0.5 ether,
                evPassWei: 0,
                mintFeeWei: 0,
                operatorBps: 200,
                builderBps: 2_500,
                skim: Skim({
                    maintenanceBps: 0, premiumBps: 0, grailFeedBps: 0, grailMinorShareBps: 5000, reserveBps: 0
                })
            })
        );
        assertEq(out.builder, 0.005 ether);
        assertEq(out.operator, 0.015 ether);
        assertEq(out.vaultCash, 0.98 ether);
    }

    // ------------------------------------------------------------------ share math

    function test_sharesAndAssetsRoundTripAtTheSameNav() public pure {
        uint256 nav = 100 ether;
        uint256 total = 100_000;
        uint256 shares = PricingLib.sharesForAssets(10 ether, nav, total);
        uint256 assets = PricingLib.assetsForShares(shares, nav + 10 ether, total + shares);
        assertLe(assets, 10 ether);
        assertApproxEqRel(assets, 10 ether, 1e15);
    }

    function test_bothDirectionsRoundDown() public pure {
        // A deposit never mints more than its NAV share, and a redemption never pays more.
        assertLe(
            PricingLib.sharesForAssets(3, 7, 11) * (7 + PricingLib.VIRTUAL_ASSETS),
            3 * (11 + PricingLib.VIRTUAL_SHARES)
        );
        assertLe(
            PricingLib.assetsForShares(3, 7, 11) * (11 + PricingLib.VIRTUAL_SHARES),
            3 * (7 + PricingLib.VIRTUAL_ASSETS)
        );
    }

    function testFuzz_aRedemptionNeverPaysMoreThanTheNavClaim(
        uint96 navWei,
        uint96 totalShares,
        uint96 shares
    ) public pure {
        vm.assume(shares <= totalShares);
        uint256 assets = PricingLib.assetsForShares(shares, navWei, totalShares);
        assertLe(assets, navWei);
    }
}
