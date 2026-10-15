// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";
import {FeeSplit} from "../../src/sponsor/FeeSplit.sol";
import {SponsoredPrize} from "../../src/sponsor/SponsoredPrize.sol";
import {DeploySponsor} from "../../script/DeploySponsor.s.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";

interface IShapesFeeAdmin {
    function admin() external view returns (address);
    function setFeeRecipient(address newRecipient) external;
}

/// @notice Sponsored prize deal against the deployed Wrapped Cryptopunks and Shapes contracts and a
///         FWA clone created by the pool: fee routing, phases, decay, capture, reclaim and rescue.
/// @dev The test cap is a few mint fees so that the cap is reached with direct Shapes mints. The test
///      floor is 1 ETH, which the pool accepts under its probability cap with a 30 ETH deposit.
contract SponsorForkTest is ForkBase, PoolFixture {
    address internal constant WPUNKS = 0xb7F7F6C52F2e2fdb1963Eab30438024864c313F6;
    uint256 internal constant PARKED_PRICE = 30 ether;
    uint256 internal constant FLOOR = 1 ether;
    uint256 internal constant CAP = 0.003 ether;

    PoolHarness internal pool;
    IFWAClone internal clone;
    FeeSplit internal feeSplit;
    SponsoredPrize internal prize;
    address internal dealOwner = makeAddr("dealOwner");
    address internal sponsor = makeAddr("sponsor");
    address internal minter = makeAddr("minter");
    address internal player = makeAddr("player");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    uint256 internal decay = 10 ether;
    uint256 internal parked = PARKED_PRICE;
    uint256 internal fee;
    uint256 internal tokenId;
    uint256 internal listingId;

    function setUp() public {
        setUpFork();
        openFactory();
        vm.prank(factory.owner());
        factory.setInventoryChangeCooldown(0);
        deployDrawPacks(admin);
        vm.deal(alice, 10_000 ether);
        _deployPool();
        _open(30 ether);
        fee = shapes.mintFee();

        feeSplit = new FeeSplit(dealOwner);
        (prize, tokenId, listingId) = _deal(WPUNKS, 0);

        vm.prank(IShapesFeeAdmin(SHAPES_ADDR).admin());
        IShapesFeeAdmin(SHAPES_ADDR).setFeeRecipient(address(feeSplit));
        assertEq(shapes.feeRecipient(), address(feeSplit));
    }

    // ---------------------------------------------------------------- helpers

    function _deployPool() internal {
        IPoolTypes.Params memory p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
        pool = new PoolHarness(p);
        vm.prank(admin);
        IPool(address(pool)).createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);
    }

    function _open(uint256 depositWei) internal {
        vm.prank(alice);
        pool.deposit{value: depositWei}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
        while (pool.settleDue() == IPoolTypes.SettleTrigger.Deep) pool.settle(20);
        warpPastCooldown(clone);
    }

    function _ip() internal view returns (IPool) {
        return IPool(address(pool));
    }

    /// @dev Deploys a prize for the token of `collection` at `index` (Wrapped Cryptopunks enumeration,
    ///      or a freshly minted Shape when `collection` is Shapes), gives it to `sponsor`, wires
    ///      `feeSplit`, makes the prize the pool's registrar and has the sponsor approve it. `stake`
    ///      is the next step.
    function _prepare(address collection, uint256 index) internal returns (SponsoredPrize p, uint256 id) {
        if (collection == WPUNKS) {
            id = IERC721Enumerable(WPUNKS).tokenByIndex(index);
            address holder = IERC721(WPUNKS).ownerOf(id);
            vm.prank(holder);
            IERC721(WPUNKS).transferFrom(holder, sponsor, id);
        } else {
            id = mintShapes(minter, 0.1 ether, 1);
            vm.prank(minter);
            IERC721(collection).transferFrom(minter, sponsor, id);
        }
        p = new SponsoredPrize(
            address(pool), address(feeSplit), sponsor, CAP, collection, parked, FLOOR, decay, 30 days
        );
        vm.prank(admin);
        _ip().setRegistrar(address(p));
        vm.startPrank(dealOwner);
        if (feeSplit.sponsor() != sponsor) feeSplit.setSponsor(sponsor, CAP);
        feeSplit.setPrize(address(p));
        vm.stopPrank();
        vm.prank(sponsor);
        IERC721(collection).approve(address(p), id);
    }

    /// @dev `_prepare` against a new `FeeSplit`, since the one of the setUp deal is locked.
    function _prepareFresh(uint256 index) internal returns (SponsoredPrize p, uint256 id) {
        FeeSplit saved = feeSplit;
        feeSplit = new FeeSplit(dealOwner);
        (p, id) = _prepare(WPUNKS, index);
        feeSplit = saved;
    }

    /// @dev `_prepare`, then the sponsor stakes and the pool activates the listing.
    function _deal(address collection, uint256 index) internal returns (SponsoredPrize p, uint256 id, uint256 lid) {
        (p, id) = _prepare(collection, index);
        vm.prank(sponsor);
        p.stake(id);
        lid = p.listingId();
        vm.prank(address(pool));
        clone.activateListings(20);
    }

    /// @dev Mints `n` Shapes so the Shapes contract credits `n` mint fees to `feeSplit`, then forwards them.
    function _payFees(uint256 n) internal {
        mintShapes(minter, 0.1 ether, n);
        shapes.withdrawFees(address(feeSplit));
    }

    function _assertI1() internal view {
        assertGe(address(pool).balance, pool.cash() + pool.maintenance() + _ip().grail().fund, "I1");
    }

    function _pulls() internal view returns (uint64) {
        return _ip().grail().pulls;
    }

    /// @dev One pooled acquisition that selects an ordinary listing, settled: one pull.
    function _pull() internal {
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        fulfill(clone, ids[0], wordAvoiding(clone, listingId));
        vm.prank(keeper);
        pool.settle(20);
    }

    /// @dev One pooled acquisition that selects the prize listing, settled.
    function _capture() internal {
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        fulfill(clone, ids[0], wordFor(clone, listingId));
        vm.prank(keeper);
        pool.settle(20);
    }

    function _price() internal view returns (uint256) {
        return _priceOf(listingId);
    }

    function _priceOf(uint256 lid) internal view returns (uint256) {
        IPoolTypes.ForeignListing[] memory all = _ip().foreignListings();
        for (uint256 i; i < all.length; ++i) {
            if (all[i].listingId == lid) return all[i].notional;
        }
        revert("no entry");
    }

    /// @dev Warps one `rotateInterval`, after which the pool accepts another foreign reprice.
    function _nextInterval() internal {
        vm.warp(block.timestamp + _ip().rotateInterval());
    }

    function _hot() internal {
        _payFees(3);
        assertEq(feeSplit.paidWei(), CAP);
        assertEq(uint8(prize.phase()), uint8(SponsoredPrize.Phase.Hot));
    }

    // ---------------------------------------------------------------- setup state

    function test_dealIsWired() public view {
        assertEq(prize.listingId(), listingId);
        assertTrue(prize.active());
        assertEq(uint8(prize.phase()), uint8(SponsoredPrize.Phase.Parked));
        assertEq(IERC721(WPUNKS).ownerOf(tokenId), address(clone));
        assertEq(_price(), PARKED_PRICE);
        assertEq(feeSplit.prize(), address(prize));
        assertEq(feeSplit.sponsor(), sponsor);
        assertEq(feeSplit.capWei(), CAP);
        assertEq(prize.startedAt(), block.timestamp);
        assertTrue(prize.staked());
        assertFalse(prize.canStake(tokenId));
        assertEq(prize.tokenId(), tokenId);
        assertEq(prize.reclaimAfter(), block.timestamp + 30 days);
    }

    // ---------------------------------------------------------------- fee routing

    function test_feesRouteToTheSponsorUntilTheCapThenToTheOwner() public {
        _payFees(2);
        assertEq(feeSplit.paidWei(), 2 * fee);
        assertEq(feeSplit.sponsorBalance(), 2 * fee);
        assertEq(feeSplit.ownerBalance(), 0);

        // 3 more fees: 1 completes the cap, 2 go to the owner.
        _payFees(3);
        assertEq(feeSplit.paidWei(), CAP);
        assertEq(feeSplit.sponsorBalance(), CAP);
        assertEq(feeSplit.ownerBalance(), 2 * fee);
        assertEq(uint8(prize.phase()), uint8(SponsoredPrize.Phase.Hot));

        _payFees(1);
        assertEq(feeSplit.paidWei(), CAP, "paid stops at the cap");
        assertEq(feeSplit.ownerBalance(), 3 * fee);
    }

    function test_theFeesOfThePoolsOwnReplacementMintsRoute() public {
        uint256 owedBefore = shapes.feesOwedTo(address(feeSplit));
        _pull();
        // The captured item queued a replacement; a settle after `batchMaxAge` mints it.
        vm.warp(block.timestamp + _ip().batchMaxAge());
        vm.prank(keeper);
        pool.settle(20);
        uint256 owed = shapes.feesOwedTo(address(feeSplit)) - owedBefore;
        assertGt(owed, 0, "the pool's replacement mints accrued fees to the fee split");
        emit log_named_uint("fees from one settled pull, wei", owed);
        shapes.withdrawFees(address(feeSplit));
        uint256 toSponsor = owed < CAP ? owed : CAP;
        assertEq(feeSplit.sponsorBalance(), toSponsor);
        assertEq(feeSplit.ownerBalance(), owed - toSponsor);
        _assertI1();
    }

    function test_withdrawPaysEachBalanceOnce() public {
        _payFees(5);
        uint256 sponsorBefore = sponsor.balance;
        uint256 ownerBefore = dealOwner.balance;

        vm.prank(sponsor);
        feeSplit.withdraw();
        assertEq(sponsor.balance - sponsorBefore, CAP);
        assertEq(feeSplit.sponsorBalance(), 0);
        assertEq(feeSplit.ownerBalance(), 2 * fee, "the owner balance is untouched");
        vm.prank(sponsor);
        vm.expectRevert(FeeSplit.NothingToWithdraw.selector);
        feeSplit.withdraw();

        vm.prank(dealOwner);
        feeSplit.withdraw();
        assertEq(dealOwner.balance - ownerBefore, 2 * fee);
        vm.prank(dealOwner);
        vm.expectRevert(FeeSplit.NothingToWithdraw.selector);
        feeSplit.withdraw();

        vm.prank(stranger);
        vm.expectRevert(FeeSplit.NothingToWithdraw.selector);
        feeSplit.withdraw();
        assertEq(address(feeSplit).balance, 0);
    }

    function test_dealTermsLockWhileTheDealRuns() public {
        vm.startPrank(dealOwner);
        vm.expectRevert(FeeSplit.Locked.selector);
        feeSplit.setSponsor(stranger, 1 ether);
        vm.expectRevert(FeeSplit.Locked.selector);
        feeSplit.setPrize(address(0));
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(FeeSplit.NotOwner.selector);
        feeSplit.setSponsor(stranger, 1 ether);
    }

    function test_setSponsorAfterAPaidDealResetsPaidWeiAndKeepsBalances() public {
        _hot();
        _payFees(2);
        uint256 sponsorBalance = feeSplit.sponsorBalance();
        uint256 ownerBalance = feeSplit.ownerBalance();
        assertEq(sponsorBalance, CAP);
        assertGt(ownerBalance, 0);
        _capture();
        assertFalse(prize.active());

        vm.startPrank(dealOwner);
        vm.expectRevert(FeeSplit.SponsorBalanceUnpaid.selector);
        feeSplit.setSponsor(stranger, 2 * CAP);
        vm.expectRevert(FeeSplit.DealLocked.selector);
        feeSplit.setPrize(address(0));

        feeSplit.setSponsor(sponsor, 2 * CAP);
        vm.stopPrank();

        assertEq(feeSplit.paidWei(), 0, "paidWei reset");
        assertEq(feeSplit.capWei(), 2 * CAP);
        assertEq(feeSplit.sponsorBalance(), sponsorBalance, "sponsor balance kept");
        assertEq(feeSplit.ownerBalance(), ownerBalance, "owner balance kept");

        vm.prank(sponsor);
        feeSplit.withdraw();
        vm.prank(dealOwner);
        feeSplit.setSponsor(stranger, 3 * CAP);
        assertEq(feeSplit.sponsor(), stranger);
        assertEq(feeSplit.paidWei(), 0);
        assertEq(feeSplit.ownerBalance(), ownerBalance, "owner balance kept");
    }

    // ---------------------------------------------------------------- decay

    function test_theCapFlipsThePhaseAndTickDecaysToTheFloorAndStops() public {
        _hot();
        uint256 expectedPulls = _pulls();
        prize.tick();
        assertEq(_price(), PARKED_PRICE, "the first tick starts the decay, no change");
        assertTrue(prize.hotStarted());
        assertEq(prize.hotFromPull(), expectedPulls);

        _pull();
        _nextInterval();
        prize.tick();
        assertEq(_price(), PARKED_PRICE - decay * (_pulls() - prize.hotFromPull()), "one pull of decay");
        assertEq(_price(), 20 ether);

        _pull();
        _nextInterval();
        prize.tick();
        assertEq(_price(), 10 ether);

        _pull();
        _nextInterval();
        prize.tick();
        assertEq(_price(), FLOOR, "stops at the floor");

        _pull();
        _nextInterval();
        prize.tick();
        assertEq(_price(), FLOOR, "no change below the floor");
        _assertI1();
    }

    function test_tickSkipsAStepSmallerThanOnePercent() public {
        // A second deal with a decay of 0.1 ETH per pull on its own fee split, Hot from the start.
        FeeSplit second = new FeeSplit(dealOwner);
        FeeSplit saved = feeSplit;
        feeSplit = second;
        decay = 0.1 ether;
        (SponsoredPrize slow,, uint256 lid) = _deal(WPUNKS, 1);
        feeSplit = saved;
        (bool ok,) = address(second).call{value: CAP}("");
        assertTrue(ok);
        assertEq(uint8(slow.phase()), uint8(SponsoredPrize.Phase.Hot));

        slow.tick();
        for (uint256 i; i < 2; ++i) {
            _pull();
            slow.tick();
        }
        assertEq(_priceOf(lid), PARKED_PRICE, "0.2 ETH is below 1 percent of 30 ETH");
        _pull();
        slow.tick();
        assertEq(_priceOf(lid), PARKED_PRICE - 0.3 ether, "0.3 ETH is exactly 1 percent");
    }

    function test_tickInsideTheRepriceIntervalKeepsThePriceAndTheNextIntervalRetries() public {
        _hot();
        prize.tick();
        _pull();
        _nextInterval();
        prize.tick();
        assertEq(_price(), 20 ether);

        _pull();
        vm.expectCall(address(pool), abi.encodeCall(IPool.repriceForeign, (listingId, 10 ether)));
        prize.tick();
        assertEq(_price(), 20 ether, "one reprice per interval");

        _nextInterval();
        prize.tick();
        assertEq(_price(), 10 ether, "retried after the interval");
    }

    function test_tickIsANoOpInParked() public {
        _pull();
        prize.tick();
        assertEq(_price(), PARKED_PRICE);
        assertFalse(prize.hotStarted());
    }

    function test_tickNeverRevertsWhileFwaIsBusy() public {
        _hot();
        prize.tick();
        _pull();
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        assertGt(clone.unsettledAcquisitionCount(), 0);
        vm.expectCall(address(pool), abi.encodeCall(IPool.repriceForeign, (listingId, 20 ether)));
        prize.tick();
        assertEq(_price(), PARKED_PRICE, "unchanged while busy");

        fulfill(clone, ids[0], wordAvoiding(clone, listingId));
        vm.prank(keeper);
        pool.settle(20);
        prize.tick();
        assertLt(_price(), PARKED_PRICE, "retried after the pool settled");
    }

    function test_tickNeverRevertsWhenThePriceDropPassesTheProbabilityCap() public {
        _hot();
        prize.tick();
        for (uint256 i; i < 3; ++i) {
            _pull();
        }
        vm.prank(admin);
        _ip().setGrailProbCap(1);
        vm.expectCall(address(pool), abi.encodeCall(IPool.repriceForeign, (listingId, FLOOR)));
        prize.tick();
        assertEq(_price(), PARKED_PRICE, "unchanged under the cap");
    }

    // ---------------------------------------------------------------- capture

    function test_aCaptureInParkedStopsSponsorPaymentsAndTheProceedsFundGrail() public {
        _payFees(1);
        uint256 fundBefore = _ip().grail().fund;
        uint256 balanceBefore = address(pool).balance;

        _capture();

        assertEq(IERC721(WPUNKS).ownerOf(tokenId), player, "the purchaser holds the punk");
        assertTrue(prize.captured());
        assertFalse(prize.active());
        assertEq(_ip().foreignListings().length, 0);
        uint256 proceeds = _ip().grail().fund - fundBefore;
        assertGt(proceeds, 0, "the proceeds reached the GRAIL fund");
        assertEq(address(prize).balance, 0);
        // The pool paid the proceeds out and took them back through fundGrail.
        assertGe(address(pool).balance, balanceBefore);
        _assertI1();

        _payFees(4);
        assertEq(feeSplit.paidWei(), fee, "paid stays at the amount before the capture");
        assertEq(feeSplit.sponsorBalance(), fee);
        assertEq(feeSplit.ownerBalance(), 4 * fee);
    }

    function test_aCaptureInHotAlsoFundsGrail() public {
        _hot();
        uint256 fundBefore = _ip().grail().fund;
        _capture();
        assertTrue(prize.captured());
        assertGt(_ip().grail().fund, fundBefore);
        _assertI1();
    }

    function test_revert_onForeignCaptureFromAnyoneButThePool() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(SponsoredPrize.NotPool.selector);
        prize.onForeignCapture{value: 1 ether}(listingId, tokenId, 1 ether);
        vm.prank(dealOwner);
        vm.expectRevert(SponsoredPrize.NotPool.selector);
        prize.onForeignCapture(listingId, tokenId, 0);
        assertFalse(prize.captured());
    }

    // ---------------------------------------------------------------- reclaim

    function test_reclaimAfterThirtyDaysInParkedReturnsThePunkAndEndsPayments() public {
        _payFees(1);
        vm.warp(prize.reclaimAfter());
        vm.prank(sponsor);
        prize.reclaim();

        assertEq(IERC721(WPUNKS).ownerOf(tokenId), sponsor);
        assertFalse(prize.active());
        assertEq(_ip().foreignListings().length, 0);
        _assertI1();

        _payFees(2);
        assertEq(feeSplit.paidWei(), fee);
        assertEq(feeSplit.sponsorBalance(), fee);
        assertEq(feeSplit.ownerBalance(), 2 * fee, "later fees go to the owner");
    }

    function test_revert_reclaimBeforeThirtyDays() public {
        uint256 at = prize.reclaimAfter();
        vm.warp(at - 1);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SponsoredPrize.TooEarly.selector, at));
        prize.reclaim();
    }

    function test_revert_reclaimInHot() public {
        _hot();
        vm.warp(prize.reclaimAfter());
        vm.prank(sponsor);
        vm.expectRevert(SponsoredPrize.WrongPhase.selector);
        prize.reclaim();
        assertEq(IERC721(WPUNKS).ownerOf(tokenId), address(clone));
    }

    function test_revert_reclaimByAnyoneButTheSponsor() public {
        vm.warp(prize.reclaimAfter());
        vm.prank(dealOwner);
        vm.expectRevert(SponsoredPrize.NotSponsor.selector);
        prize.reclaim();
    }

    // ---------------------------------------------------------------- stake

    function test_stakeRegistersListsAtTheParkedPriceLocksTheSplitAndSetsReclaimAfter() public {
        (SponsoredPrize p, uint256 id) = _prepareFresh(1);
        FeeSplit second = p.feeSplit();
        assertFalse(p.staked());
        assertEq(p.tokenId(), 0);
        assertEq(p.reclaimAfter(), 0);
        assertFalse(second.locked());
        uint64 pulls = _pulls();
        uint256 t0 = block.timestamp;

        vm.expectEmit(false, true, false, false, address(p));
        emit SponsoredPrize.Staked(0, id);
        vm.prank(sponsor);
        p.stake(id);

        assertTrue(p.staked());
        assertEq(p.tokenId(), id);
        assertEq(p.reclaimAfter(), t0 + 30 days);
        assertEq(p.startedAt(), t0);
        assertEq(p.listedAtPull(), pulls);
        assertTrue(second.locked());
        assertEq(IERC721(WPUNKS).ownerOf(id), address(clone));
        assertEq(_priceOf(p.listingId()), PARKED_PRICE);
        assertEq(_ip().foreignListings().length, 2);
        _assertI1();
    }

    function test_revert_stakeByAnyoneButTheSponsor() public {
        (SponsoredPrize p, uint256 id) = _prepareFresh(1);
        vm.prank(dealOwner);
        vm.expectRevert(SponsoredPrize.NotSponsor.selector);
        p.stake(id);
        vm.prank(admin);
        vm.expectRevert(SponsoredPrize.NotSponsor.selector);
        p.stake(id);
        vm.prank(stranger);
        vm.expectRevert(SponsoredPrize.NotSponsor.selector);
        p.stake(id);
    }

    function test_revert_stakeWithoutTheRegistrarRole() public {
        (SponsoredPrize p, uint256 id) = _prepareFresh(1);
        vm.prank(admin);
        _ip().setRegistrar(address(0));
        vm.prank(sponsor);
        vm.expectRevert(SponsoredPrize.NotRegistrar.selector);
        p.stake(id);
    }

    function test_revert_stakeWhenAnotherAddressIsTheRegistrar() public {
        (SponsoredPrize p, uint256 id) = _prepareFresh(1);
        vm.prank(admin);
        _ip().setRegistrar(stranger);
        vm.prank(sponsor);
        vm.expectRevert(SponsoredPrize.NotRegistrar.selector);
        p.stake(id);
    }

    function test_revert_stakeWithoutApproval() public {
        (SponsoredPrize p, uint256 id) = _prepareFresh(1);
        vm.prank(sponsor);
        IERC721(WPUNKS).approve(address(0), id);
        vm.prank(sponsor);
        vm.expectRevert();
        p.stake(id);
    }

    /// @dev A token of another collection cannot be staked: the prize pulls from its own immutable
    ///      `collection`, so no input selects another collection.
    function test_revert_stakeATokenTheSponsorDoesNotOwn() public {
        (SponsoredPrize p, uint256 id) = _prepareFresh(1);
        uint256 other = IERC721Enumerable(WPUNKS).tokenByIndex(2);
        assertTrue(IERC721(WPUNKS).ownerOf(other) != sponsor);
        vm.prank(sponsor);
        vm.expectRevert();
        p.stake(other);
        assertFalse(p.staked());
        assertEq(p.tokenId(), 0);
        assertEq(IERC721(WPUNKS).ownerOf(id), sponsor);
    }

    function test_revert_stakeTwice() public {
        vm.prank(sponsor);
        vm.expectRevert(SponsoredPrize.AlreadyStaked.selector);
        prize.stake(tokenId);
    }

    function test_theSponsorStakesADifferentPunkInEachOfTwoDeals() public {
        (SponsoredPrize p1, uint256 id1) = _prepareFresh(1);
        vm.prank(sponsor);
        p1.stake(id1);
        (SponsoredPrize p2, uint256 id2) = _prepareFresh(2);
        vm.prank(sponsor);
        p2.stake(id2);

        assertTrue(id1 != id2 && id1 != tokenId && id2 != tokenId);
        assertEq(p1.tokenId(), id1);
        assertEq(p2.tokenId(), id2);
        assertEq(IERC721(WPUNKS).ownerOf(id1), address(clone));
        assertEq(IERC721(WPUNKS).ownerOf(id2), address(clone));
        assertEq(_priceOf(p1.listingId()), PARKED_PRICE);
        assertEq(_priceOf(p2.listingId()), PARKED_PRICE);
        assertEq(_ip().foreignListings().length, 3);
        _assertI1();
    }

    function test_canStakeReflectsEachCondition() public {
        (SponsoredPrize p, uint256 id) = _prepareFresh(1);
        assertTrue(p.canStake(id));

        uint256 unapproved = IERC721Enumerable(WPUNKS).tokenByIndex(2);
        address holder = IERC721(WPUNKS).ownerOf(unapproved);
        vm.prank(holder);
        IERC721(WPUNKS).transferFrom(holder, sponsor, unapproved);
        assertFalse(p.canStake(unapproved), "owned but not approved");

        vm.prank(sponsor);
        IERC721(WPUNKS).approve(address(0), id);
        assertFalse(p.canStake(id), "no approval");
        vm.prank(sponsor);
        IERC721(WPUNKS).setApprovalForAll(address(p), true);
        assertTrue(p.canStake(id), "approval for all");
        assertTrue(p.canStake(unapproved), "approval for all covers every owned token");

        vm.prank(admin);
        _ip().setRegistrar(stranger);
        assertFalse(p.canStake(id), "not the registrar");
        vm.prank(admin);
        _ip().setRegistrar(address(p));
        assertTrue(p.canStake(id));

        vm.prank(sponsor);
        IERC721(WPUNKS).transferFrom(sponsor, stranger, id);
        assertFalse(p.canStake(id), "sponsor does not own the token");
        assertFalse(p.canStake(type(uint256).max), "token does not exist");

        assertFalse(prize.canStake(tokenId), "staked");
    }

    function test_revert_stakeRequiresTheFeeSplitToHoldTheTermsOfThePrize() public {
        FeeSplit other = new FeeSplit(dealOwner);
        (SponsoredPrize p, uint256 id) = _prepareFresh(1);
        SponsoredPrize q = new SponsoredPrize(
            address(pool), address(other), sponsor, CAP, WPUNKS, PARKED_PRICE, FLOOR, decay, 30 days
        );
        vm.prank(admin);
        _ip().setRegistrar(address(q));
        vm.prank(sponsor);
        IERC721(WPUNKS).approve(address(q), id);
        vm.startPrank(dealOwner);
        other.setSponsor(sponsor, 2 * CAP);
        other.setPrize(address(q));
        vm.stopPrank();
        vm.prank(sponsor);
        vm.expectRevert(SponsoredPrize.TermsMismatch.selector);
        q.stake(id);
        vm.prank(dealOwner);
        other.setSponsor(stranger, CAP);
        vm.prank(sponsor);
        vm.expectRevert(SponsoredPrize.TermsMismatch.selector);
        q.stake(id);
        assertFalse(p.staked());
    }

    // ---------------------------------------------------------------- rescue

    /// @dev A Shape lent as a prize and won by the Shapes contract: Shapes cannot receive the transfer,
    ///      so FWA refunds the delivery and the pool holds the token unlisted.
    function _griefedShape() internal returns (SponsoredPrize p, uint256 id, uint256 lid) {
        // The Wrapped Cryptopunks deal stays registered; the second deal is the Shape.
        FeeSplit second = new FeeSplit(dealOwner);
        FeeSplit saved = feeSplit;
        feeSplit = second;
        (p, id, lid) = _deal(SHAPES_ADDR, 0);
        feeSplit = saved;
        listingId = lid;
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, SHAPES_ADDR, 1);
        fulfill(clone, ids[0], wordFor(clone, lid));
        (, uint64 deadline) = clone.pendingDeliveries(lid);
        vm.warp(deadline);
        vm.prank(SHAPES_ADDR);
        clone.refundFailedDelivery(lid);
        pool.bookOnly(5);
    }

    function test_rescueWithdrawsAnUnlistedTokenToTheSponsorInParked() public {
        (SponsoredPrize p, uint256 id,) = _griefedShape();
        assertFalse(p.active(), "unlisted entry is not active");

        vm.prank(stranger);
        vm.expectRevert(SponsoredPrize.NotOwner.selector);
        p.rescue(sponsor);
        vm.prank(dealOwner);
        vm.expectRevert(SponsoredPrize.WrongDestination.selector);
        p.rescue(dealOwner);

        vm.prank(dealOwner);
        p.rescue(sponsor);
        assertEq(IERC721(SHAPES_ADDR).ownerOf(id), sponsor);
        assertEq(_ip().foreignListings().length, 1, "only the punk entry is left");
        _assertI1();
    }

    function test_aRefundedDeliveryKeepsThePhaseAndTheTermsOfTheDeal() public {
        (SponsoredPrize p, uint256 id,) = _griefedShape();
        FeeSplit split = p.feeSplit();
        assertFalse(p.active());
        assertTrue(split.locked(), "still locked while the entry is unlisted");

        vm.startPrank(dealOwner);
        vm.expectRevert(FeeSplit.Locked.selector);
        split.setSponsor(sponsor, 0);
        vm.expectRevert(FeeSplit.Locked.selector);
        split.setPrize(address(0));
        vm.stopPrank();
        assertEq(uint8(p.phase()), uint8(SponsoredPrize.Phase.Parked));

        vm.prank(dealOwner);
        vm.expectRevert(SponsoredPrize.WrongDestination.selector);
        p.rescue(dealOwner);
        vm.prank(dealOwner);
        p.rescue(sponsor);
        assertEq(IERC721(SHAPES_ADDR).ownerOf(id), sponsor);
        assertFalse(split.locked(), "unlocked after the rescue");
    }

    function test_revert_rescueWhileTheEntryIsListed() public {
        vm.prank(dealOwner);
        vm.expectRevert(SponsoredPrize.NotUnlisted.selector);
        prize.rescue(sponsor);
    }

    // ---------------------------------------------------------------- lock

    function test_theDealTermsCannotChangeAfterStart() public {
        assertTrue(feeSplit.locked());
        vm.startPrank(dealOwner);
        vm.expectRevert(FeeSplit.Locked.selector);
        feeSplit.setSponsor(sponsor, 0);
        vm.expectRevert(FeeSplit.Locked.selector);
        feeSplit.setSponsor(stranger, CAP);
        vm.expectRevert(FeeSplit.Locked.selector);
        feeSplit.setPrize(address(0));
        vm.stopPrank();
        assertEq(feeSplit.capWei(), CAP);
        assertEq(feeSplit.sponsor(), sponsor);
        assertEq(uint8(prize.phase()), uint8(SponsoredPrize.Phase.Parked));

        vm.prank(stranger);
        vm.expectRevert(FeeSplit.NotPrize.selector);
        feeSplit.unlock();
        vm.prank(dealOwner);
        vm.expectRevert(FeeSplit.NotPrize.selector);
        feeSplit.lock();
    }

    function test_theFeeSplitUnlocksWhenTheDealEnds() public {
        _capture();
        assertFalse(feeSplit.locked(), "captured");

        FeeSplit second = new FeeSplit(dealOwner);
        FeeSplit saved = feeSplit;
        feeSplit = second;
        (SponsoredPrize p,,) = _deal(WPUNKS, 1);
        feeSplit = saved;
        assertTrue(second.locked());
        vm.warp(p.reclaimAfter());
        vm.prank(sponsor);
        p.reclaim();
        assertFalse(second.locked(), "reclaimed");
    }

    // ---------------------------------------------------------------- exported token

    function _export() internal {
        vm.prank(admin);
        _ip().startExit(address(pool));
        for (uint256 i; i < 40 && !_ip().exportStep(50); ++i) {}
        assertEq(uint8(pool.lifecycle()), uint8(IPoolTypes.Lifecycle.Exported));
    }

    function test_releaseHeldReturnsAnExportedTokenToTheSponsorInParked() public {
        _export();
        assertEq(IERC721(WPUNKS).ownerOf(tokenId), address(prize), "the export sent the token to the controller");
        vm.prank(stranger);
        vm.expectRevert(SponsoredPrize.NotParty.selector);
        prize.releaseHeld();

        vm.prank(dealOwner);
        prize.releaseHeld();
        assertEq(IERC721(WPUNKS).ownerOf(tokenId), sponsor);
        assertFalse(feeSplit.locked());
        _payFees(1);
        assertEq(feeSplit.sponsorBalance(), 0, "the prize is no longer active");
    }

    function test_releaseHeldSendsAnExportedTokenToTheOwnerInHot() public {
        _hot();
        _export();
        vm.prank(sponsor);
        prize.releaseHeld();
        assertEq(IERC721(WPUNKS).ownerOf(tokenId), dealOwner);
        assertFalse(feeSplit.locked());
    }

    function test_revert_releaseHeldWhileThePoolHoldsTheToken() public {
        vm.prank(sponsor);
        vm.expectRevert();
        prize.releaseHeld();
        assertEq(IERC721(WPUNKS).ownerOf(tokenId), address(clone));
        assertTrue(feeSplit.locked());
    }

    function test_onERC721ReceivedRejectsEveryTokenBeforeStake() public {
        (SponsoredPrize p, uint256 id) = _prepareFresh(1);
        vm.prank(WPUNKS);
        vm.expectRevert(SponsoredPrize.WrongToken.selector);
        p.onERC721Received(address(0), address(0), id, "");
    }

    function test_onERC721ReceivedAcceptsOnlyTheTokenOfTheDeal() public {
        vm.prank(WPUNKS);
        assertEq(prize.onERC721Received(address(0), address(0), tokenId, ""), bytes4(0x150b7a02));
        vm.prank(WPUNKS);
        vm.expectRevert(SponsoredPrize.WrongToken.selector);
        prize.onERC721Received(address(0), address(0), tokenId + 1, "");
        vm.prank(stranger);
        vm.expectRevert(SponsoredPrize.WrongToken.selector);
        prize.onERC721Received(address(0), address(0), tokenId, "");
    }

    // ---------------------------------------------------------------- capture of another listing

    function test_aCaptureOfAnotherListingOfThePrizeDoesNotEndTheDeal() public {
        uint256 id2 = IERC721Enumerable(WPUNKS).tokenByIndex(1);
        address holder = IERC721(WPUNKS).ownerOf(id2);
        vm.prank(holder);
        IERC721(WPUNKS).transferFrom(holder, admin, id2);
        vm.startPrank(admin);
        IERC721(WPUNKS).approve(address(pool), id2);
        _ip().registerForeign(WPUNKS, id2, address(prize), PARKED_PRICE);
        vm.stopPrank();
        IPoolTypes.ForeignListing[] memory all = _ip().foreignListings();
        uint256 lid2 = all[all.length - 1].listingId;
        assertTrue(lid2 != listingId);
        vm.prank(address(pool));
        clone.activateListings(20);

        vm.prank(address(pool));
        vm.expectRevert(SponsoredPrize.UnknownEntry.selector);
        prize.onForeignCapture(lid2, id2, 0);

        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        fulfill(clone, ids[0], wordFor(clone, lid2));
        vm.prank(keeper);
        pool.settle(20);

        assertEq(IERC721(WPUNKS).ownerOf(id2), player, "the second token was won");
        assertFalse(prize.captured());
        assertTrue(prize.active());
        assertTrue(feeSplit.locked());
        _assertI1();
    }

    // ---------------------------------------------------------------- floor

    function _slowDeal() internal returns (SponsoredPrize p, uint256 lid) {
        FeeSplit second = new FeeSplit(dealOwner);
        FeeSplit saved = feeSplit;
        feeSplit = second;
        (p,, lid) = _deal(WPUNKS, 1);
        feeSplit = saved;
        (bool ok,) = address(second).call{value: CAP}("");
        assertTrue(ok);
        assertEq(uint8(p.phase()), uint8(SponsoredPrize.Phase.Hot));
    }

    function test_aTargetJustAboveTheFloorSnapsToTheFloor() public {
        // 30 - 3 * 9.665 = 1.005 ETH, which is 0.5 percent above the floor.
        decay = 9.665 ether;
        (SponsoredPrize p, uint256 lid) = _slowDeal();
        p.tick();
        for (uint256 i; i < 3; ++i) {
            _pull();
            _nextInterval();
            p.tick();
        }
        assertEq(_priceOf(lid), FLOOR, "snapped to the floor");
        assertFalse(p.atFloor());
    }

    function test_aPriceWithinOnePercentOfTheFloorIsFinal() public {
        // Parked at 1.005 ETH: the step to the 1 ETH floor is below the pool's 1 percent minimum.
        parked = 1.005 ether;
        (SponsoredPrize p, uint256 lid) = _slowDeal();
        p.tick();
        assertTrue(p.atFloor());
        assertEq(_priceOf(lid), 1.005 ether);

        _pull();
        _nextInterval();
        vm.expectCall(address(pool), abi.encodeCall(IPool.repriceForeign, (lid, FLOOR)), 0);
        p.tick();
        assertEq(_priceOf(lid), 1.005 ether, "no further attempts");
    }

    // ---------------------------------------------------------------- deploy script

    function _deployTerms(address owner_) internal view returns (DeploySponsor.Terms memory t) {
        t.pool = address(pool);
        t.owner = owner_;
        t.sponsor = sponsor;
        t.collection = WPUNKS;
        t.parkedPriceWei = PARKED_PRICE;
        t.floorWei = 0.25 ether;
        t.decayWeiPerPull = 0.001 ether;
        t.reclaimDelay = 30 days;
        t.capWei = 45 ether;
    }

    function test_deployScriptDeploysAndReadsBackEveryValue() public {
        DeploySponsor script = new DeploySponsor();
        (FeeSplit f, SponsoredPrize p) = script.runWith(_deployTerms(DEFAULT_SENDER));
        assertEq(f.owner(), DEFAULT_SENDER);
        assertEq(f.capWei(), 45 ether);
        assertEq(f.prize(), address(p));
        assertEq(p.reclaimDelay(), 30 days);
        assertEq(p.reclaimAfter(), 0);
        assertEq(p.tokenId(), 0);
        assertTrue(_ip().registrar() != address(p), "the broadcaster is not the pool admin");
        assertEq(p.floorWei(), 0.25 ether);
        assertEq(p.decayWeiPerPull(), 0.001 ether);
    }

    function test_deployScriptSetsTheRegistrarWhenTheBroadcasterIsThePoolAdmin() public {
        vm.prank(admin);
        _ip().setAdmin(DEFAULT_SENDER);
        DeploySponsor script = new DeploySponsor();
        (, SponsoredPrize p) = script.runWith(_deployTerms(DEFAULT_SENDER));
        assertEq(_ip().registrar(), address(p));
    }

    function test_deployScriptRefusesAForeignBroadcaster() public {
        DeploySponsor script = new DeploySponsor();
        vm.expectRevert(abi.encodeWithSelector(DeploySponsor.GuardFailed.selector, "broadcaster is not SPONSOR_OWNER"));
        script.runWith(_deployTerms(stranger));
    }
}
