// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPool, IPoolTypes} from "../../../src/interfaces/IPool.sol";
import {Lens} from "../../../src/Lens.sol";
import {IFWAClone} from "../../../src/interfaces/IFWAClone.sol";
import {EngineTreasury} from "../../../src/engine/EngineTreasury.sol";
import {PrizeSponsorship} from "../../../src/engine/PrizeSponsorship.sol";
import {EngineBase} from "./EngineBase.sol";

/// @notice A real Wrapped Cryptopunk lent by a sponsor and a Wrapped Cryptopunk bought by the
///         treasury, both listed on the live board: published odds, capped compensation from trading
///         receipts, early win, reclaim, completion and the bid flow.
contract EngineSponsorForkTest is EngineBase {
    uint256 internal constant LIST_PRICE = 8 ether;
    uint256 internal constant CAP = 36 ether;

    address internal sponsor = makeAddr("sponsor");
    address internal seller = makeAddr("seller");
    PrizeSponsorship internal s;
    uint256 internal punk;

    function setUp() public {
        setUpEngine();
        _launch();
        _pastSniperWindow();
        s = new PrizeSponsorship(address(d.pool), address(treasury), sponsor, WRAPPED_PUNKS, LIST_PRICE, CAP, 30 days);
        vm.prank(owner);
        treasury.setSponsorship(s, 5_000);
        punk = _wpunk(0, sponsor);
        vm.prank(sponsor);
        IERC721(WRAPPED_PUNKS).approve(address(s), punk);
        vm.prank(sponsor);
        s.stake(punk);
        _activateStaged();
    }

    function _activateStaged() internal {
        vm.prank(keeper);
        ip.settle(20);
    }

    function _winPunk(uint256 listingId) internal {
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(ip), clone, player, 1);
        fulfill(clone, ids[0], wordFor(clone, listingId));
        vm.prank(keeper);
        ip.settle(20);
    }

    function _trade(uint256 ethIn) internal {
        uint256 out = _buy(trader, ethIn);
        _sell(trader, out);
        vm.prank(keeper);
        treasury.collectFees();
    }

    function test_stake_listsAtPublishedOdds() public {
        (,,,,,,, IFWAClone.ListingStatus status) = clone.listings(s.listingId());
        if (status != IFWAClone.ListingStatus.Active) {
            vm.prank(address(d.pool));
            clone.activateListings(20);
        }
        assertTrue(s.active(), "active");
        assertEq(s.owed(), CAP, "owed the cap");
        assertEq(IERC721(WRAPPED_PUNKS).ownerOf(punk), address(clone), "punk escrowed by FWA");
        Lens.ForeignView[] memory v = d.lens.foreign();
        assertEq(v.length, 1);
        assertEq(v[0].notional, LIST_PRICE, "listed at the published price");
        // Odds per draw: listing weight (1e36 / price, `PricingLib.weightOf`) over FWA's total weight.
        // Below one basis point, so Lens rounds `weightBps` to zero; the page computes it from weights.
        (,,,, uint256 weight,,, IFWAClone.ListingStatus st) = clone.listings(s.listingId());
        assertEq(uint8(st), uint8(IFWAClone.ListingStatus.Active), "drawable now");
        assertEq(weight, 1e36 / LIST_PRICE, "weight from the published price");
        uint256 oneIn = clone.totalWeight() / weight;
        emit log_named_uint("sponsored prize: one draw in", oneIn);
        assertLt(oneIn, 200_000, "winnable at the published price");
    }

    function test_paidFromTradingAfterFounders_neverFromMintFees() public {
        address mintFeeRecipient = shapes.feeRecipient();
        uint256 mintFeesBefore = shapes.feesOwedTo(mintFeeRecipient);
        _trade(10 ether);
        EngineTreasury.Totals memory t = treasury.totals();
        uint256 afterFounders = t.tradingReceived - t.foundersFromTrading;
        assertEq(s.paid(), afterFounders * 5_000 / 10_000, "half of the post-founder share");
        assertEq(t.sponsorPaid, s.paid(), "treasury record");
        // The draws below pay Shapes mint fees to the creator, untouched by the sponsorship.
        _draws(20);
        assertGt(shapes.feesOwedTo(mintFeeRecipient), mintFeesBefore, "mint fees still go to the creator");
        uint256 before = sponsor.balance;
        vm.prank(sponsor);
        s.claim();
        assertEq(sponsor.balance - before, s.paid(), "claimed");
    }

    function test_earlyWin_cancelsUnpaidCompensation() public {
        _trade(10 ether);
        uint256 paidBefore = s.paid();
        uint256 fundBefore = ip.grail().fund;
        _winPunk(s.listingId());
        assertTrue(s.won(), "won");
        assertEq(IERC721(WRAPPED_PUNKS).ownerOf(punk), player, "player owns the punk");
        assertEq(s.owed(), 0, "no further compensation");
        assertGt(ip.grail().fund, fundBefore, "ticket proceeds to the GRAIL fund");
        _trade(10 ether);
        assertEq(s.paid(), paidBefore, "nothing paid after the win");
        vm.prank(sponsor);
        s.claim();
        assertEq(sponsor.balance, paidBefore, "sponsor keeps what was earned");
        vm.prank(sponsor);
        vm.expectRevert(PrizeSponsorship.WrongState.selector);
        s.reclaim();
    }

    function test_reclaim_onlyAfterDelayAndNeverOverAPendingDraw() public {
        uint256 after_ = s.reclaimAfter();
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(PrizeSponsorship.TooEarly.selector, after_));
        s.reclaim();
        // A draw is pending: the pool refuses to withdraw a listing that draw may select.
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(ip), clone, player, 1);
        vm.warp(after_);
        vm.prank(sponsor);
        vm.expectRevert(IPoolTypes.FwaBusy.selector);
        s.reclaim();
        fulfill(clone, ids[0], wordAvoiding(clone, s.listingId()));
        vm.prank(keeper);
        ip.settle(20);
        vm.prank(sponsor);
        s.reclaim();
        assertEq(IERC721(WRAPPED_PUNKS).ownerOf(punk), sponsor, "returned");
        assertEq(s.owed(), 0, "payments stop");
        assertEq(ip.foreignListings().length, 0, "off the board");
    }

    function test_completion_extinguishesSponsorClaim() public {
        for (uint256 i; i < 40 && !s.completed(); ++i) {
            _trade(80 ether);
        }
        assertTrue(s.completed(), "cap reached");
        assertEq(s.paid(), CAP, "paid exactly the cap");
        assertEq(s.owed(), 0);
        vm.warp(s.reclaimAfter());
        vm.prank(sponsor);
        vm.expectRevert(PrizeSponsorship.WrongState.selector);
        s.reclaim();
        assertEq(ip.foreignListings().length, 1, "still a prize on the board");
        // Founders were paid first: the sponsor share came only from the post-founder remainder.
        assertEq(round.totalDistributed(), round.entitlement(), "founders capped first");
    }

    function test_sponsorshipCannotBeSwappedWhileActive() public {
        PrizeSponsorship other =
            new PrizeSponsorship(address(d.pool), address(treasury), sponsor, WRAPPED_PUNKS, LIST_PRICE, CAP, 30 days);
        vm.prank(owner);
        vm.expectRevert(EngineTreasury.SponsorshipActive.selector);
        treasury.setSponsorship(other, 5_000);
    }

    function test_treasuryBid_buysAndListsAWrappedPunk() public {
        uint256 id = _wpunk(1, seller);
        vm.prank(owner);
        treasury.setBid(id, 0.5 ether, 6 ether);
        _trade(40 ether);
        uint256 budget = treasury.prizeBudget();
        assertGe(budget, 0.5 ether, "budget covers the bid");
        // The bid holds its price; only the rest is boosted.
        treasury.boostGrail();
        assertEq(treasury.prizeBudget(), 0.5 ether, "bid price held back");
        vm.prank(seller);
        IERC721(WRAPPED_PUNKS).approve(address(treasury), id);
        uint256 before = seller.balance;
        vm.prank(seller);
        treasury.fillBid(id);
        assertEq(seller.balance - before, 0.5 ether, "seller paid");
        assertEq(treasury.prizeBudget(), 0, "paid from the prize budget");
        IPoolTypes.ForeignListing[] memory f = ip.foreignListings();
        assertEq(f.length, 2);
        assertEq(f[1].controller, address(treasury), "treasury owns the listing");
        assertEq(f[1].notional, 6 ether);
        _activateStaged();
        _winPunk(f[1].listingId);
        assertEq(IERC721(WRAPPED_PUNKS).ownerOf(id), player, "won");
        assertGt(treasury.prizeBudget(), 0, "proceeds back to prizes");
        _assertTreasuryBooks();
    }

    function test_ownerCannotFillOwnBid() public {
        uint256 id = _wpunk(1, owner);
        vm.prank(owner);
        treasury.setBid(id, 0.5 ether, 6 ether);
        _trade(40 ether);
        vm.prank(owner);
        IERC721(WRAPPED_PUNKS).approve(address(treasury), id);
        vm.prank(owner);
        vm.expectRevert(EngineTreasury.BidInvalid.selector);
        treasury.fillBid(id);
    }

    function test_bidBoundedAndOwnerOnly() public {
        vm.prank(player);
        vm.expectRevert(EngineTreasury.NotOwner.selector);
        treasury.setBid(1, 1 ether, 1 ether);
        vm.prank(owner);
        vm.expectRevert(EngineTreasury.BidInvalid.selector);
        treasury.setBid(1, 61 ether, 1 ether);
    }
}
