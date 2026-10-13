// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Pool} from "../../src/Pool.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice GRAIL tracks against deployed Shapes, a Draw Packs deployment and a FWA clone created by
///         the pool: growth steps, compose at native denominations, decay in `rotate`, capture and
///         the selection probability lift.
/// @dev Minor track: step 0.05 ETH, target 0.5 ETH, list at 80 percent, decay 0.001 ETH per pull,
///      floor 0.1 ETH. Its backing reaches a native denomination at 0.1 ETH and 0.5 ETH. Major
///      track: step 0.15 ETH, target 1 ETH, list at 90 percent, no native backing below 1.05 ETH.
///      A 100 ETH deposit routes about 11 ETH to the two buckets.
contract PoolGrailForkTest is ForkBase, PoolFixture {
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

        IPoolTypes.Params memory p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
        p.minor = IPoolTypes.GrailParams({
            targetWei: 0.5 ether, stepWei: 0.05 ether, listBps: 8_000, decayWeiPerPull: 0.001 ether, floorWei: 0.1 ether
        });
        p.major = IPoolTypes.GrailParams({
            targetWei: 1 ether, stepWei: 0.15 ether, listBps: 9_000, decayWeiPerPull: 0.002 ether, floorWei: 0.3 ether
        });
        pool = new PoolHarness(p);
        vm.prank(admin);
        IPool(address(pool)).createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);
    }

    // ---------------------------------------------------------------- helpers

    function _openReady() internal {
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.open();
        warpPastCooldown(clone);
    }

    function _warpToRotation() internal {
        uint256 at = pool.lastRotateAt() + pool.rotateInterval();
        if (block.timestamp < at) vm.warp(at);
    }

    function _bucket(uint256 t) internal view returns (uint256 v) {
        (v,,,,,,,,,,,) = IPool(address(pool)).grail(t);
    }

    function _packId(uint256 t) internal view returns (uint256 v) {
        (, v,,,,,,,,,,) = IPool(address(pool)).grail(t);
    }

    function _backing(uint256 t) internal view returns (uint256 v) {
        (,, v,,,,,,,,,) = IPool(address(pool)).grail(t);
    }

    function _notional(uint256 t) internal view returns (uint256 v) {
        (,,, v,,,,,,,,) = IPool(address(pool)).grail(t);
    }

    function _pulls(uint256 t) internal view returns (uint256 v) {
        (,,,,,,,,, v,,) = IPool(address(pool)).grail(t);
    }

    function _receivable(uint256 t) internal view returns (uint256 v) {
        (,,,,,,,,,, v,) = IPool(address(pool)).grail(t);
    }

    function _listing(uint256 t) internal view returns (uint256 v) {
        (,,,,,,,,,,, v) = IPool(address(pool)).grail(t);
    }

    /// @dev Step plus the mint fees of the Shapes `defaultMakeup(step)` mints.
    function _cost(uint256 step) internal view returns (uint256 cost) {
        uint32[] memory counts = drawPacks.defaultMakeup(step);
        for (uint256 i; i < counts.length; ++i) {
            cost += counts[i] * mintFee;
        }
        cost += step;
    }

    function _price(uint256 listingId) internal view returns (uint256 price, IFWAClone.ListingStatus status) {
        (,,,,, price,, status) = clone.listings(listingId);
    }

    /// @dev One growth step of track `t` alone, as the GRAIL step of `rotate` applies it.
    function _grow(uint256 t) internal {
        _warpPastRotateGate(pool);
        vm.prank(keeper);
        pool.growTrack(uint8(t));
    }

    function _rotateAsKeeper() internal {
        _warpPastRotateGate(pool);
        vm.prank(keeper);
        pool.rotate();
    }

    function _acquire(address who, uint256 count) internal returns (uint256[] memory ids) {
        return acquirePooled(address(pool), clone, who, count);
    }

    function _assertI1() internal view {
        assertGe(address(pool).balance, pool.cash() + pool.maintenance() + _bucket(0) + _bucket(1), "I1");
    }

    /// @dev Number of `topic` logs emitted by the pool, and the data of the last one.
    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n, bytes memory last) {
        return _countTrack(logs, topic, type(uint256).max);
    }

    /// @dev As `_count`, restricted to logs whose first indexed argument is `track`. A `track` of
    ///      `type(uint256).max` matches every log.
    function _countTrack(Vm.Log[] memory logs, bytes32 topic, uint256 track)
        internal
        view
        returns (uint256 n, bytes memory last)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool) || logs[i].topics[0] != topic) continue;
            if (track != type(uint256).max && uint256(logs[i].topics[1]) != track) continue;
            ++n;
            last = logs[i].data;
        }
    }

    // ---------------------------------------------------------------- guards

    function test_growthStepIsDueOnlyOnceTheBucketCoversTheStep() public {
        _openReady();
        uint256 cost = _cost(0.05 ether);
        pool.loseGrailBucket(0, _bucket(0) - cost + 1);
        pool.loseGrailBucket(1, _bucket(1));
        _warpPastRotateGate(pool);
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None), "short by one wei");
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();

        pool.addGrailBucket{value: 1}(0);
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.GrailStep));
        pool.rotate();
        assertEq(_bucket(0), 0, "the step spent the bucket exactly");
        assertEq(_backing(0), 0.05 ether);
        assertEq(pool.lastRotateAt(), block.timestamp, "growth is an inventory change");
    }

    function test_rotateWaitsToGrowWhileAcquisitionsAreUnsettled() public {
        _openReady();
        _grow(0);
        warpPastCooldown(clone);
        uint256[] memory ids = _acquire(player, 1);
        assertEq(clone.unsettledAcquisitionCount(), 1);

        _warpPastRotateGate(pool);
        uint256 lastBefore = pool.lastRotateAt();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.GrailStep));
        pool.rotate();
        assertEq(_backing(0), 0.05 ether, "locked while an acquisition is unsettled");
        assertEq(_backing(1), 0, "locked while an acquisition is unsettled");
        assertEq(pool.lastRotateAt(), lastBefore, "a rotate that grew nothing leaves the spacing alone");

        fulfill(clone, ids[0], wordAvoiding(clone, _listing(0)));
        _rotateAsKeeper();
        assertEq(_backing(0), 0.1 ether, "grows once the acquisition settled");
        assertEq(_backing(1), 0.15 ether);
    }

    // ---------------------------------------------------------------- growth

    function test_firstGrowthCreatesTheTrackPackAndListsItAtTheNotional() public {
        _openReady();
        uint256 cost = _cost(0.05 ether);
        uint256 bucketBefore = _bucket(0);
        uint256 balanceBefore = address(pool).balance;
        uint256 cashBefore = pool.cash();
        uint256 backingBefore = pool.backing();
        uint256 expectedPack = drawPacks.totalMinted() + 1;

        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.GrailGrown(0, expectedPack, 0.05 ether, 0.04 ether);
        _grow(0);

        assertEq(cost, 0.05 ether + mintFee, "defaultMakeup(0.05) is one Shape");
        assertEq(bucketBefore - _bucket(0), cost, "the bucket paid the step and the mint fee");
        assertEq(balanceBefore - address(pool).balance, cost, "the ETH left the pool");
        assertEq(pool.cash(), cashBefore, "ordinary cash untouched");
        assertEq(pool.backing(), backingBefore, "ordinary backing untouched");
        assertEq(_packId(0), expectedPack);
        assertEq(_backing(0), 0.05 ether);
        assertEq(drawPacks.valueOf(expectedPack), _backing(0), "pack value equals track backing");
        assertEq(drawPacks.contentsOf(expectedPack).length, 1);
        assertEq(_notional(0), 0.04 ether, "80 percent of the backing");
        assertEq(_pulls(0), 0);
        (uint256 price, IFWAClone.ListingStatus status) = _price(_listing(0));
        assertEq(price, 0.04 ether);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active));
        assertEq(drawPacks.ownerOf(expectedPack), address(clone), "FWA holds the pack");
        assertEq(_packId(1), 0, "the other track is untouched");
        _assertI1();
    }

    function test_secondGrowthWithdrawsTheListingAddsToThePackAndRelists() public {
        _openReady();
        _grow(1);
        uint256 packId = _packId(1);
        uint256 firstListing = _listing(1);
        assertEq(_backing(1), 0.15 ether);
        assertEq(drawPacks.contentsOf(packId).length, 2, "0.1 and 0.05");
        uint256 cost = _cost(0.15 ether);
        uint256 bucketBefore = _bucket(1);

        _grow(1);

        assertEq(_packId(1), packId, "same pack");
        assertEq(_backing(1), 0.3 ether);
        assertEq(drawPacks.valueOf(packId), 0.3 ether);
        assertEq(drawPacks.contentsOf(packId).length, 4);
        assertEq(bucketBefore - _bucket(1), cost);
        assertEq(_notional(1), 0.27 ether);
        assertTrue(_listing(1) != firstListing, "relisted under a new id");
        (, IFWAClone.ListingStatus oldStatus) = _price(firstListing);
        assertEq(uint8(oldStatus), uint8(IFWAClone.ListingStatus.Withdrawn));
        (uint256 price, IFWAClone.ListingStatus status) = _price(_listing(1));
        assertEq(price, 0.27 ether);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active));
        assertEq(drawPacks.ownerOf(packId), address(clone));
        _assertI1();
    }

    function test_composeAtANativeDenominationLeavesOnePackOfOneShape() public {
        _openReady();
        _grow(0);
        uint256 firstPack = _packId(0);
        uint256 survivor = drawPacks.contentsOf(firstPack)[0];
        uint256 bucketBefore = _bucket(0);

        _grow(0);

        assertEq(_backing(0), 0.1 ether, "0.05 twice is the 0.1 rung");
        uint256 packId = _packId(0);
        assertTrue(packId != firstPack, "a fresh pack");
        assertFalse(drawPacks.exists(firstPack), "the opened pack is burned");
        uint256[] memory contents = drawPacks.contentsOf(packId);
        assertEq(contents.length, 1, "one composed Shape");
        assertEq(contents[0], survivor, "the first Shape survives");
        assertEq(shapes.backingOf(survivor), 0.1 ether);
        assertEq(shapes.denomIndexOf(survivor), 2);
        assertEq(drawPacks.valueOf(packId), 0.1 ether);
        assertEq(bucketBefore - _bucket(0), _cost(0.05 ether));
        assertEq(_notional(0), 0.08 ether);
        assertEq(drawPacks.ownerOf(packId), address(clone));
        (uint256 price, IFWAClone.ListingStatus status) = _price(_listing(0));
        assertEq(price, 0.08 ether);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active));
        assertEq(shapes.ownerOf(survivor), address(drawPacks), "the pack custodies the Shape");
        _assertI1();
    }

    function test_growthStopsAtTheTargetAfterComposingTheHalfEthShape() public {
        _openReady();
        uint256 bucketBefore = _bucket(0);
        for (uint256 i = 1; i <= 10; ++i) {
            _grow(0);
            assertEq(_backing(0), i * 0.05 ether);
            assertEq(drawPacks.valueOf(_packId(0)), _backing(0), "pack value equals track backing");
            uint256 expectedShapes = i <= 2 || i == 10 ? 1 : i - 1;
            assertEq(drawPacks.contentsOf(_packId(0)).length, expectedShapes, "composed at 0.1 and 0.5 only");
        }
        assertEq(bucketBefore - _bucket(0), 10 * _cost(0.05 ether), "I5: ten steps, ten costs");
        assertEq(_notional(0), 0.4 ether);

        _warpPastRotateGate(pool);
        vm.expectRevert(IPoolTypes.GrailNotReady.selector);
        pool.growTrack(0);
        _assertI1();
    }

    function test_majorTrackGrowsInItsOwnStep() public {
        _openReady();
        _grow(1);
        assertEq(_backing(1), 0.15 ether);
        assertEq(_notional(1), 0.135 ether);
        assertEq(drawPacks.valueOf(_packId(1)), 0.15 ether);
        assertEq(_backing(0), 0, "minor untouched");
    }

    // ---------------------------------------------------------------- rotate

    function test_rotateGrowsFundedTracks() public {
        _openReady();
        _warpToRotation();

        vm.recordLogs();
        vm.prank(keeper);
        pool.rotate();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 grown,) = _count(logs, IPoolTypes.GrailGrown.selector);
        assertEq(grown, 2, "both tracks grew");
        assertEq(_backing(0), 0.05 ether);
        assertEq(_backing(1), 0.15 ether);
        assertTrue(_listing(0) != 0 && _listing(1) != 0);
        assertEq(pool.lastRotateAt(), block.timestamp, "a GRAIL listing change is an inventory change");
        _assertI1();
    }

    function test_rotateSkipsTracksThatAreNotReady() public {
        _openReady();
        pool.loseGrailBucket(0, _bucket(0));
        _warpToRotation();

        vm.recordLogs();
        pool.rotate();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 grown,) = _count(logs, IPoolTypes.GrailGrown.selector);
        assertEq(grown, 1, "only the funded track grew");
        assertEq(_backing(0), 0);
        assertEq(_backing(1), 0.15 ether);
    }

    function test_decayInRotateLowersThePriceByPullsTimesDecayDownToTheFloor() public {
        _openReady();
        for (uint256 i; i < 10; ++i) {
            _grow(0);
        }
        uint256 listingId = _listing(0);
        assertEq(_notional(0), 0.4 ether);

        pool.recordPulls(100);
        assertEq(_pulls(0), 100, "listed track counts pulls");
        _warpToRotation();
        vm.recordLogs();
        pool.rotate();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_listing(0), listingId, "repriced in place");
        assertEq(_notional(0), 0.3 ether, "100 pulls at 0.001 ETH");
        (uint256 price,) = _price(listingId);
        assertEq(price, 0.3 ether);
        assertEq(_pulls(0), 0, "the reprice restarts the count");
        (uint256 listed,) = _count(logs, IPoolTypes.GrailListed.selector);
        assertGe(listed, 1);

        pool.recordPulls(5_000);
        _warpToRotation();
        pool.rotate();
        (price,) = _price(listingId);
        assertEq(price, 0.1 ether, "never below the floor");
        assertEq(_notional(0), 0.1 ether);

        pool.recordPulls(10);
        _warpToRotation();
        assertTrue(pool.rotateDue() != IPoolTypes.RotateTrigger.Decay, "at the floor no decay is due");
        (price,) = _price(listingId);
        assertEq(price, 0.1 ether, "at the floor there is nothing to reprice");
        assertEq(_pulls(0), 10, "pulls keep counting");
        _assertI1();
    }

    function test_decayBelowOnePercentOfTheListPriceDoesNotReprice() public {
        _openReady();
        for (uint256 i; i < 10; ++i) {
            _grow(0);
        }
        for (uint256 i; i < 7; ++i) {
            _grow(1);
        }
        assertEq(_backing(1), 1.05 ether, "the major track is at its target");
        uint256 listingId = _listing(0);
        assertEq(_notional(0), 0.4 ether);

        pool.recordPulls(3);
        _warpToRotation();
        assertEq(uint256(pool.rotateDue()), uint256(IPoolTypes.RotateTrigger.None), "0.75 percent is not due");
        (uint256 price,) = _price(listingId);
        assertEq(price, 0.4 ether);
        assertEq(_pulls(0), 3, "the pulls keep counting");

        pool.recordPulls(1);
        _warpToRotation();
        assertEq(uint256(pool.rotateDue()), uint256(IPoolTypes.RotateTrigger.Decay), "1 percent is due");
        pool.rotate();
        assertEq(_notional(0), 0.396 ether, "4 pulls at 0.001 ETH");
        assertEq(_pulls(0), 0);
        _assertI1();
    }

    function test_growthRunsInsideRotateAndRestartsTheSpacing() public {
        _openReady();
        vm.expectRevert(IPoolTypes.RotateTooSoon.selector);
        pool.rotate();

        _warpToRotation();
        pool.rotate();
        assertEq(_backing(0), 0.05 ether);
        assertEq(pool.lastRotateAt(), block.timestamp, "growth restarts the spacing");
        vm.expectRevert(IPoolTypes.RotateTooSoon.selector);
        pool.rotate();

        vm.warp(block.timestamp + pool.rotateInterval() - 1);
        vm.expectRevert(IPoolTypes.RotateTooSoon.selector);
        pool.rotate();
        vm.warp(block.timestamp + 1);
        pool.rotate();
        assertEq(_backing(0), 0.1 ether);
    }

    function test_growthRelistResetsThePullCount() public {
        _openReady();
        _grow(0);
        warpPastCooldown(clone);
        uint256[] memory ids = _acquire(player, 2);
        assertEq(_pulls(0), 0, "pulls count towards decay when booked");
        fulfill(clone, ids[0], wordAvoiding(clone, _listing(0)));
        fulfill(clone, ids[1], wordAvoiding(clone, _listing(0)));
        pool.bookOnly(5);
        assertEq(_pulls(0), 2, "booked pulls count towards decay");
        _grow(0);
        assertEq(_pulls(0), 0, "relisting restarts the count");
    }

    function test_decayWaitsWhileAcquisitionsAreUnsettled() public {
        _openReady();
        for (uint256 i; i < 10; ++i) {
            _grow(0);
        }
        warpPastCooldown(clone);
        uint256[] memory ids = _acquire(player, 1);
        pool.recordPulls(100);
        _warpToRotation();

        vm.prank(keeper);
        pool.rotate();

        assertEq(_notional(0), 0.4 ether, "locked while an acquisition is unsettled");
        assertEq(_pulls(0), 100, "the unsettled pull is counted once booked");

        fulfill(clone, ids[0], wordAvoiding(clone, _listing(0)));
        _warpToRotation();
        vm.prank(keeper);
        pool.rotate();
        assertEq(_notional(0), 0.4 ether - 101 * 0.001 ether, "repriced once settled");
    }

    function test_rotateListsAPackThatIsNoLongerListed() public {
        _openReady();
        for (uint256 i; i < 10; ++i) {
            _grow(0);
        }
        uint256 packId = _packId(0);
        pool.unlistGrail(0);
        assertEq(_listing(0), 0);
        assertEq(drawPacks.ownerOf(packId), address(pool));
        _warpToRotation();

        pool.rotate();

        assertTrue(_listing(0) != 0, "listed again");
        assertEq(_packId(0), packId);
        assertEq(drawPacks.ownerOf(packId), address(clone));
        (uint256 price, IFWAClone.ListingStatus status) = _price(_listing(0));
        assertEq(price, 0.4 ether);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active));
    }

    // ---------------------------------------------------------------- capture

    function test_captureBooksProceedsToTheTrackAndRegrowsFromItsBucket() public {
        _openReady();
        _grow(0);
        _grow(0);
        warpPastCooldown(clone);
        uint256 packId = _packId(0);
        uint256 listingId = _listing(0);
        uint256 backingBefore = pool.backing();
        int256 marginBefore = IPool(address(pool)).margin();
        uint256 receivableBefore = pool.receivable();
        uint256 bucketBefore = _bucket(0);

        uint256[] memory ids = _acquire(player, 1);
        fulfill(clone, ids[0], wordFor(clone, listingId));
        (,, uint256 paid,, IFWAClone.AcquisitionStatus status) = clone.acquisitions(ids[0]);
        assertEq(uint8(status), uint8(IFWAClone.AcquisitionStatus.Fulfilled));
        (uint256 base, bool recorded) = pool.baseOf(ids[0]);
        assertTrue(recorded);
        uint256 proceeds = paid - (paid - base) / 2;

        vm.expectEmit(true, true, false, true, address(pool));
        emit IPoolTypes.GrailCaptured(0, ids[0], proceeds);
        pool.bookOnly(5);

        assertEq(drawPacks.ownerOf(packId), player, "the player received the pack");
        assertEq(_receivable(0), proceeds, "proceeds booked to the track");
        assertEq(_packId(0), 0);
        assertEq(_backing(0), 0);
        assertEq(_notional(0), 0);
        assertEq(_listing(0), 0);
        assertEq(_pulls(0), 0);
        assertEq(pool.backing(), backingBefore, "ordinary backing untouched");
        assertEq(IPool(address(pool)).margin(), marginBefore, "no ordinary margin");
        assertEq(pool.receivable(), receivableBefore, "no ordinary receivable");
        assertEq(pool.replacementLength(), 0, "no replacement");
        assertEq(_bucket(0), bucketBefore, "the bucket receives the proceeds at harvest");

        assertTrue(pool.harvest());
        assertEq(_receivable(0), 0);
        assertEq(_bucket(0), bucketBefore + proceeds);
        _assertI1();

        // I5: the track regrows from its own bucket.
        uint256 beforeRegrow = _bucket(0);
        warpPastCooldown(clone);
        _grow(0);
        assertEq(beforeRegrow - _bucket(0), _cost(0.05 ether));
        assertTrue(_packId(0) != packId && _packId(0) != 0, "a new pack");
        assertEq(_backing(0), 0.05 ether);
        assertEq(drawPacks.valueOf(_packId(0)), 0.05 ether);
    }

    function test_growthBooksACaptureBeforeItGrows() public {
        _openReady();
        _grow(0);
        warpPastCooldown(clone);
        uint256 oldPack = _packId(0);
        uint256[] memory ids = _acquire(player, 1);
        fulfill(clone, ids[0], wordFor(clone, _listing(0)));
        assertEq(_packId(0), oldPack, "the capture is not booked yet");

        warpPastCooldown(clone);
        _grow(0);

        assertEq(drawPacks.ownerOf(oldPack), player);
        assertTrue(_packId(0) != oldPack, "a new pack");
        assertEq(_backing(0), 0.05 ether, "the track restarted");
        assertEq(_receivable(0), 0, "proceeds harvested into the bucket");
        _assertI1();
    }

    function test_bucketAccountingAcrossGrowthCaptureAndRegrowth() public {
        _openReady();
        uint256 start = _bucket(0);
        uint256 spent;
        for (uint256 i; i < 3; ++i) {
            _grow(0);
            spent += _cost(0.05 ether);
        }
        warpPastCooldown(clone);
        uint256[] memory ids = _acquire(player, 1);
        fulfill(clone, ids[0], wordFor(clone, _listing(0)));
        vm.recordLogs();
        pool.bookOnly(5);
        (, bytes memory data) = _count(vm.getRecordedLogs(), IPoolTypes.GrailCaptured.selector);
        uint256 proceeds = abi.decode(data, (uint256));
        assertGt(proceeds, 0);
        pool.harvest();
        warpPastCooldown(clone);
        for (uint256 i; i < 2; ++i) {
            _grow(0);
            spent += _cost(0.05 ether);
        }
        assertEq(_bucket(0) + _receivable(0), start + proceeds - spent, "I5: bucket = in + proceeds - spent");
        assertEq(_backing(0), 0.1 ether);
        _assertI1();
    }

    function test_writtenOffGrailListingResetsTheTrackWithoutProceeds() public {
        _openReady();
        _grow(0);
        uint256 listingId = _listing(0);
        int256 marginBefore = IPool(address(pool)).margin();
        uint256 backingBefore = pool.backing();

        vm.expectEmit(true, true, false, true, address(pool));
        emit IPoolTypes.GrailCaptured(0, 77, 0);
        pool.writeOff(77, listingId);

        assertEq(_packId(0), 0);
        assertEq(_backing(0), 0);
        assertEq(_listing(0), 0);
        assertEq(_receivable(0), 0);
        assertEq(IPool(address(pool)).margin(), marginBefore);
        assertEq(pool.backing(), backingBefore);
    }

    // ---------------------------------------------------------------- selection probability

    function _capExceeded() internal view returns (bool) {
        (uint256 price,) = _price(_listing(0));
        return (1e36 / price) * 10_000 > clone.totalWeight() * IPool(address(pool)).grailProbCapBps();
    }

    function test_rotateLiftsAGrailPriceWhoseWeightExceedsTheProbabilityCap() public {
        _openReady();
        pool.loseGrailBucket(1, _bucket(1));
        vm.startPrank(admin);
        IPool(address(pool)).setConcurrency(0);
        IPool(address(pool)).setGrail(0, 0.5 ether, 0.05 ether, 8_000, 0.001 ether, 0.01 ether);
        vm.stopPrank();
        _grow(0);
        pool.loseGrailBucket(0, _bucket(0));
        uint256 listingId = _listing(0);
        uint256 ceiling = _backing(0) * 8_000 / 10_000;
        assertEq(_notional(0), ceiling);

        // Ten pulls decay the 0.04 ETH list price to 0.03 ETH, which the cap allows on the full board.
        pool.recordPulls(10);
        _warpToRotation();
        vm.prank(keeper);
        pool.rotate();
        assertEq(_notional(0), 0.03 ether);
        assertFalse(_capExceeded());

        // A cap between the GRAIL weight share at 0.03 ETH and at the ceiling puts the track above the
        // cap now and within it once lifted.
        uint256 rest = clone.totalWeight() - 1e36 / _notional(0);
        uint256 shareAtCeiling = (1e36 / ceiling) * 10_000 / (rest + 1e36 / ceiling);
        assertLt(shareAtCeiling + 1, (1e36 / _notional(0)) * 10_000 / (rest + 1e36 / _notional(0)));
        vm.prank(admin);
        IPool(address(pool)).setGrailProbCap(shareAtCeiling + 1);
        assertTrue(_capExceeded(), "the GRAIL weight is above the cap");

        // Acquisitions open above the cap. The request expires so the board keeps its weight.
        warpPastCooldown(clone);
        uint256[] memory ids = _acquire(player, 1);
        expire(clone, ids[0]);
        pool.bookOnly(5);
        assertEq(clone.unsettledAcquisitionCount(), 0);
        assertTrue(_capExceeded());

        _warpToRotation();
        vm.recordLogs();
        vm.prank(keeper);
        pool.rotate();
        (uint256 listed,) = _countTrack(vm.getRecordedLogs(), IPoolTypes.GrailListed.selector, 0);
        assertEq(listed, 1);

        (uint256 price,) = _price(listingId);
        assertEq(_listing(0), listingId, "repriced in place");
        assertEq(_notional(0), price);
        assertGt(price, 0.03 ether, "lifted");
        assertLe(price, ceiling);
        assertFalse(_capExceeded(), "the cap holds at the lifted price");
        assertEq(_pulls(0), 0, "the lift restarts the count");

        // One wei lower would exceed the cap.
        uint256 lowerWeight = 1e36 / (price - 1);
        uint256 total = clone.totalWeight() - 1e36 / price + lowerWeight;
        assertGt(lowerWeight * 10_000, total * IPool(address(pool)).grailProbCapBps(), "the lifted price is the smallest admissible");
        _assertI1();
    }
}
