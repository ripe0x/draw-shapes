// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {Pool} from "../../src/Pool.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice Rotation, refund, GRAIL decay and liquidation rules against deployed Shapes, a Draw Packs
///         deployment and a FWA clone created by the pool.
/// @dev Mix: row 0 is a one rung Shape of 0.1 ETH (7,000 bps), row 1 is a two rung pack of
///      2 x 0.01 ETH (3,000 bps). `_openLarge` builds a board of 42 + 18 items. Both GRAIL steps
///      are 500 ETH, so `rotate` never grows a track. `_enableMinor` sets the minor track to step
///      0.05 ETH, target 0.05 ETH (one growth), list 80 percent (first price 0.04 ETH), decay
///      0.001 ETH per pull and floor 0.02 ETH.
contract PoolFixesForkTest is ForkBase, PoolFixture {
    PoolHarness internal pool;
    IFWAClone internal clone;
    address internal player = makeAddr("player");
    address internal keeper = makeAddr("keeper");
    address internal exiter = makeAddr("exiter");
    address internal saver = makeAddr("saver");
    uint256 internal mintFee;

    function setUp() public {
        setUpFork();
        openFactory();
        deployDrawPacks(admin);
        mintFee = shapes.mintFee();
        vm.deal(alice, 10_000 ether);
        pool = new PoolHarness(_fixtureParams());
        vm.prank(admin);
        pool.createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);
    }

    function _fixtureParams() internal returns (IPoolTypes.Params memory p) {
        p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
        p.minor = IPoolTypes.GrailParams({
            targetWei: 1_000 ether,
            stepWei: 500 ether,
            listBps: 8_000,
            decayWeiPerPull: 0.001 ether,
            floorWei: 0.02 ether
        });
        p.major = IPoolTypes.GrailParams({
            targetWei: 1_000 ether,
            stepWei: 500 ether,
            listBps: 9_000,
            decayWeiPerPull: 0.002 ether,
            floorWei: 0.3 ether
        });
    }

    // ---------------------------------------------------------------- helpers

    function _openLarge() internal {
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(pool.openingDeadlineAt());
        pool.recordPulls(60);
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
        assertEq(pool.listedCount(), 60);
        warpPastCooldown(clone);
    }

    function _warpToRotation() internal {
        uint256 at = pool.lastRotateAt() + pool.rotateInterval();
        if (block.timestamp < at) vm.warp(at);
    }

    function _acquire(address who, uint256 count) internal returns (uint256[] memory ids) {
        return acquirePooled(address(pool), clone, who, count);
    }

    /// @dev Pulls once and fulfills the request with the last listed Shape of row 0.
    function _captureShape() internal {
        uint256[] memory ids = _acquire(player, 1);
        uint256[] memory listed = pool.listedIds(0);
        fulfill(clone, ids[0], wordFor(clone, listed[listed.length - 1]));
    }

    /// @dev Moves forward to the end of the FWA purchase cooldown, never backward.
    function _pastCooldown() internal {
        uint256 at = clone.purchasesResumeAt() + 1;
        if (at > block.timestamp) vm.warp(at);
    }

    function _enableMinor() internal {
        vm.prank(admin);
        IPool(address(pool)).setGrail(0, 0.05 ether, 0.05 ether, 8_000, 0.001 ether, 0.02 ether);
    }

    function _grow(uint256 t) internal {
        _warpPastRotateGate(pool);
        vm.prank(keeper);
        pool.growGrail(uint8(t));
    }

    function _notional(uint256 t) internal view returns (uint256 v) {
        (,,, v,,,,,,,,) = pool.grail(t);
    }

    function _pulls(uint256 t) internal view returns (uint256 v) {
        (,,,,,,,,, v,,) = pool.grail(t);
    }

    function _packId(uint256 t) internal view returns (uint256 v) {
        (, v,,,,,,,,,,) = pool.grail(t);
    }

    function _listing(uint256 t) internal view returns (uint256 v) {
        (,,,,,,,,,,, v) = pool.grail(t);
    }

    function _price(uint256 listingId) internal view returns (uint256 price, IFWAClone.ListingStatus status) {
        (,,,,, price,, status) = clone.listings(listingId);
    }

    /// @dev Deposits `depositWei` as `exiter`, removes ordinary cash down to `cashLeft`, then
    ///      `exiter` withdraws every share. Returns the amount queued.
    function _queueClaim(uint256 depositWei, uint256 cashLeft) internal returns (uint256 queued) {
        vm.deal(exiter, depositWei);
        vm.prank(exiter);
        pool.deposit{value: depositWei}();
        pool.loseCash(pool.cash() - cashLeft);
        uint256 shares = pool.sharesOf(exiter);
        vm.prank(exiter);
        pool.withdraw(shares);
        queued = pool.claims();
    }

    struct Summary {
        uint256 liquidated;
        uint256 heldLiquidated;
        uint256 paid;
        uint256 refund;
    }

    function _summarize(Vm.Log[] memory logs) internal view returns (Summary memory s) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == IPoolTypes.Liquidated.selector) {
                ++s.liquidated;
                if (uint256(logs[i].topics[1]) == 0) ++s.heldLiquidated;
            } else if (topic == IPoolTypes.ClaimPaid.selector) {
                s.paid += abi.decode(logs[i].data, (uint256));
            } else if (topic == IPoolTypes.Rotated.selector) {
                (,, s.refund) = abi.decode(logs[i].data, (bool, bool, uint256));
            }
        }
    }

    function _rotate() internal returns (Summary memory s) {
        vm.recordLogs();
        vm.prank(keeper);
        pool.rotate();
        s = _summarize(vm.getRecordedLogs());
    }

    function _liquidate() internal returns (Summary memory s) {
        vm.recordLogs();
        vm.prank(keeper);
        pool.liquidate();
        s = _summarize(vm.getRecordedLogs());
    }

    // ---------------------------------------------------------------- A1: GRAIL parameters

    function test_revert_constructorGrailFloorZero() public {
        IPoolTypes.Params memory p = _fixtureParams();
        p.minor.floorWei = 0;
        vm.expectRevert(IPoolTypes.GrailFloorInvalid.selector);
        new PoolHarness(p);
    }

    function test_revert_constructorGrailFloorAboveTheListPriceAtFullBacking() public {
        IPoolTypes.Params memory p = _fixtureParams();
        p.major.targetWei = 10 ether;
        p.major.floorWei = 9 ether + 1;
        vm.expectRevert(IPoolTypes.GrailFloorInvalid.selector);
        new PoolHarness(p);

        p.major.floorWei = 9 ether;
        new PoolHarness(p);
    }

    function test_revert_constructorGrailStepBelowTwoUnits() public {
        IPoolTypes.Params memory p = _fixtureParams();
        p.minor.stepWei = 0.01 ether;
        vm.expectRevert(IPoolTypes.GrailStepInvalid.selector);
        new PoolHarness(p);
    }

    function test_rotateActivatesAStagedGrailListingBeforeRepricingIt() public {
        _openLarge();
        _enableMinor();
        _grow(0);
        uint256 pack = _packId(0);
        uint256 notional = _notional(0);
        assertEq(notional, 0.04 ether);

        // List the pack while an acquisition is unsettled: FWA stages the listing.
        pool.unlistGrail(0);
        warpPastCooldown(clone);
        uint256[] memory ids = _acquire(player, 1);
        vm.prank(address(pool));
        uint256 stagedId = clone.listNFT(address(drawPacks), pack, notional);
        (, IFWAClone.ListingStatus status) = _price(stagedId);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Staged), "staged behind the unsettled acquisition");
        pool.setGrailListing(0, pack, stagedId, notional);
        pool.recordPulls(10);

        uint256[] memory listed = pool.listedIds(0);
        fulfill(clone, ids[0], wordFor(clone, listed[listed.length - 1]));
        _warpToRotation();
        _rotate();

        uint256 price;
        (price, status) = _price(stagedId);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active), "activated by rotate");
        assertEq(price, 0.029 ether, "11 pulls at 0.001 ETH: 10 recorded and the booked pull");
        assertEq(_notional(0), 0.029 ether);
    }

    // ---------------------------------------------------------------- A2: refund gate

    function test_refundIsPaidOncePerRotateIntervalWhenEveryRotateBooks() public {
        _openLarge();
        pool.loseCash(pool.cash());
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        _warpToRotation();

        _captureShape();
        Summary memory first = _rotate();
        assertGt(first.refund, 0, "booking a capture pays the first refund");
        assertEq(pool.lastRefundAt(), block.timestamp);
        assertEq(pool.replacementLength(), 1, "replacement still waits for cash");

        _pastCooldown();
        _captureShape();
        uint256 maintenanceBefore = pool.maintenance();
        Summary memory second = _rotate();
        assertEq(second.refund, 0, "no second refund inside the interval");
        assertGe(pool.maintenance(), maintenanceBefore, "maintenance only grows");

        vm.warp(block.timestamp + pool.rotateInterval());
        _pastCooldown();
        _captureShape();
        Summary memory third = _rotate();
        assertGt(third.refund, 0, "a refund is due again after the interval");
        assertEq(pool.lastRefundAt(), block.timestamp);
    }

    // ---------------------------------------------------------------- A3: probability cap

    function test_decayThatWouldCrossTheProbabilityCapIsSkippedAndPullsKeepWorking() public {
        _openLarge();
        _enableMinor();
        _grow(0);
        uint256 listingId = _listing(0);
        _pastCooldown();
        uint256 weight = 1e36 / _notional(0);
        uint256 capBps = weight * 10_000 / clone.totalWeight() + 1;
        vm.prank(admin);
        IPool(address(pool)).setGrailProbCap(capBps);

        pool.recordPulls(100);
        assertEq(_pulls(0), 100);
        _warpToRotation();
        vm.recordLogs();
        _rotate();
        (uint256 price,) = _price(listingId);
        assertEq(price, 0.04 ether, "the reprice to the 0.02 ETH floor would exceed the cap");
        assertEq(_notional(0), 0.04 ether);
        assertEq(_pulls(0), 100, "pulls keep counting");

        _pastCooldown();
        _acquire(player, 1);

        vm.prank(admin);
        IPool(address(pool)).setGrailProbCap(10_000);
        vm.warp(block.timestamp + pool.rotateInterval());
        _pastCooldown();
        uint256[] memory listed = pool.listedIds(0);
        fulfill(clone, clone.requestIdAtSequence(clone.lastIssuedSequence()), wordFor(clone, listed[0]));
        _rotate();
        (price,) = _price(listingId);
        assertEq(price, 0.02 ether, "reprices once the cap allows it");
    }

    // ---------------------------------------------------------------- A4: claim age gate

    function test_rotatePaysAFreshClaimFromCashButLiquidatesOnlyOnceItIsOldEnough() public {
        _openLarge();
        _warpToRotation();
        uint256 queued = _queueClaim(8 ether, 0);
        assertGt(queued, 0.05 ether);
        vm.deal(saver, 1 ether);
        vm.prank(saver);
        pool.deposit{value: 0.05 ether}();
        uint256 listedBefore = pool.listedCount();

        Summary memory fresh = _rotate();

        assertEq(fresh.liquidated, 0, "a claim younger than rotateInterval is not liquidated");
        assertGt(fresh.paid, 0, "cash still pays it");
        assertEq(pool.listedCount(), listedBefore);
        assertGt(pool.claims(), 0);
        assertLt(pool.claims(), queued);

        vm.warp(block.timestamp + pool.rotateInterval());
        Summary memory old = _rotate();
        assertGt(old.liquidated, 0, "liquidated once the claim is old enough");
        assertEq(pool.claims(), 0);
    }

    // ---------------------------------------------------------------- A5: held items first

    function test_liquidationRedeemsHeldItemsBeforeListedOnesAndNeedsNoFwaCall() public {
        _openLarge();
        _captureShape();
        pool.settle(20);
        _pastCooldown();
        _acquire(player, 1);
        assertEq(pool.heldCount(), 1, "the second pull mints the replacement and holds it");
        assertEq(clone.unsettledAcquisitionCount(), 1, "FWA is busy");
        uint256 listedBefore = pool.listedCount();

        uint256 queued = _queueClaim(0.1 ether, 0);
        assertGt(queued, 0);
        assertLt(queued, 0.1 ether, "one Shape covers the claim");
        vm.warp(block.timestamp + pool.rotateInterval());

        Summary memory s = _liquidate();

        assertEq(s.liquidated, 1);
        assertEq(s.heldLiquidated, 1, "the held item went first");
        assertEq(pool.heldCount(), 0);
        assertEq(pool.listedCount(), listedBefore, "no listing was withdrawn");
        assertEq(pool.claims(), 0);
        assertEq(clone.unsettledAcquisitionCount(), 1, "still busy: no FWA call was needed");
    }

    // ---------------------------------------------------------------- A6: remainder below the mint fee

    function test_aRemainderBelowTheMintFeeLeavesListingsAlone() public {
        _openLarge();
        uint256 queued = _queueClaim(0.00045 ether, 0);
        assertGt(queued, 0);
        assertLe(queued, mintFee, "the claim does not exceed the mint fee of a Shape");
        vm.warp(block.timestamp + pool.rotateInterval());
        uint256 listedBefore = pool.listedCount();
        uint256 backingBefore = pool.backing();

        Summary memory s = _liquidate();

        assertEq(s.liquidated, 0);
        assertEq(pool.listedCount(), listedBefore);
        assertEq(pool.backing(), backingBefore);
        assertEq(pool.claims(), queued, "the claim waits for cash");

        pool.bookProceeds{value: queued}();
        pool.liquidate();
        assertEq(pool.claims(), 0, "cash pays it");
    }
}
