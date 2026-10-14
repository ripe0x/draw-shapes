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
///      2 x 0.01 ETH (3,000 bps). `_openLarge` builds a board of 42 + 18 items and empties the GRAIL
///      fund, so `rotate` has no GRAIL work. The opening five (5 ETH, listed at face) is GRAIL item 0:
///      decay 0.001 ETH per pull, floor 1 ETH.
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
        vm.prank(factory.owner());
        factory.setInventoryChangeCooldown(0);
        deployDrawPacks(admin);
        mintFee = shapes.mintFee();
        vm.deal(alice, 10_000 ether);
        pool = new PoolHarness(_fixtureParams());
        vm.prank(admin);
        IPool(address(pool)).createFwaPool(0);
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
    }

    // ---------------------------------------------------------------- helpers

    function _openLarge() internal {
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.sizeBoard(60);
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
        assertEq(pool.listedCount(), 60);
        pool.loseGrailFund(IPool(address(pool)).grail().fund);
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

    function _item() internal view returns (IPoolTypes.GrailItem memory) {
        return IPool(address(pool)).grailItems()[0];
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

    /// @dev Books the captures and harvests as `keeper`. The factory cooldown is nonzero, so
    ///      `settle` lists nothing.
    function _settle() internal {
        vm.prank(keeper);
        pool.settle(20);
    }

    function _rotate() internal returns (Summary memory s) {
        vm.recordLogs();
        vm.prank(keeper);
        pool.rotate();
        s = _summarize(vm.getRecordedLogs());
    }

    // ---------------------------------------------------------------- A1: GRAIL parameters

    function test_settleActivatesAStagedGrailListingAndRepricesIt() public {
        _openLarge();
        uint256 tokenId = _item().tokenId;
        uint256 notional = _item().notional;
        assertEq(notional, 5 ether);

        // List the item while an acquisition is unsettled: FWA stages the listing.
        pool.unlistGrail(0);
        warpPastCooldown(clone);
        uint256[] memory ids = _acquire(player, 1);
        vm.prank(address(pool));
        uint256 stagedId = clone.listNFT(SHAPES_ADDR, tokenId, notional);
        (, IFWAClone.ListingStatus status) = _price(stagedId);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Staged), "staged behind the unsettled acquisition");
        pool.setGrailListing(0, stagedId);
        pool.recordPulls(100);
        vm.prank(admin);
        IPool(address(pool)).setBatch(1, 1 hours);

        uint256[] memory listed = pool.listedIds(0);
        fulfill(clone, ids[0], wordFor(clone, listed[listed.length - 1]));
        _settle();

        uint256 price;
        (price, status) = _price(stagedId);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active), "activated by settle");
        assertEq(price, 4.899 ether, "101 pulls at 0.001 ETH: 100 recorded and the booked pull");
        assertEq(_item().notional, 4.899 ether);
        assertEq(_item().pullsSinceList, 0, "the reprice restarts the pull count");
    }

    // ---------------------------------------------------------------- A2: refund gate

    function test_refundIsPaidOncePerRotateIntervalWhenEveryRotateBooks() public {
        // A nonzero cooldown keeps settle from listing, so each replacement waits for a rotation.
        vm.prank(factory.owner());
        factory.setInventoryChangeCooldown(300);
        _openLarge();
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        _warpToRotation();

        _captureShape();
        _settle();
        Summary memory first = _rotate();
        assertGt(first.refund, 0, "relisting the replacement pays the first refund");
        assertEq(IPool(address(pool)).lastRefundAt(), block.timestamp);
        assertEq(pool.replacementLength(), 0, "replacement minted and listed");

        _pastCooldown();
        _captureShape();
        _settle();
        uint256 maintenanceBefore = pool.maintenance();
        vm.expectRevert(IPoolTypes.RotateTooSoon.selector);
        pool.rotate();
        assertEq(pool.maintenance(), maintenanceBefore, "a rejected rotate pays nothing");

        vm.warp(block.timestamp + pool.rotateInterval());
        _pastCooldown();
        _settle();
        Summary memory third = _rotate();
        assertGt(third.refund, 0, "a refund is due again after the interval");
        assertEq(IPool(address(pool)).lastRefundAt(), block.timestamp);
    }

    // ---------------------------------------------------------------- A3: probability cap

    function test_decayThatWouldCrossTheProbabilityCapIsSkippedAndPullsKeepWorking() public {
        _openLarge();
        uint256 listingId = _item().listingId;
        _pastCooldown();
        vm.prank(admin);
        IPool(address(pool)).setGrailProbCap(1);

        pool.recordPulls(100);
        assertEq(_item().pullsSinceList, 100);
        vm.prank(admin);
        IPool(address(pool)).setBatch(1, 1 hours);
        pool.pushReplacement(0);
        assertTrue(pool.settleDue() != IPoolTypes.SettleTrigger.None);
        _settle();
        (uint256 price,) = _price(listingId);
        assertEq(price, 5 ether, "the lower price would put the GRAIL weight above the cap");
        assertEq(_item().notional, 5 ether);
        assertEq(_item().pullsSinceList, 100, "pulls keep counting");

        vm.prank(admin);
        IPool(address(pool)).setGrailProbCap(10_000);
        pool.pushReplacement(0);
        assertTrue(pool.settleDue() != IPoolTypes.SettleTrigger.None, "the first settle listed the queue");
        _settle();
        (price,) = _price(listingId);
        assertEq(price, 4.9 ether, "reprices once the cap allows it");
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
        // A funded GRAIL step makes the rotation due while the claim is fresh.
        pool.addGrailFund{value: 5 ether}();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.GrailStep));

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
        uint256 heldId = mintShapes(address(pool), 0.1 ether, 1);
        pool.loseCash(0.1 ether);
        pool.addItem(SHAPES_ADDR, 0, heldId, 0.1 ether, 0);
        _acquire(player, 1);
        assertEq(pool.heldCount(), 1, "one Shape is held unlisted");
        assertEq(clone.unsettledAcquisitionCount(), 1, "FWA is busy");
        uint256 listedBefore = pool.listedCount();

        uint256 queued = _queueClaim(0.1 ether, 0);
        assertGt(queued, 0);
        assertLt(queued, 0.1 ether, "one Shape covers the claim");
        vm.warp(block.timestamp + pool.rotateInterval());

        Summary memory s = _rotate();

        assertEq(s.liquidated, 1);
        assertEq(s.heldLiquidated, 1, "the held item went first");
        assertEq(pool.heldCount(), 0);
        assertGe(pool.listedCount(), listedBefore, "no listing was withdrawn");
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

        Summary memory s = _rotate();

        assertEq(s.liquidated, 0);
        assertEq(pool.listedCount(), listedBefore);
        assertEq(pool.backing(), backingBefore);
        assertEq(pool.claims(), queued, "the claim waits for cash");

        pool.bookProceeds{value: queued}();
        pool.payClaims();
        assertEq(pool.claims(), 0, "cash pays it");
    }
}
