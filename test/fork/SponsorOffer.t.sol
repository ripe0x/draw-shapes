// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";
import {SponsorOffer} from "../../src/sponsor/SponsorOffer.sol";
import {DeployOffer} from "../../script/DeployOffer.s.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";

interface IShapesFeeAdmin {
    function admin() external view returns (address);
    function setFeeRecipient(address newRecipient) external;
}

/// @notice Standing offer against the deployed Wrapped Cryptopunks and Shapes contracts and a FWA clone created by
///         the pool: take, the fee queue, phases, decay, capture, reclaim, exit and rescue.
/// @dev The sponsors are real Wrapped Cryptopunks holders. The test cap is three mint fees so that direct Shapes
///      mints reach it. The test floor is 1 ETH, which the pool accepts under its probability cap with a 30 ETH
///      deposit.
contract SponsorOfferForkTest is ForkBase, PoolFixture {
    address internal constant WPUNKS = 0xb7F7F6C52F2e2fdb1963Eab30438024864c313F6;
    uint256 internal constant PARKED_PRICE = 30 ether;
    uint256 internal constant FLOOR = 1 ether;
    uint256 internal constant DECAY = 10 ether;
    uint256 internal constant CAP = 0.003 ether;
    uint256 internal constant DELAY = 30 days;

    PoolHarness internal pool;
    IFWAClone internal clone;
    SponsorOffer internal offer;
    address internal dealOwner = makeAddr("dealOwner");
    address internal minter = makeAddr("minter");
    address internal player = makeAddr("player");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    address internal s1;
    address internal s2;
    address internal s3;
    uint256 internal id1;
    uint256 internal id2;
    uint256 internal id3;
    uint256 internal fee;

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
        assertEq(3 * fee, CAP);
        _pickHolders();

        offer = new SponsorOffer(address(pool), SHAPES_ADDR, dealOwner);
        vm.prank(dealOwner);
        offer.setTerms(WPUNKS, _terms());
        vm.prank(admin);
        _ip().setRegistrar(address(offer));
        vm.prank(IShapesFeeAdmin(SHAPES_ADDR).admin());
        IShapesFeeAdmin(SHAPES_ADDR).setFeeRecipient(address(offer));
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

    function _terms() internal pure returns (SponsorOffer.Terms memory) {
        return SponsorOffer.Terms({
            parkedPriceWei: PARKED_PRICE,
            floorWei: FLOOR,
            decayWeiPerPull: DECAY,
            reclaimDelay: DELAY,
            capWei: CAP,
            maxOpen: 2,
            enabled: true
        });
    }

    /// @dev Three distinct externally owned holders of Wrapped Cryptopunks and one token of each.
    function _pickHolders() internal {
        IERC721Enumerable nft = IERC721Enumerable(WPUNKS);
        uint256 n = nft.totalSupply();
        uint256 found;
        for (uint256 i; i < n && found < 3; ++i) {
            uint256 id = nft.tokenByIndex(i);
            address h = nft.ownerOf(id);
            if (h.code.length != 0 || h == s1 || h == s2 || h == s3) continue;
            if (found == 0) (s1, id1) = (h, id);
            else if (found == 1) (s2, id2) = (h, id);
            else (s3, id3) = (h, id);
            ++found;
        }
        assertEq(found, 3, "three holders");
    }

    /// @dev Moves the token at enumeration index `index` to `to` from whoever holds it.
    function _give(address to, uint256 index) internal returns (uint256 id) {
        id = IERC721Enumerable(WPUNKS).tokenByIndex(index);
        address h = IERC721(WPUNKS).ownerOf(id);
        vm.prank(h);
        IERC721(WPUNKS).transferFrom(h, to, id);
    }

    /// @dev `who` approves the offer for `id` and takes it, then the pool activates the listing.
    function _take(address who, uint256 id) internal returns (uint256 dealId) {
        vm.startPrank(who);
        IERC721(WPUNKS).approve(address(offer), id);
        dealId = offer.take(WPUNKS, id);
        vm.stopPrank();
        vm.prank(address(pool));
        clone.activateListings(20);
    }

    function _two() internal {
        _take(s1, id1);
        _take(s2, id2);
    }

    /// @dev Mints `n` Shapes so the Shapes contract credits `n` mint fees to the offer, then forwards them.
    function _payFees(uint256 n) internal {
        mintShapes(minter, 0.1 ether, n);
        shapes.withdrawFees(address(offer));
    }

    function _assertI1() internal view {
        assertGe(address(pool).balance, pool.cash() + pool.maintenance() + _ip().grail().fund, "I1");
    }

    function _pulls() internal view returns (uint64) {
        return _ip().grail().pulls;
    }

    function _lid(uint256 dealId) internal view returns (uint256) {
        return offer.deal(dealId).listingId;
    }

    function _price(uint256 dealId) internal view returns (uint256) {
        uint256 lid = _lid(dealId);
        IPoolTypes.ForeignListing[] memory all = _ip().foreignListings();
        for (uint256 i; i < all.length; ++i) {
            if (all[i].listingId == lid) return all[i].notional;
        }
        revert("no entry");
    }

    /// @dev One pooled acquisition that selects an ordinary listing, settled: one pull.
    function _pull() internal {
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        fulfill(clone, ids[0], wordAvoiding(clone, _lid(0)));
        vm.prank(keeper);
        pool.settle(20);
    }

    /// @dev One pooled acquisition that selects the listing of deal `dealId`, settled.
    function _capture(uint256 dealId) internal {
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        fulfill(clone, ids[0], wordFor(clone, _lid(dealId)));
        vm.prank(keeper);
        pool.settle(20);
    }

    function _nextInterval() internal {
        vm.warp(block.timestamp + _ip().rotateInterval());
    }

    function _export() internal {
        vm.prank(admin);
        _ip().startExit(address(pool));
        for (uint256 i; i < 40 && !_ip().exportStep(50); ++i) {}
        assertEq(uint8(pool.lifecycle()), uint8(IPoolTypes.Lifecycle.Exported));
    }

    // ---------------------------------------------------------------- terms

    function test_setTermsStoresAndEmits() public {
        SponsorOffer.Terms memory t = _terms();
        t.parkedPriceWei = 20 ether;
        t.maxOpen = 8;
        vm.expectEmit(true, false, false, true, address(offer));
        emit SponsorOffer.TermsSet(address(0xBEEF), t);
        vm.prank(dealOwner);
        offer.setTerms(address(0xBEEF), t);
        SponsorOffer.Terms memory got = offer.terms(address(0xBEEF));
        assertEq(got.parkedPriceWei, 20 ether);
        assertEq(got.maxOpen, 8);
        assertTrue(got.enabled);
    }

    function test_revert_setTermsBoundsAndOwner() public {
        SponsorOffer.Terms memory t = _terms();
        vm.prank(stranger);
        vm.expectRevert(SponsorOffer.NotOwner.selector);
        offer.setTerms(WPUNKS, t);

        vm.startPrank(dealOwner);
        t = _terms();
        t.floorWei = 0;
        vm.expectRevert(SponsorOffer.BadTerms.selector);
        offer.setTerms(WPUNKS, t);
        t = _terms();
        t.floorWei = PARKED_PRICE;
        vm.expectRevert(SponsorOffer.BadTerms.selector);
        offer.setTerms(WPUNKS, t);
        t = _terms();
        t.decayWeiPerPull = 0;
        vm.expectRevert(SponsorOffer.BadTerms.selector);
        offer.setTerms(WPUNKS, t);
        t = _terms();
        t.capWei = 0;
        vm.expectRevert(SponsorOffer.BadTerms.selector);
        offer.setTerms(WPUNKS, t);
        t = _terms();
        t.maxOpen = 0;
        vm.expectRevert(SponsorOffer.BadTerms.selector);
        offer.setTerms(WPUNKS, t);
        t = _terms();
        t.maxOpen = 9;
        vm.expectRevert(SponsorOffer.BadTerms.selector);
        offer.setTerms(WPUNKS, t);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- take

    function test_twoSponsorsTakeAndTheDealsAreRecorded() public {
        uint256 t0 = block.timestamp;
        uint64 pulls = _pulls();
        vm.prank(s1);
        IERC721(WPUNKS).approve(address(offer), id1);
        vm.expectEmit(true, true, true, false, address(offer));
        emit SponsorOffer.Taken(0, s1, WPUNKS, id1, 0);
        vm.prank(s1);
        uint256 d0 = offer.take(WPUNKS, id1);
        vm.prank(address(pool));
        clone.activateListings(20);
        uint256 d1 = _take(s2, id2);
        assertEq(d0, 0);
        assertEq(d1, 1);

        SponsorOffer.Deal[] memory all = offer.deals();
        assertEq(all.length, 2);
        assertEq(offer.dealCount(), 2);
        assertEq(all[0].sponsor, s1);
        assertEq(all[1].sponsor, s2);
        assertEq(all[0].collection, WPUNKS);
        assertEq(all[0].tokenId, id1);
        assertEq(all[1].tokenId, id2);
        assertTrue(all[0].listingId != all[1].listingId);
        assertEq(all[0].capWei, CAP);
        assertEq(all[0].paidWei, 0);
        assertEq(all[0].takenAt, t0);
        assertEq(all[0].reclaimAfter, t0 + DELAY);
        assertEq(all[0].listedAtPull, pulls);
        assertEq(all[0].floorWei, FLOOR);
        assertEq(all[0].decayWeiPerPull, DECAY);
        assertEq(all[0].parkedPriceWei, PARKED_PRICE);
        assertFalse(all[0].captured || all[0].released || all[0].atFloor || all[0].hotStarted);

        assertEq(IERC721(WPUNKS).ownerOf(id1), address(clone));
        assertEq(IERC721(WPUNKS).ownerOf(id2), address(clone));
        assertEq(_price(0), PARKED_PRICE);
        assertEq(_price(1), PARKED_PRICE);
        assertEq(_ip().foreignListings().length, 2);
        assertTrue(offer.active(0) && offer.active(1));
        assertEq(uint8(offer.phase(0)), uint8(SponsorOffer.Phase.Parked));

        SponsorOffer.QueueItem[] memory q = offer.queue();
        assertEq(q.length, 2);
        assertEq(q[0].dealId, 0);
        assertEq(q[0].sponsor, s1);
        assertEq(q[0].remainingWei, CAP);
        assertEq(q[1].dealId, 1);
        _assertI1();
    }

    function test_revert_takeWhenTheCollectionIsNotEnabled() public {
        SponsorOffer.Terms memory t = _terms();
        t.enabled = false;
        vm.prank(dealOwner);
        offer.setTerms(WPUNKS, t);
        vm.startPrank(s1);
        IERC721(WPUNKS).approve(address(offer), id1);
        assertFalse(offer.canTake(WPUNKS, id1, s1));
        vm.expectRevert(SponsorOffer.NotEnabled.selector);
        offer.take(WPUNKS, id1);
        vm.stopPrank();
        vm.prank(s1);
        vm.expectRevert(SponsorOffer.NotEnabled.selector);
        offer.take(address(0xBEEF), 1);
    }

    function test_revert_takeAtMaxOpenAndAPaidDealFreesASlot() public {
        _two();
        vm.startPrank(s3);
        IERC721(WPUNKS).approve(address(offer), id3);
        assertFalse(offer.canTake(WPUNKS, id3, s3));
        vm.expectRevert(SponsorOffer.TooManyOpen.selector);
        offer.take(WPUNKS, id3);
        vm.stopPrank();

        _payFees(3);
        assertEq(offer.deal(0).paidWei, CAP);
        assertTrue(offer.canTake(WPUNKS, id3, s3));
        uint256 d = _take(s3, id3);
        assertEq(d, 2);
        vm.startPrank(stranger);
        vm.expectRevert(SponsorOffer.TooManyOpen.selector);
        offer.take(WPUNKS, 1);
        vm.stopPrank();
    }

    function test_revert_takeATokenTheCallerDoesNotOwnOrHasNotApproved() public {
        vm.startPrank(s1);
        assertFalse(offer.canTake(WPUNKS, id1, s1), "not approved");
        vm.expectRevert();
        offer.take(WPUNKS, id1);
        IERC721(WPUNKS).approve(address(offer), id1);
        assertTrue(offer.canTake(WPUNKS, id1, s1));
        vm.stopPrank();

        // s1 approved the offer for id1 but does not own id2.
        vm.startPrank(s1);
        assertFalse(offer.canTake(WPUNKS, id2, s1), "not the owner");
        vm.expectRevert();
        offer.take(WPUNKS, id2);
        vm.stopPrank();
        vm.prank(s2);
        IERC721(WPUNKS).approve(address(offer), id2);
        vm.prank(s1);
        vm.expectRevert();
        offer.take(WPUNKS, id2);
        assertFalse(offer.canTake(WPUNKS, type(uint256).max, s1), "no such token");
        assertEq(offer.dealCount(), 0);
        assertEq(IERC721(WPUNKS).ownerOf(id2), s2);

        vm.prank(s1);
        IERC721(WPUNKS).setApprovalForAll(address(offer), true);
        assertTrue(offer.canTake(WPUNKS, id1, s1), "approval for all");
    }

    function test_revert_takeWithoutTheRegistrarRole() public {
        vm.prank(admin);
        _ip().setRegistrar(stranger);
        vm.startPrank(s1);
        IERC721(WPUNKS).approve(address(offer), id1);
        assertFalse(offer.canTake(WPUNKS, id1, s1));
        vm.expectRevert();
        offer.take(WPUNKS, id1);
        vm.stopPrank();
    }

    function test_revert_takeWhenThePoolForeignListingsAreFull() public {
        // The pool holds up to 8 foreign listings: 7 registered by the admin and the first take fill it.
        for (uint256 i; i < 7; ++i) {
            uint256 id = _give(admin, 100 + i);
            vm.startPrank(admin);
            IERC721(WPUNKS).approve(address(pool), id);
            _ip().registerForeign(WPUNKS, id, makeAddr("controller"), PARKED_PRICE);
            vm.stopPrank();
        }
        _take(s1, id1);
        assertEq(_ip().foreignListings().length, 8);
        vm.startPrank(s2);
        IERC721(WPUNKS).approve(address(offer), id2);
        assertFalse(offer.canTake(WPUNKS, id2, s2));
        vm.expectRevert(IPoolTypes.ForeignFull.selector);
        offer.take(WPUNKS, id2);
        vm.stopPrank();
        assertEq(IERC721(WPUNKS).ownerOf(id2), s2);
    }

    // ---------------------------------------------------------------- fee queue

    function test_feesPayTheFirstDealToItsCapBeforeTheSecondThenTheOwner() public {
        _two();
        _payFees(2);
        assertEq(offer.deal(0).paidWei, 2 * fee);
        assertEq(offer.deal(1).paidWei, 0);
        assertEq(offer.balance(s1), 2 * fee);
        assertEq(offer.balance(s2), 0);
        assertEq(offer.balance(dealOwner), 0);
        assertEq(offer.queueHead(), 0);

        // 4 more fees: 1 completes the first cap, 3 reach the second deal and complete it.
        mintShapes(minter, 0.1 ether, 4);
        vm.expectEmit(true, false, false, true, address(offer));
        emit SponsorOffer.Paid(0, fee);
        shapes.withdrawFees(address(offer));
        assertEq(offer.deal(0).paidWei, CAP);
        assertEq(offer.deal(1).paidWei, 3 * fee);
        assertEq(offer.balance(s1), CAP);
        assertEq(offer.balance(s2), CAP);
        assertEq(offer.balance(dealOwner), 0);
        assertEq(offer.queueHead(), 2, "the head moves past both paid deals");
        assertEq(offer.queue().length, 0);

        _payFees(2);
        assertEq(offer.balance(dealOwner), 2 * fee);
        assertEq(offer.deal(0).paidWei + offer.deal(1).paidWei, 2 * CAP);
        assertEq(address(offer).balance, 2 * CAP + 2 * fee);
    }

    function test_theHeadMovesPastAPaidDealBeforeTheNextFeeReachesTheSecond() public {
        _two();
        _payFees(4);
        assertEq(offer.deal(0).paidWei, CAP);
        assertEq(offer.deal(1).paidWei, fee);
        assertEq(offer.queueHead(), 1);
        SponsorOffer.QueueItem[] memory q = offer.queue();
        assertEq(q.length, 1);
        assertEq(q[0].dealId, 1);
        assertEq(q[0].remainingWei, 2 * fee);
    }

    function test_feesGoToTheOwnerWithoutDeals() public {
        _payFees(2);
        assertEq(offer.balance(dealOwner), 2 * fee);
    }

    function test_theSecondDealWaitEqualsTheRemainingCapOfTheFirst() public {
        assertEq(offer.expectedWaitWei(WPUNKS), 0);
        _take(s1, id1);
        assertEq(offer.expectedWaitWei(WPUNKS), CAP, "a deal taken now waits for the first cap");
        _payFees(1);
        assertEq(offer.expectedWaitWei(WPUNKS), CAP - fee);
        _take(s2, id2);
        assertEq(offer.expectedWaitWei(WPUNKS), (CAP - fee) + CAP);
        _payFees(3);
        assertEq(offer.expectedWaitWei(WPUNKS), CAP - fee);
    }

    function test_theFeesOfThePoolsOwnReplacementMintsRoute() public {
        _take(s1, id1);
        uint256 owedBefore = shapes.feesOwedTo(address(offer));
        _pull();
        vm.warp(block.timestamp + _ip().batchMaxAge());
        vm.prank(keeper);
        pool.settle(20);
        uint256 owed = shapes.feesOwedTo(address(offer)) - owedBefore;
        assertGt(owed, 0, "the pool's replacement mints accrued fees to the offer");
        shapes.withdrawFees(address(offer));
        uint256 toSponsor = owed < CAP ? owed : CAP;
        assertEq(offer.balance(s1), toSponsor);
        assertEq(offer.balance(dealOwner), owed - toSponsor);
        _assertI1();
    }

    function test_withdrawPaysEachBalanceOnce() public {
        _two();
        _payFees(8);
        uint256 s1Before = s1.balance;
        uint256 ownerBefore = dealOwner.balance;

        vm.prank(s1);
        offer.withdraw();
        assertEq(s1.balance - s1Before, CAP);
        assertEq(offer.balance(s1), 0);
        assertEq(offer.balance(s2), CAP, "the second balance is untouched");
        vm.prank(s1);
        vm.expectRevert(SponsorOffer.NothingToWithdraw.selector);
        offer.withdraw();

        vm.prank(dealOwner);
        offer.withdraw();
        assertEq(dealOwner.balance - ownerBefore, 2 * fee);
        vm.prank(dealOwner);
        vm.expectRevert(SponsorOffer.NothingToWithdraw.selector);
        offer.withdraw();
        vm.prank(stranger);
        vm.expectRevert(SponsorOffer.NothingToWithdraw.selector);
        offer.withdraw();
        assertEq(address(offer).balance, CAP);
    }

    // ---------------------------------------------------------------- decay

    function test_theCapFlipsTheFirstDealHotAndTickDecaysItToTheFloorWhileTheSecondStaysParked() public {
        _two();
        _payFees(3);
        assertEq(uint8(offer.phase(0)), uint8(SponsorOffer.Phase.Hot));
        assertEq(uint8(offer.phase(1)), uint8(SponsorOffer.Phase.Parked));

        uint64 start = _pulls();
        offer.tick(0);
        assertEq(_price(0), PARKED_PRICE, "the first tick starts the decay, no change");
        assertTrue(offer.deal(0).hotStarted);
        assertEq(offer.deal(0).hotFromPull, start);

        _pull();
        _nextInterval();
        offer.tick(0);
        assertEq(_price(0), PARKED_PRICE - DECAY * (_pulls() - start), "one pull of decay");
        assertEq(_price(0), 20 ether);
        offer.tick(1);
        assertEq(_price(1), PARKED_PRICE, "the second deal does not decay");
        assertFalse(offer.deal(1).hotStarted);

        _pull();
        _nextInterval();
        offer.tick(0);
        assertEq(_price(0), 10 ether);
        _payFees(1);
        assertGe(offer.deal(1).paidWei, fee, "the second deal keeps being paid");

        _pull();
        _nextInterval();
        offer.tick(0);
        assertEq(_price(0), FLOOR, "stops at the floor");
        _pull();
        _nextInterval();
        offer.tick(0);
        assertEq(_price(0), FLOOR);
        assertEq(_price(1), PARKED_PRICE);
        _assertI1();
    }

    function test_tickInParkedChangesNothing() public {
        _take(s1, id1);
        _pull();
        offer.tick(0);
        assertEq(_price(0), PARKED_PRICE);
        assertFalse(offer.deal(0).hotStarted);
    }

    function test_revert_tickOfAnUnknownDeal() public {
        vm.expectRevert(SponsorOffer.UnknownDeal.selector);
        offer.tick(0);
    }

    function test_tickInsideTheRepriceIntervalKeepsThePriceAndTheNextIntervalRetries() public {
        _take(s1, id1);
        _payFees(3);
        offer.tick(0);
        _pull();
        _nextInterval();
        offer.tick(0);
        assertEq(_price(0), 20 ether);

        _pull();
        vm.expectCall(address(pool), abi.encodeCall(IPool.repriceForeign, (_lid(0), 10 ether)));
        offer.tick(0);
        assertEq(_price(0), 20 ether, "one reprice per interval");
        _nextInterval();
        offer.tick(0);
        assertEq(_price(0), 10 ether, "retried after the interval");
    }

    function test_tickNeverRevertsWhileFwaIsBusy() public {
        _take(s1, id1);
        _payFees(3);
        offer.tick(0);
        _pull();
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        assertGt(clone.unsettledAcquisitionCount(), 0);
        vm.expectCall(address(pool), abi.encodeCall(IPool.repriceForeign, (_lid(0), 20 ether)));
        offer.tick(0);
        assertEq(_price(0), PARKED_PRICE, "unchanged while busy");
        fulfill(clone, ids[0], wordAvoiding(clone, _lid(0)));
        vm.prank(keeper);
        pool.settle(20);
        offer.tick(0);
        assertLt(_price(0), PARKED_PRICE, "retried after the pool settled");
    }

    function test_aPriceWithinOnePercentOfTheFloorIsFinal() public {
        SponsorOffer.Terms memory t = _terms();
        t.parkedPriceWei = 1.005 ether;
        vm.prank(dealOwner);
        offer.setTerms(WPUNKS, t);
        _take(s1, id1);
        _payFees(3);
        offer.tick(0);
        assertTrue(offer.deal(0).atFloor);
        assertEq(_price(0), 1.005 ether);
        _pull();
        _nextInterval();
        vm.expectCall(address(pool), abi.encodeCall(IPool.repriceForeign, (_lid(0), FLOOR)), 0);
        offer.tick(0);
        assertEq(_price(0), 1.005 ether, "no further attempts");
    }

    // ---------------------------------------------------------------- terms snapshot

    function test_aTermsChangeDoesNotAlterALiveDeal() public {
        _take(s1, id1);
        SponsorOffer.Deal memory before_ = offer.deal(0);
        SponsorOffer.Terms memory t = _terms();
        t.parkedPriceWei = 20 ether;
        t.floorWei = 2 ether;
        t.decayWeiPerPull = 1 ether;
        t.reclaimDelay = 1 days;
        t.capWei = 10 * CAP;
        vm.prank(dealOwner);
        offer.setTerms(WPUNKS, t);

        SponsorOffer.Deal memory after_ = offer.deal(0);
        assertEq(abi.encode(after_), abi.encode(before_));
        _payFees(3);
        assertEq(uint8(offer.phase(0)), uint8(SponsorOffer.Phase.Hot), "the old cap still applies");
        assertEq(_price(0), PARKED_PRICE);

        _take(s2, id2);
        SponsorOffer.Deal memory second = offer.deal(1);
        assertEq(second.capWei, 10 * CAP);
        assertEq(second.parkedPriceWei, 20 ether);
        assertEq(second.floorWei, 2 ether);
        assertEq(second.decayWeiPerPull, 1 ether);
        assertEq(second.reclaimAfter, block.timestamp + 1 days);
        assertEq(_price(1), 20 ether);
    }

    // ---------------------------------------------------------------- capture

    function test_aCaptureOfAParkedDealEndsItsPaymentsAndTheNextDealBecomesTheHead() public {
        _two();
        _payFees(1);
        uint256 fundBefore = _ip().grail().fund;

        _capture(0);

        assertEq(IERC721(WPUNKS).ownerOf(id1), player, "the purchaser holds the punk");
        assertTrue(offer.deal(0).captured);
        assertFalse(offer.active(0));
        assertTrue(offer.active(1));
        assertEq(_ip().foreignListings().length, 1);
        assertGt(_ip().grail().fund, fundBefore, "the proceeds reached the GRAIL fund");
        assertEq(address(offer).balance, fee, "the offer forwards the proceeds");
        _assertI1();

        SponsorOffer.QueueItem[] memory q = offer.queue();
        assertEq(q.length, 1);
        assertEq(q[0].dealId, 1);
        assertEq(offer.expectedWaitWei(WPUNKS), CAP);

        _payFees(4);
        assertEq(offer.deal(0).paidWei, fee, "paid stays at the amount before the capture");
        assertEq(offer.balance(s1), fee);
        assertEq(offer.deal(1).paidWei, CAP);
        assertEq(offer.balance(s2), CAP);
        assertEq(offer.balance(dealOwner), fee);
        assertEq(offer.queueHead(), 2);
    }

    function test_aCaptureOfAHotDealFundsGrail() public {
        _two();
        _payFees(3);
        uint256 fundBefore = _ip().grail().fund;
        _capture(0);
        assertTrue(offer.deal(0).captured);
        assertGt(_ip().grail().fund, fundBefore);
        _assertI1();
        _capture(1);
        assertTrue(offer.deal(1).captured);
        assertEq(_ip().foreignListings().length, 0);
        _assertI1();
    }

    function test_revert_onForeignCaptureFromAnyoneButThePool() public {
        _take(s1, id1);
        uint256 lid = _lid(0);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(SponsorOffer.NotPool.selector);
        offer.onForeignCapture{value: 1 ether}(lid, id1, 1 ether);
        vm.prank(dealOwner);
        vm.expectRevert(SponsorOffer.NotPool.selector);
        offer.onForeignCapture(lid, id1, 0);
        vm.prank(address(pool));
        vm.expectRevert(SponsorOffer.UnknownEntry.selector);
        offer.onForeignCapture(lid + 1000, id1, 0);
        assertFalse(offer.deal(0).captured);
    }

    // ---------------------------------------------------------------- reclaim

    function test_reclaimAfterTheDelayInParkedReturnsThePunkAndEndsPayments() public {
        _two();
        _payFees(1);
        vm.warp(offer.deal(0).reclaimAfter);
        vm.expectEmit(true, false, false, false, address(offer));
        emit SponsorOffer.Reclaimed(0);
        vm.prank(s1);
        offer.reclaim(0);

        assertEq(IERC721(WPUNKS).ownerOf(id1), s1);
        assertFalse(offer.active(0));
        assertTrue(offer.deal(0).released);
        assertEq(_ip().foreignListings().length, 1);
        _assertI1();

        _payFees(2);
        assertEq(offer.deal(0).paidWei, fee);
        assertEq(offer.deal(1).paidWei, 2 * fee, "the next deal is paid");
        assertEq(offer.balance(s1), fee);

        vm.prank(s1);
        vm.expectRevert(SponsorOffer.NotListed.selector);
        offer.reclaim(0);
    }

    function test_revert_reclaimBeforeTheDelay() public {
        _take(s1, id1);
        uint256 at = offer.deal(0).reclaimAfter;
        vm.warp(at - 1);
        vm.prank(s1);
        vm.expectRevert(abi.encodeWithSelector(SponsorOffer.TooEarly.selector, at));
        offer.reclaim(0);
    }

    function test_revert_reclaimInHot() public {
        _take(s1, id1);
        _payFees(3);
        vm.warp(offer.deal(0).reclaimAfter);
        vm.prank(s1);
        vm.expectRevert(SponsorOffer.WrongPhase.selector);
        offer.reclaim(0);
        assertEq(IERC721(WPUNKS).ownerOf(id1), address(clone));
    }

    function test_revert_reclaimByAnyoneButTheSponsor() public {
        _take(s1, id1);
        vm.warp(offer.deal(0).reclaimAfter);
        vm.prank(dealOwner);
        vm.expectRevert(SponsorOffer.NotSponsor.selector);
        offer.reclaim(0);
        vm.prank(s2);
        vm.expectRevert(SponsorOffer.NotSponsor.selector);
        offer.reclaim(0);
    }

    // ---------------------------------------------------------------- exit

    function test_afterAnExitReleaseHeldRoutesByPhase() public {
        _two();
        _payFees(3);
        _export();
        assertEq(IERC721(WPUNKS).ownerOf(id1), address(offer), "the export sent the token to the controller");
        assertEq(IERC721(WPUNKS).ownerOf(id2), address(offer));

        vm.prank(stranger);
        vm.expectRevert(SponsorOffer.NotParty.selector);
        offer.releaseHeld(0);
        vm.prank(s2);
        vm.expectRevert(SponsorOffer.NotParty.selector);
        offer.releaseHeld(0);

        vm.expectEmit(true, true, false, false, address(offer));
        emit SponsorOffer.HeldReleased(0, dealOwner);
        vm.prank(s1);
        offer.releaseHeld(0);
        assertEq(IERC721(WPUNKS).ownerOf(id1), dealOwner, "a paid deal goes to the owner");

        vm.prank(dealOwner);
        offer.releaseHeld(1);
        assertEq(IERC721(WPUNKS).ownerOf(id2), s2, "a Parked deal goes to the sponsor");

        vm.prank(s1);
        vm.expectRevert(SponsorOffer.DealClosed.selector);
        offer.releaseHeld(0);
        vm.prank(s2);
        vm.expectRevert(SponsorOffer.DealClosed.selector);
        offer.releaseHeld(1);

        _payFees(1);
        assertEq(offer.deal(1).paidWei, 0, "a released deal is not paid");
        assertEq(offer.balance(dealOwner), fee);
    }

    function test_revert_releaseHeldWhileThePoolHoldsTheToken() public {
        _take(s1, id1);
        vm.prank(s1);
        vm.expectRevert();
        offer.releaseHeld(0);
        assertEq(IERC721(WPUNKS).ownerOf(id1), address(clone));
        assertFalse(offer.deal(0).released);
    }

    function test_onERC721ReceivedAcceptsOnlyTheTokenOfAnOpenDeal() public {
        vm.prank(WPUNKS);
        vm.expectRevert(SponsorOffer.WrongToken.selector);
        offer.onERC721Received(address(0), address(0), id1, "");

        _take(s1, id1);
        vm.prank(WPUNKS);
        assertEq(offer.onERC721Received(address(0), address(0), id1, ""), bytes4(0x150b7a02));
        vm.prank(WPUNKS);
        vm.expectRevert(SponsorOffer.WrongToken.selector);
        offer.onERC721Received(address(0), address(0), id2, "");
        vm.prank(stranger);
        vm.expectRevert(SponsorOffer.WrongToken.selector);
        offer.onERC721Received(address(0), address(0), id1, "");

        vm.warp(offer.deal(0).reclaimAfter);
        vm.prank(s1);
        offer.reclaim(0);
        vm.prank(WPUNKS);
        vm.expectRevert(SponsorOffer.WrongToken.selector);
        offer.onERC721Received(address(0), address(0), id1, "");
    }

    // ---------------------------------------------------------------- rescue

    /// @dev A Shape lent through the offer and won by the Shapes contract: Shapes cannot receive the transfer, so FWA
    ///      refunds the delivery and the pool holds the token unlisted. Returns the deal id.
    function _griefedShape(bool hot) internal returns (uint256 dealId, uint256 id) {
        SponsorOffer.Terms memory t = _terms();
        vm.prank(dealOwner);
        offer.setTerms(SHAPES_ADDR, t);
        id = mintShapes(minter, 0.1 ether, 1);
        shapes.withdrawFees(address(offer));
        vm.startPrank(minter);
        IERC721(SHAPES_ADDR).approve(address(offer), id);
        dealId = offer.take(SHAPES_ADDR, id);
        vm.stopPrank();
        vm.prank(address(pool));
        clone.activateListings(20);
        if (hot) _payFees(3);

        uint256 lid = _lid(dealId);
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
        (uint256 d, uint256 id) = _griefedShape(false);
        assertFalse(offer.active(d), "an unlisted entry is not active");
        assertFalse(offer.deal(d).captured);

        vm.prank(stranger);
        vm.expectRevert(SponsorOffer.NotOwner.selector);
        offer.rescue(d, minter);
        vm.prank(minter);
        vm.expectRevert(SponsorOffer.NotOwner.selector);
        offer.rescue(d, minter);
        vm.prank(dealOwner);
        vm.expectRevert(SponsorOffer.WrongDestination.selector);
        offer.rescue(d, dealOwner);

        vm.prank(dealOwner);
        offer.rescue(d, minter);
        assertEq(IERC721(SHAPES_ADDR).ownerOf(id), minter);
        assertEq(_ip().foreignListings().length, 0);
        assertTrue(offer.deal(d).released);
        _assertI1();

        vm.prank(dealOwner);
        vm.expectRevert(SponsorOffer.NotUnlisted.selector);
        offer.rescue(d, minter);
    }

    function test_rescueSendsAnUnlistedTokenOfAPaidDealWhereverTheOwnerChooses() public {
        (uint256 d, uint256 id) = _griefedShape(true);
        assertEq(uint8(offer.phase(d)), uint8(SponsorOffer.Phase.Hot));
        vm.prank(dealOwner);
        offer.rescue(d, dealOwner);
        assertEq(IERC721(SHAPES_ADDR).ownerOf(id), dealOwner);
    }

    function test_revert_rescueWhileTheEntryIsListed() public {
        _take(s1, id1);
        vm.prank(dealOwner);
        vm.expectRevert(SponsorOffer.NotUnlisted.selector);
        offer.rescue(0, s1);
    }

    // ---------------------------------------------------------------- deploy script

    function _deployTerms(address owner_) internal view returns (DeployOffer.Terms memory t) {
        t.pool = address(pool);
        t.owner = owner_;
        t.collection = WPUNKS;
        t.parkedPriceWei = 32 ether;
        t.floorWei = 0.25 ether;
        t.decayWeiPerPull = 0.001 ether;
        t.reclaimDelay = 30 days;
        t.capWei = 48 ether;
        t.maxOpen = 2;
    }

    function test_deployScriptDeploysSetsTheTermsAndReadsBackEveryValue() public {
        DeployOffer script = new DeployOffer();
        SponsorOffer o = script.runWith(_deployTerms(DEFAULT_SENDER));
        assertEq(o.owner(), DEFAULT_SENDER);
        assertEq(address(o.pool()), address(pool));
        assertEq(o.shapes(), SHAPES_ADDR);
        SponsorOffer.Terms memory t = o.terms(WPUNKS);
        assertTrue(t.enabled);
        assertEq(t.parkedPriceWei, 32 ether);
        assertEq(t.capWei, 48 ether);
        assertEq(t.maxOpen, 2);
        assertEq(o.deals().length, 0);
        assertTrue(_ip().registrar() != address(o), "the broadcaster is not the pool admin");
    }

    function test_deployScriptSetsTheRegistrarWhenTheBroadcasterIsThePoolAdmin() public {
        vm.prank(admin);
        _ip().setAdmin(DEFAULT_SENDER);
        DeployOffer script = new DeployOffer();
        SponsorOffer o = script.runWith(_deployTerms(DEFAULT_SENDER));
        assertEq(_ip().registrar(), address(o));
    }

    function test_deployScriptRefusesAForeignBroadcaster() public {
        DeployOffer script = new DeployOffer();
        vm.expectRevert(abi.encodeWithSelector(DeployOffer.GuardFailed.selector, "broadcaster is not OFFER_OWNER"));
        script.runWith(_deployTerms(stranger));
    }
}
