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
        fundAndFill(3 ether);
        openMarket(10 ether);
        vm.warp(block.timestamp + 2 hours);
        openGame();
        handler = new Handler(sys, pool, SHAPES, POOL_MANAGER);
        // give the treasury something to route from the start
        vm.deal(address(sys.treasury), 1 ether);
        targetContract(address(handler));
        excludeSender(address(sys.timelock));
    }

    /// @notice I1 custody: every ETH, ENGINE and NFT outflow from a holder lands on an allowlisted destination.
    function invariant_custody() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// @notice I2 solvency: vault + game value covers what was lent less booked losses and mint fees.
    function invariant_solvency() public view {
        uint256 value = address(sys.vault).balance + address(sys.game).balance + sys.game.inventoryBacking();
        uint256 lhs = value + sys.game.mintFeesPaid() + sys.game.bookedLoss() + sys.game.grailCapturedBacking()
            + sys.game.pullsBooked(); // 1 wei of FWA rounding per pull
        uint256 rhs = handler.vaultFunded() + handler.grailFunded();
        assertGe(lhs, rhs, "solvency");
    }

    /// @notice I3 ledger: `accepted` = requests FWA issued (and the walk has seen) per epoch; `units` = delivered
    ///         pulls the walk has resolved per epoch; resolved never exceeds accepted.
    function invariant_ledgerMatchesFwa() public view {
        uint256 open = sys.farm.openBlock();
        uint256[64] memory accepted;
        uint256[64] memory deliveredResolved;
        uint256 n = sys.game.seenSeq();
        for (uint64 sq = 1; sq < n; ++sq) {
            (, uint256 requestBlock,,, IFWAPool.AcquisitionStatus st) = pool.acquisitions(pool.requestIdAtSequence(sq));
            uint256 e = (requestBlock - open) / 7_200;
            if (e >= 64) continue;
            ++accepted[e];
            if (st == IFWAPool.AcquisitionStatus.Fulfilled && !_isOpen(sq)) ++deliveredResolved[e];
        }
        for (uint256 e; e < 64; ++e) {
            (uint256 acc, uint256 res, uint256 units) = sys.game.epochTotals(e);
            assertEq(acc, accepted[e], "accepted = FWA issued");
            assertLe(res, acc, "resolved <= accepted");
            assertEq(units, deliveredResolved[e], "units = delivered pulls resolved");
        }
    }

    function _isOpen(uint64) internal pure returns (bool) {
        return false; // a Fulfilled request is never left open: the walk resolves it on sight
    }

    /// @notice I4 the farm never pays more than allocation + deposits, and its balance reconciles.
    function invariant_farmBounded() public view {
        assertLe(sys.farm.totalClaimed(), sys.farm.genesisBudget() + sys.farm.totalDeposited(), "claims");
        assertLe(sys.farm.totalBonusPaid(), 10_000_000 ether, "bonus");
        assertEq(
            sys.engine.balanceOf(address(sys.farm)),
            900_000_000 ether + sys.farm.totalDeposited() - sys.farm.totalClaimed() - sys.farm.totalBonusPaid()
                - sys.farm.totalBurned(),
            "farm balance"
        );
    }

    /// @notice I5 the treasury table always sums to 10,000 and allocations are covered.
    function invariant_treasuryTable() public view {
        uint256 sum;
        for (uint256 i; i < sys.treasury.sinkCount(); ++i) {
            (, uint16 bps) = sys.treasury.sinkAt(i);
            sum += bps;
        }
        assertEq(sum, 10_000);
        assertGe(address(sys.treasury).balance, sys.treasury.allocatedTotal());
        assertGe(address(sys.keeperFund).balance, sys.keeperFund.tipCreditTotal());
    }

    /// @notice I6 sinks and modules hold nothing between calls.
    function invariant_sinksHoldNothing() public view {
        address[4] memory m = [address(sys.buyback), address(sys.grailFund), address(sys.buyer), address(sys.converter)];
        for (uint256 i; i < 4; ++i) {
            assertEq(m[i].balance, 0, "ETH");
            assertEq(sys.engine.balanceOf(m[i]), 0, "ENGINE");
        }
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
        handler.distribute(0);
        handler.buyback(1);
        handler.grailProcess(3);
        handler.convert(0);
        handler.convert(1);
        handler.withdrawRefund(1);
        handler.claim(0);
        handler.marketSell(0, 50);
        handler.attack(1, 3);
        handler.donate(1, 0.1 ether);
        invariant_custody();
        invariant_solvency();
        invariant_ledgerMatchesFwa();
        invariant_farmBounded();
        invariant_treasuryTable();
        invariant_sinksHoldNothing();
        invariant_inventoryInEscrow();
    }
}
