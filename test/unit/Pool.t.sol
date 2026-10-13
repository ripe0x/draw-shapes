// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Pool} from "../../src/Pool.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";

/// @notice Pool with test-only entrypoints that move value between buckets.
contract PoolHarness is Pool {
    address internal constant SINK = address(0xdead);

    error Preview(uint256 nav, uint256 cash, uint256 claims);

    constructor(Params memory p) Pool(p) {}

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

    function setMaintenance(uint256 amount) external {
        maintenance = amount;
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

    function restock() external returns (uint256) {
        return _restock();
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

    function pushReplacement(uint16 row) external {
        replacementQueue.push(row);
    }

    function recordPulls(uint256 count) external {
        _recordPulls(count);
    }

    function trailingPulls() external view returns (uint256) {
        return _trailingPulls();
    }

    function setFwaPool(address clone, uint256 deadlineAt) external {
        fwaPool = IFWAClone(clone);
        openingDeadlineAt = deadlineAt;
    }

    function harvest() external returns (bool) {
        return _harvest();
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
        margin = amount;
    }

    function setMintLineOwed(uint256 amount) external {
        mintLineOwed = amount;
    }

    function setGrailListing(uint256 track, uint256 packId, uint256 listingId, uint256 notional) external {
        Grail storage g = grail[track];
        g.packId = packId;
        g.listingId = listingId;
        g.notional = notional;
    }

    function setPullsPaused(bool paused) external {
        pullsPaused = paused;
    }

    function grailReceivable(uint256 track) external view returns (uint256) {
        return grail[track].receivable;
    }
}

abstract contract PoolFixture is Test {
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _params() internal returns (Pool.Params memory p) {
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
        p.feeSplit = Pool.FeeSplit({premiumBps: 200, maintenanceBps: 100, feedBps: 400, minorShareBps: 4_000});
        p.minor = Pool.GrailParams({
            targetWei: 10 ether, stepWei: 0.1 ether, listBps: 10_000, decayWeiPerPull: 0.001 ether, floorWei: 0.5 ether
        });
        p.major = Pool.GrailParams({
            targetWei: 100 ether, stepWei: 1 ether, listBps: 9_000, decayWeiPerPull: 0.01 ether, floorWei: 5 ether
        });
        p.navCap = 1_000 ether;
        p.curve = Pool.EntryCurve({baseBps: 1_100, slopeBps: 2_000, capBps: 2_500, referenceWei: 55 ether});
        p.rotateInterval = 3_600;
        p.openingDeadline = 24 hours;
        p.minItems = 10;
        p.grailProbCapBps = 2_000;
    }

    function _deploy(Pool.Params memory p) internal returns (PoolHarness) {
        return new PoolHarness(p);
    }
}

contract PoolConstructorTest is PoolFixture {
    function test_constructorStoresParams() public {
        PoolHarness pool = _deploy(_params());
        assertEq(pool.admin(), admin);
        assertEq(uint256(pool.lifecycle()), uint256(Pool.Lifecycle.Opening));
        assertEq(pool.mixLength(), 2);
        assertEq(pool.navCap(), 1_000 ether);
        assertEq(pool.rotateInterval(), 3_600);
        assertEq(pool.openingDeadline(), 24 hours);
        (,,,, uint256 target, uint256 step, uint256 listBps, uint256 decay, uint256 floor,,,) = pool.grail(1);
        assertEq(target, 100 ether);
        assertEq(step, 1 ether);
        assertEq(listBps, 9_000);
        assertEq(decay, 0.01 ether);
        assertEq(floor, 5 ether);
    }

    function test_revert_adminZero() public {
        Pool.Params memory p = _params();
        p.admin = address(0);
        vm.expectRevert(Pool.ZeroAddress.selector);
        new PoolHarness(p);
    }

    function test_revert_feeSplitTooHigh() public {
        Pool.Params memory p = _params();
        p.feeSplit.feedBps = 701;
        vm.expectRevert(Pool.FeeSplitTooHigh.selector);
        new PoolHarness(p);
    }

    function test_feeSplitAtBoundAccepted() public {
        Pool.Params memory p = _params();
        p.feeSplit.feedBps = 700;
        _deploy(p);
    }

    function test_revert_minorShareTooHigh() public {
        Pool.Params memory p = _params();
        p.feeSplit.minorShareBps = 10_001;
        vm.expectRevert(Pool.MinorShareTooHigh.selector);
        new PoolHarness(p);
    }

    function test_revert_capBpsTooHigh() public {
        Pool.Params memory p = _params();
        p.curve.capBps = 2_501;
        vm.expectRevert(Pool.CurveCapTooHigh.selector);
        new PoolHarness(p);
    }

    function test_revert_referenceZero() public {
        Pool.Params memory p = _params();
        p.curve.referenceWei = 0;
        vm.expectRevert(Pool.CurveReferenceZero.selector);
        new PoolHarness(p);
    }

    function test_revert_listBpsZeroMinor() public {
        Pool.Params memory p = _params();
        p.minor.listBps = 0;
        vm.expectRevert(Pool.ListBpsOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_listBpsTooHighMajor() public {
        Pool.Params memory p = _params();
        p.major.listBps = 10_001;
        vm.expectRevert(Pool.ListBpsOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_grailProbCapZero() public {
        Pool.Params memory p = _params();
        p.grailProbCapBps = 0;
        vm.expectRevert(Pool.GrailProbCapOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_grailProbCapTooHigh() public {
        Pool.Params memory p = _params();
        p.grailProbCapBps = 10_001;
        vm.expectRevert(Pool.GrailProbCapOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_constructorStoresBoardParams() public {
        PoolHarness pool = _deploy(_params());
        assertEq(pool.minItems(), 10);
        assertEq(pool.grailProbCapBps(), 2_000);
        assertEq(pool.rowCount(0), 0);
        assertEq(pool.rowCount(1), 0);
    }

    function test_revert_emptyMixRow() public {
        Pool.Params memory p = _params();
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
        (bucket,,,,,,,,,,,) = pool.grail(track);
    }

    function _claim(uint256 index) internal view returns (address to, uint256 requestedAt, uint256 amount) {
        return pool.claimQueue(index);
    }

    // ---------------------------------------------------------------- opening guards

    function test_revert_createFwaPoolNotAdmin() public {
        vm.expectRevert(Pool.NotAdmin.selector);
        pool.createFwaPool(0);
    }

    function test_revert_createFwaPoolNotOpening() public {
        pool.setLifecycle(Pool.Lifecycle.Live);
        vm.prank(admin);
        vm.expectRevert(Pool.NotOpening.selector);
        pool.createFwaPool(0);
    }

    function test_revert_openWithoutFwaPool() public {
        vm.expectRevert(Pool.FwaPoolMissing.selector);
        pool.open();
    }

    function test_revert_openWhenLive() public {
        pool.setLifecycle(Pool.Lifecycle.Live);
        vm.expectRevert(Pool.NotOpening.selector);
        pool.open();
    }

    function test_revert_openBeforeDeadline() public {
        pool.setFwaPool(address(0xF00D), block.timestamp + 1);
        vm.expectRevert(Pool.OpeningDeadlineNotReached.selector);
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
        assertEq(pool.rowCount(0), 2);
        assertEq(pool.rowCount(1), 1);
        assertEq(pool.heldCount(), 3);

        Pool.Item memory removed = pool.removeHeld(0);
        assertEq(removed.tokenId, 11);
        assertEq(pool.backing(), 0.25 ether);
        assertEq(pool.rowCount(0), 1);
        assertEq(pool.heldCount(), 2);
        assertEq(pool.heldItem(0).tokenId, 13);
        assertEq(pool.heldItem(1).tokenId, 12);
    }

    function test_addAndRemoveListedKeepBackingAndRowCount() public {
        pool.addItem(alice, 1, 21, 0.15 ether, 7);
        assertEq(pool.backing(), 0.15 ether);
        assertEq(pool.rowCount(1), 1);
        assertEq(pool.heldCount(), 0);
        Pool.Item memory it = pool.listedItem(7);
        assertEq(it.tokenId, 21);
        assertEq(it.value, 0.15 ether);
        assertEq(it.row, 1);
        assertEq(it.listingId, 7);

        pool.removeListed(7);
        assertEq(pool.backing(), 0);
        assertEq(pool.rowCount(1), 0);
        assertEq(pool.listedItem(7).value, 0);
    }

    // ---------------------------------------------------------------- trailing pulls

    function test_trailingPullsSumsCurrentAndFourPriorHours() public {
        vm.warp(10 hours);
        pool.recordPulls(3);
        pool.recordPulls(2);
        assertEq(pool.trailingPulls(), 5);
        for (uint256 i = 1; i <= 4; ++i) {
            vm.warp(10 hours + i * 1 hours);
            pool.recordPulls(1);
            assertEq(pool.trailingPulls(), 5 + i);
        }
        vm.warp(15 hours);
        assertEq(pool.trailingPulls(), 4);
        vm.warp(16 hours);
        pool.recordPulls(7);
        assertEq(pool.trailingPulls(), 1 + 1 + 1 + 7);
        vm.warp(30 hours);
        assertEq(pool.trailingPulls(), 0);
    }

    function test_trailingPullsSlotResetsOnReuse() public {
        vm.warp(10 hours);
        pool.recordPulls(9);
        vm.warp(15 hours);
        pool.recordPulls(1);
        assertEq(pool.trailingPulls(), 1);
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

        uint256 curveBps = PricingLib.entryCurveBps(17.8 ether, 1_100, 2_000, 2_500, 55 ether);
        uint256 contribution = PricingLib.entryContribution(10 ether, curveBps);
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
        emit Pool.Deposited(alice, 10 ether, 1.1 ether, 8.9 ether);
        _deposit(alice, 10 ether);
    }

    function test_revert_navCap() public {
        Pool.Params memory p = _params();
        p.navCap = 5 ether;
        pool = _deploy(p);
        _deposit(alice, 10 ether);
        vm.expectRevert(Pool.NavCapReached.selector);
        _deposit(bob, 1 ether);
    }

    function test_revert_depositsPaused() public {
        pool.pauseDeposits();
        vm.expectRevert(Pool.DepositsPaused.selector);
        _deposit(alice, 1 ether);
    }

    function test_revert_exiting() public {
        pool.setLifecycle(Pool.Lifecycle.Exiting);
        vm.expectRevert(Pool.PoolExiting.selector);
        _deposit(alice, 1 ether);
        pool.setLifecycle(Pool.Lifecycle.Exported);
        vm.expectRevert(Pool.PoolExiting.selector);
        _deposit(alice, 1 ether);
    }

    function test_revert_zeroValue() public {
        vm.expectRevert(Pool.ZeroAmount.selector);
        _deposit(alice, 0);
    }

    // ---------------------------------------------------------------- withdraw

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
        vm.expectRevert(Pool.ZeroAmount.selector);
        pool.withdraw(0);
    }

    function test_revert_withdrawMoreThanBalance() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(Pool.InsufficientShares.selector);
        pool.withdraw(8.9 ether + 1);
    }

    function test_withdrawWithCashShortEnqueuesRemainder() public {
        _deposit(alice, 10 ether);
        pool.spendOnBacking(5 ether);
        assertEq(pool.cash(), 3.9 ether);
        assertEq(pool.nav(), 8.9 ether);

        uint256 before = alice.balance;
        vm.expectEmit(true, false, false, true, address(pool));
        emit Pool.Withdrawn(alice, 4.45 ether, 3.9 ether, 0.55 ether);
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

    // ---------------------------------------------------------------- liquidate

    function test_liquidateNoopWhenQueueEmpty() public {
        pool.liquidate();
        assertEq(pool.claimHead(), 0);
    }

    function test_revert_liquidateBeforeInterval() public {
        _deposit(alice, 10 ether);
        pool.spendOnBacking(8.9 ether);
        vm.prank(alice);
        pool.withdraw(8.9 ether);
        pool.bookProceeds{value: 1 ether}();

        vm.warp(block.timestamp + 3_599);
        vm.expectRevert(Pool.ClaimNotDue.selector);
        pool.liquidate();
        vm.warp(block.timestamp + 1);
        pool.liquidate();
        assertEq(alice.balance, 1_000 ether - 10 ether + 1 ether);
    }

    function test_liquidatePaysHeadPartially() public {
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
        emit Pool.ClaimPaid(alice, 3 ether);
        pool.liquidate();

        assertEq(alice.balance - before, 3 ether);
        assertEq(pool.claimHead(), 0);
        (,, uint256 amount) = _claim(0);
        assertEq(amount, 5.9 ether);
        assertEq(pool.claims(), 5.9 ether);
        assertEq(pool.cash(), 0);
    }

    function test_twoClaimsPaidInOrderAcrossLiquidations() public {
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
        pool.liquidate();
        assertEq(alice.balance - aliceBefore, claimA / 2);
        assertEq(bob.balance, bobBefore);
        assertEq(pool.claimHead(), 0);

        pool.bookProceeds{value: claimA - claimA / 2 + 1 ether}();
        pool.liquidate();
        assertEq(alice.balance - aliceBefore, claimA);
        assertEq(bob.balance - bobBefore, 1 ether);
        assertEq(pool.claimHead(), 1);
        (,, uint256 headAmount) = _claim(1);
        assertEq(headAmount, claimB - 1 ether);
        assertEq(pool.claims(), claimB - 1 ether);

        pool.bookProceeds{value: claimB}();
        pool.liquidate();
        assertEq(bob.balance - bobBefore, claimB);
        assertEq(pool.claimHead(), 2);
        assertEq(pool.claims(), 0);
        assertEq(pool.cash(), 1 ether);
    }

    function test_liquidateBoundedByItemLimit() public {
        _deposit(alice, 100 ether);
        pool.spendOnBacking(pool.cash());
        uint256 shares = pool.sharesOf(alice);
        for (uint256 i; i < 25; ++i) {
            vm.prank(alice);
            pool.withdraw(shares / 25);
        }
        pool.bookProceeds{value: 100 ether}();
        vm.warp(block.timestamp + 3_600);
        pool.liquidate();
        assertEq(pool.claimHead(), 20);
        pool.liquidate();
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
        pool.liquidate();
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
        vm.expectRevert(Pool.NavZero.selector);
        pool.deposit{value: 1 ether}();
    }

    function test_withdrawAtZeroNavBurnsSharesAndPaysNothing() public {
        _deposit(alice, 10 ether);
        pool.setClaims(9 ether);
        uint256 shares = pool.sharesOf(alice);
        uint256 before = alice.balance;
        uint256 cashBefore = pool.cash();

        vm.expectEmit(true, false, false, true, address(pool));
        emit Pool.Withdrawn(alice, shares, 0, 0);
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
        pool.liquidate();

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
