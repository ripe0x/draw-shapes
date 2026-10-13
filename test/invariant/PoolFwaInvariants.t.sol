// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Pool} from "../../src/Pool.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "../fork/ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {PoolHandler} from "./PoolInvariants.t.sol";

/// @notice Drives the pool against a real FWA clone, deployed Shapes and a Draw Packs deployment.
///         Deposit, withdraw, liquidate and warp are delegated to `PoolHandler`, which holds the
///         I3 and I4 ghost state. Pool events are read after every action and summed into the I6
///         and I7 ghost state. A reverted action leaves no ghost change because the whole handler
///         call reverts.
contract PoolFwaHandler is ForkBase {
    PoolHarness public immutable pool;
    IFWAClone public immutable clone;
    PoolHandler public immutable base;
    address[] internal _actors;
    address[] internal _players;

    uint256 public ghostMaintenanceShares;
    uint256 public ghostGrailIn;
    uint256 public ghostCapturedProceeds;
    uint256 public ghostHarvestReceived;
    uint256 public ghostHarvestSurplus;
    uint256 public ghostCapturedValue;
    uint256 public ghostWrittenOff;
    uint256 public ghostMarginSplit;
    uint256 public lastMaintenance;
    bool public i6Broken;
    bool public harvestBroken;

    uint256 public captures;
    uint256 public griefs;
    uint256 public harvests;
    uint256 public directPurchases;
    uint256 public pulls;

    constructor(PoolHarness pool_, IFWAClone clone_, address[] memory actors_, address[] memory players_) {
        pool = pool_;
        clone = clone_;
        _actors = actors_;
        _players = players_;
        base = new PoolHandler(pool_, actors_);
        lastMaintenance = pool_.maintenance();
        (uint256 minorBucket,,,,,,,,,,,) = pool_.grail(0);
        (uint256 majorBucket,,,,,,,,,,,) = pool_.grail(1);
        ghostGrailIn = minorBucket + majorBucket;
        vm.recordLogs();
    }

    // ------------------------------------------------------------------ ghost accounting

    /// @dev Sums the pool events emitted since the last call and checks I6.
    function _collect() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == Pool.Deposited.selector) {
                (, uint256 contribution,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                ghostGrailIn += contribution;
            } else if (topic == Pool.MarginSplit.selector) {
                (uint256 cover, uint256 premiumShare, uint256 maintenanceShare, uint256 feedShare) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                ghostMarginSplit += cover + premiumShare + maintenanceShare + feedShare;
                ghostMaintenanceShares += maintenanceShare;
                ghostGrailIn += feedShare;
            } else if (topic == Pool.Captured.selector) {
                (, uint256 value, uint256 proceeds) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                ghostCapturedProceeds += proceeds;
                ghostCapturedValue += value;
                ++captures;
            } else if (topic == Pool.WrittenOff.selector) {
                ghostWrittenOff += abi.decode(logs[i].data, (uint256));
            } else if (topic == Pool.Harvested.selector) {
                (uint256 received, uint256 surplus) = abi.decode(logs[i].data, (uint256, uint256));
                ghostHarvestReceived += received;
                ghostHarvestSurplus += surplus;
            }
        }
        uint256 current = pool.maintenance();
        if (current < lastMaintenance) i6Broken = true;
        lastMaintenance = current;
    }

    modifier recorded() {
        vm.recordLogs();
        _;
        _collect();
    }

    // ------------------------------------------------------------------ depositor actions

    function deposit(uint96 value, uint8 actorSeed) external recorded {
        base.deposit(value, actorSeed);
    }

    function withdraw(uint256 shares, uint8 actorSeed) external recorded {
        base.withdraw(shares, actorSeed);
    }

    function liquidate() external recorded {
        base.liquidate();
    }

    function warp(uint32 seconds_) external {
        base.warp(seconds_);
    }

    function warpToResume() external {
        _warpToResume();
    }

    function _warpToResume() internal {
        uint256 resumeAt = clone.purchasesResumeAt() + 1;
        if (resumeAt > block.timestamp) vm.warp(resumeAt);
    }

    function redeemAndDeposit(uint8 actorSeed) external recorded {
        address actor = _actors[actorSeed % _actors.length];
        uint256 tokenId = mintShapes(actor, 0.1 ether, 1);
        vm.startPrank(actor);
        IERC721(SHAPES_ADDR).approve(address(pool), tokenId);
        pool.redeemAndDeposit(tokenId);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ player actions

    /// @dev Pulls `count` as a player. `fulfillNow` delivers a word for every outstanding request.
    function pull(uint8 countSeed, uint8 playerSeed, uint256 pick, bool fulfillNow) external recorded {
        _warpToResume();
        uint256 count = bound(countSeed, 1, 3);
        if (count > pool.maxBatch()) return;
        if (pool.listedCount() < clone.unsettledAcquisitionCount() + count + pool.concurrency()) return;
        address player = _players[playerSeed % _players.length];
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(count);
        vm.deal(player, player.balance + total);
        vm.prank(player);
        pool.pull{value: total}(count, fee, block.timestamp + 1 hours);
        ++pulls;
        if (fulfillNow) _fulfillOutstanding(pick, false);
    }

    /// @dev A wallet acquires at the FWA pool without going through `Pool.pull`.
    function directAcquire(uint8 playerSeed, uint256 pick, bool fulfillNow) external recorded {
        _warpToResume();
        if (clone.totalWeight() == 0 || clone.unsettledAcquisitionCount() >= 3) return;
        address player = _players[playerSeed % _players.length];
        acquireAs(player, player, clone, block.timestamp + 1 hours);
        ++directPurchases;
        if (fulfillNow) _fulfillOutstanding(pick, false);
    }

    function fulfillOutstanding(uint256 pick) external recorded {
        _fulfillOutstanding(pick, false);
    }

    /// @dev Direct acquisition with the Shapes contract as purchaser, fulfilled on a Shape listing.
    ///      Delivery reverts in the Shapes contract, which leaves the acquisition DeliveryPending.
    function griefShapes(uint256 pick) external recorded {
        _warpToResume();
        if (clone.totalWeight() == 0 || clone.unsettledAcquisitionCount() >= 3) return;
        acquireAs(SHAPES_ADDR, SHAPES_ADDR, clone, block.timestamp + 1 hours);
        ++griefs;
        _fulfillOutstanding(pick, true);
    }

    /// @dev Rolls past the word deadline of every pending request and lets FWA expire them.
    function expireOutstanding() external recorded {
        if (clone.unsettledAcquisitionCount() == 0) return;
        vm.roll(block.number + clone.selectionTimeoutBlocks() + 2);
        clone.processAcquisitions(50);
    }

    /// @dev FWA processing without pool booking.
    function processOnly(uint8 n) external recorded {
        clone.processAcquisitions(bound(n, 1, 5));
    }

    // ------------------------------------------------------------------ settlement actions

    function settle(uint8 n) external recorded {
        pool.settle(bound(n, 1, 20));
    }

    function settleAndHarvest() external recorded {
        pool.settle(20);
        _harvest();
    }

    function harvest() external recorded {
        _harvest();
    }

    function _harvest() internal {
        uint256 ownerProceedsBefore = clone.ownerProceeds();
        uint256 cashBefore = pool.cash();
        bool done = pool.harvest();
        if (done) {
            if (
                pool.receivable() != 0 || pool.maintenanceReceivable() != 0 || pool.grailReceivable(0) != 0
                    || pool.grailReceivable(1) != 0 || clone.ownerProceeds() != 0 || pool.cash() < cashBefore
                    || ownerProceedsBefore == 0
            ) harvestBroken = true;
            ++harvests;
        } else if (pool.cash() != cashBefore) {
            harvestBroken = true;
        }
    }

    /// @dev Lists held items and mints replacements, as a rotation does.
    function restock() external recorded {
        pool.restock();
    }

    // ------------------------------------------------------------------ FWA helpers

    function _activeListings(bool shapesOnly) internal view returns (uint256[] memory ids) {
        uint256 next = clone.nextListingId();
        ids = new uint256[](next);
        uint256 n;
        for (uint256 id = 1; id < next; ++id) {
            (address collection,,,,,,, IFWAClone.ListingStatus status) = clone.listings(id);
            if (status == IFWAClone.ListingStatus.Active && (!shapesOnly || collection == SHAPES_ADDR)) {
                ids[n++] = id;
            }
        }
        assembly {
            mstore(ids, n)
        }
    }

    /// @dev Delivers a word for every Pending request in sequence order. Each word selects an
    ///      Active listing chosen from `pick`.
    function _fulfillOutstanding(uint256 pick, bool shapesOnly) internal {
        uint64 last = clone.lastIssuedSequence();
        for (uint64 seq = clone.nextSequenceToProcess(); seq <= last; ++seq) {
            uint256 requestId = clone.requestIdAtSequence(seq);
            (,,,, IFWAClone.AcquisitionStatus status) = clone.acquisitions(requestId);
            if (status != IFWAClone.AcquisitionStatus.Pending) continue;
            (, uint64 wordDeadlineBlock,,,,) = clone.acquisitionMeta(requestId);
            if (block.number > wordDeadlineBlock) {
                clone.processAcquisitions(50);
                continue;
            }
            uint256[] memory active = _activeListings(shapesOnly);
            uint256 word = active.length == 0
                ? 0
                : wordFor(clone, active[uint256(keccak256(abi.encode(pick, seq))) % active.length]);
            fulfill(clone, requestId, word);
        }
    }
}

contract PoolFwaInvariantsTest is ForkBase, PoolFixture {
    PoolHarness internal pool;
    IFWAClone internal clone;
    PoolFwaHandler internal handler;

    function setUp() public {
        setUpFork();
        openFactory();
        deployDrawPacks(admin);
        vm.deal(alice, 10_000 ether);

        Pool.Params memory p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
        pool = new PoolHarness(p);
        vm.prank(admin);
        pool.createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);

        // 60 item board: 42 Shapes and 18 packs.
        vm.prank(alice);
        pool.deposit{value: 200 ether}();
        vm.warp(pool.openingDeadlineAt());
        pool.recordPulls(60);
        pool.open();
        pool.restock();
        pool.restock();
        warpPastCooldown(clone);

        address[] memory actors = new address[](4);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }
        address[] memory players = new address[](3);
        for (uint256 i; i < players.length; ++i) {
            players[i] = makeAddr(string.concat("player", vm.toString(i)));
        }
        handler = new PoolFwaHandler(pool, clone, actors, players);

        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = PoolFwaHandler.deposit.selector;
        selectors[1] = PoolFwaHandler.withdraw.selector;
        selectors[2] = PoolFwaHandler.liquidate.selector;
        selectors[3] = PoolFwaHandler.warp.selector;
        selectors[4] = PoolFwaHandler.warpToResume.selector;
        selectors[5] = PoolFwaHandler.redeemAndDeposit.selector;
        selectors[6] = PoolFwaHandler.pull.selector;
        selectors[7] = PoolFwaHandler.directAcquire.selector;
        selectors[8] = PoolFwaHandler.fulfillOutstanding.selector;
        selectors[9] = PoolFwaHandler.expireOutstanding.selector;
        selectors[10] = PoolFwaHandler.processOnly.selector;
        selectors[11] = PoolFwaHandler.settle.selector;
        selectors[12] = PoolFwaHandler.harvest.selector;
        selectors[13] = PoolFwaHandler.restock.selector;
        selectors[14] = PoolFwaHandler.settleAndHarvest.selector;
        selectors[15] = PoolFwaHandler.griefShapes.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Walks the handler through each path once so the invariant campaign is known to reach
    ///      captures, direct purchases, harvest surplus, deferred fulfillment and expiry.
    function test_handlerReachesEveryPath() public {
        for (uint256 i; i < 16; ++i) {
            handler.warpToResume();
            handler.pull(uint8(i), uint8(i), i, i % 3 != 0);
            handler.directAcquire(uint8(i), i, i % 2 == 0);
            handler.fulfillOutstanding(i);
            handler.settle(5);
            handler.harvest();
            handler.settleAndHarvest();
            handler.restock();
            handler.warp(uint32(i * 1000));
            if (i % 4 == 3) handler.griefShapes(i);
            handler.deposit(uint96(i * 1e17), uint8(i));
            handler.withdraw(i * 1e18, uint8(i));
            handler.liquidate();
            handler.redeemAndDeposit(uint8(i));
        }
        handler.directAcquire(0, 1, false);
        handler.expireOutstanding();
        handler.settle(5);
        handler.griefShapes(7);
        handler.settle(5);
        assertGt(handler.pulls(), 0);
        assertGt(handler.directPurchases(), 0);
        assertGt(handler.captures(), 0);
        assertGt(handler.harvests(), 0);
        assertGt(handler.ghostHarvestSurplus(), 0);
        assertGt(handler.ghostMaintenanceShares(), 0);
        assertGt(handler.griefs(), 0);
        assertGt(handler.ghostWrittenOff(), 0);
        invariant_I1_balanceCoversBuckets();
        invariant_I2_backingMatchesRegistry();
        invariant_I3_withdrawalNeverExceedsNavShare();
        invariant_I4_claimsPaidInRequestOrder();
        invariant_I6_maintenanceNeverDecreases();
        invariant_I7_bucketsCreditedOnlyFromSplitsAndContributions();
        invariant_proceedsConserved();
        invariant_harvestConsistency();
        invariant_sharesSumToTotal();
        invariant_marginConserved();
        emit log_named_uint("written off", handler.ghostWrittenOff());
        emit log_named_uint("pulls", handler.pulls());
        emit log_named_uint("direct purchases", handler.directPurchases());
        emit log_named_uint("captures", handler.captures());
        emit log_named_uint("harvests", handler.harvests());
        emit log_named_uint("held items", pool.heldCount());
    }

    function afterInvariant() public {
        emit log_named_uint("last run: pulls", handler.pulls());
        emit log_named_uint("last run: direct purchases", handler.directPurchases());
        emit log_named_uint("last run: captures", handler.captures());
        emit log_named_uint("last run: harvests", handler.harvests());
    }

    function _grailBuckets() internal view returns (uint256 total) {
        (uint256 minorBucket,,,,,,,,,,,) = pool.grail(0);
        (uint256 majorBucket,,,,,,,,,,,) = pool.grail(1);
        return minorBucket + majorBucket;
    }

    function _grailReceivables() internal view returns (uint256) {
        return pool.grailReceivable(0) + pool.grailReceivable(1);
    }

    function _bookedReceivables() internal view returns (uint256) {
        return pool.receivable() + pool.maintenanceReceivable() + _grailReceivables();
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I1_balanceCoversBuckets() public view {
        assertGe(address(pool).balance, pool.cash() + pool.maintenance() + _grailBuckets());
    }

    /// @dev `backing` equals the value of every held item and every listed item.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I2_backingMatchesRegistry() public view {
        uint256 sum;
        for (uint256 i; i < pool.heldCount(); ++i) {
            sum += pool.heldItem(i).value;
        }
        uint256 listed;
        uint256 next = clone.nextListingId();
        for (uint256 id = 1; id < next; ++id) {
            uint256 value = pool.listedItem(id).value;
            if (value != 0) ++listed;
            sum += value;
        }
        assertEq(pool.backing(), sum);
        assertEq(pool.listedCount(), listed);
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I3_withdrawalNeverExceedsNavShare() public view {
        assertFalse(handler.base().i3Broken());
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I4_claimsPaidInRequestOrder() public view {
        PoolHandler base = handler.base();
        assertFalse(base.i4Broken());
        assertEq(base.paidIndex(), pool.claimHead());
        assertEq(pool.claims(), base.outstandingClaims());
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I6_maintenanceNeverDecreases() public view {
        assertFalse(handler.i6Broken());
    }

    /// @dev Maintenance and the GRAIL buckets are credited only from deposit contributions and
    ///      margin splits, including the shares still held as receivables.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I7_bucketsCreditedOnlyFromSplitsAndContributions() public view {
        assertEq(pool.maintenance() + pool.maintenanceReceivable(), handler.ghostMaintenanceShares());
        assertEq(_grailBuckets() + _grailReceivables(), handler.ghostGrailIn());
    }

    /// @dev Booked proceeds are either still a receivable or already received at harvest. Harvest
    ///      surplus is received without having been booked.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_proceedsConserved() public view {
        assertEq(
            handler.ghostCapturedProceeds() + handler.ghostHarvestSurplus(),
            _bookedReceivables() + handler.ghostHarvestReceived()
        );
    }

    /// @dev Margin is the net of every captured proceeds, harvest surplus, captured value and
    ///      written-off value, less what splits have released. A write-off books no proceeds, so the
    ///      ETH-side equation above is unchanged and written-off value enters on the loss side only.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_marginConserved() public view {
        assertEq(
            pool.margin(),
            int256(handler.ghostCapturedProceeds() + handler.ghostHarvestSurplus())
                - int256(handler.ghostCapturedValue() + handler.ghostWrittenOff() + handler.ghostMarginSplit())
        );
    }

    /// @dev Booked receivables are held at FWA as owner proceeds. A successful harvest leaves all four
    ///      receivables at zero.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_harvestConsistency() public view {
        assertFalse(handler.harvestBroken());
        assertLe(_bookedReceivables(), clone.ownerProceeds());
        assertLe(pool.nextSequenceToBook(), clone.nextSequenceToProcess());
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_sharesSumToTotal() public view {
        uint256 sum;
        PoolHandler base = handler.base();
        for (uint256 i; i < base.actorCount(); ++i) {
            sum += pool.sharesOf(base.actors(i));
        }
        assertEq(sum + pool.sharesOf(alice), pool.totalShares());
    }
}
