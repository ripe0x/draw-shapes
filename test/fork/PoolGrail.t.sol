// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice The GRAIL against deployed Shapes, a Draw Packs deployment and a FWA clone created by
///         the pool: fund credits, piece mints, the merge recipes, the opening five, cycles,
///         decay, capture and the busy rule.
/// @dev Launch-style parameters: target 25 ETH, list 75 percent, decay 0.001 ETH per pull, piece
///      floor 0.25 ETH, floor 1 ETH. Most tests open a pool with a 30 ETH deposit, whose 3.3 ETH
///      contribution is below the opening five, and then control the fund directly. The recipe
///      tests seed real tokens listed at FWA through `_seed` and let `rotate` merge them.
contract PoolGrailForkTest is ForkBase, PoolFixture {
    PoolHarness internal pool;
    IFWAClone internal clone;
    address internal player = makeAddr("player");
    address internal keeper = makeAddr("keeper");
    uint256 internal mintFee;

    function setUp() public {
        setUpFork();
        openFactory();
        vm.prank(factory.owner());
        factory.setInventoryChangeCooldown(0);
        deployDrawPacks(admin);
        mintFee = shapes.mintFee();
        vm.deal(alice, 10_000 ether);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ---------------------------------------------------------------- helpers

    function _deployPool(uint256 target) internal {
        IPoolTypes.Params memory p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
        p.grail.targetWei = target;
        pool = new PoolHarness(p);
        vm.prank(admin);
        IPool(address(pool)).createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);
    }

    /// @dev Deploys with `target`, deposits `depositWei`, opens and leaves the fund as the open left it.
    function _open(uint256 target, uint256 depositWei) internal {
        _deployPool(target);
        vm.prank(alice);
        pool.deposit{value: depositWei}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
        warpPastCooldown(clone);
    }

    /// @dev A pool with no opening five, target `target`, and an empty fund.
    function _openEmpty(uint256 target) internal {
        _open(target, 30 ether);
        assertEq(_items().length, 0, "no opening five below five pieces of fund");
        _setFund(0);
    }

    function _setFund(uint256 wei_) internal {
        uint256 fund = _fund();
        if (fund > wei_) pool.loseGrailFund(fund - wei_);
        else if (fund < wei_) pool.addGrailFund{value: wei_ - fund}();
    }

    function _fund() internal view returns (uint256) {
        return IPool(address(pool)).grail().fund;
    }

    function _g() internal view returns (IPoolTypes.Grail memory) {
        return IPool(address(pool)).grail();
    }

    function _items() internal view returns (IPoolTypes.GrailItem[] memory) {
        return IPool(address(pool)).grailItems();
    }

    function _pieceCost() internal view returns (uint256) {
        return 1 ether + mintFee;
    }

    function _warpToRotation() internal {
        uint256 at = pool.lastRotateAt() + pool.rotateInterval();
        if (vm.getBlockTimestamp() < at) vm.warp(at);
    }

    function _rotate() internal {
        _warpToRotation();
        vm.prank(keeper);
        pool.rotate();
    }

    /// @dev Rotates until `rotateDue` is `None`, at most `max` times. Returns the rotations run.
    function _rotateAll(uint256 max) internal returns (uint256 n) {
        while (n < max) {
            _warpToRotation();
            if (pool.rotateDue() == IPoolTypes.RotateTrigger.None) return n;
            vm.prank(keeper);
            pool.rotate();
            ++n;
        }
    }

    /// @dev Lists `id` of `coll` at FWA from the pool at `notional` and books it as a GRAIL item.
    function _list(address coll, uint256 id, uint256 backing_, uint256 notional) internal {
        vm.prank(address(pool));
        uint256 listingId = clone.listNFT(coll, id, notional);
        pool.addGrailItem(coll, id, backing_, notional, listingId, false);
    }

    /// @dev Mints a Shape of `value` to the pool and books it as a listed GRAIL item at `value`.
    function _seed(uint256 value) internal returns (uint256 id) {
        id = mintShapes(address(pool), value, 1);
        _list(SHAPES_ADDR, id, value, value);
    }

    /// @dev Builds a Draw Pack of the Shapes `values` owned by the pool and books it as a listed
    ///      GRAIL item.
    function _seedPack(uint256[] memory values) internal returns (uint256 packId) {
        uint256[] memory ids = new uint256[](values.length);
        uint256 total;
        for (uint256 i; i < values.length; ++i) {
            ids[i] = mintShapes(address(this), values[i], 1);
            total += values[i];
        }
        shapes.setApprovalForAll(address(drawPacks), true);
        packId = drawPacks.createPackTo(ids, new uint32[](9), address(pool));
        _list(address(drawPacks), packId, total, total);
    }

    function _seedPack25() internal returns (uint256) {
        uint256[] memory v = new uint256[](3);
        v[0] = 10 ether;
        v[1] = 10 ether;
        v[2] = 5 ether;
        return _seedPack(v);
    }

    function _price(uint256 listingId) internal view returns (uint256 price, IFWAClone.ListingStatus status) {
        (,,,,, price,, status) = clone.listings(listingId);
    }

    function _countBacking(uint256 backing_) internal view returns (uint256 n) {
        IPoolTypes.GrailItem[] memory items = _items();
        for (uint256 i; i < items.length; ++i) {
            if (items[i].backing == backing_) ++n;
        }
    }

    /// @dev Makes `settleDue` nonzero: `batchMin` 1 and one queued replacement.
    function _makeSettleDue() internal {
        vm.prank(admin);
        IPool(address(pool)).setBatch(1, 1 hours);
        if (pool.replacementLength() == 0) pool.pushReplacement(1);
        assertTrue(pool.settleDue() != IPoolTypes.SettleTrigger.None, "settle is due");
    }

    /// @dev One pooled acquisition fulfilled on the GRAIL item at `index`, then settled. Returns the
    ///      `GrailCaptured` backing and proceeds.
    function _captureItem(uint256 index) internal returns (uint256 backing_, uint256 proceeds) {
        warpPastCooldown(clone);
        uint256 listingId = _items()[index].listingId;
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        fulfill(clone, ids[0], wordFor(clone, listingId));
        vm.recordLogs();
        vm.prank(keeper);
        pool.settle(20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.GrailCaptured.selector) {
                (backing_, proceeds) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    function _assertI1() internal view {
        assertGe(address(pool).balance, pool.cash() + pool.maintenance() + _fund(), "I1");
    }

    // ---------------------------------------------------------------- fund credits

    function test_theEntryContributionGoesToTheFundInFull() public {
        _deployPool(25 ether);
        assertEq(_fund(), 0);
        uint256 contribution = pool.contributionFor(30 ether, 0);
        vm.prank(alice);
        pool.deposit{value: 30 ether}();
        assertEq(_fund(), contribution);
        assertGt(contribution, 0);
        _assertI1();
    }

    function test_fundGrailCreditsTheFund() public {
        _openEmpty(25 ether);
        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.GrailFunded(bob, 2 ether);
        vm.deal(bob, 2 ether);
        vm.prank(bob);
        IPool(address(pool)).fundGrail{value: 2 ether}();
        assertEq(_fund(), 2 ether);
        _assertI1();
    }

    function test_theFeedShareOfASettledCaptureReachesTheFund() public {
        _openEmpty(25 ether);
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        uint256[] memory listed = pool.listedIds(1);
        fulfill(clone, ids[0], wordFor(clone, listed[listed.length - 1]));
        vm.recordLogs();
        vm.prank(keeper);
        pool.settle(20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 feed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.MarginSplit.selector) {
                (,,, feed) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
        assertGt(feed, 0, "the pack capture left a feed share");
        assertEq(_fund(), feed, "harvest credited the feed share to the fund");
        assertEq(_g().receivable, 0);
        _assertI1();
    }

    // ---------------------------------------------------------------- mint

    function test_aPieceMintsWhenTheFundCoversItAndListsAtFace() public {
        _openEmpty(25 ether);
        _setFund(_pieceCost() - 1);
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None), "short by one wei");
        pool.addGrailFund{value: 1}();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.GrailStep));

        vm.expectEmit(false, false, false, false, address(pool));
        emit IPoolTypes.GrailMinted(0, 1, _pieceCost());
        _rotate();

        assertEq(_fund(), 0, "the piece and its mint fee left the fund");
        IPoolTypes.GrailItem memory it = _items()[0];
        assertEq(_items().length, 1);
        assertEq(it.collection, SHAPES_ADDR);
        assertEq(it.backing, 1 ether);
        assertEq(it.notional, 1 ether, "listed at face");
        assertFalse(it.done);
        assertEq(shapes.backingOf(it.tokenId), 1 ether);
        assertEq(shapes.ownerOf(it.tokenId), address(clone));
        (uint256 price, IFWAClone.ListingStatus status) = _price(it.listingId);
        assertEq(price, 1 ether);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active));
        assertTrue(IPool(address(pool)).registered(SHAPES_ADDR, it.tokenId));
        assertEq(pool.lastRotateAt(), vm.getBlockTimestamp(), "a mint is an inventory change");
        _assertI1();
    }

    function test_atMostThreePiecesMintPerRotate() public {
        _openEmpty(25 ether);
        _setFund(10 * _pieceCost());
        _rotate();
        assertEq(_items().length, 3);
        assertEq(_fund(), 7 * _pieceCost());
        _rotate();
        assertEq(_items().length, 2, "three more pieces made six and five of them merged");
        assertEq(_countBacking(1 ether), 1);
        assertEq(_countBacking(5 ether), 1);
        assertEq(_fund(), 4 * _pieceCost());
    }

    function test_mintStopsAtSixPieces() public {
        _openEmpty(25 ether);
        for (uint256 i; i < 6; ++i) {
            pool.addGrailItem(SHAPES_ADDR, 9_000_000 + i, 1 ether, 1 ether, 9_000_000 + i, true);
        }
        _setFund(10 * _pieceCost());
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None), "six pieces exist");
    }

    function test_mintStopsAtSixteenItems() public {
        _openEmpty(25 ether);
        for (uint256 i; i < 16; ++i) {
            pool.addGrailItem(SHAPES_ADDR, 9_000_000 + i, 5 ether, 3.75 ether, 9_000_000 + i, true);
        }
        _setFund(10 * _pieceCost());
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None), "sixteen items exist");
    }

    function test_grailStepWaitsWhileAnAcquisitionIsUnsettled() public {
        _openEmpty(25 ether);
        _setFund(3 * _pieceCost());
        acquirePooled(address(pool), clone, player, 1);
        assertEq(clone.unsettledAcquisitionCount(), 1);
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None), "busy");
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();
        vm.expectRevert(IPoolTypes.FwaBusy.selector);
        pool.stepGrail();
        assertEq(_items().length, 0);
        assertEq(_fund(), 3 * _pieceCost());
    }

    // ---------------------------------------------------------------- merge recipes

    function test_fivePiecesMergeIntoAFiveAndASixthPieceStaysListed() public {
        _openEmpty(25 ether);
        uint256[] memory pieceIds = new uint256[](6);
        for (uint256 i; i < 6; ++i) {
            pieceIds[i] = _seed(1 ether);
        }
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.GrailStep), "a recipe is ready");

        _rotate();

        assertEq(_items().length, 2, "five pieces became one item");
        assertEq(_countBacking(1 ether), 1, "a sixth piece stays");
        assertEq(_countBacking(5 ether), 1);
        IPoolTypes.GrailItem memory five = _items()[_items()[0].backing == 5 ether ? 0 : 1];
        assertEq(five.collection, SHAPES_ADDR);
        assertEq(shapes.backingOf(five.tokenId), 5 ether);
        assertEq(five.notional, 3.75 ether, "backing at listBps");
        assertFalse(five.done, "a 5 ETH item is not the 25 ETH target");
        (uint256 price, IFWAClone.ListingStatus status) = _price(five.listingId);
        assertEq(price, 3.75 ether);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active));
        assertEq(_g().cycleId, 1);
        uint256 burned;
        for (uint256 i; i < 6; ++i) {
            if (!shapes.exists(pieceIds[i])) ++burned;
        }
        assertEq(burned, 4, "four pieces were burned into the survivor");
    }

    function test_exactlyFivePiecesMerge() public {
        _openEmpty(25 ether);
        for (uint256 i; i < 5; ++i) {
            _seed(1 ether);
        }
        _rotate();
        assertEq(_items().length, 1);
        assertEq(_items()[0].backing, 5 ether);
    }

    function test_fourPiecesDoNotMerge() public {
        _openEmpty(25 ether);
        for (uint256 i; i < 4; ++i) {
            _seed(1 ether);
        }
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None));
    }

    function test_twoFivesMergeIntoATen() public {
        _openEmpty(25 ether);
        _seed(5 ether);
        _seed(5 ether);
        _rotate();
        assertEq(_items().length, 1);
        IPoolTypes.GrailItem memory ten = _items()[0];
        assertEq(ten.backing, 10 ether);
        assertEq(ten.collection, SHAPES_ADDR);
        assertEq(shapes.backingOf(ten.tokenId), 10 ether);
        assertEq(ten.notional, 7.5 ether);
    }

    function test_twoTensAndAFiveMergeIntoA25DrawPack() public {
        _openEmpty(25 ether);
        _seed(10 ether);
        _seed(10 ether);
        _seed(5 ether);
        _seed(5 ether);
        _rotate();
        assertEq(_items().length, 2, "the second five stays");
        assertEq(_countBacking(5 ether), 1);
        IPoolTypes.GrailItem memory pack;
        for (uint256 i; i < 2; ++i) {
            if (_items()[i].backing == 25 ether) pack = _items()[i];
        }
        assertEq(pack.collection, address(drawPacks));
        assertEq(drawPacks.valueOf(pack.tokenId), 25 ether);
        assertEq(drawPacks.ownerOf(pack.tokenId), address(clone));
        assertEq(pack.notional, 18.75 ether);
        assertTrue(pack.done, "25 ETH is the cycle target");
        assertEq(drawPacks.contentsOf(pack.tokenId).length, 3);
        assertEq(_g().cycleId, 2, "the cycle completed");
    }

    function test_twoPacksOf25ComposeIntoA50Shape() public {
        _openEmpty(50 ether);
        _seedPack25();
        _seedPack25();
        _rotate();
        assertEq(_items().length, 1);
        IPoolTypes.GrailItem memory fifty = _items()[0];
        assertEq(fifty.backing, 50 ether);
        assertEq(fifty.collection, SHAPES_ADDR);
        assertEq(shapes.backingOf(fifty.tokenId), 50 ether);
        assertEq(fifty.notional, 37.5 ether);
        assertTrue(fifty.done);
        assertEq(_g().cycleId, 2);
    }

    function test_twoFiftiesComposeIntoA100Shape() public {
        _openEmpty(100 ether);
        _seed(50 ether);
        _seed(50 ether);
        _rotate();
        assertEq(_items().length, 1);
        IPoolTypes.GrailItem memory hundred = _items()[0];
        assertEq(hundred.backing, 100 ether);
        assertEq(shapes.backingOf(hundred.tokenId), 100 ether);
        assertEq(hundred.notional, 75 ether);
        assertTrue(hundred.done);
    }

    function test_aRecipeLargerThanTheTargetDoesNotRun() public {
        _openEmpty(10 ether);
        _seed(10 ether);
        _seed(10 ether);
        _seed(5 ether);
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None), "25 ETH exceeds the 10 ETH target");
    }

    function test_aMergeWaitsWhileAnAcquisitionIsUnsettled() public {
        _openEmpty(25 ether);
        for (uint256 i; i < 5; ++i) {
            _seed(1 ether);
        }
        acquirePooled(address(pool), clone, player, 1);
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None), "busy");
        vm.expectRevert(IPoolTypes.FwaBusy.selector);
        pool.stepGrail();
        assertEq(_items().length, 5);
    }

    function test_aTenFundedPieceCycleRunsFromFundToCompletion() public {
        _openEmpty(10 ether);
        _setFund(10 * _pieceCost());
        uint256 rotations = _rotateAll(10);
        assertGt(rotations, 1);
        assertEq(_items().length, 1);
        IPoolTypes.GrailItem memory ten = _items()[0];
        assertEq(ten.backing, 10 ether);
        assertTrue(ten.done);
        assertEq(_fund(), 0);
        assertEq(_g().cycleId, 2);
        _assertI1();
    }

    // ---------------------------------------------------------------- cycles

    function test_theCycleCompletesAtTheTargetAndTheNextTargetComesFromNextTargetWei() public {
        _openEmpty(5 ether);
        vm.prank(admin);
        IPool(address(pool)).setGrailTarget(10 ether);
        assertEq(_g().targetWei, 5 ether, "the running cycle keeps its target");
        for (uint256 i; i < 5; ++i) {
            _seed(1 ether);
        }

        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.GrailCycleCompleted(1, 10 ether);
        _rotate();

        IPoolTypes.Grail memory g = _g();
        assertEq(g.cycleId, 2);
        assertEq(g.targetWei, 10 ether);
        assertEq(g.nextTargetWei, 10 ether);
        assertTrue(_items()[0].done);
    }

    function test_aCompletedGrailStaysListedWhilePiecesKeepMinting() public {
        _openEmpty(5 ether);
        for (uint256 i; i < 5; ++i) {
            _seed(1 ether);
        }
        _rotate();
        IPoolTypes.GrailItem memory completed = _items()[0];
        assertTrue(completed.done);
        assertEq(_g().cycleId, 2);

        _setFund(3 * _pieceCost());
        _rotate();

        assertEq(_items().length, 4, "three pieces joined the completed GRAIL");
        assertEq(_items()[0].tokenId, completed.tokenId);
        (, IFWAClone.ListingStatus status) = _price(completed.listingId);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active), "still listed");
    }

    function test_aCompletedGrailIsNotAMergeInput() public {
        _openEmpty(5 ether);
        vm.prank(admin);
        IPool(address(pool)).setGrailTarget(10 ether);
        for (uint256 i; i < 5; ++i) {
            _seed(1 ether);
        }
        _rotate();
        uint256 completedId = _items()[0].tokenId;
        assertTrue(_items()[0].done);

        _seed(5 ether);
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None), "the completed five is not an input");

        _seed(5 ether);
        _rotate();
        assertEq(_countBacking(10 ether), 1, "the two new fives merged");
        assertEq(_countBacking(5 ether), 1);
        assertTrue(shapes.exists(completedId), "the completed five stayed");
        assertEq(_g().cycleId, 3, "and the 10 ETH item completed the second cycle");
    }

    // ---------------------------------------------------------------- opening five

    function test_openFormsTheOpeningFiveListedAtFace() public {
        _deployPool(25 ether);
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        uint256 contribution = _fund();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.open();

        IPoolTypes.GrailItem[] memory items = _items();
        assertEq(items.length, 1);
        assertEq(items[0].collection, SHAPES_ADDR);
        assertEq(items[0].backing, 5 ether);
        assertEq(items[0].notional, 5 ether, "listed at face");
        assertEq(shapes.backingOf(items[0].tokenId), 5 ether);
        assertEq(shapes.ownerOf(items[0].tokenId), address(clone));
        (uint256 price, IFWAClone.ListingStatus status) = _price(items[0].listingId);
        assertEq(price, 5 ether);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active));
        assertEq(_fund(), contribution - 5 * _pieceCost(), "five pieces and their mint fees");
        assertEq(_g().cycleId, 1);
        assertFalse(items[0].done);
        _assertI1();
    }

    function test_openFormsNoOpeningFiveBelowFivePiecesOfFund() public {
        _deployPool(25 ether);
        vm.prank(alice);
        pool.deposit{value: 30 ether}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.open();
        assertEq(_items().length, 0);
    }

    // ---------------------------------------------------------------- decay

    function test_aPieceDecaysFromTheFaceToThePieceFloor() public {
        _openEmpty(25 ether);
        _setFund(_pieceCost());
        _rotate();
        _makeSettleDue();
        uint256 listingId = _items()[0].listingId;

        pool.recordPulls(9);
        pool.settle(20);
        assertEq(_items()[0].notional, 1 ether, "9 pulls decay 0.009 ETH, under 1 percent");
        assertEq(_items()[0].pullsSinceList, 9);

        pool.recordPulls(1);
        pool.pushReplacement(1);
        pool.settle(20);
        assertEq(_items()[0].notional, 0.99 ether, "10 pulls reach 1 percent");
        assertEq(_items()[0].pullsSinceList, 0, "the reprice restarts the count");
        (uint256 price,) = _price(listingId);
        assertEq(price, 0.99 ether);

        vm.prank(admin);
        IPool(address(pool)).setGrailProbCap(10_000);
        pool.recordPulls(1_000_000);
        pool.pushReplacement(1);
        pool.settle(20);
        assertEq(_items()[0].notional, 0.25 ether, "stops at the piece floor");
        (price,) = _price(listingId);
        assertEq(price, 0.25 ether);
    }

    function test_aLargerItemDecaysToTheFloorNotThePieceFloor() public {
        _openEmpty(25 ether);
        _seed(5 ether);
        _makeSettleDue();
        vm.prank(admin);
        IPool(address(pool)).setGrailProbCap(10_000);

        pool.recordPulls(1_000_000);
        pool.settle(20);

        assertEq(_items()[0].notional, 1 ether, "floorWei, not pieceFloorWei");
    }

    function test_eachItemDecaysByItsOwnPullCount() public {
        _openEmpty(25 ether);
        _seed(1 ether);
        pool.recordPulls(30);
        _seed(5 ether);
        _makeSettleDue();

        pool.settle(20);

        assertEq(_items()[0].notional, 0.97 ether, "30 pulls on the older piece");
        assertEq(_items()[1].notional, 5 ether, "no pulls on the new item");
        assertEq(_items()[0].pullsSinceList, 0);
    }

    // ---------------------------------------------------------------- capture

    function test_capturingAPieceBooksTheReceivableAndHarvestCreditsTheFund() public {
        _openEmpty(25 ether);
        _setFund(_pieceCost());
        _rotate();
        uint256 fundBefore = _fund();
        assertEq(_items().length, 1);
        uint256 listingId = _items()[0].listingId;

        (uint256 backing_, uint256 proceeds) = _captureItem(0);

        assertEq(backing_, 1 ether);
        assertGt(proceeds, 0);
        assertEq(_items().length, 0, "the item left grailItems");
        assertEq(_g().receivable, 0, "harvested");
        assertEq(_fund(), fundBefore + proceeds, "the proceeds reached the fund");
        assertEq(_g().cycleId, 1, "the cycle keeps running");
        (, IFWAClone.ListingStatus status) = _price(listingId);
        assertTrue(status != IFWAClone.ListingStatus.Active);
        _assertI1();
    }

    function test_capturingTheCompletedGrailBooksItsProceedsAndTheNextCycleContinues() public {
        _openEmpty(5 ether);
        for (uint256 i; i < 5; ++i) {
            _seed(1 ether);
        }
        _rotate();
        assertTrue(_items()[0].done);
        uint256 fundBefore = _fund();

        (uint256 backing_, uint256 proceeds) = _captureItem(0);

        assertEq(backing_, 5 ether);
        assertGt(proceeds, 0);
        assertEq(_items().length, 0);
        assertEq(_fund(), fundBefore + proceeds);
        assertEq(_g().cycleId, 2, "the next cycle was already running");
        _assertI1();
    }

    function test_capturingAnIntermediateLeavesTheCycleRunning() public {
        _openEmpty(25 ether);
        _seed(5 ether);
        _seed(10 ether);
        IPoolTypes.Grail memory before_ = _g();

        _captureItem(0);

        assertEq(_items().length, 1);
        assertEq(_items()[0].backing, 10 ether);
        IPoolTypes.Grail memory after_ = _g();
        assertEq(after_.cycleId, before_.cycleId);
        assertEq(after_.targetWei, before_.targetWei);
        _assertI1();
    }

    function test_aRefundedDeliveryLeavesTheItemUnlistedAndRotateListsItAgain() public {
        _openEmpty(25 ether);
        _seed(5 ether);
        IPoolTypes.GrailItem memory it = _items()[0];
        pool.unlistGrail(0);
        assertEq(_items()[0].listingId, 0);
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.GrailStep));

        _rotate();

        assertTrue(_items()[0].listingId != 0, "listed again");
        assertEq(_items()[0].notional, it.notional);
        (, IFWAClone.ListingStatus status) = _price(_items()[0].listingId);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active));
    }

    /// @dev A retired FWA clone rejects `listNFT`, so the relist inside `grailStep` reverts.
    function test_rotateSkipsAFailingGrailStep() public {
        _openEmpty(25 ether);
        _seed(5 ether);
        pool.unlistGrail(0);

        uint256 shares = pool.sharesOf(alice);
        vm.prank(alice);
        pool.withdraw(shares);
        uint256 queued = pool.claims();
        assertGt(queued, 0, "claim queued");
        vm.deal(player, 10 ether);
        vm.prank(player);
        pool.deposit{value: 10 ether}();

        vm.prank(address(pool));
        clone.retirePool();
        vm.warp(vm.getBlockTimestamp() + pool.rotateInterval());
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.Claim));

        vm.recordLogs();
        vm.prank(keeper);
        pool.rotate();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 skipped;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.GrailStepSkipped.selector) {
                ++skipped;
                assertTrue(abi.decode(logs[i].data, (bytes4)) != bytes4(0), "revert selector reported");
                emit log_named_bytes("skipped selector", abi.encodePacked(abi.decode(logs[i].data, (bytes4))));
            }
        }
        assertEq(skipped, 1, "GrailStepSkipped emitted once");

        assertLt(pool.claims(), queued, "the claim was paid by the same rotate");
        assertEq(_items()[0].listingId, 0, "the item stays unlisted");
        _assertI1();
    }
}
