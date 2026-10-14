// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IShapePacks} from "draw-packs/interfaces/IShapePacks.sol";
import {Pool} from "../../src/Pool.sol";
import {Lens} from "../../src/Lens.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice Replacement row sampling, `settle` listing, the cash reserve and held-first filling
///         against deployed Shapes, a Draw Packs deployment and a FWA clone created by the pool.
/// @dev Mix (launch table): row 0 is a 0.01 Shape (3,800 bps), row 1 a 0.02 pack of two 0.01
///      Shapes (2,800), row 2 a 0.03 pack of three (1,900), row 3 a 0.05 Shape (1,000), row 4 a
///      0.1 Shape (400), row 5 a 0.5 Shape (100). `minItems` is 100, so the targets are 38, 28,
///      19, 10, 4 and 1 items. The factory's `inventoryChangeCooldown` is 300 on the fork; tests
///      that need `settle` to list set it to 0 with `_setCooldown`.
contract PoolReplaceForkTest is ForkBase, PoolFixture {
    uint256 internal constant BPS = 10_000;

    PoolHarness internal pool;
    IFWAClone internal clone;
    address internal player = makeAddr("player");
    address internal keeper = makeAddr("keeper");
    uint256 internal mintFee;

    function setUp() public {
        setUpFork();
        openFactory();
        deployDrawPacks(admin);
        mintFee = shapes.mintFee();
        vm.deal(alice, 10_000 ether);
        _create(100);
    }

    // ---------------------------------------------------------------- helpers

    function _launchMix() internal pure returns (PricingLib.MixRow[] memory rows) {
        uint8[6][6] memory rungs = [
            [uint8(0), 0, 0, 0, 0, 0],
            [uint8(0), 0, 0, 0, 0, 0],
            [uint8(0), 0, 0, 0, 0, 0],
            [uint8(1), 0, 0, 0, 0, 0],
            [uint8(2), 0, 0, 0, 0, 0],
            [uint8(3), 0, 0, 0, 0, 0]
        ];
        uint8[6] memory lengths = [1, 2, 3, 1, 1, 1];
        uint16[6] memory shares = [3_800, 2_800, 1_900, 1_000, 400, 100];
        rows = new PricingLib.MixRow[](6);
        for (uint256 i; i < 6; ++i) {
            rows[i].rungs = new uint8[](lengths[i]);
            for (uint256 j; j < lengths[i]; ++j) {
                rows[i].rungs[j] = rungs[i][j];
            }
            rows[i].shareBps = shares[i];
        }
    }

    function _params(uint256 minItems_) internal returns (IPoolTypes.Params memory p) {
        p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.mix = _launchMix();
        p.batchMin = 5;
        p.minItems = minItems_;
        p.rotateInterval = 900;
        p.minor.stepWei = 500 ether;
        p.minor.targetWei = 1_000 ether;
        p.major.stepWei = 500 ether;
        p.major.targetWei = 1_000 ether;
    }

    /// @dev Deploys a pool with `minItems_`, funds it with 100 ETH and builds its board.
    function _create(uint256 minItems_) internal {
        pool = new PoolHarness(_params(minItems_));
        vm.prank(admin);
        IPool(address(pool)).createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
        assertEq(pool.listedCount(), _target(minItems_), "board");
        warpPastCooldown(clone);
    }

    function _target(uint256 minItems_) internal view returns (uint256 total) {
        for (uint256 i; i < IPool(address(pool)).mixLength(); ++i) {
            (, uint16 share) = IPool(address(pool)).mixRow(i);
            total += PricingLib.rowDepth(minItems_, share);
        }
    }

    function _setCooldown(uint32 seconds_) internal {
        vm.prank(factory.owner());
        factory.setInventoryChangeCooldown(seconds_);
    }

    function _admin() internal returns (IPool) {
        vm.prank(admin);
        return IPool(address(pool));
    }

    function _fundMaintenance() internal {
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
    }

    /// @dev One pooled acquisition fulfilled on the last listed item of `row`. Returns the request id.
    function _captureRow(uint256 row) internal returns (uint256 requestId) {
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        uint256[] memory listed = pool.listedIds(row);
        fulfill(clone, ids[0], wordFor(clone, listed[listed.length - 1]));
        requestId = ids[0];
    }

    function _settle() internal returns (uint256 listed, uint256 refund) {
        vm.recordLogs();
        vm.prank(keeper);
        pool.settle(20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.Settled.selector) {
                (listed, refund) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    function _due() internal view returns (IPoolTypes.SettleTrigger) {
        return pool.settleDue();
    }

    function _rows() internal view returns (PricingLib.RowState[] memory rows) {
        uint256 n = IPool(address(pool)).mixLength();
        rows = new PricingLib.RowState[](n);
        for (uint256 i; i < n; ++i) {
            (uint8[] memory rungs, uint16 share) = IPool(address(pool)).mixRow(i);
            uint256 backingWei;
            for (uint256 j; j < rungs.length; ++j) {
                backingWei += _rungAmount(rungs[j]);
            }
            rows[i] = PricingLib.RowState(
                share,
                IPool(address(pool)).rowCount(i) + pool.queuedOf(i),
                (pool.minItems() * share + BPS - 1) / BPS,
                backingWei,
                rungs.length == 1
            );
        }
    }

    function _rungAmount(uint8 rung) internal pure returns (uint256) {
        if (rung == 0) return 0.01 ether;
        if (rung == 1) return 0.05 ether;
        if (rung == 2) return 0.1 ether;
        return 0.5 ether;
    }

    // ---------------------------------------------------------------- reference for the sampling rule

    /// @dev The four steps of the sampling rule, written out directly.
    function _reference(
        bytes32 h,
        PricingLib.RowState[] memory rows,
        uint256 k,
        uint256 surpriseBps_,
        uint256 bandBps_,
        uint256 fallbackRow
    ) internal pure returns (uint256 row, bool surprise) {
        uint256 n = rows.length;
        uint256[] memory w = new uint256[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            uint256 factor = BPS;
            if (rows[i].target > rows[i].count) {
                factor += k * (rows[i].target - rows[i].count) * BPS / rows[i].target;
            }
            w[i] = rows[i].shareBps * factor / BPS;
            total += w[i];
        }
        if (total == 0) return (fallbackRow, false);

        uint256 pick = uint256(h) % total;
        uint256 drawn;
        uint256 acc;
        for (uint256 i; i < n; ++i) {
            acc += w[i];
            if (pick < acc) {
                drawn = i;
                break;
            }
        }
        row = drawn;

        if ((uint256(h) >> 64) % BPS < surpriseBps_) {
            uint256[3] memory chosen;
            uint256 m;
            for (; m < 3; ++m) {
                uint256 best = type(uint256).max;
                for (uint256 i; i < n; ++i) {
                    if (!rows[i].single || rows[i].backingWei < 5 * rows[drawn].backingWei) continue;
                    bool taken;
                    for (uint256 t; t < m; ++t) {
                        if (chosen[t] == i) taken = true;
                    }
                    if (taken) continue;
                    if (
                        best == type(uint256).max || rows[i].backingWei < rows[best].backingWei
                            || (rows[i].backingWei == rows[best].backingWei && i < best)
                    ) best = i;
                }
                if (best == type(uint256).max) break;
                chosen[m] = best;
            }
            if (m != 0) {
                uint256[3] memory weights = [uint256(60), 30, 10];
                uint256 sum;
                for (uint256 j; j < m; ++j) {
                    sum += weights[j];
                }
                uint256 x = ((uint256(h) >> 128) % 100) * sum / 100;
                uint256 cumulative;
                for (uint256 j; j < m; ++j) {
                    cumulative += weights[j];
                    if (x < cumulative) {
                        row = chosen[j];
                        surprise = true;
                        break;
                    }
                }
            }
        }

        uint256 cap = (rows[row].target * (BPS + bandBps_) + BPS - 1) / BPS;
        if (cap < rows[row].target + 1) cap = rows[row].target + 1;
        if (rows[row].count >= cap) {
            uint256 bestRow = type(uint256).max;
            uint256 bestDeficit;
            for (uint256 i; i < n; ++i) {
                uint256 deficit = rows[i].target > rows[i].count ? rows[i].target - rows[i].count : 0;
                if (deficit > bestDeficit) {
                    bestDeficit = deficit;
                    bestRow = i;
                }
            }
            row = bestRow == type(uint256).max ? drawn : bestRow;
            surprise = false;
        }
    }

    /// @dev Compares the pool's choice for 150 words with the reference under the current state.
    function _assertMatchesReference(uint256 capturedRow) internal view returns (uint256[6] memory hits) {
        PricingLib.RowState[] memory rows = _rows();
        IPool p = IPool(address(pool));
        for (uint256 i; i < 150; ++i) {
            uint256 word = uint256(keccak256(abi.encode("word", i)));
            uint256 requestId = 1_000 + i;
            (uint256 row, bool surprise) = pool.chooseRow(word, requestId, capturedRow);
            (uint256 expected, bool expectedSurprise) = _reference(
                keccak256(abi.encode(word, requestId)), rows, p.restoreK(), p.surpriseBps(), p.bandBps(), capturedRow
            );
            assertEq(row, expected, "row");
            assertEq(surprise, expectedSurprise, "surprise");
            ++hits[row];
        }
    }

    // ---------------------------------------------------------------- the sampling rule

    function test_chooseRowOnAFullBoardDrawsByShare() public view {
        // surpriseBps 200: most draws are step 1 draws by share.
        PricingLib.RowState[] memory rows = _rows();
        for (uint256 i; i < rows.length; ++i) {
            assertEq(rows[i].count, rows[i].target, "board at target");
        }
        uint256[6] memory hits = _assertMatchesReference(0);
        assertGt(hits[0], hits[3], "the 3,800 bps row is drawn more often than the 1,000 bps row");
        assertGt(hits[1], hits[4]);
    }

    function test_chooseRowWeightsRowsBelowTargetByTheirDeficit() public {
        // Remove all four 0.1 Shapes: weight 400 * (1 + 8) = 3,600 against 400 at target.
        uint256[] memory listed = pool.listedIds(4);
        assertEq(listed.length, 4);
        for (uint256 i; i < listed.length; ++i) {
            pool.removeListed(listed[i]);
        }
        _admin().setReplacement(0, 8, 3_000);
        uint256[6] memory hits = _assertMatchesReference(0);
        // Weights: 3800, 2800, 1900, 1000, 3600, 100 out of 13,200.
        assertGt(hits[4], hits[2], "the empty 0.1 row outdraws the 0.03 pack row");
        assertGt(hits[4], hits[3]);
    }

    function test_chooseRowSurpriseUpgradesToASingleRowOfAtLeastFiveTimesTheBacking() public {
        _admin().setReplacement(10_000, 8, 100_000);
        uint256[6] memory hits = _assertMatchesReference(0);
        // Every draw takes the surprise step. Rows 0, 1 and 2 (0.01, 0.02, 0.03) upgrade to the
        // single rows at five times their backing or more, and rows 3, 4 and 5 can only reach
        // row 5 or stay, so the result is always a single row of 0.05 ETH or more.
        assertEq(hits[0] + hits[1] + hits[2], 0);
        assertGt(hits[3], 0);
        assertGt(hits[4], 0);
        assertGt(hits[5], 0);
    }

    function test_chooseRowSurpriseWeighsTheThreeSmallestCandidatesSixtyThirtyTen() public {
        // Row 0 (0.01) holds 90 percent of the draws. Its candidates are rows 3, 4 and 5
        // (0.05, 0.1, 0.5). The band is wide so no candidate sits at its cap.
        PricingLib.MixRow[] memory rows = _launchMix();
        for (uint256 i; i < rows.length; ++i) {
            rows[i].shareBps = i == 0 ? 9_000 : 200;
        }
        IPool p = _admin();
        p.setMix(rows);
        _admin().setReplacement(10_000, 0, 100_000);
        uint256[6] memory hits = _assertMatchesReference(0);
        assertGt(hits[3], hits[4], "60 against 30");
        assertGt(hits[4], hits[5], "30 against 10");
        assertGt(hits[5], 0);
    }

    function test_chooseRowSurpriseNeedsACandidate() public {
        // restoreK 0 draws by share. A drawn 0.5 row (row 5) has no single row at 2.5 ETH or
        // more, so its draw stands without the surprise flag.
        _admin().setReplacement(10_000, 0, 100_000);
        PricingLib.RowState[] memory rows = _rows();
        uint256 stood;
        for (uint256 i; i < 600; ++i) {
            (uint256 row, bool surprise) = pool.chooseRow(i, 7, 0);
            (uint256 expected, bool expectedSurprise) =
                _reference(keccak256(abi.encode(i, uint256(7))), rows, 0, 10_000, 100_000, 0);
            assertEq(row, expected);
            assertEq(surprise, expectedSurprise);
            if (row == 5 && !surprise) ++stood;
        }
        assertGt(stood, 0, "a 0.5 draw stands without the surprise flag");
    }

    function test_chooseRowBandReplacesARowAtItsCapWithTheLargestDeficitRow() public {
        // Row 0 (target 38, cap 50) gets 60 queued replacements and the 0.5 row loses its Shape.
        for (uint256 i; i < 60; ++i) {
            pool.pushReplacement(0);
        }
        pool.removeListed(pool.listedIds(5)[0]);
        _admin().setReplacement(0, 8, 3_000);
        uint256[6] memory hits = _assertMatchesReference(0);
        assertEq(hits[0], 0, "row 0 is over its cap and never chosen");
        assertGt(hits[5], 0, "the largest deficit row takes its draws");
    }

    function test_chooseRowKeepsTheDrawnRowWhenEveryRowIsAtOrAboveTarget() public {
        for (uint256 i; i < 60; ++i) {
            pool.pushReplacement(0);
        }
        _admin().setReplacement(0, 8, 3_000);
        uint256[6] memory hits = _assertMatchesReference(0);
        assertGt(hits[0], 0, "no row has a deficit, so the draw stands");
    }

    function test_chooseRowCapIsAtLeastTargetPlusOne() public {
        // bandBps 0: the cap of the 1 item 0.5 row is 2. One missing 0.05 Shape is the largest deficit.
        _admin().setReplacement(0, 8, 0);
        pool.removeListed(pool.listedIds(3)[0]);
        uint256[6] memory hits = _assertMatchesReference(0);
        assertGt(hits[5], 0, "count 1 is below the cap of 2, so the row is still chosen");

        pool.pushReplacement(5);
        hits = _assertMatchesReference(0);
        assertEq(hits[5], 0, "count 2 reaches the cap, so the draw moves to the deficit row");
        assertGt(hits[3], 0);
    }

    function test_chooseRowReturnsTheCapturedRowWhenEveryShareIsZero() public {
        PricingLib.MixRow[] memory rows = _launchMix();
        for (uint256 i; i < rows.length; ++i) {
            rows[i].shareBps = 0;
        }
        // A zero share row keeps its items, so setMix accepts the table.
        _admin().setMix(rows);
        (uint256 row, bool surprise) = pool.chooseRow(123, 1, 3);
        assertEq(row, 3);
        assertFalse(surprise);
    }

    function testFuzz_chooseRowMatchesTheReference(uint256 word, uint256 requestId, uint8 capturedRow) public view {
        uint256 captured = capturedRow % 6;
        PricingLib.RowState[] memory rows = _rows();
        IPool p = IPool(address(pool));
        (uint256 row, bool surprise) = pool.chooseRow(word, requestId, captured);
        (uint256 expected, bool expectedSurprise) = _reference(
            keccak256(abi.encode(word, requestId)), rows, p.restoreK(), p.surpriseBps(), p.bandBps(), captured
        );
        assertEq(row, expected);
        assertEq(surprise, expectedSurprise);
    }

    // ---------------------------------------------------------------- the rule on real captures

    function test_aCaptureQueuesTheRowTheRuleChoosesFromTheRealRandomWord() public {
        _setCooldown(0);
        uint256 capturedRow = 3;
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        uint256[] memory listed = pool.listedIds(capturedRow);
        fulfill(clone, ids[0], wordFor(clone, listed[listed.length - 1]));
        (,,,,, uint256 word) = clone.acquisitionMeta(ids[0]);

        // At booking the captured item has left its row.
        PricingLib.RowState[] memory rows = _rows();
        --rows[capturedRow].count;
        IPool p = IPool(address(pool));
        (uint256 expected, bool expectedSurprise) = _reference(
            keccak256(abi.encode(word, ids[0])), rows, p.restoreK(), p.surpriseBps(), p.bandBps(), capturedRow
        );

        vm.recordLogs();
        pool.bookOnly(20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.ReplacementChosen.selector) {
                found = true;
                assertEq(uint256(logs[i].topics[1]), ids[0], "request id");
                (uint256 capturedLogged, uint256 chosenLogged, bool surpriseLogged) =
                    abi.decode(logs[i].data, (uint256, uint256, bool));
                assertEq(capturedLogged, capturedRow);
                assertEq(chosenLogged, expected);
                assertEq(surpriseLogged, expectedSurprise);
            }
        }
        assertTrue(found, "ReplacementChosen");
        assertEq(pool.replacementLength(), 1);
        assertEq(uint256(IPool(address(pool)).replacementQueue(pool.replacementHead())), expected);
        assertEq(pool.queuedOf(expected), 1);
    }

    function test_aSurpriseCaptureQueuesALargerSingleRow() public {
        _setCooldown(0);
        _admin().setReplacement(10_000, 8, 100_000);
        uint256 requestId = _captureRow(0);
        vm.recordLogs();
        pool.bookOnly(20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.ReplacementChosen.selector) {
                assertEq(uint256(logs[i].topics[1]), requestId);
                (, uint256 chosen, bool surprise) = abi.decode(logs[i].data, (uint256, uint256, bool));
                assertTrue(surprise, "surprise");
                assertTrue(chosen >= 3, "row 3, 4 or 5");
            }
        }
    }

    function test_aCapturedPointOneRowIsRestoredWithinFortyCaptures() public {
        _setCooldown(0);
        // Capture a 0.1 Shape, then capture 0.01 Shapes until the 0.1 row is back at its target.
        _captureRow(4);
        _settle();
        assertEq(IPool(address(pool)).rowCount(4), 3, "0.1 row below target");
        uint256 captures;
        while (IPool(address(pool)).rowCount(4) + pool.queuedOf(4) < 4 && captures < 40) {
            _captureRow(0);
            ++captures;
            _settle();
        }
        assertLt(captures, 40, "restored inside forty captures");
        assertEq(IPool(address(pool)).rowCount(4) + pool.queuedOf(4), 4);
    }

    // ---------------------------------------------------------------- settle triggers

    function test_settleDueIsNoneOnAFullBoardWithAnEmptyQueue() public {
        _setCooldown(0);
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.None));
    }

    function test_batchTriggerListsFiveReplacementsAndRefundsTheCaller() public {
        _setCooldown(0);
        _fundMaintenance();
        for (uint256 i; i < 4; ++i) {
            _captureRow(0);
        }
        pool.bookOnly(20);
        assertEq(pool.replacementLength(), 4);
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.None), "four are queued");
        _captureRow(0);
        pool.bookOnly(20);
        assertEq(pool.replacementLength(), 5);
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.Batch));

        pool.harvest();
        uint256 maintenanceBefore = pool.maintenance();
        uint256 listedBefore = pool.listedCount();
        (uint256 listed, uint256 refund) = _settle();

        assertEq(listed, 5);
        assertEq(pool.listedCount(), listedBefore + 5);
        assertEq(pool.replacementLength(), 0);
        assertEq(IPool(address(pool)).oldestQueuedAt(), 0, "cleared when the queue empties");
        assertGe(refund, IPool(address(pool)).tipWei(), "refund covers the tip");
        assertEq(keeper.balance, refund);
        assertEq(maintenanceBefore - pool.maintenance(), refund, "paid from maintenance");
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.None));
    }

    function test_ageTriggerListsAReplacementOnceTheQueueIsOldEnough() public {
        _setCooldown(0);
        _fundMaintenance();
        _captureRow(0);
        pool.bookOnly(20);
        assertEq(pool.replacementLength(), 1);
        uint256 queuedAt = IPool(address(pool)).oldestQueuedAt();
        assertEq(queuedAt, block.timestamp, "set when the queue becomes nonempty");
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.None));

        vm.warp(queuedAt + IPool(address(pool)).batchMaxAge() - 1);
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.None));
        vm.warp(queuedAt + IPool(address(pool)).batchMaxAge());
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.Age));

        (uint256 listed, uint256 refund) = _settle();
        assertEq(listed, 1);
        assertGt(refund, 0);
        assertEq(keeper.balance, refund);
        assertEq(pool.replacementLength(), 0);
    }

    function test_thinTriggerListsWhenTheBoardIsWithinFiveOfTheConcurrencyGuard() public {
        _setCooldown(0);
        _create(10);
        _fundMaintenance();
        uint256 concurrency = IPool(address(pool)).concurrency();
        assertLt(pool.listedCount(), concurrency + 5, "thin board");
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.None), "nothing to list");

        pool.pushReplacement(0);
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.Thin));
        (uint256 listed, uint256 refund) = _settle();
        assertEq(listed, 1);
        assertGt(refund, 0);
        assertEq(keeper.balance, refund);
    }

    function test_aSettleThatIsNotDueListsNothingAndRefundsNothing() public {
        _setCooldown(0);
        _fundMaintenance();
        _captureRow(0);
        pool.bookOnly(20);
        assertEq(pool.replacementLength(), 1);
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.None));
        uint256 maintenanceBefore = pool.maintenance();
        uint256 listedBefore = pool.listedCount();

        (uint256 listed, uint256 refund) = _settle();

        assertEq(listed, 0);
        assertEq(refund, 0);
        assertEq(keeper.balance, 0);
        assertEq(pool.listedCount(), listedBefore);
        assertEq(pool.replacementLength(), 1, "the replacement stays queued");
        assertGe(pool.maintenance(), maintenanceBefore, "only a harvest changes maintenance");
    }

    function test_settleListsAtMostTwentyFivePerCall() public {
        _setCooldown(0);
        _fundMaintenance();
        for (uint256 i; i < 30; ++i) {
            pool.pushReplacement(0);
        }
        assertEq(pool.replacementLength(), 30);
        uint256 listedBefore = pool.listedCount();

        (uint256 listed,) = _settle();
        assertEq(listed, 25, "MAX_LIST_PER_SETTLE");
        assertEq(pool.listedCount(), listedBefore + 25);
        assertEq(pool.replacementLength(), 5);
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.Batch), "five queued meets this fixture's batchMin");

        (listed,) = _settle();
        assertEq(listed, 5);
        assertEq(pool.replacementLength(), 0);
    }

    function test_batchTriggerAtTwentyListsAllTwentyInOneSettle() public {
        _setCooldown(0);
        _fundMaintenance();
        _admin().setBatch(20, 1 hours);
        for (uint256 i; i < 19; ++i) {
            pool.pushReplacement(0);
        }
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.None), "19 queued");
        pool.pushReplacement(0);
        assertEq(pool.replacementLength(), 20);
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.Batch), "20 queued");
        uint256 listedBefore = pool.listedCount();

        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        pool.settle(20);
        emit log_named_uint("gas of settle listing 20", gasBefore - gasleft());
        uint256 listed = pool.listedCount() - listedBefore;
        uint256 refund = keeper.balance;

        assertEq(listed, 20, "one due settle lists the whole batch");
        assertEq(pool.listedCount(), listedBefore + 20);
        assertEq(pool.replacementLength(), 0);
        assertGe(refund, IPool(address(pool)).tipWei());
        assertEq(keeper.balance, refund);
    }

    function test_theTipSetterChangesTheSettleRefund() public {
        _setCooldown(0);
        _fundMaintenance();
        _admin().setBatch(1, 1 hours);
        pool.pushReplacement(0);
        (, uint256 refundDefault) = _settle();
        assertGe(refundDefault, 0.0002 ether);

        _admin().setTip(0.005 ether);
        pool.pushReplacement(0);
        (, uint256 refundRaised) = _settle();
        assertGe(refundRaised, 0.005 ether, "the refund carries the new tip");
        assertGt(refundRaised, refundDefault + 0.004 ether);

        _admin().setTip(0);
        pool.pushReplacement(0);
        (, uint256 refundZero) = _settle();
        assertLt(refundZero, refundDefault, "no tip leaves the gas cost alone");
    }

    function test_listBatchAndOpenBoardAreClosedToOutsiders() public {
        vm.prank(keeper);
        vm.expectRevert(IPoolTypes.NotSelf.selector);
        IPool(address(pool)).listBatch(25);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.NotSelf.selector);
        IPool(address(pool)).openBoard();
        address listing = pool.listingModule();
        vm.expectRevert(IPoolTypes.NotDelegated.selector);
        IPool(listing).listBatch(25);
    }

    // ---------------------------------------------------------------- the cash reserve

    function test_theReserveKeepsASettleFromMintingAndTheRowStaysQueued() public {
        _setCooldown(0);
        for (uint256 i; i < 5; ++i) {
            _captureRow(3);
        }
        pool.bookOnly(20);
        assertEq(pool.replacementLength(), 5);

        // A reserve of all of NAV leaves no cash to spend.
        _admin().setReserve(10_000);
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.None), "nothing can be funded");
        pool.harvest();
        uint256 cashBefore = pool.cash();
        (uint256 listed, uint256 refund) = _settle();
        assertEq(listed, 0);
        assertEq(refund, 0);
        assertEq(pool.cash(), cashBefore, "no mint");
        assertEq(pool.replacementLength(), 5, "the rows stay queued");

        _admin().setReserve(1_000);
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.Batch));
    }

    function test_aMintNeedsCashAboveClaimsAndTheReserveForItsFullCost() public {
        _setCooldown(0);
        _admin().setReserve(0);
        _admin().setBatch(1, 1 hours);
        pool.pushReplacement(3);
        uint256 cost = 0.05 ether + mintFee;
        pool.loseCash(pool.cash() - (cost - 1));
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.None), "one wei short");
        (uint256 listed,) = _settle();
        assertEq(listed, 0);

        pool.bookProceeds{value: 1}();
        assertEq(pool.cash(), cost);
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.Batch));
        (listed,) = _settle();
        assertEq(listed, 1);
        assertEq(pool.cash(), 0);
    }

    // ---------------------------------------------------------------- the cooldown guard

    function test_aNonzeroFactoryCooldownKeepsSettleFromListingAndRotateListsTheBatch() public {
        assertEq(factory.inventoryChangeCooldown(), 300);
        _fundMaintenance();
        for (uint256 i; i < 5; ++i) {
            _captureRow(0);
            vm.warp(clone.purchasesResumeAt() + 1);
        }
        pool.bookOnly(20);
        assertEq(uint8(_due()), uint8(IPoolTypes.SettleTrigger.Batch));
        uint256 listedBefore = pool.listedCount();

        (uint256 listed, uint256 refund) = _settle();
        assertEq(listed, 0, "settle does not list");
        assertEq(refund, 0);
        assertEq(pool.listedCount(), listedBefore);
        assertEq(pool.replacementLength(), 5);

        vm.warp(pool.lastRotateAt() + pool.rotateInterval());
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.Held));
        vm.prank(keeper);
        pool.rotate();
        assertEq(pool.listedCount(), listedBefore + 5, "rotate lists the batch");
        assertEq(pool.replacementLength(), 0);
        assertGt(keeper.balance, 0, "rotate refunds");
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None));
    }

    function test_listWhilePausedLetsSettleListUnderACooldown() public {
        assertEq(factory.inventoryChangeCooldown(), 300);
        _fundMaintenance();
        _admin().setListWhilePaused(true);
        for (uint256 i; i < 5; ++i) {
            _captureRow(0);
            vm.warp(clone.purchasesResumeAt() + 1);
        }
        pool.bookOnly(20);
        (uint256 listed, uint256 refund) = _settle();
        assertEq(listed, 5);
        assertGt(refund, 0);
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None));
    }

    // ---------------------------------------------------------------- held Shapes fill first

    function _approveAll(address who) internal {
        vm.prank(who);
        IERC721(SHAPES_ADDR).setApprovalForAll(address(pool), true);
    }

    function _pullWithShape(uint256 tokenId) internal returns (uint256 total) {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        return _pullWithShapes(tokenIds, 0.01 ether * tokenIds.length);
    }

    function _pullWithShapes(uint256[] memory tokenIds, uint256 covered) internal returns (uint256 total) {
        uint256 fee;
        (fee,, total) = clone.quoteAcquisitionPrice(1);
        uint256 topUp = total > covered ? total - covered : 0;
        vm.deal(player, player.balance + topUp);
        vm.prank(player);
        pool.pullWithShapes{value: topUp}(tokenIds, 1, fee, block.timestamp + 1 hours);
    }

    function test_pullWithShapesKeepsTheShapeAndTheNextReplacementListsItWithoutAMintFee() public {
        _setCooldown(0);
        uint256 id = mintShapes(player, 0.01 ether, 1);
        _approveAll(player);
        uint256 backingBefore = pool.backing();
        uint256 cashBefore = pool.cash();
        uint256 navBefore = pool.nav();

        uint256 total = _pullWithShape(id);

        assertEq(shapes.ownerOf(id), address(pool), "kept");
        assertEq(pool.heldCount(), 1);
        uint256[] memory heldIds = IPool(address(pool)).heldShapes(0);
        assertEq(heldIds.length, 1);
        assertEq(heldIds[0], id);
        assertEq(pool.backing(), backingBefore + 0.01 ether, "held at its backing");
        assertEq(pool.cash(), cashBefore - 0.01 ether, "FWA is paid from cash for what the Shape covers");
        assertEq(pool.nav(), navBefore, "nav unchanged");
        assertEq(IPool(address(pool)).rowCount(0), 39);
        assertGt(total, 0);

        // The next 0.01 replacement lists the held Shape. Nothing is minted.
        pool.pushReplacement(0);
        _admin().setBatch(1, 1 hours);
        uint256 cashBeforeSettle = pool.cash();
        (uint256 listed,) = _settle();
        assertEq(listed, 1);
        assertEq(pool.cash(), cashBeforeSettle, "no mint fee");
        assertEq(pool.heldCount(), 0);
        assertEq(IPool(address(pool)).heldShapes(0).length, 0);
        IPoolTypes.Item memory it = pool.listedItem(clone.nextListingId() - 1);
        assertEq(it.tokenId, id, "the held Shape is listed");
        assertEq(it.row, 0);
        assertEq(pool.backing(), backingBefore + 0.01 ether);
    }

    function test_aPackRowBuiltFromTwoHeldShapesMintsNothing() public {
        _setCooldown(0);
        uint256 first = mintShapes(player, 0.01 ether, 2);
        _approveAll(player);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = first;
        tokenIds[1] = first + 1;
        _pullWithShapes(tokenIds, 0.02 ether);
        assertEq(pool.heldCount(), 2);
        assertEq(IPool(address(pool)).heldShapes(0).length, 2);

        pool.pushReplacement(1);
        _admin().setBatch(1, 1 hours);
        uint256 cashBefore = pool.cash();
        uint256 backingBefore = pool.backing();
        (uint256 listed,) = _settle();

        assertEq(listed, 1);
        assertEq(pool.cash(), cashBefore, "no Shape minted, no fee");
        assertEq(pool.backing(), backingBefore, "the pack carries the held Shapes' backing");
        assertEq(pool.heldCount(), 0);
        IPoolTypes.Item memory it = pool.listedItem(clone.nextListingId() - 1);
        assertEq(it.collection, address(drawPacks));
        assertEq(it.row, 1);
        assertEq(IShapePacks(address(drawPacks)).valueOf(it.tokenId), 0.02 ether);
        assertEq(shapes.ownerOf(first), address(drawPacks), "the Shapes sit in the pack");
    }

    function test_aPackRowTakesOneHeldShapeAndMintsTheOtherRung() public {
        _setCooldown(0);
        uint256 id = mintShapes(player, 0.01 ether, 1);
        _approveAll(player);
        _pullWithShape(id);

        pool.pushReplacement(1);
        _admin().setBatch(1, 1 hours);
        uint256 cashBefore = pool.cash();
        (uint256 listed,) = _settle();

        assertEq(listed, 1);
        assertEq(cashBefore - pool.cash(), 0.01 ether + mintFee, "one rung minted");
        assertEq(pool.heldCount(), 0);
        assertEq(shapes.ownerOf(id), address(drawPacks));
    }

    function test_aHeldPackEqualToTheRowBackingIsListedDirectly() public {
        _setCooldown(0);
        // A pack of two 0.01 Shapes created by the pool and held unlisted.
        uint32[] memory counts = new uint32[](9);
        counts[0] = 2;
        uint256 value = 0.02 ether + 2 * mintFee;
        vm.deal(address(pool), address(pool).balance + value);
        vm.prank(address(pool));
        uint256 packId = drawPacks.createPack{value: value}(new uint256[](0), counts);
        pool.addItem(address(drawPacks), 1, packId, 0.02 ether, 0);
        assertEq(pool.heldCount(), 1);

        pool.pushReplacement(1);
        _admin().setBatch(1, 1 hours);
        uint256 cashBefore = pool.cash();
        (uint256 listed,) = _settle();

        assertEq(listed, 1);
        assertEq(pool.cash(), cashBefore, "no mint");
        assertEq(pool.heldCount(), 0);
        assertEq(pool.listedItem(clone.nextListingId() - 1).tokenId, packId, "the held pack is listed");
    }

    function test_redeemAndDepositKeepsTheShapeAndTakesTheContributionFromCash() public {
        uint256 id = mintShapes(player, 0.01 ether, 1);
        vm.prank(player);
        IERC721(SHAPES_ADDR).approve(address(pool), id);

        uint256 navBefore = pool.nav();
        uint256 supplyBefore = pool.totalShares();
        uint256 cashBefore = pool.cash();
        uint256 balanceBefore = address(pool).balance;
        uint256 contribution = pool.contributionFor(0.01 ether, navBefore);
        uint256 expectedShares = PricingLib.sharesFor(0.01 ether - contribution, navBefore, supplyBefore);

        vm.prank(player);
        pool.redeemAndDeposit(id);

        assertEq(shapes.ownerOf(id), address(pool), "kept");
        assertEq(pool.heldCount(), 1);
        assertEq(pool.sharesOf(player), expectedShares);
        assertEq(pool.cash(), cashBefore - contribution, "the contribution leaves cash");
        assertEq(address(pool).balance, balanceBefore, "no ETH moved");
        assertEq(pool.nav(), navBefore + 0.01 ether - contribution);
        assertEq(IPool(address(pool)).heldShapes(0)[0], id);
    }

    function test_pullWithShapesRedeemsWhenCashAboveTheReserveCannotCoverTheShape() public {
        uint256 id = mintShapes(player, 0.01 ether, 1);
        _approveAll(player);
        pool.loseCash(pool.cash() - 0.005 ether);
        uint256 backingBefore = pool.backing();
        uint256 cashBefore = pool.cash();

        _pullWithShape(id);

        assertEq(pool.heldCount(), 0, "redeemed");
        vm.expectRevert();
        shapes.ownerOf(id);
        assertEq(pool.backing(), backingBefore);
        assertEq(pool.cash(), cashBefore, "no bucket moved");
    }

    function test_redeemAndDepositRedeemsWhenCashAboveTheReserveCannotCoverTheShape() public {
        uint256 id = mintShapes(player, 0.01 ether, 1);
        vm.prank(player);
        IERC721(SHAPES_ADDR).approve(address(pool), id);
        pool.loseCash(pool.cash() - 0.005 ether);
        uint256 balanceBefore = address(pool).balance;

        vm.prank(player);
        pool.redeemAndDeposit(id);

        assertEq(pool.heldCount(), 0, "redeemed");
        vm.expectRevert();
        shapes.ownerOf(id);
        assertEq(address(pool).balance, balanceBefore + 0.01 ether, "the redeemed ETH arrived");
        assertGt(pool.sharesOf(player), 0);
    }

    function test_aShapeWithoutAMatchingSingleRowIsRedeemed() public {
        uint256 id = mintShapes(player, 1 ether, 1);
        _approveAll(player);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = id;
        uint256 backingBefore = pool.backing();
        _pullWithShapes(tokenIds, 1 ether);
        assertEq(pool.heldCount(), 0);
        assertEq(pool.backing(), backingBefore);
        vm.expectRevert();
        shapes.ownerOf(id);
    }

    // ---------------------------------------------------------------- views

    function test_lensReportsSettleDue() public {
        Lens lens = new Lens(Pool(payable(address(pool))));
        assertEq(uint8(lens.settleDue()), uint8(IPoolTypes.SettleTrigger.None));
        _setCooldown(0);
        for (uint256 i; i < 5; ++i) {
            _captureRow(0);
        }
        pool.bookOnly(20);
        assertEq(uint8(lens.settleDue()), uint8(IPoolTypes.SettleTrigger.Batch));
    }

    function test_fundGrail_creditsBucket() public {
        IPool p = IPool(address(pool));
        (uint256 before_,,,,,,,,,,,) = p.grail(1);
        uint256 balBefore = address(pool).balance;
        vm.expectEmit(true, true, false, true, address(pool));
        emit IPoolTypes.GrailFunded(alice, 1, 1 ether);
        vm.prank(alice);
        p.fundGrail{value: 1 ether}(1);
        (uint256 after_,,,,,,,,,,,) = p.grail(1);
        assertEq(after_ - before_, 1 ether);
        assertEq(address(pool).balance - balBefore, 1 ether);
    }

    function test_fundGrail_rejectsZero() public {
        vm.expectRevert(IPoolTypes.ZeroAmount.selector);
        IPool(address(pool)).fundGrail(1);
    }

    function test_fundGrail_rejectsBadTrack() public {
        vm.prank(alice);
        vm.expectRevert(IPoolTypes.InvalidTrack.selector);
        IPool(address(pool)).fundGrail{value: 1 ether}(2);
    }

    function test_theModuleGettersMatchTheConstructor() public view {
        IPool p = IPool(address(pool));
        assertEq(p.batchMin(), 5);
        assertEq(p.tipWei(), 0.0002 ether);
        assertEq(p.batchMaxAge(), 1 hours);
        assertEq(p.surpriseBps(), 200);
        assertEq(p.restoreK(), 8);
        assertEq(p.bandBps(), 3_000);
        assertEq(p.reserveBps(), 1_000);
        assertFalse(p.listWhilePaused());
        assertEq(p.oldestQueuedAt(), 0);
        assertEq(p.mixLength(), 6);
    }
}
