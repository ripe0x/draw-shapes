// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PricingLib} from "../../src/lib/PricingLib.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";

/// @notice Deposit admission against deployed Shapes and a FWA clone: the volume measure, the
///         volume-responsive `navCap()`, the yield-indexed entry fee and the founder window.
/// @dev Volume comes from captures booked through `acquireBatch`, fulfillment and `bookOnly`. The
///      expected daily volume is recomputed in the test from the `priceEscrowed` of each request.
///      Timestamps are read with `vm.getBlockTimestamp()`, which stays correct after `vm.warp`.
contract PoolAdmissionForkTest is ForkBase, PoolFixture {
    uint256 internal constant DAY = 1 days;

    PoolHarness internal pool;
    IFWAClone internal clone;
    address internal player = makeAddr("player");
    address internal carol = makeAddr("carol");

    /// @dev UTC day index of the transition to Live.
    uint256 internal liveDay;
    /// @dev FWA fees booked per day, indexed by days since `liveDay`.
    uint256[24] internal paidOnDay;

    function setUp() public {
        setUpFork();
        openFactory();
        deployDrawPacks(admin);
        vm.deal(alice, 10_000 ether);
        vm.deal(carol, 10_000 ether);
        vm.deal(bob, 10_000 ether);
        (pool, clone) = _deploy(address(0));
    }

    // ---------------------------------------------------------------- helpers

    function _forkParams(address oldPool_) internal returns (IPoolTypes.Params memory p) {
        p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.oldPool = oldPool_;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
    }

    function _deploy(address oldPool_) internal returns (PoolHarness p_, IFWAClone c_) {
        p_ = new PoolHarness(_forkParams(oldPool_));
        vm.prank(admin);
        IPool(address(p_)).createFwaPool(0);
        c_ = p_.fwaPool();
        vm.prank(address(p_));
        c_.setBool(41, true);
    }

    /// @dev Deposits 150 ETH while Opening, then opens at 01:00 UTC of the next day so that the
    ///      cooldown wait stays inside the Live day. Sets `liveDay`.
    function _open() internal {
        vm.prank(alice);
        pool.deposit{value: 150 ether}();
        pool.sizeBoard(60);
        uint256 t = (IPool(address(pool)).openingDeadlineAt() / DAY + 1) * DAY + 1 hours;
        vm.warp(t);
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
        liveDay = vm.getBlockTimestamp() / DAY;
        pool.loseGrailFund(IPool(address(pool)).grail().fund);
        warpPastCooldown(clone);
        assertEq(vm.getBlockTimestamp() / DAY, liveDay, "cooldown stays inside the Live day");
    }

    /// @dev Moves to 01:00 UTC of day `liveDay + k`, or stays when already past it.
    function _toDay(uint256 k) internal {
        uint256 t = (liveDay + k) * DAY + 1 hours;
        if (vm.getBlockTimestamp() < t) vm.warp(t);
        assertEq(vm.getBlockTimestamp() / DAY, liveDay + k, "day");
    }

    /// @dev Opens `count` requests, fulfills them and books the captures. Adds the fees to
    ///      `paidOnDay[k]`.
    function _tickets(uint256 k, uint256 count) internal {
        _toDay(k);
        uint256[] memory ids = acquirePooled(address(pool), clone, player, count);
        for (uint256 i; i < count; ++i) {
            fulfill(clone, ids[i], 0);
            (,, uint256 escrowed,,) = clone.acquisitions(ids[i]);
            paidOnDay[k] += escrowed;
        }
        pool.bookOnly(count + 5);
    }

    /// @dev Mean of `paidOnDay` over the complete days before day `k`, at most seven.
    function _expectedVolume(uint256 k) internal view returns (uint256 sum) {
        if (k == 0) return 0;
        uint256 n = k > 7 ? 7 : k;
        for (uint256 i = 1; i <= n; ++i) {
            sum += paidOnDay[k - i];
        }
        sum /= n;
    }

    function _setFloor(uint256 wei_) internal {
        vm.prank(admin);
        IPool(address(pool)).setNavCapFloor(wei_);
    }

    function _setTurnover(uint16 bps) internal {
        vm.prank(admin);
        IPool(address(pool)).setTurnover(bps);
    }

    function _setEntryFee(uint32 floorBps, uint32 capBps, uint32 paybackDays) internal {
        vm.prank(admin);
        IPool(address(pool)).setEntryFee(floorBps, capBps, paybackDays);
    }

    /// @dev Deposits `value` as `who` and returns the shares minted.
    function _depositAs(address who, uint256 value) internal returns (uint256 minted) {
        uint256 before = pool.sharesOf(who);
        vm.prank(who);
        pool.deposit{value: value}();
        minted = pool.sharesOf(who) - before;
    }

    /// @dev Shares a deposit of `value` receives at fee `feeBps`, from the NAV and supply now.
    function _sharesAt(uint256 value, uint256 feeBps) internal view returns (uint256) {
        uint256 contribution = value * feeBps / 10_000;
        return PricingLib.sharesFor(value - contribution, pool.nav(), pool.totalShares());
    }

    /// @dev Entry fee in bps for the volume and NAV now, from the stored parameters.
    function _feeNow() internal view returns (uint256) {
        (uint32 floorBps, uint32 capBps, uint32 paybackDays) = pool.entryFee();
        (uint16 premiumBps,,) = pool.feeSplit();
        uint256 raw = uint256(paybackDays) * premiumBps * pool.dailyVolume() / pool.nav();
        if (raw < floorBps) return floorBps;
        return raw > capBps ? capBps : raw;
    }

    // ---------------------------------------------------------------- cap

    function test_capEqualsTheFloorWithNoVolume() public {
        _open();
        assertEq(pool.dailyVolume(), 0);
        assertEq(pool.navCap(), pool.navCapFloor());
        assertEq(pool.navCap(), 1_000 ether);

        _setFloor(5 ether);
        assertEq(pool.navCap(), 5 ether);

        _toDay(10);
        assertEq(pool.dailyVolume(), 0, "days without captures read zero");
        assertEq(pool.navCap(), 5 ether);
    }

    function test_capFollowsASevenDayRampUpAndDown() public {
        _open();
        _setTurnover(1);
        _setFloor(50 ether);

        uint256[7] memory tickets = [uint256(1), 0, 2, 0, 3, 1, 1];
        bool aboveFloor;
        for (uint256 k; k < 16; ++k) {
            _toDay(k);
            uint256 expected = _expectedVolume(k);
            assertEq(pool.dailyVolume(), expected, "volume before today's captures");
            uint256 dynamic = expected * 10_000;
            uint256 cap = dynamic > 50 ether ? dynamic : 50 ether;
            assertEq(pool.navCap(), cap, "cap before today's captures");

            if (k < 7 && tickets[k] != 0) {
                _tickets(k, tickets[k]);
                assertGt(paidOnDay[k], 0);
                assertEq(pool.dailyVolume(), expected, "today's partial day is excluded");
                assertEq(pool.navCap(), cap, "cap does not move within a day");
            }
            assertGe(pool.navCap(), pool.navCapFloor());
            if (pool.navCap() > 50 ether) aboveFloor = true;
        }
        assertTrue(aboveFloor, "volume lifted the cap above the floor");
        assertEq(pool.dailyVolume(), 0, "volume leaves the window");
        assertEq(pool.navCap(), 50 ether, "cap back at the floor");
    }

    function test_volumeIsTheMeanOverCompleteDays() public {
        _open();
        _tickets(0, 2);
        assertEq(pool.dailyVolume(), 0, "the Live day is still open");
        _toDay(1);
        assertEq(pool.dailyVolume(), paidOnDay[0], "one complete day");
        _toDay(2);
        assertEq(pool.dailyVolume(), paidOnDay[0] / 2, "mean over two complete days");
        _toDay(8);
        assertEq(pool.dailyVolume(), 0, "day 0 is eight days old");
    }

    function test_depositAdmittedBelowTheCapAndRevertedAtIt() public {
        _open();
        uint256 nav0 = pool.nav();

        _setFloor(nav0);
        vm.expectRevert(IPoolTypes.NavCapReached.selector);
        vm.prank(bob);
        pool.deposit{value: 1 ether}();

        _setFloor(nav0 + 1);
        assertGt(_depositAs(bob, 1 ether), 0, "admitted at cap minus one wei");
        assertGt(pool.nav(), nav0 + 1);

        vm.expectRevert(IPoolTypes.NavCapReached.selector);
        vm.prank(bob);
        pool.deposit{value: 1 ether}();
    }

    function test_volumeCapClosesDepositsWhenItFallsBelowNav() public {
        _open();
        _tickets(0, 2);
        _toDay(1);
        _setFloor(1);

        _setTurnover(1);
        assertEq(pool.navCap(), pool.dailyVolume() * 10_000);
        assertGt(pool.navCap(), pool.nav(), "volume cap above NAV");
        assertGt(_depositAs(bob, 1 ether), 0);

        _setTurnover(10_000);
        assertEq(pool.navCap(), pool.dailyVolume());
        vm.expectRevert(IPoolTypes.NavCapReached.selector);
        vm.prank(bob);
        pool.deposit{value: 1 ether}();
    }

    // ---------------------------------------------------------------- entry fee

    function test_feeEqualsTheFloorWithNoHistory() public {
        _open();
        _setEntryFee(1_000, 2_500, 20);
        assertEq(pool.dailyVolume(), 0);
        assertEq(_feeNow(), 1_000);
        uint256 expected = _sharesAt(10 ether, 1_000);
        assertEq(_depositAs(bob, 10 ether), expected);
    }

    function test_feeIsPaybackDaysOfYieldInsideTheBand() public {
        _open();
        _tickets(0, 3);
        _toDay(1);

        uint256 volume = pool.dailyVolume();
        assertGt(volume, 0);
        (uint16 premiumBps,,) = pool.feeSplit();
        // paybackDays for a yield target of 1,500 bps at the NAV now.
        uint256 payback = 1_500 * pool.nav() / (uint256(premiumBps) * volume) + 1;
        _setEntryFee(1_000, 2_500, uint32(payback));

        uint256 expectedBps = payback * premiumBps * volume / pool.nav();
        assertGe(expectedBps, 1_000);
        assertLe(expectedBps, 2_500);
        assertGt(expectedBps, 1_000, "above the floor");
        assertLt(expectedBps, 2_500, "below the cap");
        assertEq(_feeNow(), expectedBps);

        uint256 expectedShares = _sharesAt(10 ether, expectedBps);
        assertEq(_depositAs(bob, 10 ether), expectedShares);
    }

    function test_feeClampsToTheCapAndTheFloor() public {
        _open();
        _tickets(0, 3);
        _toDay(1);

        uint256 volume = pool.dailyVolume();
        (uint16 premiumBps,,) = pool.feeSplit();
        uint256 payback = 1_500 * pool.nav() / (uint256(premiumBps) * volume) + 1;

        _setEntryFee(1_000, 2_500, uint32(payback * 3));
        assertGt(uint256(payback * 3) * premiumBps * volume / pool.nav(), 2_500, "raw fee above the cap");
        uint256 expectedShares = _sharesAt(10 ether, 2_500);
        assertEq(_depositAs(bob, 10 ether), expectedShares, "clamped to the cap");

        _setEntryFee(1_000, 2_500, 1);
        assertLt(uint256(premiumBps) * volume / pool.nav(), 1_000, "raw fee below the floor");
        expectedShares = _sharesAt(10 ether, 1_000);
        assertEq(_depositAs(bob, 10 ether), expectedShares, "clamped to the floor");
    }

    // ---------------------------------------------------------------- founder window

    function test_founderWindowRejectsLiveDepositsUntilDepositsOpenAt() public {
        vm.prank(admin);
        IPool(address(pool)).setFounderWindow(7 days);
        assertEq(pool.depositsOpenAt(), 0);

        // Opening deposits are unaffected.
        assertGt(_depositAs(bob, 1 ether), 0, "admitted while Opening");

        _open();
        uint256 openedAt = vm.getBlockTimestamp();
        uint256 openAt = pool.depositsOpenAt();
        assertGt(openAt, openedAt + 7 days - 1 days);
        assertLe(openAt, openedAt + 7 days);

        vm.expectRevert(IPoolTypes.DepositsClosed.selector);
        vm.prank(carol);
        pool.deposit{value: 1 ether}();

        vm.warp(openAt - 1);
        vm.expectRevert(IPoolTypes.DepositsClosed.selector);
        vm.prank(carol);
        pool.deposit{value: 1 ether}();

        vm.warp(openAt);
        assertGt(_depositAs(carol, 1 ether), 0, "admitted at depositsOpenAt");
    }

    function test_founderWindowChangeAppliesToTheNextOpenOnly() public {
        _open();
        assertEq(pool.depositsOpenAt(), uint64(liveDay * DAY + 1 hours), "zero window opens deposits at once");
        vm.prank(admin);
        IPool(address(pool)).setFounderWindow(30 days);
        assertEq(pool.founderWindowSeconds(), 30 days);
        assertEq(pool.depositsOpenAt(), uint64(liveDay * DAY + 1 hours));
        assertGt(_depositAs(carol, 1 ether), 0);
    }

    // ---------------------------------------------------------------- migration import

    function test_importIgnoresTheCapAndTheWindow() public {
        address old = makeAddr("oldPool");
        IPoolTypes.Params memory p = _forkParams(old);
        p.navCapFloor = 1 ether;
        p.founderWindowSeconds = 30 days;
        PoolHarness succ = new PoolHarness(p);
        vm.prank(admin);
        IPool(address(succ)).createFwaPool(0);
        IFWAClone succClone = succ.fwaPool();
        vm.prank(address(succ));
        succClone.setBool(41, true);

        vm.prank(alice);
        succ.deposit{value: 0.5 ether}();
        vm.warp(IPool(address(succ)).openingDeadlineAt());
        while (succ.lifecycle() == IPoolTypes.Lifecycle.Opening) succ.open();
        warpPastCooldown(succClone);

        vm.deal(old, 20 ether);
        vm.prank(old);
        IPool(address(succ)).importCash{value: 20 ether}();
        assertEq(succ.importedNav(), 20 ether);
        assertGt(succ.nav(), succ.navCap(), "imported NAV sits above the cap");

        vm.prank(old);
        IPool(address(succ)).finalizeImport(100 ether);
        assertGt(IPool(address(succ)).importedShares(), 0);

        vm.expectRevert(IPoolTypes.DepositsClosed.selector);
        vm.prank(carol);
        succ.deposit{value: 1 ether}();
        vm.warp(succ.depositsOpenAt());
        vm.expectRevert(IPoolTypes.NavCapReached.selector);
        vm.prank(carol);
        succ.deposit{value: 1 ether}();
    }
}
