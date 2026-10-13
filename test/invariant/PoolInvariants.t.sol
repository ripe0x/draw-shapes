// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Pool} from "../../src/Pool.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";

/// @notice Drives deposits, withdrawals, liquidations and bucket moves, and records the ghost
///         state the invariants compare against. Assertion failures inside the handler are
///         recorded in `i3Broken` and `i4Broken` because reverts of handler calls are discarded.
contract PoolHandler is Test {
    PoolHarness public immutable pool;
    address[] public actors;

    uint256 public ghostBacking;
    bool public i3Broken;
    bool public i4Broken;

    address[] internal _queuedTo;
    uint256[] internal _queuedAmount;
    uint256 public paidIndex;
    uint256 public paidInHead;

    constructor(PoolHarness pool_, address[] memory actors_) {
        pool = pool_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function queuedLength() external view returns (uint256) {
        return _queuedTo.length;
    }

    /// @notice Sum of unpaid claim amounts according to the ghost queue.
    function outstandingClaims() external view returns (uint256 total) {
        for (uint256 i = paidIndex; i < _queuedAmount.length; ++i) {
            total += _queuedAmount[i];
        }
        total -= paidInHead;
    }

    function deposit(uint96 value, uint8 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(value, 0.01 ether, 50 ether);
        vm.deal(actor, amount);
        vm.prank(actor);
        pool.deposit{value: amount}();
    }

    function withdraw(uint256 shares, uint8 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = pool.sharesOf(actor);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);

        uint256 navBefore = pool.nav();
        uint256 supplyBefore = pool.totalShares();
        uint256 cashBefore = pool.cash();
        uint256 claimsBefore = pool.claims();
        uint256 ethBefore = actor.balance;
        uint256 expected = PricingLib.claimFor(shares, navBefore, supplyBefore);

        vm.prank(actor);
        pool.withdraw(shares);

        uint256 paidNow = actor.balance - ethBefore;
        uint256 enqueued = pool.claims() - claimsBefore;
        if (paidNow + enqueued != expected) i3Broken = true;
        if (paidNow > navBefore * shares / supplyBefore) i3Broken = true;
        if (paidNow != (expected < cashBefore ? expected : cashBefore)) i3Broken = true;
        if (pool.cash() != cashBefore - paidNow) i3Broken = true;

        if (enqueued != 0) {
            (address to,, uint256 amount) = pool.claimQueue(_queuedTo.length);
            if (to != actor || amount != enqueued) i4Broken = true;
            _queuedTo.push(actor);
            _queuedAmount.push(enqueued);
        }
    }

    function liquidate() external {
        uint256 head = pool.claimHead();
        if (head == _queuedTo.length) return;
        (, uint256 requestedAt,) = pool.claimQueue(head);
        if (block.timestamp < requestedAt + pool.rotateInterval()) return;

        uint256 cashBefore = pool.cash();
        uint256 claimsBefore = pool.claims();
        vm.recordLogs();
        pool.liquidate();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 total;
        uint256 events;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != Pool.ClaimPaid.selector) continue;
            ++events;
            address to = address(uint160(uint256(logs[i].topics[1])));
            uint256 amount = abi.decode(logs[i].data, (uint256));
            total += amount;
            if (paidIndex >= _queuedTo.length || to != _queuedTo[paidIndex]) {
                i4Broken = true;
                return;
            }
            paidInHead += amount;
            if (paidInHead > _queuedAmount[paidIndex]) i4Broken = true;
            if (paidInHead == _queuedAmount[paidIndex]) {
                ++paidIndex;
                paidInHead = 0;
            }
        }

        if (events > 20) i4Broken = true;
        if (paidIndex != pool.claimHead()) i4Broken = true;
        if (paidIndex < _queuedTo.length) {
            (,, uint256 amountLeft) = pool.claimQueue(paidIndex);
            if (amountLeft != _queuedAmount[paidIndex] - paidInHead) i4Broken = true;
        }
        if (pool.cash() != cashBefore - total || pool.claims() != claimsBefore - total) i4Broken = true;
        // The loop stops only when cash is empty, the queue is empty or the item limit is reached.
        if (pool.cash() != 0 && paidIndex < _queuedTo.length && events < 20) i4Broken = true;
    }

    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 3 hours));
    }

    /// @notice Moves cash into backing, as a mint does.
    function mintBacking(uint16 fractionBps) external {
        uint256 value = pool.cash() * bound(fractionBps, 0, 10_000) / 10_000;
        if (value == 0) return;
        pool.spendOnBacking(value);
        ghostBacking += value;
    }

    /// @notice Moves backing into cash, as a redemption does.
    function releaseBacking(uint16 fractionBps) external {
        uint256 value = ghostBacking * bound(fractionBps, 0, 10_000) / 10_000;
        if (value == 0) return;
        vm.deal(address(this), value);
        pool.releaseBacking{value: value}();
        ghostBacking -= value;
    }

    /// @notice Adds ETH to cash, as harvested proceeds do.
    function harvest(uint96 amount) external {
        uint256 value = bound(amount, 1, 20 ether);
        vm.deal(address(this), value);
        pool.bookProceeds{value: value}();
    }
}

contract PoolInvariantsTest is PoolFixture {
    PoolHarness internal pool;
    PoolHandler internal handler;

    function setUp() public {
        pool = _deploy(_params());
        address[] memory actors = new address[](6);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }
        handler = new PoolHandler(pool, actors);
        targetContract(address(handler));
    }

    /// @dev Backing the pool should hold: tokens are not yet held, so it is the handler's record
    ///      of cash moved into backing.
    function _expectedBacking() internal view returns (uint256) {
        return handler.ghostBacking();
    }

    function _grailBuckets() internal view returns (uint256 total) {
        (uint256 minorBucket,,,,,,,,,) = pool.grail(0);
        (uint256 majorBucket,,,,,,,,,) = pool.grail(1);
        return minorBucket + majorBucket;
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_I1_balanceCoversBuckets() public view {
        assertGe(address(pool).balance, pool.cash() + pool.maintenance() + _grailBuckets());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_I2_backingMatchesTokens() public view {
        assertEq(pool.backing(), _expectedBacking());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_I3_withdrawalNeverExceedsNavShare() public view {
        assertFalse(handler.i3Broken());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_I4_claimsPaidInRequestOrder() public view {
        assertFalse(handler.i4Broken());
        assertEq(handler.paidIndex(), pool.claimHead());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_claimsBucketEqualsOutstandingQueue() public view {
        assertEq(pool.claims(), handler.outstandingClaims());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_sharesSumToTotal() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += pool.sharesOf(handler.actors(i));
        }
        assertEq(sum, pool.totalShares());
    }
}
