// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {Lens} from "../../src/Lens.sol";
import {Pool} from "../../src/Pool.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {IForeignController} from "../../src/interfaces/IForeignController.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";

/// @dev Controller of foreign listings in the tests: records every capture callback and drives
///      `repriceForeign` and `withdrawForeign` through the pool.
contract TestController is IForeignController {
    struct Call {
        uint256 listingId;
        uint256 tokenId;
        uint256 proceeds;
        uint256 value;
    }

    IPool internal immutable pool;
    Call[] internal calls;
    bool public rejects;
    bool public burnsGas;

    constructor(address pool_) {
        pool = IPool(pool_);
    }

    function setRejects(bool on) external {
        rejects = on;
    }

    function setBurnsGas(bool on) external {
        burnsGas = on;
    }

    function onForeignCapture(uint256 listingId, uint256 tokenId, uint256 proceeds) external payable {
        if (burnsGas) {
            while (true) {}
        }
        if (rejects) revert("rejected");
        calls.push(Call(listingId, tokenId, proceeds, msg.value));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function callAt(uint256 i) external view returns (Call memory) {
        return calls[i];
    }

    function reprice(uint256 listingId, uint256 priceWei) external {
        pool.repriceForeign(listingId, priceWei);
    }

    function withdraw(uint256 listingId, address to) external {
        pool.withdrawForeign(listingId, to);
    }
}

/// @notice Foreign listings against the deployed Wrapped Cryptopunks collection, deployed Shapes
///         and a FWA clone created by the pool: register, reprice, withdraw, capture, a controller
///         that fails, exit and the Lens view.
/// @dev Tokens are the first Wrapped Cryptopunks ids by `tokenByIndex` at the fork block. Each one
///      moves from its holder to the admin with a prank, then the admin registers it.
contract PoolForeignForkTest is ForkBase, PoolFixture {
    address internal constant WPUNKS = 0xb7F7F6C52F2e2fdb1963Eab30438024864c313F6;
    uint256 internal constant PRICE = 1 ether;

    PoolHarness internal pool;
    IFWAClone internal clone;
    TestController internal controller;
    address internal player = makeAddr("player");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        setUpFork();
        openFactory();
        vm.prank(factory.owner());
        factory.setInventoryChangeCooldown(0);
        deployDrawPacks(admin);
        vm.deal(alice, 10_000 ether);
        _deployPool();
        controller = new TestController(address(pool));
        _open(30 ether);
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

    /// @dev Token id at `index` of the Wrapped Cryptopunks enumeration, moved to the admin and approved
    ///      for the pool.
    function _punk(uint256 index) internal returns (uint256 id) {
        id = IERC721Enumerable(WPUNKS).tokenByIndex(index);
        address holder = IERC721(WPUNKS).ownerOf(id);
        vm.prank(holder);
        IERC721(WPUNKS).transferFrom(holder, admin, id);
        vm.prank(admin);
        IERC721(WPUNKS).approve(address(pool), id);
    }

    function _register(uint256 index, address controller_, uint256 price)
        internal
        returns (uint256 tokenId, uint256 listingId)
    {
        tokenId = _punk(index);
        vm.prank(admin);
        _ip().registerForeign(WPUNKS, tokenId, controller_, price);
        IPoolTypes.ForeignListing[] memory all = _ip().foreignListings();
        listingId = all[all.length - 1].listingId;
    }

    function _activate() internal {
        vm.prank(address(pool));
        clone.activateListings(20);
    }

    function _status(uint256 listingId) internal view returns (IFWAClone.ListingStatus status) {
        (,,,,,,, status) = clone.listings(listingId);
    }

    function _priceOf(uint256 listingId) internal view returns (uint256 price) {
        (,,,,, price,,) = clone.listings(listingId);
    }

    function _assertI1() internal view {
        assertGe(address(pool).balance, pool.cash() + pool.maintenance() + _ip().grail().fund, "I1");
    }

    struct Books {
        uint256 cash;
        uint256 backing;
        uint256 receivable;
        uint256 maintenance;
        uint256 maintenanceReceivable;
        uint256 fund;
        uint256 grailReceivable;
        int256 margin;
        uint256 nav;
        uint256 balance;
    }

    function _books() internal view returns (Books memory b) {
        IPoolTypes.Grail memory g = _ip().grail();
        b = Books(
            pool.cash(),
            pool.backing(),
            pool.receivable(),
            pool.maintenance(),
            _ip().maintenanceReceivable(),
            g.fund,
            g.receivable,
            _ip().margin(),
            pool.nav(),
            address(pool).balance
        );
    }

    /// @dev One pooled acquisition fulfilled on `listingId` and settled. Returns the recorded logs.
    function _capture(uint256 listingId) internal returns (Vm.Log[] memory logs) {
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        fulfill(clone, ids[0], wordFor(clone, listingId));
        vm.recordLogs();
        vm.prank(keeper);
        pool.settle(20);
        logs = vm.getRecordedLogs();
    }

    function _foreignCaptured(Vm.Log[] memory logs)
        internal
        view
        returns (bool found, uint256 tokenId, uint256 proceeds, bool delivered)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.ForeignCaptured.selector) {
                found = true;
                (tokenId, proceeds, delivered) = abi.decode(logs[i].data, (uint256, uint256, bool));
            }
        }
    }

    // ---------------------------------------------------------------- register

    function test_registerListsThePunkOnTheCloneAndLensShowsATinyWeight() public {
        (uint256 tokenId, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();

        assertEq(IERC721(WPUNKS).ownerOf(tokenId), address(clone), "the clone holds the token");
        assertEq(uint8(_status(listingId)), uint8(IFWAClone.ListingStatus.Active));
        assertEq(_priceOf(listingId), PRICE);
        assertTrue(_ip().registered(WPUNKS, tokenId));
        IPoolTypes.ForeignListing[] memory all = _ip().foreignListings();
        assertEq(all.length, 1);
        assertEq(all[0].collection, WPUNKS);
        assertEq(all[0].tokenId, tokenId);
        assertEq(all[0].controller, address(controller));
        assertEq(all[0].listingId, listingId);
        assertEq(all[0].notional, PRICE);

        Lens lens = new Lens(Pool(payable(address(pool))));
        Lens.ForeignView[] memory v = lens.foreign();
        assertEq(v.length, 1);
        assertEq(v[0].listingId, listingId);
        assertEq(v[0].controller, address(controller));
        assertGt(v[0].weightBps, 0, "listed weight");
        assertLt(v[0].weightBps, 200, "a tiny share of the board");
        emit log_named_uint("foreign weight bps", v[0].weightBps);
    }

    function test_registerTouchesNeitherNavNorTheFund() public {
        Books memory before_ = _books();
        _register(0, address(controller), PRICE);
        Books memory after_ = _books();
        assertEq(after_.nav, before_.nav);
        assertEq(after_.cash, before_.cash);
        assertEq(after_.backing, before_.backing);
        assertEq(after_.fund, before_.fund);
        assertEq(after_.balance, before_.balance);
        _assertI1();
    }

    function test_revert_registerNotAdmin() public {
        uint256 id = _punk(0);
        vm.prank(stranger);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        _ip().registerForeign(WPUNKS, id, address(controller), PRICE);
    }

    function test_revert_registerWhenNotLive() public {
        PoolHarness opening = new PoolHarness(_openingParams());
        vm.prank(admin);
        IPool(address(opening)).createFwaPool(0);
        uint256 id = _punk(0);
        vm.prank(admin);
        IERC721(WPUNKS).approve(address(opening), id);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.NotLive.selector);
        IPool(address(opening)).registerForeign(WPUNKS, id, address(controller), PRICE);

        pool.setLifecycle(IPoolTypes.Lifecycle.Exiting);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.NotLive.selector);
        _ip().registerForeign(WPUNKS, id, address(controller), PRICE);
    }

    function _openingParams() internal returns (IPoolTypes.Params memory p) {
        p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
    }

    function test_revert_registerWithAZeroController() public {
        uint256 id = _punk(0);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.ZeroAddress.selector);
        _ip().registerForeign(WPUNKS, id, address(0), PRICE);
    }

    function test_revert_registerTwice() public {
        (uint256 tokenId,) = _register(0, address(controller), PRICE);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.AlreadyRegistered.selector);
        _ip().registerForeign(WPUNKS, tokenId, address(controller), PRICE);
    }

    function test_revert_registerAtTheCapOfEight() public {
        for (uint256 i; i < 8; ++i) {
            _register(i, address(controller), PRICE + i * 1 ether);
        }
        assertEq(_ip().foreignListings().length, 8);
        uint256 id = _punk(8);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.ForeignFull.selector);
        _ip().registerForeign(WPUNKS, id, address(controller), PRICE);
    }

    function test_sweepRefusesARegisteredForeignToken() public {
        (uint256 tokenId,) = _register(0, address(controller), PRICE);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.Accounted.selector);
        _ip().sweep(WPUNKS, tokenId, admin);
    }

    // ---------------------------------------------------------------- reprice

    function test_repriceByTheControllerUpdatesTheCloneAndTheEntry() public {
        (, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();

        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.ForeignRepriced(listingId, 0.8 ether);
        controller.reprice(listingId, 0.8 ether);

        assertEq(_priceOf(listingId), 0.8 ether);
        assertEq(_ip().foreignListings()[0].notional, 0.8 ether);
        Lens lens = new Lens(Pool(payable(address(pool))));
        assertGt(lens.foreign()[0].weightBps, 0);
    }

    function test_revert_repriceByAnyoneElse() public {
        (, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        vm.prank(stranger);
        vm.expectRevert(IPoolTypes.NotController.selector);
        _ip().repriceForeign(listingId, 4 ether);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.NotController.selector);
        _ip().repriceForeign(listingId, 4 ether);
    }

    function test_revert_repriceAnUnknownListing() public {
        vm.expectRevert(abi.encodeWithSelector(IPoolTypes.UnknownListing.selector, 12345));
        controller.reprice(12345, 4 ether);
    }

    function test_revert_repriceWhileTheListingIsNotActive() public {
        // A listing made while an acquisition is unsettled stays Staged until `activateListings`.
        // `deposit` books the acquisition without activating.
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        (, uint256 listingId) = _register(0, address(controller), PRICE);
        assertEq(uint8(_status(listingId)), uint8(IFWAClone.ListingStatus.Staged), "staged");
        fulfill(clone, ids[0], wordAvoiding(clone, listingId));
        vm.prank(alice);
        pool.deposit{value: 1 ether}();
        assertEq(uint8(_status(listingId)), uint8(IFWAClone.ListingStatus.Staged), "still staged");
        vm.expectRevert(abi.encodeWithSelector(IPoolTypes.ListingNotActive.selector, listingId));
        controller.reprice(listingId, 4 ether);
    }

    function test_revert_repriceWhileAnAcquisitionIsUnsettled() public {
        (, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        warpPastCooldown(clone);
        acquirePooled(address(pool), clone, player, 1);
        assertGt(clone.unsettledAcquisitionCount(), 0);
        vm.expectRevert(IPoolTypes.FwaBusy.selector);
        controller.reprice(listingId, 4 ether);
    }

    function test_revert_repriceThatPassesTheProbabilityCap() public {
        (, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        vm.expectRevert(IPoolTypes.ProbCapExceeded.selector);
        controller.reprice(listingId, 0.0001 ether);
        assertEq(_priceOf(listingId), PRICE, "unchanged");
    }

    function test_theCapCountsTheOtherForeignListings() public {
        (, uint256 first) = _register(0, address(controller), PRICE);
        (, uint256 second) = _register(1, address(controller), PRICE);
        _activate();
        // At 0.00125 ETH one listing holds about 13 percent of the selection weight, two hold about 23.
        controller.reprice(first, 0.00125 ether);
        vm.expectRevert(IPoolTypes.ProbCapExceeded.selector);
        controller.reprice(second, 0.00125 ether);
    }

    function test_aPriceRiseIsAllowedWhileTheCapIsExceeded() public {
        (, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        controller.reprice(listingId, 0.05 ether);
        // Lower the cap below the current share. A rise in price only lowers the share.
        vm.prank(admin);
        _ip().setGrailProbCap(1);
        controller.reprice(listingId, 0.06 ether);
        assertEq(_priceOf(listingId), 0.06 ether);
    }

    // ---------------------------------------------------------------- withdraw

    function test_withdrawByTheControllerReturnsTheTokenAndClearsTheEntry() public {
        (uint256 tokenId, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        address to = makeAddr("to");

        controller.withdraw(listingId, to);

        assertEq(IERC721(WPUNKS).ownerOf(tokenId), to);
        assertEq(_ip().foreignListings().length, 0);
        assertFalse(_ip().registered(WPUNKS, tokenId));
        assertTrue(_status(listingId) != IFWAClone.ListingStatus.Active);
        _assertI1();
    }

    function test_withdrawAndRegisterAgainWithAnotherController() public {
        (uint256 tokenId, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        controller.withdraw(listingId, admin);
        vm.prank(admin);
        IERC721(WPUNKS).approve(address(pool), tokenId);
        vm.prank(admin);
        _ip().registerForeign(WPUNKS, tokenId, stranger, 6 ether);
        assertEq(_ip().foreignListings()[0].controller, stranger);
    }

    function test_revert_withdrawByAnyoneElse() public {
        (, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        vm.prank(stranger);
        vm.expectRevert(IPoolTypes.NotController.selector);
        _ip().withdrawForeign(listingId, stranger);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.NotController.selector);
        _ip().withdrawForeign(listingId, admin);
    }

    function test_revert_withdrawToTheZeroAddress() public {
        (, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        vm.expectRevert(IPoolTypes.ZeroAddress.selector);
        controller.withdraw(listingId, address(0));
    }

    function test_revert_withdrawWhileAnAcquisitionIsUnsettled() public {
        (, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        warpPastCooldown(clone);
        acquirePooled(address(pool), clone, player, 1);
        vm.expectRevert(IPoolTypes.FwaBusy.selector);
        controller.withdraw(listingId, address(controller));
    }

    // ---------------------------------------------------------------- capture

    function test_captureSendsTheProceedsToTheControllerAndBooksNothing() public {
        (uint256 tokenId, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        Books memory before_ = _books();

        Vm.Log[] memory logs = _capture(listingId);

        (bool found, uint256 loggedToken, uint256 proceeds, bool delivered) = _foreignCaptured(logs);
        assertTrue(found, "ForeignCaptured emitted");
        assertTrue(delivered);
        assertEq(loggedToken, tokenId);
        assertGt(proceeds, 0);
        assertEq(controller.callCount(), 1);
        TestController.Call memory c = controller.callAt(0);
        assertEq(c.listingId, listingId);
        assertEq(c.tokenId, tokenId);
        assertEq(c.proceeds, proceeds);
        assertEq(c.value, proceeds, "the ETH value equals the proceeds");
        assertEq(address(controller).balance, proceeds);

        Books memory after_ = _books();
        assertEq(after_.nav, before_.nav, "NAV");
        assertEq(after_.cash, before_.cash, "cash");
        assertEq(after_.backing, before_.backing, "backing");
        assertEq(after_.receivable, 0, "receivable");
        assertEq(after_.maintenance, before_.maintenance, "maintenance");
        assertEq(after_.maintenanceReceivable, 0);
        assertEq(after_.fund, before_.fund, "the GRAIL fund");
        assertEq(after_.grailReceivable, 0);
        assertEq(after_.margin, before_.margin, "margin");
        assertEq(after_.balance, before_.balance, "the pool balance");
        assertEq(IERC721(WPUNKS).ownerOf(tokenId), player, "the purchaser holds the punk");
        assertEq(_ip().foreignListings().length, 0, "the entry left");
        assertFalse(_ip().registered(WPUNKS, tokenId));
        _assertI1();
    }

    function test_aControllerThatRevertsLeavesTheProceedsInCashAsMargin() public {
        (uint256 tokenId, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        controller.setRejects(true);
        Books memory before_ = _books();

        Vm.Log[] memory logs = _capture(listingId);

        (bool found, uint256 loggedToken, uint256 proceeds, bool delivered) = _foreignCaptured(logs);
        assertTrue(found);
        assertFalse(delivered, "the callback failed");
        assertEq(loggedToken, tokenId);
        assertGt(proceeds, 0);
        assertEq(controller.callCount(), 0);
        assertEq(address(controller).balance, 0);

        Books memory after_ = _books();
        assertEq(after_.balance, before_.balance + proceeds, "the pool kept the ETH");
        assertEq(
            after_.cash + after_.maintenance + after_.fund,
            before_.cash + before_.maintenance + before_.fund + proceeds,
            "the proceeds joined the buckets"
        );
        assertEq(after_.receivable, 0);
        assertEq(after_.margin, 0, "the margin was split");
        assertEq(_ip().foreignListings().length, 0);
        _assertI1();
    }

    function test_aControllerThatBurnsGasIsCutOffAtTheGasLimit() public {
        (, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        controller.setBurnsGas(true);

        Vm.Log[] memory logs = _capture(listingId);

        (bool found,, uint256 proceeds, bool delivered) = _foreignCaptured(logs);
        assertTrue(found);
        assertFalse(delivered);
        assertGt(proceeds, 0);
        assertEq(_books().receivable, 0);
        _assertI1();
    }

    function test_theBookingWalkPassesAForeignListingWithoutDisturbingOrdinaryCaptures() public {
        (, uint256 listingId) = _register(0, address(controller), PRICE);
        _activate();
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, player, 2);
        uint256 ordinary = pool.listedIds(0)[0];
        fulfill(clone, ids[0], wordFor(clone, listingId));
        fulfill(clone, ids[1], wordFor(clone, ordinary));
        uint256 listedBefore = pool.listedCount();

        vm.prank(keeper);
        pool.settle(20);

        assertEq(pool.listedCount(), listedBefore - 1, "one ordinary capture");
        assertEq(controller.callCount(), 1, "one foreign capture");
        assertEq(_ip().foreignListings().length, 0);
        assertEq(pool.receivable(), 0);
        _assertI1();
    }

    // ---------------------------------------------------------------- failed delivery

    /// @dev Wrapped Cryptopunks deliver to any recipient, so a failed delivery needs a Shape, which
    ///      reverts on a transfer to a contract without a receiver. A freshly minted Shape moved to the admin is
    ///      registered as a foreign listing and fulfilled for the Shapes contract, so FWA holds the
    ///      delivery pending.
    function _griefedForeign() internal returns (uint256 tokenId, uint256 listingId, uint256 requestId) {
        address minter = makeAddr("minter");
        tokenId = mintShapes(minter, 0.1 ether, 1);
        vm.prank(minter);
        IERC721(SHAPES_ADDR).transferFrom(minter, admin, tokenId);
        vm.prank(admin);
        IERC721(SHAPES_ADDR).approve(address(pool), tokenId);
        vm.prank(admin);
        _ip().registerForeign(SHAPES_ADDR, tokenId, address(controller), PRICE);
        listingId = _ip().foreignListings()[0].listingId;
        _activate();
        warpPastCooldown(clone);
        uint256[] memory ids = acquirePooled(address(pool), clone, SHAPES_ADDR, 1);
        requestId = ids[0];
        fulfill(clone, requestId, wordFor(clone, listingId));
    }

    function _refundDelivery(uint256 listingId) internal {
        (, uint64 deadline) = clone.pendingDeliveries(listingId);
        vm.warp(deadline);
        vm.prank(SHAPES_ADDR);
        clone.refundFailedDelivery(listingId);
    }

    function test_aRefundedDeliveryKeepsTheEntryUnlistedAndTheControllerWithdraws() public {
        (uint256 tokenId, uint256 listingId,) = _griefedForeign();
        _refundDelivery(listingId);
        Books memory before_ = _books();

        pool.bookOnly(5);

        assertEq(IERC721(SHAPES_ADDR).ownerOf(tokenId), address(pool), "token recovered");
        IPoolTypes.ForeignListing[] memory all = _ip().foreignListings();
        assertEq(all.length, 1, "entry kept");
        assertEq(all[0].listingId, listingId);
        assertEq(all[0].notional, 0, "unlisted");
        assertTrue(_ip().registered(SHAPES_ADDR, tokenId));
        assertEq(controller.callCount(), 0);
        Books memory after_ = _books();
        assertEq(after_.nav, before_.nav);
        assertEq(after_.cash, before_.cash);
        assertEq(after_.backing, before_.backing);
        Lens lens = new Lens(Pool(payable(address(pool))));
        assertEq(lens.foreign()[0].weightBps, 0, "no weight while unlisted");

        vm.prank(admin);
        vm.expectRevert(IPoolTypes.Accounted.selector);
        _ip().sweep(SHAPES_ADDR, tokenId, admin);
        vm.expectRevert(abi.encodeWithSelector(IPoolTypes.ListingNotActive.selector, listingId));
        controller.reprice(listingId, 0.8 ether);

        controller.withdraw(listingId, address(controller));
        assertEq(IERC721(SHAPES_ADDR).ownerOf(tokenId), address(controller));
        assertEq(_ip().foreignListings().length, 0);
        assertFalse(_ip().registered(SHAPES_ADDR, tokenId));
        _assertI1();
    }

    function test_aRefundedForeignTokenCanBeRegisteredAgainAfterTheWithdrawal() public {
        (uint256 tokenId, uint256 listingId,) = _griefedForeign();
        _refundDelivery(listingId);
        pool.bookOnly(5);

        controller.withdraw(listingId, admin);
        vm.prank(admin);
        IERC721(SHAPES_ADDR).approve(address(pool), tokenId);
        vm.prank(admin);
        _ip().registerForeign(SHAPES_ADDR, tokenId, address(controller), PRICE);
        assertEq(_ip().foreignListings().length, 1);
        assertTrue(_ip().foreignListings()[0].listingId != listingId, "a new listing");
    }

    function test_aPendingDeliveryRemovesTheEntryWithoutProceeds() public {
        (uint256 tokenId, uint256 listingId, uint256 requestId) = _griefedForeign();
        assertEq(uint8(_acquisitionStatus(requestId)), uint8(IFWAClone.AcquisitionStatus.DeliveryPending));
        Books memory before_ = _books();

        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.ForeignCaptured(listingId, tokenId, 0, false);
        pool.bookOnly(5);

        assertEq(_ip().foreignListings().length, 0);
        assertFalse(_ip().registered(SHAPES_ADDR, tokenId));
        assertEq(controller.callCount(), 0);
        Books memory after_ = _books();
        assertEq(after_.nav, before_.nav);
        assertEq(after_.cash, before_.cash);
        assertEq(after_.margin, before_.margin);
        _assertI1();
    }

    function _acquisitionStatus(uint256 requestId) internal view returns (IFWAClone.AcquisitionStatus status) {
        (,,,, status) = clone.acquisitions(requestId);
    }

    // ---------------------------------------------------------------- exit

    function test_exitWithdrawsTheForeignListingsToTheirControllers() public {
        (uint256 first, uint256 firstListing) = _register(0, address(controller), PRICE);
        TestController other = new TestController(address(pool));
        (uint256 second,) = _register(1, address(other), PRICE + 1 ether);
        _activate();

        vm.prank(admin);
        _ip().startExit(address(pool));
        for (uint256 i; i < 40 && !_ip().exportStep(50); ++i) {}

        assertEq(uint8(pool.lifecycle()), uint8(IPoolTypes.Lifecycle.Exported));
        assertEq(IERC721(WPUNKS).ownerOf(first), address(controller));
        assertEq(IERC721(WPUNKS).ownerOf(second), address(other));
        assertEq(_ip().foreignListings().length, 0);
        assertFalse(_ip().registered(WPUNKS, first));
        assertTrue(_status(firstListing) != IFWAClone.ListingStatus.Active);
        _assertI1();
    }

    function test_exitWithdrawsTheForeignListingsInTheFirstCall() public {
        (uint256 tokenId,) = _register(0, address(controller), PRICE);
        _activate();
        vm.prank(admin);
        _ip().startExit(address(pool));

        _ip().exportStep(1);

        assertEq(IERC721(WPUNKS).ownerOf(tokenId), address(controller));
    }
}
