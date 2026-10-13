// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Pool} from "../../src/Pool.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";

/// @notice Retirement and migration (`startExit`, `exportStep`, `transferGrailEstate`, the import
///         functions and `migrateHolder`) against deployed Shapes, a Draw Packs deployment and FWA
///         clones created by the pools.
/// @dev Mix: row 0 is a one rung Shape of 0.1 ETH (7,000 bps), row 1 is a two rung pack of
///      2 x 0.01 ETH (3,000 bps). `recordPulls(60)` before `open` builds a board of 42 + 18 items.
///      Pool A holds two depositors, two captures, one replacement held unlisted and a listed pack
///      on each GRAIL track. Minor track: step 0.05 ETH, list 80 percent. Major track: step 0.15 ETH,
///      list 90 percent.
contract PoolExitForkTest is ForkBase, PoolFixture {
    struct Token {
        address collection;
        uint256 id;
        uint256 value;
    }

    PoolHarness internal pool;
    IFWAClone internal clone;
    PoolHarness internal succ;
    IFWAClone internal succClone;
    address internal player = makeAddr("player");
    address internal keeper = makeAddr("keeper");
    address internal estate = makeAddr("estate");
    address internal stranger = makeAddr("stranger");
    address internal holderOne = makeAddr("holderOne");
    address internal holderTwo = makeAddr("holderTwo");
    address internal carol = makeAddr("carol");
    uint256 internal mintFee;

    function setUp() public {
        setUpFork();
        openFactory();
        deployDrawPacks(admin);
        mintFee = shapes.mintFee();
        (pool, clone) = _deployPool(address(0));
    }

    // ---------------------------------------------------------------- helpers

    function _forkParams(address oldPool_) internal returns (Pool.Params memory p) {
        p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.oldPool = oldPool_;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
        p.minor = Pool.GrailParams({
            targetWei: 0.5 ether, stepWei: 0.05 ether, listBps: 8_000, decayWeiPerPull: 0.001 ether, floorWei: 0.1 ether
        });
        p.major = Pool.GrailParams({
            targetWei: 1 ether, stepWei: 0.15 ether, listBps: 9_000, decayWeiPerPull: 0.002 ether, floorWei: 0.3 ether
        });
    }

    function _deployPool(address oldPool_) internal returns (PoolHarness p_, IFWAClone c_) {
        p_ = new PoolHarness(_forkParams(oldPool_));
        vm.prank(admin);
        p_.createFwaPool(0);
        c_ = p_.fwaPool();
        vm.prank(address(p_));
        c_.setBool(41, true);
    }

    function _deposit(PoolHarness p_, address who, uint256 value) internal {
        vm.deal(who, who.balance + value);
        vm.prank(who);
        p_.deposit{value: value}();
    }

    function _open(PoolHarness p_, IFWAClone c_) internal {
        vm.warp(p_.openingDeadlineAt());
        while (p_.lifecycle() == Pool.Lifecycle.Opening) p_.open();
        warpPastCooldown(c_);
    }

    function _grail(PoolHarness p_, uint256 t)
        internal
        view
        returns (uint256 bucket, uint256 packId, uint256 backing_, uint256 notional, uint256 listingId)
    {
        (bucket, packId, backing_, notional,,,,,,,, listingId) = p_.grail(t);
    }

    function _pullAs(address who, uint256 count) internal returns (uint256[] memory ids) {
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(count);
        vm.deal(who, who.balance + total);
        uint64 last = clone.lastIssuedSequence();
        vm.prank(who);
        pool.pull{value: total}(count, fee, block.timestamp + 1 hours);
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = clone.requestIdAtSequence(last + 1 + uint64(i));
        }
    }

    /// @dev Pulls one acquisition and fulfills it with the last listed ordinary item of `row`.
    function _captureRow(uint256 row) internal {
        uint256[] memory ids = _pullAs(player, 1);
        uint256[] memory listed = pool.listedIds(row);
        fulfill(clone, ids[0], wordFor(clone, listed[listed.length - 1]));
        pool.settle(20);
    }

    /// @dev Pool A: two depositors, a 60 item board, a listed pack on both GRAIL tracks, two
    ///      settled captures and one replacement held unlisted.
    function _buildA() internal {
        _deposit(pool, holderOne, 100 ether);
        _deposit(pool, holderTwo, 50 ether);
        vm.warp(pool.openingDeadlineAt());
        pool.recordPulls(60);
        _open(pool, clone);
        assertEq(pool.listedCount(), 60, "board");

        pool.growGrail(0);
        pool.growGrail(1);
        warpPastCooldown(clone);

        _captureRow(0);
        _captureRow(1);
        assertEq(pool.listedCount(), 58, "two captures");
        assertEq(pool.heldCount(), 1, "the first replacement is minted by the second pull and held");
        pool.harvest();
        pool.setMaintenance(pool.maintenance() + 1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        assertEq(pool.receivable(), 0);
    }

    /// @dev Pool B as successor of A with one native depositor, opened with a 10 item board.
    function _buildB() internal {
        (succ, succClone) = _deployPool(address(pool));
        _deposit(succ, carol, 20 ether);
        _open(succ, succClone);
        assertEq(succ.listedCount(), 10, "successor board");
    }

    function _tokens(PoolHarness p_, IFWAClone c_) internal view returns (Token[] memory out) {
        uint256 n = p_.listedCount() + p_.heldCount();
        out = new Token[](n);
        uint256 k;
        uint256 next = c_.nextListingId();
        for (uint256 id = 1; id < next; ++id) {
            Pool.Item memory it = p_.listedItem(id);
            if (it.value != 0) out[k++] = Token(it.collection, it.tokenId, it.value);
        }
        for (uint256 i; i < p_.heldCount(); ++i) {
            Pool.Item memory it = p_.heldItem(i);
            out[k++] = Token(it.collection, it.tokenId, it.value);
        }
        assertEq(k, n, "enumerated every item");
    }

    function _assertI1(PoolHarness p_) internal view {
        (uint256 minorBucket,,,,) = _grail(p_, 0);
        (uint256 majorBucket,,,,) = _grail(p_, 1);
        assertGe(address(p_).balance, p_.cash() + p_.maintenance() + minorBucket + majorBucket, "I1");
    }

    function _exportAll(PoolHarness p_, uint256 perCall) internal returns (uint256 calls) {
        bool done;
        while (!done) {
            done = p_.exportStep(perCall);
            ++calls;
            assertLt(calls, 50, "export terminates");
        }
    }

    /// @dev Queues a withdrawal claim: removes ordinary cash down to 0.5 ETH and withdraws half of
    ///      `holderOne`'s shares.
    function _queueClaim() internal returns (uint256 queued) {
        pool.loseCash(pool.cash() - 0.5 ether);
        uint256 shares = pool.sharesOf(holderOne) / 2;
        vm.prank(holderOne);
        pool.withdraw(shares);
        queued = pool.claims();
        assertGt(queued, 0, "claim queued");
        assertEq(pool.cash(), 0, "cash paid out");
    }

    // ---------------------------------------------------------------- startExit

    function test_revert_startExitNotAdmin() public {
        _buildA();
        vm.expectRevert(Pool.NotAdmin.selector);
        pool.startExit(address(pool));
    }

    function test_revert_startExitWithoutFwaPool() public {
        PoolHarness fresh = new PoolHarness(_forkParams(address(0)));
        vm.prank(admin);
        vm.expectRevert(Pool.FwaPoolMissing.selector);
        fresh.startExit(address(fresh));
    }

    function test_revert_startExitToAPoolWithAnotherOldPool() public {
        _buildA();
        PoolHarness other = new PoolHarness(_forkParams(address(0)));
        vm.prank(admin);
        vm.expectRevert(Pool.InvalidDest.selector);
        pool.startExit(address(other));
    }

    function test_revert_startExitToAnAddressWithoutCode() public {
        _buildA();
        vm.prank(admin);
        vm.expectRevert();
        pool.startExit(stranger);
    }

    function test_revert_startExitTwice() public {
        _buildA();
        vm.startPrank(admin);
        pool.startExit(address(pool));
        vm.expectRevert(Pool.PoolExiting.selector);
        pool.startExit(address(pool));
        vm.stopPrank();
    }

    function test_startExitInOpeningClosesDeposits() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(pool));
        emit Pool.ExitStarted(address(pool));
        pool.startExit(address(pool));
        assertEq(uint8(pool.lifecycle()), uint8(Pool.Lifecycle.Exiting));
        assertEq(pool.exitDest(), address(pool));

        vm.deal(holderOne, 1 ether);
        vm.prank(holderOne);
        vm.expectRevert(Pool.PoolExiting.selector);
        pool.deposit{value: 1 ether}();
        vm.expectRevert(Pool.PoolExiting.selector);
        pool.open();
    }

    function test_revert_exportStepBeforeStartExit() public {
        _buildA();
        vm.expectRevert(Pool.NotExiting.selector);
        pool.exportStep(10);
    }

    // ---------------------------------------------------------------- retirement

    function test_retirementClosesPlayerAndRotationPaths() public {
        _buildA();
        vm.prank(admin);
        pool.startExit(address(pool));

        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        vm.deal(player, total + 1 ether);
        vm.startPrank(player);
        vm.expectRevert(Pool.PoolExiting.selector);
        pool.pull{value: total}(1, fee, block.timestamp + 1 hours);
        uint256[] memory none = new uint256[](0);
        vm.expectRevert(Pool.PoolExiting.selector);
        pool.pullWithShapes(none, 1, fee, block.timestamp + 1 hours);
        vm.expectRevert(Pool.PoolExiting.selector);
        pool.deposit{value: 1 ether}();
        vm.expectRevert(Pool.PoolExiting.selector);
        pool.redeemAndDeposit(1);
        vm.stopPrank();

        vm.warp(pool.lastRotateAt() + pool.rotateInterval());
        vm.expectRevert(Pool.PoolExiting.selector);
        pool.rotate();
        vm.expectRevert(Pool.PoolExiting.selector);
        pool.growGrail(0);
        vm.expectRevert(Pool.PoolExiting.selector);
        pool.open();
    }

    function test_revert_exportStepWhileAnAcquisitionIsUnsettled() public {
        _buildA();
        uint256[] memory ids = _pullAs(player, 1);
        assertEq(clone.unsettledAcquisitionCount(), 1);
        vm.prank(admin);
        pool.startExit(address(pool));

        vm.expectRevert(Pool.FwaBusy.selector);
        pool.exportStep(10);

        uint256[] memory listed = pool.listedIds(0);
        fulfill(clone, ids[0], wordFor(clone, listed[0]));
        pool.exportStep(1);
        // 58 listed and 2 held items, minus the booked capture, minus the one item moved.
        assertEq(pool.listedCount() + pool.heldCount(), 58, "the capture was booked and one item moved");
    }

    function test_retirementRedeemsEveryItemIntoCash() public {
        _buildA();
        uint256 value = pool.backing();
        uint256 cashBefore = pool.cash();
        uint256 maintenanceBefore = pool.maintenance();
        (uint256 minorBucket, uint256 minorPack,, uint256 minorNotional, uint256 minorListing) = _grail(pool, 0);
        (uint256 majorBucket, uint256 majorPack,,, uint256 majorListing) = _grail(pool, 1);
        uint256 shares = pool.totalShares();
        uint256 navBefore = pool.nav();
        Token[] memory tokens = _tokens(pool, clone);
        assertEq(tokens.length, 59);

        vm.prank(admin);
        pool.startExit(address(pool));
        assertEq(uint8(pool.lifecycle()), uint8(Pool.Lifecycle.Exiting));

        assertFalse(pool.exportStep(20), "first call stops at the budget");
        assertEq(pool.listedCount() + pool.heldCount(), 39);
        assertFalse(pool.exportStep(20));
        assertEq(pool.listedCount() + pool.heldCount(), 19);
        assertEq(uint8(pool.lifecycle()), uint8(Pool.Lifecycle.Exiting));
        assertEq(pool.exportedShares(), 0, "nothing recorded before the last item");
        assertTrue(pool.exportStep(20));

        assertEq(pool.backing(), 0, "backing");
        assertEq(pool.listedCount(), 0);
        assertEq(pool.heldCount(), 0);
        assertEq(pool.cash(), cashBefore + value + maintenanceBefore, "redeemed values and maintenance joined cash");
        assertEq(pool.maintenance(), 0);
        assertEq(uint8(pool.lifecycle()), uint8(Pool.Lifecycle.Exported));
        assertTrue(clone.retired(), "FWA pool retired");
        assertEq(pool.exportedShares(), shares);
        assertEq(pool.exportedNav(), navBefore + maintenanceBefore, "exported NAV is ordinary NAV plus maintenance");
        assertEq(pool.nav(), pool.cash());
        assertEq(clone.activeListingCount(), 2, "only the GRAIL listings remain at FWA");

        (uint256 bucket0, uint256 pack0,, uint256 notional0, uint256 listing0) = _grail(pool, 0);
        (uint256 bucket1, uint256 pack1,,, uint256 listing1) = _grail(pool, 1);
        assertEq(bucket0, minorBucket);
        assertEq(pack0, minorPack);
        assertEq(notional0, minorNotional);
        assertEq(listing0, minorListing);
        assertEq(bucket1, majorBucket);
        assertEq(pack1, majorPack);
        assertEq(listing1, majorListing);
        assertEq(drawPacks.ownerOf(minorPack), address(clone), "GRAIL pack untouched");
        _assertI1(pool);
    }

    function test_exportMovesListingsMadeWhileAcquisitionsWereUnsettled() public {
        _buildA();
        uint256[] memory ids = _pullAs(player, 1);
        vm.warp(pool.lastRotateAt() + pool.rotateInterval());
        vm.prank(keeper);
        pool.rotate();
        assertEq(pool.heldCount(), 0, "held items listed");
        uint256 stagedListing = clone.nextListingId() - 1;
        (,,,,,,, IFWAClone.ListingStatus status) = clone.listings(stagedListing);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Staged), "listed behind an unsettled acquisition");

        uint256[] memory listed = pool.listedIds(0);
        fulfill(clone, ids[0], wordFor(clone, listed[0]));
        vm.prank(admin);
        pool.startExit(address(pool));
        _exportAll(pool, 100);

        assertEq(uint8(pool.lifecycle()), uint8(Pool.Lifecycle.Exported));
        assertEq(pool.backing(), 0);
        assertEq(pool.listedCount(), 0);
    }

    function test_retirementHoldersWithdrawTheirShareOfCash() public {
        _buildA();
        vm.prank(admin);
        pool.startExit(address(pool));
        _exportAll(pool, 25);

        uint256 cashAll = pool.cash();
        uint256 supply = pool.totalShares();
        uint256 one = pool.sharesOf(holderOne);
        uint256 two = pool.sharesOf(holderTwo);
        vm.prank(holderOne);
        pool.withdraw(one);
        vm.prank(holderTwo);
        pool.withdraw(two);

        assertApproxEqAbs(holderOne.balance, one * cashAll / supply, 1, "holder one pro rata");
        assertApproxEqAbs(holderTwo.balance, two * cashAll / supply, 2, "holder two pro rata");
        assertEq(holderOne.balance + holderTwo.balance + pool.cash(), cashAll, "cash conserved");
        assertEq(pool.claims(), 0);
        _assertI1(pool);
    }

    function test_retirementTransferGrailEstate() public {
        _buildA();
        (uint256 bucket, uint256 packId,,,) = _grail(pool, 0);
        (uint256 majorBucket, uint256 majorPack,,,) = _grail(pool, 1);
        vm.prank(admin);
        vm.expectRevert(Pool.NotExiting.selector);
        pool.transferGrailEstate(0, estate);

        vm.prank(admin);
        pool.startExit(address(pool));
        _exportAll(pool, 25);

        vm.expectRevert(Pool.NotAdmin.selector);
        pool.transferGrailEstate(0, estate);
        vm.prank(admin);
        vm.expectRevert(Pool.ZeroAddress.selector);
        pool.transferGrailEstate(0, address(0));

        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Pool.GrailEstateTransferred(0, estate, packId, bucket);
        pool.transferGrailEstate(0, estate);

        assertEq(drawPacks.ownerOf(packId), estate, "pack sent");
        assertEq(estate.balance, bucket, "bucket sent");
        (uint256 bucketAfter, uint256 packAfter, uint256 backingAfter, uint256 notionalAfter, uint256 listingAfter) =
            _grail(pool, 0);
        assertEq(bucketAfter, 0);
        assertEq(packAfter, 0);
        assertEq(backingAfter, 0);
        assertEq(notionalAfter, 0);
        assertEq(listingAfter, 0);
        _assertI1(pool);

        (uint256 majorAfter, uint256 majorPackAfter,,,) = _grail(pool, 1);
        assertEq(majorAfter, majorBucket, "other track untouched");
        assertEq(majorPackAfter, majorPack);

        vm.prank(admin);
        pool.transferGrailEstate(1, estate);
        assertEq(drawPacks.ownerOf(majorPack), estate);
        assertEq(estate.balance, bucket + majorBucket);
        assertEq(clone.activeListingCount(), 0);
    }

    function test_transferGrailEstateInExitingBeforeTheExportEnds() public {
        _buildA();
        (, uint256 packId,,,) = _grail(pool, 1);
        vm.prank(admin);
        pool.startExit(address(pool));
        vm.prank(admin);
        pool.transferGrailEstate(1, estate);
        assertEq(drawPacks.ownerOf(packId), estate);
        _exportAll(pool, 25);
        assertEq(uint8(pool.lifecycle()), uint8(Pool.Lifecycle.Exported));
    }

    function test_retirementLiquidateStillPaysAQueuedClaim() public {
        _buildA();
        uint256 queued = _queueClaim();
        uint256 balanceBefore = holderOne.balance;

        vm.prank(admin);
        pool.startExit(address(pool));
        _exportAll(pool, 25);
        assertGe(pool.cash(), queued, "redeemed items cover the claim");
        assertEq(pool.claims(), queued);

        vm.expectRevert(Pool.ClaimNotDue.selector);
        pool.liquidate();
        vm.warp(block.timestamp + pool.rotateInterval());
        pool.liquidate();

        assertEq(pool.claims(), 0, "claim paid");
        assertEq(holderOne.balance - balanceBefore, queued);
        _assertI1(pool);
    }

    // ---------------------------------------------------------------- migration

    function test_revert_importFunctionsRequireTheOldPool() public {
        _buildA();
        _buildB();
        vm.deal(stranger, 1 ether);
        vm.startPrank(stranger);
        vm.expectRevert(Pool.NotOldPool.selector);
        succ.importCash{value: 1 wei}();
        vm.expectRevert(Pool.NotOldPool.selector);
        succ.importItem(SHAPES_ADDR, 1);
        vm.expectRevert(Pool.NotOldPool.selector);
        succ.importGrail{value: 1 wei}(0, 0);
        vm.expectRevert(Pool.NotOldPool.selector);
        succ.finalizeImport(1);
        vm.stopPrank();
    }

    function test_revert_importItemWithAValueNoRowMatches() public {
        _buildA();
        _buildB();
        uint256 id = mintShapes(address(succ), 0.05 ether, 1);
        assertEq(shapes.ownerOf(id), address(succ));

        vm.prank(address(pool));
        vm.expectRevert(Pool.NoMatchingRow.selector);
        succ.importItem(SHAPES_ADDR, id);
    }

    function test_revert_importItemOfAPackWithAShapeRowValue() public {
        _buildA();
        _buildB();
        uint32[] memory counts = new uint32[](9);
        counts[2] = 1;
        uint256 cost = 0.1 ether + mintFee;
        vm.deal(address(this), cost);
        uint256 packId = drawPacks.createPackTo{value: cost}(new uint256[](0), counts, address(succ));
        assertEq(drawPacks.valueOf(packId), 0.1 ether);

        vm.prank(address(pool));
        vm.expectRevert(Pool.NoMatchingRow.selector);
        succ.importItem(address(drawPacks), packId);
    }

    function test_revert_importItemTheSuccessorDoesNotOwn() public {
        _buildA();
        _buildB();
        uint256 id = mintShapes(stranger, 0.1 ether, 1);
        vm.prank(address(pool));
        vm.expectRevert(Pool.TokenNotReceived.selector);
        succ.importItem(SHAPES_ADDR, id);
    }

    function test_revert_importItemOfAnUnknownCollection() public {
        _buildA();
        _buildB();
        vm.prank(address(pool));
        vm.expectRevert(Pool.NoMatchingRow.selector);
        succ.importItem(address(succClone), 1);
    }

    function test_revert_importGrailIntoAnOccupiedTrack() public {
        _buildA();
        _buildB();
        succ.growGrail(0);
        (, uint256 packId,,,) = _grail(succ, 0);
        assertTrue(packId != 0);
        vm.prank(address(pool));
        vm.expectRevert(Pool.GrailOccupied.selector);
        succ.importGrail(0, 1);
    }

    function test_revert_migrateHolderBeforeTheImportIsFinal() public {
        _buildA();
        _buildB();
        vm.expectRevert(Pool.ImportNotFinal.selector);
        succ.migrateHolder(holderOne);
    }

    function test_migrationMovesEveryItemGrailAndCashToTheSuccessor() public {
        _buildA();
        _buildB();
        Token[] memory tokens = _tokens(pool, clone);
        uint256 aBacking = pool.backing();
        uint256 aCash = pool.cash();
        uint256 aMaintenance = pool.maintenance();
        uint256 aShares = pool.totalShares();
        uint256 aNav = pool.nav();
        (uint256 minorBucket, uint256 minorPack, uint256 minorBacking,,) = _grail(pool, 0);
        (uint256 majorBucket, uint256 majorPack, uint256 majorBacking,,) = _grail(pool, 1);
        uint256 bBacking = succ.backing();
        uint256 bCash = succ.cash();
        uint256 bShares = succ.totalShares();
        uint256 bNav = succ.nav();
        uint256 carolClaim = succ.sharesOf(carol) * bNav / bShares;
        (uint256 bMinorBucket,,,,) = _grail(succ, 0);
        (uint256 bMajorBucket,,,,) = _grail(succ, 1);
        uint256 held = succ.heldCount();

        vm.prank(admin);
        pool.startExit(address(succ));
        assertEq(pool.exitDest(), address(succ));

        uint256 calls = _exportAll(pool, 12);
        assertEq(calls, 6, "59 items and 2 tracks at 12 per call");

        assertEq(uint8(pool.lifecycle()), uint8(Pool.Lifecycle.Exported));
        assertTrue(clone.retired());
        assertEq(pool.backing(), 0);
        assertEq(pool.listedCount() + pool.heldCount(), 0);
        assertEq(pool.cash(), 0, "cash less claims moved");
        assertEq(pool.maintenance(), 0);
        assertEq(pool.nav(), 0, "nothing left in the old pool");
        assertEq(address(pool).balance, 0, "the old pool holds no ETH");
        assertEq(pool.exportedShares(), aShares);
        assertEq(pool.exportedNav(), aNav + aMaintenance, "exported NAV");
        assertEq(pool.exportedNav(), succ.importedNav(), "the successor counted the same NAV");
        (uint256 aMinorBucket, uint256 aMinorPack,,, uint256 aMinorListing) = _grail(pool, 0);
        assertEq(aMinorBucket + aMinorPack + aMinorListing, 0, "old track cleared");
        (uint256 aMajorBucket, uint256 aMajorPack,,, uint256 aMajorListing) = _grail(pool, 1);
        assertEq(aMajorBucket + aMajorPack + aMajorListing, 0);

        assertEq(succ.backing(), bBacking + aBacking, "I2: backing is the sum of values");
        assertEq(succ.heldCount(), held + tokens.length, "imported items are held");
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC721(tokens[i].collection).ownerOf(tokens[i].id), address(succ), "token moved");
        }
        assertEq(succ.cash(), bCash + aCash + aMaintenance, "cash and maintenance imported as cash");
        (uint256 sMinorBucket, uint256 sMinorPack, uint256 sMinorBacking, uint256 sMinorNotional, uint256 sMinorId) =
            _grail(succ, 0);
        (uint256 sMajorBucket, uint256 sMajorPack, uint256 sMajorBacking,, uint256 sMajorId) = _grail(succ, 1);
        assertEq(sMinorPack, minorPack);
        assertEq(sMajorPack, majorPack);
        assertEq(sMinorBacking, minorBacking);
        assertEq(sMajorBacking, majorBacking);
        assertEq(sMinorBucket, bMinorBucket + minorBucket);
        assertEq(sMajorBucket, bMajorBucket + majorBucket);
        assertEq(sMinorNotional, minorBacking * 8_000 / 10_000, "notional at the successor listBps");
        assertEq(sMinorId + sMajorId, 0, "relisted by rotate");
        assertEq(drawPacks.ownerOf(minorPack), address(succ));
        assertEq(drawPacks.ownerOf(majorPack), address(succ));

        uint256 importedNav = succ.importedNav();
        assertEq(importedNav, aBacking + aCash + aMaintenance);
        assertEq(succ.importedShares(), importedNav * bShares / bNav, "priced at the successor NAV per share");
        assertEq(succ.totalShares(), bShares + succ.importedShares());
        assertEq(succ.exportedShares(), aShares);
        assertApproxEqAbs(succ.sharesOf(carol) * succ.nav() / succ.totalShares(), carolClaim, 1, "native claim unchanged");
        _assertI1(pool);
        _assertI1(succ);
    }

    function test_migrateHolderMintsTheProRataShare() public {
        _buildA();
        _buildB();
        uint256 one = pool.sharesOf(holderOne);
        uint256 two = pool.sharesOf(holderTwo);
        vm.prank(admin);
        pool.startExit(address(succ));
        _exportAll(pool, 25);

        uint256 imported = succ.importedShares();
        uint256 exported = succ.exportedShares();
        uint256 supplyBefore = succ.totalShares();
        vm.expectEmit(true, false, false, true, address(succ));
        emit Pool.Migrated(holderOne, one * imported / exported);
        succ.migrateHolder(holderOne);
        assertEq(succ.sharesOf(holderOne), one * imported / exported);
        assertTrue(succ.migrated(holderOne));

        vm.prank(keeper);
        succ.migrateHolder(holderTwo);
        assertEq(succ.sharesOf(holderTwo), two * imported / exported);

        vm.expectRevert(Pool.AlreadyMigrated.selector);
        succ.migrateHolder(holderOne);

        succ.migrateHolder(stranger);
        assertEq(succ.sharesOf(stranger), 0, "a stranger holds no shares at the old pool");
        assertEq(succ.totalShares(), supplyBefore, "migration mints into the imported supply");
        assertLe(succ.sharesOf(holderOne) + succ.sharesOf(holderTwo), imported);
        assertApproxEqAbs(succ.sharesOf(holderOne) + succ.sharesOf(holderTwo), imported, 2, "rounding dust only");
    }

    function test_migratedHolderWithdrawsFromTheSuccessorAtItsNav() public {
        _buildA();
        _buildB();
        uint256 one = pool.sharesOf(holderOne);
        vm.prank(admin);
        pool.startExit(address(succ));
        _exportAll(pool, 25);
        succ.migrateHolder(holderOne);

        uint256 claim = succ.sharesOf(holderOne) * succ.nav() / succ.totalShares();
        assertGt(claim, 0);
        assertApproxEqRel(claim, one * pool.exportedNav() / pool.exportedShares(), 1e12, "value follows the shares");
        uint256 migrated_ = succ.sharesOf(holderOne);
        vm.prank(holderOne);
        succ.withdraw(migrated_);
        assertApproxEqAbs(holderOne.balance, claim, 1);
        _assertI1(succ);
    }

    function test_oldPoolWithdrawPaysNothingAfterMigration() public {
        _buildA();
        _buildB();
        uint256 one = pool.sharesOf(holderOne);
        vm.prank(admin);
        pool.startExit(address(succ));
        _exportAll(pool, 25);

        vm.prank(holderOne);
        pool.withdraw(one);
        assertEq(holderOne.balance, 0, "the old pool pays zero");
        assertEq(pool.sharesOf(holderOne), 0, "shares burned");
        assertEq(pool.claims(), 0, "no claim queued");
    }

    function test_successorRotateListsTheImportedItemsAndGrailPacks() public {
        _buildA();
        _buildB();
        uint256 aItems = pool.listedCount() + pool.heldCount();
        vm.prank(admin);
        pool.startExit(address(succ));
        _exportAll(pool, 25);
        assertEq(succ.heldCount(), aItems);

        vm.warp(succ.lastRotateAt() + succ.rotateInterval());
        succ.rotate();

        assertEq(succ.heldCount(), 0, "every imported item is listed");
        assertEq(succ.listedCount(), 10 + aItems);
        (, uint256 packId,,, uint256 listingId) = _grail(succ, 0);
        assertTrue(listingId != 0, "minor pack listed");
        assertEq(drawPacks.ownerOf(packId), address(succClone));
        (, uint256 majorId,,, uint256 majorListing) = _grail(succ, 1);
        assertTrue(majorListing != 0, "major pack listed");
        assertEq(drawPacks.ownerOf(majorId), address(succClone));
        _assertI1(succ);
    }

    function test_migrationRedeemsItemsUntilCashCoversTheQueuedClaims() public {
        _buildA();
        _buildB();
        uint256 queued = _queueClaim();
        uint256 aBacking = pool.backing();
        uint256 aMaintenance = pool.maintenance();
        uint256 balanceBefore = holderOne.balance;
        uint256 aNav = pool.nav();

        vm.prank(admin);
        pool.startExit(address(succ));
        _exportAll(pool, 25);

        assertEq(pool.cash(), queued, "cash left behind is the queued claims");
        assertEq(pool.claims(), queued);
        assertEq(pool.nav(), 0);
        assertLt(succ.importedNav(), aBacking + aMaintenance, "part of the backing was redeemed to fund the claim");
        assertEq(pool.exportedNav(), succ.importedNav());
        assertEq(pool.exportedNav(), aNav + aMaintenance);

        vm.warp(block.timestamp + pool.rotateInterval());
        pool.liquidate();
        assertEq(pool.claims(), 0);
        assertEq(holderOne.balance - balanceBefore, queued);
        assertEq(address(pool).balance, 0);
    }

    function test_migrationStepsAreBoundedAndResumable() public {
        _buildA();
        _buildB();
        vm.prank(admin);
        pool.startExit(address(succ));

        assertFalse(pool.exportStep(0), "a zero budget moves nothing");
        assertEq(pool.listedCount(), 58);
        assertFalse(pool.exportStep(1));
        assertEq(pool.listedCount() + pool.heldCount(), 58);
        assertEq(succ.heldCount(), 1);
        assertGt(succ.importedNav(), 0);
        assertEq(pool.exportedNav(), succ.importedNav(), "exported NAV accumulates per call");
        assertEq(_exportAll(pool, 100), 1, "one call finishes the rest");
        assertEq(pool.exportedNav(), succ.importedNav());
    }

    function test_revert_successorImportAfterItIsFinalized() public {
        _buildA();
        _buildB();
        vm.prank(admin);
        pool.startExit(address(succ));
        _exportAll(pool, 25);

        vm.prank(address(pool));
        vm.expectRevert(Pool.ImportClosed.selector);
        succ.importCash();
    }
}
