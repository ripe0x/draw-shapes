// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAdmin} from "../../src/PoolAdmin.sol";
import {PoolListing} from "../../src/PoolListing.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice Pool with test-only entrypoints that move value between buckets.
contract PoolHarness is Pool {
    address internal constant SINK = address(0xdead);

    error Preview(uint256 nav, uint256 cash, uint256 claims);

    constructor(Params memory p) Pool(p, address(new PoolAdmin()), address(new PoolListing())) {}

    /// @dev Entry contribution a deposit of `value` pays at ordinary NAV `atNav` with the current
    ///      trailing volume.
    function contributionFor(uint256 value, uint256 atNav) external view returns (uint256) {
        return PricingLib.entryContribution(value, _entryFeeBps(atNav, _dailyVolume()));
    }

    /// @dev Moves `amount` from `cash` to `backing` and sends the ETH out, as a mint does.
    function spendOnBacking(uint256 amount) external {
        cash -= amount;
        backing += amount;
        SafeTransferLib.safeTransferETH(SINK, amount);
    }

    /// @dev Moves `msg.value` from `backing` to `cash`, as a redemption does.
    function releaseBacking() external payable {
        backing -= msg.value;
        cash += msg.value;
    }

    /// @dev Credits `msg.value` to `cash`, as harvested proceeds do.
    function bookProceeds() external payable {
        cash += msg.value;
    }

    /// @dev Sends `amount` of `cash` out of the pool, as a loss of ordinary ETH.
    function loseCash(uint256 amount) external {
        cash -= amount;
        SafeTransferLib.safeTransferETH(SINK, amount);
    }

    /// @dev Sends `amount` of ETH out of the pool without changing any bucket.
    function leak(uint256 amount) external {
        SafeTransferLib.safeTransferETH(SINK, amount);
    }

    /// @dev Raises `backing` without registering an item.
    function bumpBacking(uint256 amount) external {
        backing += amount;
    }

    function setMaintenance(uint256 amount) external {
        maintenance = amount;
    }

    /// @dev Listed item for FWA `listingId`; zero fields for an unknown id.
    function listedItem(uint256 listingId) external view returns (Item memory) {
        return _listed[listingId];
    }

    function heldCount() external view returns (uint256) {
        return _held.length;
    }

    function heldItem(uint256 index) external view returns (Item memory) {
        return _held[index];
    }

    function replacementLength() external view returns (uint256) {
        return _replacementQueue.length - replacementHead;
    }

    /// @dev FWA base price recorded for pull request `requestId`; `recorded` is false for a
    ///      request opened directly at the FWA pool.
    function baseOf(uint256 requestId) external view returns (uint256 base, bool recorded) {
        uint256 stored = _basePlusOne[requestId];
        return (stored == 0 ? 0 : stored - 1, stored != 0);
    }

    function listedIds(uint256 row) external view returns (uint256[] memory) {
        return _listedByRow[row];
    }

    function pauseDeposits() external {
        depositsPaused = true;
    }

    function setLifecycle(Lifecycle state) external {
        lifecycle = state;
    }

    /// @dev Setup helper for one track: books FWA results, then runs the growth step `rotate`
    ///      applies to the track, without the spacing check, and restarts the spacing. Reverts
    ///      `GrailNotReady` when the track cannot grow and `FwaBusy` while acquisitions are
    ///      unsettled.
    function growTrack(uint8 t) external {
        _sync();
        uint256 status = _growGrail(t, _unsettled() != 0);
        if (status == 1) revert GrailNotReady();
        if (status == 2) revert FwaBusy();
        lastRotateAt = block.timestamp;
    }

    /// @dev Runs the pass `open` repeats: pays claims, queues each row's missing items and lists
    ///      the queue and the held items. Returns the number listed.
    function restock() external returns (uint256) {
        _payClaims();
        return IPool(address(this)).openBoard();
    }

    function sync() external {
        _sync();
    }

    /// @dev Runs `_sync` and reverts with the resulting pricing state, so a caller reads the state
    ///      a pricing action would use without changing the pool.
    function previewSynced() external {
        _sync();
        revert Preview(nav(), cash, claims);
    }

    function setClaims(uint256 amount) external {
        claims = amount;
    }

    function addItem(address collection, uint16 row, uint256 tokenId, uint256 value, uint256 listingId) external {
        _addItem(Item(collection, row, tokenId, value, listingId));
    }

    function removeHeld(uint256 index) external returns (Item memory) {
        return _removeHeld(index);
    }

    function removeListed(uint256 listingId) external returns (Item memory) {
        return _removeListed(listingId);
    }

    /// @dev Replacement row for a capture of `capturedRow` under the random word `word`, read from
    ///      the pool's rows, counts and replacement parameters.
    function chooseRow(uint256 word, uint256 requestId, uint256 capturedRow)
        external
        view
        returns (uint256 row, bool surprise)
    {
        return _pickRow(word, requestId, capturedRow);
    }

    /// @dev Queued replacements of `row`.
    function queuedOf(uint256 row) external view returns (uint256) {
        return _queuedByRow[row];
    }

    function pushReplacement(uint16 row) external {
        _enqueue(row);
    }

    /// @dev Sets `minItems`, which sizes every row's target depth.
    function sizeBoard(uint256 items) external {
        minItems = items;
    }

    function recordPulls(uint256 count) external {
        _recordPulls(count);
    }

    function setFwaPool(address clone, uint256 deadlineAt) external {
        fwaPool = IFWAClone(clone);
        _openingDeadlineAt = deadlineAt;
    }

    function harvest() external returns (bool) {
        return _harvest();
    }

    /// @dev Processes and books up to `maxCount` acquisitions without the harvest and listing of
    ///      `settle`.
    function bookOnly(uint256 maxCount) external {
        _processAndSettle(maxCount);
    }

    function settleBudget(uint256 maxItems) external {
        _settle(maxItems);
    }

    function splitMargin() external {
        _splitMargin();
    }

    function setReceivable(uint256 amount) external {
        receivable = amount;
    }

    function setMargin(int256 amount) external {
        _margin = amount;
    }

    function setLastRotateAt(uint256 timestamp) external {
        lastRotateAt = timestamp;
    }

    function setNextSequenceToBook(uint64 sequence) external {
        nextSequenceToBook = sequence;
    }

    /// @dev Raises the four booked receivables without moving ETH.
    function addReceivables(uint256 ordinary, uint256 maintenanceWei, uint256 minorWei, uint256 majorWei) external {
        receivable += ordinary;
        _maintenanceReceivable += maintenanceWei;
        _grail[MINOR].receivable += minorWei;
        _grail[MAJOR].receivable += majorWei;
    }

    function setMintLineOwed(uint256 amount) external {
        _mintLineOwed = amount;
    }

    function setGrailListing(uint256 track, uint256 packId, uint256 listingId, uint256 notional) external {
        Grail storage g = _grail[track];
        g.packId = packId;
        g.listingId = listingId;
        g.notional = notional;
    }

    /// @dev Credits `msg.value` to track `track`'s bucket.
    function addGrailBucket(uint256 track) external payable {
        _grail[track].bucket += msg.value;
    }

    /// @dev Sends `amount` of track `track`'s bucket out of the pool, as a loss of GRAIL ETH.
    function loseGrailBucket(uint256 track, uint256 amount) external {
        _grail[track].bucket -= amount;
        SafeTransferLib.safeTransferETH(SINK, amount);
    }

    /// @dev Withdraws the track's pack from FWA and leaves it unlisted, as a refunded delivery does.
    function unlistGrail(uint256 track) external {
        fwaPool.withdrawListing(_grail[track].listingId);
        _grail[track].listingId = 0;
    }

    function writeOff(uint256 requestId, uint256 listingId) external {
        _writeOff(requestId, listingId);
    }

    function setPullsPaused(bool paused) external {
        pullsPaused = paused;
    }

    function grailReceivable(uint256 track) external view returns (uint256) {
        return _grail[track].receivable;
    }
}

abstract contract PoolFixture is Test {
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _params() internal returns (IPoolTypes.Params memory p) {
        p.shapes = makeAddr("shapes");
        p.drawPacks = makeAddr("drawPacks");
        p.fwaFactory = makeAddr("fwaFactory");
        p.admin = admin;
        p.mix = new PricingLib.MixRow[](2);
        p.mix[0].rungs = new uint8[](1);
        p.mix[0].rungs[0] = 2;
        p.mix[0].shareBps = 7_000;
        p.mix[1].rungs = new uint8[](2);
        p.mix[1].rungs[0] = 1;
        p.mix[1].rungs[1] = 2;
        p.mix[1].shareBps = 3_000;
        p.feeSplit = IPoolTypes.FeeSplit({premiumBps: 200, maintenanceBps: 100, feedBps: 400, minorShareBps: 4_000});
        p.minor = IPoolTypes.GrailParams({
            targetWei: 10 ether, stepWei: 0.1 ether, listBps: 10_000, decayWeiPerPull: 0.001 ether, floorWei: 0.5 ether
        });
        p.major = IPoolTypes.GrailParams({
            targetWei: 100 ether, stepWei: 1 ether, listBps: 9_000, decayWeiPerPull: 0.01 ether, floorWei: 5 ether
        });
        p.navCapFloor = 1_000 ether;
        p.turnoverBps = 1_250;
        p.entryFee = IPoolTypes.EntryFee({floorBps: 1_100, capBps: 2_500, paybackDays: 20});
        p.rotateInterval = 3_600;
        p.openingDeadline = 24 hours;
        p.minItems = 10;
        p.grailProbCapBps = 2_000;
        p.batchMin = 20;
        p.batchMaxAge = 1 hours;
        p.surpriseBps = 200;
        p.restoreK = 8;
        p.bandBps = 3_000;
        p.reserveBps = 1_000;
        p.tipWei = 0.0002 ether;
    }

    /// @dev Warps to the end of the `rotateInterval` that follows `lastRotateAt`, which `rotate`
    ///      waits for. A later timestamp is kept.
    function _warpPastRotateGate(Pool target) internal {
        uint256 at = target.lastRotateAt() + target.rotateInterval();
        if (block.timestamp < at) vm.warp(at);
    }

    function _deploy(IPoolTypes.Params memory p) internal returns (PoolHarness) {
        return new PoolHarness(p);
    }
}

contract PoolConstructorTest is PoolFixture {
    function test_constructorStoresParams() public {
        PoolHarness pool = _deploy(_params());
        assertEq(pool.admin(), admin);
        assertEq(uint256(pool.lifecycle()), uint256(IPoolTypes.Lifecycle.Opening));
        assertEq(IPool(address(pool)).mixLength(), 2);
        assertEq(pool.navCapFloor(), 1_000 ether);
        assertEq(pool.navCap(), 1_000 ether);
        assertEq(pool.turnoverBps(), 1_250);
        assertEq(pool.founderWindowSeconds(), 0);
        assertEq(pool.rotateInterval(), 3_600);
        assertEq(IPool(address(pool)).openingDeadline(), 24 hours);
        (,,,, uint256 target, uint256 step, uint256 listBps, uint256 decay, uint256 floor,,,) = IPool(address(pool)).grail(1);
        assertEq(target, 100 ether);
        assertEq(step, 1 ether);
        assertEq(listBps, 9_000);
        assertEq(decay, 0.01 ether);
        assertEq(floor, 5 ether);
    }

    function test_revert_adminZero() public {
        IPoolTypes.Params memory p = _params();
        p.admin = address(0);
        vm.expectRevert(IPoolTypes.ZeroAddress.selector);
        new PoolHarness(p);
    }

    function test_revert_feeSplitTooHigh() public {
        IPoolTypes.Params memory p = _params();
        p.feeSplit.feedBps = 701;
        vm.expectRevert(IPoolTypes.FeeSplitTooHigh.selector);
        new PoolHarness(p);
    }

    function test_feeSplitAtBoundAccepted() public {
        IPoolTypes.Params memory p = _params();
        p.feeSplit.feedBps = 700;
        _deploy(p);
    }

    function test_revert_minorShareTooHigh() public {
        IPoolTypes.Params memory p = _params();
        p.feeSplit.minorShareBps = 10_001;
        vm.expectRevert(IPoolTypes.MinorShareTooHigh.selector);
        new PoolHarness(p);
    }

    function test_revert_entryFeeCapAboveBps() public {
        IPoolTypes.Params memory p = _params();
        p.entryFee.capBps = 10_001;
        vm.expectRevert(IPoolTypes.EntryFeeOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_entryFeeFloorAboveCap() public {
        IPoolTypes.Params memory p = _params();
        p.entryFee.floorBps = 2_501;
        vm.expectRevert(IPoolTypes.EntryFeeOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_entryFeePaybackZero() public {
        IPoolTypes.Params memory p = _params();
        p.entryFee.paybackDays = 0;
        vm.expectRevert(IPoolTypes.EntryFeeOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_turnoverZero() public {
        IPoolTypes.Params memory p = _params();
        p.turnoverBps = 0;
        vm.expectRevert(IPoolTypes.TurnoverOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_turnoverAboveBps() public {
        IPoolTypes.Params memory p = _params();
        p.turnoverBps = 10_001;
        vm.expectRevert(IPoolTypes.TurnoverOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_listBpsZeroMinor() public {
        IPoolTypes.Params memory p = _params();
        p.minor.listBps = 0;
        vm.expectRevert(IPoolTypes.ListBpsOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_listBpsTooHighMajor() public {
        IPoolTypes.Params memory p = _params();
        p.major.listBps = 10_001;
        vm.expectRevert(IPoolTypes.ListBpsOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_grailStepZero() public {
        IPoolTypes.Params memory p = _params();
        p.minor.stepWei = 0;
        vm.expectRevert(IPoolTypes.GrailStepInvalid.selector);
        new PoolHarness(p);
    }

    function test_revert_grailStepNotAUnitMultiple() public {
        IPoolTypes.Params memory p = _params();
        p.major.stepWei = 1 ether + 1;
        vm.expectRevert(IPoolTypes.GrailStepInvalid.selector);
        new PoolHarness(p);
    }

    function test_revert_grailProbCapZero() public {
        IPoolTypes.Params memory p = _params();
        p.grailProbCapBps = 0;
        vm.expectRevert(IPoolTypes.GrailProbCapOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_grailProbCapTooHigh() public {
        IPoolTypes.Params memory p = _params();
        p.grailProbCapBps = 10_001;
        vm.expectRevert(IPoolTypes.GrailProbCapOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_batchMinZero() public {
        IPoolTypes.Params memory p = _params();
        p.batchMin = 0;
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_batchMaxAgeZero() public {
        IPoolTypes.Params memory p = _params();
        p.batchMaxAge = 0;
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_surpriseBpsTooHigh() public {
        IPoolTypes.Params memory p = _params();
        p.surpriseBps = 10_001;
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_restoreKTooHigh() public {
        IPoolTypes.Params memory p = _params();
        p.restoreK = 101;
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_bandBpsTooHigh() public {
        IPoolTypes.Params memory p = _params();
        p.bandBps = 100_001;
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_reserveBpsTooHigh() public {
        IPoolTypes.Params memory p = _params();
        p.reserveBps = 10_001;
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_tipAboveBound() public {
        IPoolTypes.Params memory p = _params();
        p.tipWei = 0.01 ether + 1;
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        new PoolHarness(p);
        p.tipWei = 0.01 ether;
        assertEq(IPool(address(new PoolHarness(p))).tipWei(), 0.01 ether);
    }

    function test_revert_moduleAddressZero() public {
        IPoolTypes.Params memory p = _params();
        address admin_ = address(new PoolAdmin());
        address listing_ = address(new PoolListing());
        vm.expectRevert(IPoolTypes.ZeroAddress.selector);
        new Pool(p, address(0), listing_);
        vm.expectRevert(IPoolTypes.ZeroAddress.selector);
        new Pool(p, admin_, address(0));
    }

    function test_constructorStoresTheModulesAndTheTip() public {
        PoolHarness pool = _deploy(_params());
        assertTrue(pool.adminModule().code.length != 0);
        assertTrue(pool.listingModule().code.length != 0);
        assertTrue(pool.adminModule() != pool.listingModule());
        assertEq(IPool(address(pool)).tipWei(), 0.0002 ether);
    }

    function test_revert_listingSelectorsOnThePoolFromAnyOtherSender() public {
        PoolHarness pool = _deploy(_params());
        vm.prank(alice);
        vm.expectRevert(IPoolTypes.NotSelf.selector);
        IPool(address(pool)).listBatch(1);
        vm.prank(alice);
        vm.expectRevert(IPoolTypes.NotSelf.selector);
        IPool(address(pool)).openBoard();
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.NotSelf.selector);
        IPool(address(pool)).listBatch(1);
    }

    function test_revert_listingModuleCalledDirectly() public {
        PoolHarness pool = _deploy(_params());
        IPool listing = IPool(pool.listingModule());
        vm.expectRevert(IPoolTypes.NotDelegated.selector);
        listing.listBatch(1);
        vm.expectRevert(IPoolTypes.NotDelegated.selector);
        listing.openBoard();
        vm.prank(address(listing));
        vm.expectRevert(IPoolTypes.NotDelegated.selector);
        listing.listBatch(1);
    }

    function test_constructorStoresReplacementParams() public {
        PoolHarness pool = _deploy(_params());
        assertEq(IPool(address(pool)).batchMin(), 20);
        assertEq(IPool(address(pool)).batchMaxAge(), 1 hours);
        assertEq(IPool(address(pool)).surpriseBps(), 200);
        assertEq(IPool(address(pool)).restoreK(), 8);
        assertEq(IPool(address(pool)).bandBps(), 3_000);
        assertEq(IPool(address(pool)).reserveBps(), 1_000);
        assertFalse(IPool(address(pool)).listWhilePaused());
        assertEq(IPool(address(pool)).oldestQueuedAt(), 0);
    }

    function test_constructorStoresBoardParams() public {
        PoolHarness pool = _deploy(_params());
        assertEq(pool.minItems(), 10);
        assertEq(IPool(address(pool)).grailProbCapBps(), 2_000);
        assertEq(IPool(address(pool)).rowCount(0), 0);
        assertEq(IPool(address(pool)).rowCount(1), 0);
    }

    function test_revert_emptyMixRow() public {
        IPoolTypes.Params memory p = _params();
        p.mix[0].rungs = new uint8[](0);
        vm.expectRevert(PricingLib.EmptyRow.selector);
        new PoolHarness(p);
    }
}

contract PoolTest is PoolFixture {
    PoolHarness internal pool;

    function setUp() public {
        pool = _deploy(_params());
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(address(this), 1_000 ether);
    }

    function _deposit(address who, uint256 value) internal {
        vm.prank(who);
        pool.deposit{value: value}();
    }

    function _bucket(uint256 track) internal view returns (uint256 bucket) {
        (bucket,,,,,,,,,,,) = IPool(address(pool)).grail(track);
    }

    function _claim(uint256 index) internal view returns (address to, uint256 requestedAt, uint256 amount) {
        return IPool(address(pool)).claimQueue(index);
    }

    // ---------------------------------------------------------------- opening guards

    function test_revert_createFwaPoolNotAdmin() public {
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).createFwaPool(0);
    }

    function test_revert_createFwaPoolNotOpening() public {
        pool.setLifecycle(IPoolTypes.Lifecycle.Live);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.NotOpening.selector);
        IPool(address(pool)).createFwaPool(0);
    }

    function test_revert_openWithoutFwaPool() public {
        vm.expectRevert(IPoolTypes.FwaPoolMissing.selector);
        pool.open();
    }

    function test_revert_openWhenLive() public {
        pool.setLifecycle(IPoolTypes.Lifecycle.Live);
        vm.expectRevert(IPoolTypes.NotOpening.selector);
        pool.open();
    }

    function test_revert_openBeforeDeadline() public {
        pool.setFwaPool(address(0xF00D), block.timestamp + 1);
        vm.expectRevert(IPoolTypes.OpeningDeadlineNotReached.selector);
        pool.open();
    }

    function test_onERC721ReceivedReturnsSelector() public view {
        assertEq(pool.onERC721Received(alice, bob, 1, ""), pool.onERC721Received.selector);
        assertEq(pool.heldCount(), 0);
        assertEq(pool.backing(), 0);
    }

    // ---------------------------------------------------------------- registry

    function test_addAndRemoveHeldKeepBackingAndRowCount() public {
        pool.addItem(alice, 0, 11, 0.1 ether, 0);
        pool.addItem(alice, 1, 12, 0.15 ether, 0);
        pool.addItem(alice, 0, 13, 0.1 ether, 0);
        assertEq(pool.backing(), 0.35 ether);
        assertEq(IPool(address(pool)).rowCount(0), 2);
        assertEq(IPool(address(pool)).rowCount(1), 1);
        assertEq(pool.heldCount(), 3);

        IPoolTypes.Item memory removed = pool.removeHeld(0);
        assertEq(removed.tokenId, 11);
        assertEq(pool.backing(), 0.25 ether);
        assertEq(IPool(address(pool)).rowCount(0), 1);
        assertEq(pool.heldCount(), 2);
        assertEq(pool.heldItem(0).tokenId, 13);
        assertEq(pool.heldItem(1).tokenId, 12);
    }

    function test_addAndRemoveListedKeepBackingAndRowCount() public {
        pool.addItem(alice, 1, 21, 0.15 ether, 7);
        assertEq(pool.backing(), 0.15 ether);
        assertEq(IPool(address(pool)).rowCount(1), 1);
        assertEq(pool.heldCount(), 0);
        IPoolTypes.Item memory it = pool.listedItem(7);
        assertEq(it.tokenId, 21);
        assertEq(it.value, 0.15 ether);
        assertEq(it.row, 1);
        assertEq(it.listingId, 7);

        pool.removeListed(7);
        assertEq(pool.backing(), 0);
        assertEq(IPool(address(pool)).rowCount(1), 0);
        assertEq(pool.listedItem(7).value, 0);
    }

    // ---------------------------------------------------------------- deposit

    function test_firstDepositIsOneToOneAfterContribution() public {
        _deposit(alice, 10 ether);
        assertEq(pool.sharesOf(alice), 8.9 ether);
        assertEq(pool.totalShares(), 8.9 ether);
        assertEq(pool.cash(), 8.9 ether);
        assertEq(pool.nav(), 8.9 ether);
        assertEq(address(pool).balance, 10 ether);
    }

    function test_secondDepositPricesAtNav() public {
        _deposit(alice, 10 ether);
        pool.bookProceeds{value: 8.9 ether}();
        assertEq(pool.nav(), 17.8 ether);

        uint256 feeBps = PricingLib.entryFeeBps(200, 0, 17.8 ether, 1_100, 2_500, 20);
        uint256 contribution = PricingLib.entryContribution(10 ether, feeBps);
        uint256 expected = PricingLib.sharesFor(10 ether - contribution, 17.8 ether, 8.9 ether);

        _deposit(bob, 10 ether);
        assertEq(pool.sharesOf(bob), expected);
        assertEq(pool.totalShares(), 8.9 ether + expected);
        assertEq(pool.cash(), 8.9 ether + 8.9 ether + 10 ether - contribution);
    }

    function test_contributionSplitsBetweenTracks() public {
        _deposit(alice, 10 ether);
        assertEq(_bucket(0), 0.44 ether);
        assertEq(_bucket(1), 0.66 ether);
        assertEq(_bucket(0) + _bucket(1), 1.1 ether);
    }

    function test_emitsDeposited() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.Deposited(alice, 10 ether, 1.1 ether, 8.9 ether);
        _deposit(alice, 10 ether);
    }

    function test_revert_navCap() public {
        IPoolTypes.Params memory p = _params();
        p.navCapFloor = 5 ether;
        pool = _deploy(p);
        _deposit(alice, 10 ether);
        vm.expectRevert(IPoolTypes.NavCapReached.selector);
        _deposit(bob, 1 ether);
    }

    function test_revert_depositsPaused() public {
        pool.pauseDeposits();
        vm.expectRevert(IPoolTypes.DepositsPaused.selector);
        _deposit(alice, 1 ether);
    }

    function test_revert_exiting() public {
        pool.setLifecycle(IPoolTypes.Lifecycle.Exiting);
        vm.expectRevert(IPoolTypes.PoolExiting.selector);
        _deposit(alice, 1 ether);
        pool.setLifecycle(IPoolTypes.Lifecycle.Exported);
        vm.expectRevert(IPoolTypes.PoolExiting.selector);
        _deposit(alice, 1 ether);
    }

    function test_revert_zeroValue() public {
        vm.expectRevert(IPoolTypes.ZeroAmount.selector);
        _deposit(alice, 0);
    }

    // ---------------------------------------------------------------- withdraw

    function test_fundMaintenanceAddsToTheBucket() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.MaintenanceFunded(alice, 0.4 ether);
        IPool(address(pool)).fundMaintenance{value: 0.4 ether}();
        assertEq(pool.maintenance(), 0.4 ether, "bucket");
        assertGe(address(pool).balance, pool.cash() + pool.maintenance(), "I1");
        vm.expectRevert(IPoolTypes.ZeroAmount.selector);
        IPool(address(pool)).fundMaintenance{value: 0}();
    }

    function test_withdrawPaysInFullFromCash() public {
        _deposit(alice, 10 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        pool.withdraw(8.9 ether);
        assertEq(alice.balance - before, 8.9 ether);
        assertEq(pool.sharesOf(alice), 0);
        assertEq(pool.totalShares(), 0);
        assertEq(pool.cash(), 0);
        assertEq(pool.claims(), 0);
    }

    function test_revert_withdrawZero() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(IPoolTypes.ZeroAmount.selector);
        pool.withdraw(0);
    }

    function test_revert_withdrawMoreThanBalance() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(IPoolTypes.InsufficientShares.selector);
        pool.withdraw(8.9 ether + 1);
    }

    function test_withdrawWithCashShortEnqueuesRemainder() public {
        _deposit(alice, 10 ether);
        pool.spendOnBacking(5 ether);
        assertEq(pool.cash(), 3.9 ether);
        assertEq(pool.nav(), 8.9 ether);

        uint256 before = alice.balance;
        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.Withdrawn(alice, 4.45 ether, 3.9 ether, 0.55 ether);
        vm.prank(alice);
        pool.withdraw(4.45 ether);

        assertEq(alice.balance - before, 3.9 ether);
        assertEq(pool.cash(), 0);
        assertEq(pool.claims(), 0.55 ether);
        assertEq(pool.nav(), 4.45 ether);
        (address to, uint256 requestedAt, uint256 amount) = _claim(0);
        assertEq(to, alice);
        assertEq(requestedAt, block.timestamp);
        assertEq(amount, 0.55 ether);
    }

    // ---------------------------------------------------------------- claim payment

    function test_payClaimsNoopWhenQueueEmpty() public {
        pool.payClaims();
        assertEq(pool.claimHead(), 0);
    }

    function test_payClaimsPaysCashToTheHeadClaim() public {
        _deposit(alice, 10 ether);
        pool.spendOnBacking(8.9 ether);
        vm.prank(alice);
        pool.withdraw(8.9 ether);
        pool.bookProceeds{value: 1 ether}();

        pool.payClaims();
        assertEq(alice.balance, 1_000 ether - 10 ether + 1 ether);
    }

    function test_payClaimsPaysHeadPartially() public {
        _deposit(alice, 10 ether);
        pool.spendOnBacking(8.9 ether);
        vm.prank(alice);
        pool.withdraw(8.9 ether);
        assertEq(pool.claims(), 8.9 ether);
        assertEq(pool.nav(), 0);

        pool.bookProceeds{value: 3 ether}();
        vm.warp(block.timestamp + 3_600);
        uint256 before = alice.balance;
        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.ClaimPaid(alice, 3 ether);
        pool.payClaims();

        assertEq(alice.balance - before, 3 ether);
        assertEq(pool.claimHead(), 0);
        (,, uint256 amount) = _claim(0);
        assertEq(amount, 5.9 ether);
        assertEq(pool.claims(), 5.9 ether);
        assertEq(pool.cash(), 0);
    }

    function test_twoClaimsPaidInOrderAcrossPayments() public {
        _deposit(alice, 10 ether);
        _deposit(bob, 10 ether);
        pool.spendOnBacking(pool.cash());
        assertEq(pool.cash(), 0);

        uint256 aliceShares = pool.sharesOf(alice);
        uint256 bobShares = pool.sharesOf(bob);
        vm.prank(alice);
        pool.withdraw(aliceShares);
        vm.prank(bob);
        pool.withdraw(bobShares);
        (,, uint256 claimA) = _claim(0);
        (,, uint256 claimB) = _claim(1);
        assertEq(pool.claims(), claimA + claimB);
        assertEq(pool.nav(), 0);

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        vm.warp(block.timestamp + 3_600);

        pool.bookProceeds{value: claimA / 2}();
        pool.payClaims();
        assertEq(alice.balance - aliceBefore, claimA / 2);
        assertEq(bob.balance, bobBefore);
        assertEq(pool.claimHead(), 0);

        pool.bookProceeds{value: claimA - claimA / 2 + 1 ether}();
        pool.payClaims();
        assertEq(alice.balance - aliceBefore, claimA);
        assertEq(bob.balance - bobBefore, 1 ether);
        assertEq(pool.claimHead(), 1);
        (,, uint256 headAmount) = _claim(1);
        assertEq(headAmount, claimB - 1 ether);
        assertEq(pool.claims(), claimB - 1 ether);

        pool.bookProceeds{value: claimB}();
        pool.payClaims();
        assertEq(bob.balance - bobBefore, claimB);
        assertEq(pool.claimHead(), 2);
        assertEq(pool.claims(), 0);
        assertEq(pool.cash(), 1 ether);
    }

    function test_payClaimsBoundedByClaimLimit() public {
        _deposit(alice, 100 ether);
        pool.spendOnBacking(pool.cash());
        uint256 shares = pool.sharesOf(alice);
        for (uint256 i; i < 25; ++i) {
            vm.prank(alice);
            pool.withdraw(shares / 25);
        }
        pool.bookProceeds{value: 100 ether}();
        vm.warp(block.timestamp + 3_600);
        pool.payClaims();
        assertEq(pool.claimHead(), 20);
        pool.payClaims();
        assertEq(pool.claimHead(), 25);
    }

    function test_rejectingRecipientDoesNotStallQueue() public {
        RejectEther rejecter = new RejectEther();
        vm.deal(address(rejecter), 10 ether);
        rejecter.deposit(pool, 10 ether);
        pool.spendOnBacking(pool.cash());
        rejecter.withdrawAll(pool);
        pool.bookProceeds{value: 20 ether}();
        vm.warp(block.timestamp + 3_600);
        pool.payClaims();
        assertEq(pool.claimHead(), 1);
        assertEq(pool.claims(), 0);
        assertEq(address(rejecter).balance, 8.9 ether);
    }

    // ---------------------------------------------------------------- nav saturation

    function test_navIsZeroWhenClaimsExceedAssets() public {
        _deposit(alice, 10 ether);
        assertEq(pool.nav(), 8.9 ether);
        pool.setClaims(8.9 ether);
        assertEq(pool.nav(), 0);
        pool.setClaims(9 ether);
        assertEq(pool.nav(), 0);
    }

    function test_revert_depositAtZeroNav() public {
        _deposit(alice, 10 ether);
        pool.setClaims(9 ether);
        vm.prank(bob);
        vm.expectRevert(IPoolTypes.NavZero.selector);
        pool.deposit{value: 1 ether}();
    }

    function test_withdrawAtZeroNavBurnsSharesAndPaysNothing() public {
        _deposit(alice, 10 ether);
        pool.setClaims(9 ether);
        uint256 shares = pool.sharesOf(alice);
        uint256 before = alice.balance;
        uint256 cashBefore = pool.cash();

        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.Withdrawn(alice, shares, 0, 0);
        vm.prank(alice);
        pool.withdraw(shares);

        assertEq(alice.balance, before);
        assertEq(pool.sharesOf(alice), 0);
        assertEq(pool.totalShares(), 0);
        assertEq(pool.cash(), cashBefore);
        assertEq(pool.claims(), 9 ether);
    }

    // ---------------------------------------------------------------- effects before sends

    function test_payClaimsWritesStateBeforeSending() public {
        ClaimProbe probe = new ClaimProbe(pool);
        vm.deal(address(probe), 10 ether);
        probe.deposit(10 ether);
        _deposit(alice, 10 ether);
        pool.spendOnBacking(pool.cash());
        probe.withdrawAll();
        uint256 aliceShares = pool.sharesOf(alice);
        vm.prank(alice);
        pool.withdraw(aliceShares);
        assertEq(pool.claimHead(), 0);

        pool.bookProceeds{value: 30 ether}();
        vm.warp(block.timestamp + 3_600);
        pool.payClaims();

        assertEq(probe.calls(), 1);
        assertEq(pool.claimHead(), 2);
        assertEq(probe.seenCash(), pool.cash(), "cash updated before the send");
        assertEq(probe.seenClaims(), pool.claims(), "claims updated before the send");
        assertEq(probe.seenHead(), pool.claimHead(), "head updated before the send");
        assertEq(pool.claims(), 0);
    }
}

/// @dev Claimant that records the pool's public state when it receives a claim payout.
contract ClaimProbe {
    Pool internal immutable _pool;
    uint256 public calls;
    uint256 public seenCash;
    uint256 public seenClaims;
    uint256 public seenHead;

    constructor(Pool pool) {
        _pool = pool;
    }

    function deposit(uint256 value) external {
        _pool.deposit{value: value}();
    }

    function withdrawAll() external {
        _pool.withdraw(_pool.sharesOf(address(this)));
    }

    receive() external payable {
        ++calls;
        seenCash = _pool.cash();
        seenClaims = _pool.claims();
        seenHead = _pool.claimHead();
    }
}

contract RejectEther {
    function deposit(Pool pool, uint256 value) external {
        pool.deposit{value: value}();
    }

    function withdrawAll(Pool pool) external {
        pool.withdraw(pool.sharesOf(address(this)));
    }

    receive() external payable {
        revert();
    }
}
