// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Pool} from "../../src/Pool.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice Drives deposits, withdrawals, liquidations and bucket moves, and records the ghost
///         state the invariants compare against. Assertion failures inside the handler are
///         recorded in `i3Broken` and `i4Broken` because reverts of handler calls are discarded.
///         Pricing inputs (NAV, cash, claims) are read through `PoolHarness.previewSynced`, which
///         returns the state a pricing action sees after `_sync` and leaves the pool unchanged.
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

    /// @dev Pool state a pricing action reads after `_sync`. Other reverts are rethrown. The
    ///      recorder keeps logs of reverted calls, so the recorded logs are cleared afterwards. Call
    ///      this before any other pool call of the action.
    function _preview() internal returns (uint256 navNow, uint256 cashNow, uint256 claimsNow) {
        try pool.previewSynced() {}
        catch (bytes memory data) {
            vm.getRecordedLogs();
            if (bytes4(data) != PoolHarness.Preview.selector) {
                assembly {
                    revert(add(data, 32), mload(data))
                }
            }
            assembly {
                navNow := mload(add(data, 36))
                cashNow := mload(add(data, 68))
                claimsNow := mload(add(data, 100))
            }
        }
    }

    function deposit(uint96 value, uint8 actorSeed) external returns (bool) {
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(value, 0.01 ether, 50 ether);
        vm.deal(actor, amount);
        vm.prank(actor);
        pool.deposit{value: amount}();
        return true;
    }

    /// @dev Returns whether `withdraw` was called.
    function withdraw(uint256 shares, uint8 actorSeed) external returns (bool) {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = pool.sharesOf(actor);
        if (balance == 0) return false;
        shares = bound(shares, 1, balance);

        (uint256 navBefore, uint256 cashBefore, uint256 claimsBefore) = _preview();
        uint256 supplyBefore = pool.totalShares();
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
        return true;
    }

    /// @dev Returns whether `liquidate` was called and every log it emitted.
    function liquidate() external returns (bool executed, Vm.Log[] memory logs) {
        uint256 head = pool.claimHead();
        if (head == _queuedTo.length) return (false, logs);
        (, uint256 requestedAt,) = pool.claimQueue(head);
        if (block.timestamp < requestedAt + pool.rotateInterval()) return (false, logs);

        (, uint256 cashBefore, uint256 claimsBefore) = _preview();
        vm.recordLogs();
        pool.liquidate();
        logs = vm.getRecordedLogs();
        executed = true;

        uint256 total;
        uint256 events;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool) || logs[i].topics[0] != IPoolTypes.ClaimPaid.selector) continue;
            ++events;
            address to = address(uint160(uint256(logs[i].topics[1])));
            uint256 amount = abi.decode(logs[i].data, (uint256));
            total += amount;
            if (paidIndex >= _queuedTo.length || to != _queuedTo[paidIndex]) {
                i4Broken = true;
                return (executed, logs);
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
        (uint256 minorBucket,,,,,,,,,,,) = pool.grail(0);
        (uint256 majorBucket,,,,,,,,,,,) = pool.grail(1);
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
