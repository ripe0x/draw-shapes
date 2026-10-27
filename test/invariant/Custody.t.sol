// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "../fork/ForkBase.sol";
import {Handler} from "./Handler.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";

/// @notice System invariants on the pinned mainnet fork with every real dependency. Custody stays in CI forever.
/// forge-config: default.invariant.runs = 12
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = false
contract CustodyInvariants is ForkBase {
    Handler handler;

    function setUp() public {
        deployLaunch();
        fundAndFill(OPENING_CAPITAL);
        openMarket(LAUNCH_ETH);
        openGame();
        handler = new Handler(sys, pool, SHAPES, POOL_MANAGER);
        targetContract(address(handler));
        excludeSender(address(sys.timelock));
    }

    /// @notice I1 custody: every ETH, ENGINE and NFT outflow from a holder lands on an allowlisted destination.
    function invariant_custody() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// @notice I2 books: the game's cash plus inventory at cost equals the capital it received plus its realised
    ///         results (to the wei FWA's split rounds in its favour); and the vault plus the game's capital account
    ///         cover everything put into the vault.
    function invariant_books() public view {
        uint256 lhs = address(sys.game).balance + sys.game.inventoryCost();
        uint256 rhs = sys.game.capitalIn() + sys.game.revenue() + sys.game.opsReturned() - sys.game.prizeExpense()
            - sys.game.opsPaid() - sys.game.distributed();
        assertGe(lhs, rhs, "books");
        assertGe(address(sys.vault).balance + sys.game.capitalIn(), handler.vaultFunded(), "capital");
    }

    /// @notice I3 ledger: `accepted` = requests FWA issued (and the walk has seen) per epoch; weight never exceeds the
    ///         ticket ETH of pulls FWA delivered, and the difference is at most the requests still open (FWA can
    ///         deliver one between two syncs); resolved never exceeds accepted.
    function invariant_ledgerMatchesFwa() public view {
        uint256 open = sys.farm.openBlock();
        uint256[64] memory accepted;
        uint256[64] memory fulfilled;
        uint256 maxPaid;
        uint256 n = sys.game.seenSeq();
        for (uint64 sq = 1; sq < n; ++sq) {
            (, uint256 requestBlock, uint256 paid,, IFWAPool.AcquisitionStatus st) =
                pool.acquisitions(pool.requestIdAtSequence(sq));
            uint256 e = (requestBlock - open) / 7_200;
            if (e >= 64) continue;
            ++accepted[e];
            if (st == IFWAPool.AcquisitionStatus.Fulfilled) fulfilled[e] += paid;
            if (paid > maxPaid) maxPaid = paid;
        }
        uint256 gap;
        for (uint256 e; e < 64; ++e) {
            (uint256 acc, uint256 res, uint256 weight) = sys.game.epochTotals(e);
            assertEq(acc, accepted[e], "accepted = FWA issued");
            assertLe(res, acc, "resolved <= accepted");
            assertLe(weight, fulfilled[e], "weight <= delivered ticket ETH");
            gap += fulfilled[e] - weight;
        }
        assertLe(gap, sys.game.openCount() * maxPaid, "unbooked deliveries are open requests");
    }

    /// @notice I4 the farm never pays more than its allocations, and its balance reconciles.
    function invariant_farmBounded() public view {
        assertLe(sys.farm.totalClaimed(), sys.farm.totalPots(), "claims within fixed pots");
        assertLe(sys.farm.totalPots(), sys.farm.genesisBudget(), "pots within the budget");
        assertLe(sys.farm.totalBonusPaid(), 10_000_000 ether, "bonus");
        assertEq(
            sys.engine.balanceOf(address(sys.farm)),
            200_000_000 ether - sys.farm.totalClaimed() - sys.farm.totalBonusPaid() - sys.farm.totalBurned(),
            "farm balance"
        );
        assertGe(sys.engine.balanceOf(address(sys.farm)), sys.farm.reserved() + sys.farm.bonusPool(), "reserved held");
    }

    /// @notice I5 the buyback spends only profit, and keeper credits are covered.
    function invariant_buybackSpendsProfitOnly() public view {
        assertLe(sys.buyback.totalSpent(), sys.buyback.profitReceived(), "spent within profit received");
        assertEq(sys.buyback.profitReceived(), sys.game.distributed(), "profit received = distributed");
        assertGe(address(sys.keeperFund).balance, sys.keeperFund.tipCreditTotal());
    }

    /// @notice I6 modules hold nothing between calls; the buyback holds no ENGINE (it burns all it buys).
    function invariant_modulesHoldNothing() public view {
        address[2] memory m = [address(sys.buyer), address(sys.converter)];
        for (uint256 i; i < 2; ++i) {
            assertEq(m[i].balance, 0, "ETH");
            assertEq(sys.engine.balanceOf(m[i]), 0, "ENGINE");
        }
        assertEq(sys.engine.balanceOf(address(sys.buyback)), 0, "buyback ENGINE");
    }

    /// @notice I7 every live listing's prize is in FWA escrow, or FWA has already allocated it to a purchaser
    ///         and the walk has not booked that pull yet.
    function invariant_inventoryInEscrow() public view {
        uint256 backing;
        for (uint256 i; i < sys.game.liveCount(); ++i) {
            uint256 id = sys.game.liveAt(i);
            (uint48 tokenId, uint80 b,,,,) = sys.game.items(id);
            (,, address purchaser,,,,, IFWAPool.ListingStatus st) = pool.listings(id);
            if (st == IFWAPool.ListingStatus.Active || st == IFWAPool.ListingStatus.Staged) {
                assertEq(shapes.ownerOf(tokenId), address(pool), "escrowed");
            } else {
                assertTrue(
                    st == IFWAPool.ListingStatus.Settled || st == IFWAPool.ListingStatus.DeliveryPending
                        || st == IFWAPool.ListingStatus.DeliveryRefunded,
                    "allocated, awaiting booking"
                );
                assertTrue(purchaser != address(0), "has a purchaser");
            }
            backing += b;
        }
        assertLe(backing, sys.game.inventoryBacking());
    }

    function test_handlerReachesEveryPath() public {
        // A fixed walk through the handler so CI shows each action runs against the fork.
        handler.pullOne(0);
        handler.pullOne(1);
        handler.settle(5, 0);
        handler.settle(6, 2);
        handler.keeperSync(2, 20);
        handler.warp(2 days);
        handler.keeperSync(3, 20);
        handler.buyback(1);
        handler.convert(0);
        handler.convert(1);
        handler.withdrawRefund(1);
        handler.claim(0);
        handler.marketSell(0, 50);
        handler.attack(1, 3);
        handler.donate(1, 0.1 ether);
        invariant_custody();
        invariant_books();
        invariant_ledgerMatchesFwa();
        invariant_farmBounded();
        invariant_buybackSpendsProfitOnly();
        invariant_modulesHoldNothing();
        invariant_inventoryInEscrow();
    }
}
