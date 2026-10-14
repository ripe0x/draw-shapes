// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IShapePacks} from "draw-packs/interfaces/IShapePacks.sol";
import {Pool} from "../../src/Pool.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "../fork/ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {PoolHandler} from "./PoolInvariants.t.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice Drives the pool against a real FWA clone, deployed Shapes and a Draw Packs deployment.
///         Deposit, withdraw and warp are delegated to `PoolHandler`, which holds the I3 ghost
///         state. The claim queue ghost (I4), the I6 and I7 ghost state are kept here: pool events
///         are read after every action, including the claim payouts and liquidation fee deductions
///         of `pull`, `payClaims` and `rotateIfDue`. A reverted action leaves no ghost change because
///         the whole handler call reverts. After every pricing action (deposit, withdraw,
///         rotateIfDue, redeemAndDeposit) the handler checks that the books are level with
///         FWA and every receivable is harvested. GRAIL ghost state is kept per track: credits
///         (entry contributions and feed shares), captured proceeds, and the cost of every growth
///         step, derived from the track's `stepWei` and the mint fees of its `defaultMakeup`.
contract PoolFwaHandler is ForkBase {
    PoolHarness public immutable pool;
    IFWAClone public immutable clone;
    PoolHandler public immutable base;
    address[] internal _actors;
    address[] internal _players;

    uint256 public ghostMaintenanceShares;
    uint256 public ghostMaintenanceFolded;
    uint256[2] public ghostGrailIn;
    uint256[2] public ghostGrailProceeds;
    uint256[2] public ghostGrailSpend;
    uint256 public ghostCapturedProceeds;
    uint256 public ghostHarvestReceived;
    uint256 public ghostSurplus;
    uint256 public ghostCapturedValue;
    uint256 public ghostWrittenOff;
    uint256 public ghostMarginSplit;
    uint256 public ghostRefunds;
    uint256 public ghostClaimsQueued;
    uint256 public ghostClaimsPaid;
    uint256 public ghostLiquidationFees;
    uint256 public lastMaintenance;
    uint256 internal _batchRefund;
    address[] internal _queuedTo;
    uint256[] internal _queuedAmount;
    uint256 internal _paidIndex;
    uint256 internal _paidInHead;
    bool public i4Broken;
    bool public i6Broken;
    bool public harvestBroken;
    bool public booksBehindAfterPricing;
    /// @dev Set when `settle` pays a refund without listing an item or repricing a GRAIL track.
    bool public settleBroken;
    /// @dev `GrailListed` events since the last `Settled` or `Rotated` event.
    uint256 internal _grailListedInCall;
    uint256 public settleListed;
    uint256 public settleRefunds;
    /// @dev Shapes `pullWithShapes` and `redeemAndDeposit` left in the pool as held items.
    uint256 public keptShapes;
    /// @dev Set when `rotate` succeeds while `rotateDue` is `None`.
    bool public rotateGateBroken;
    /// @dev Set when `rotate` leaves inventory unchanged while `rotateDue` is GrailStep.
    bool public rotateStalled;
    bool internal _rotatedInventoryChanged;

    uint256 public captures;
    uint256 public grailCaptures;
    uint256 public grailGrowths;
    uint256 public griefs;
    uint256 public harvests;
    /// @dev Number of `HarvestShortfall` events: FWA paid less than the booked receivables.
    uint256 public harvestShortfalls;
    uint256 public directPurchases;
    uint256 public pulls;
    uint256 public rotations;
    uint256 public liquidations;
    uint256 public liquidatedItems;
    uint256 public liquidatedListed;
    uint256 public paramChanges;
    /// @dev Number of `setPurchaseGate` calls, from `toggleGate` and from the direct purchase actions.
    uint256 public gateToggles;
    uint256 public exportSteps;

    receive() external payable {}

    constructor(PoolHarness pool_, IFWAClone clone_, address[] memory actors_, address[] memory players_) {
        pool = pool_;
        clone = clone_;
        _actors = actors_;
        _players = players_;
        base = new PoolHandler(pool_, actors_);
        lastMaintenance = pool_.maintenance();
        (uint256 minorBucket,,,,,,,,,,,) = IPool(address(pool_)).grail(0);
        (uint256 majorBucket,,,,,,,,,,,) = IPool(address(pool_)).grail(1);
        ghostGrailIn[0] = minorBucket;
        ghostGrailIn[1] = majorBucket;
        vm.recordLogs();
    }

    // ------------------------------------------------------------------ ghost accounting

    /// @dev Sums the pool events emitted since the last call and checks I6.
    function _collect() internal {
        _ingest(vm.getRecordedLogs());
    }

    function _ingest(Vm.Log[] memory logs) internal {
        _batchRefund = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == IPoolTypes.Deposited.selector) {
                (, uint256 contribution,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                _creditGrail(contribution);
            } else if (topic == IPoolTypes.MarginSplit.selector) {
                (uint256 cover, uint256 premiumShare, uint256 maintenanceShare, uint256 feedShare) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                ghostMarginSplit += cover + premiumShare + maintenanceShare + feedShare;
                ghostMaintenanceShares += maintenanceShare;
                _creditGrail(feedShare);
            } else if (topic == IPoolTypes.GrailGrown.selector) {
                ghostGrailSpend[uint256(logs[i].topics[1])] += _growthCost(uint256(logs[i].topics[1]));
                ++grailGrowths;
            } else if (topic == IPoolTypes.GrailCaptured.selector) {
                ghostGrailProceeds[uint256(logs[i].topics[1])] += abi.decode(logs[i].data, (uint256));
                ++grailCaptures;
            } else if (topic == IPoolTypes.Captured.selector) {
                (, uint256 value, uint256 proceeds) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                ghostCapturedProceeds += proceeds;
                ghostCapturedValue += value;
                ++captures;
            } else if (topic == IPoolTypes.WrittenOff.selector) {
                ghostWrittenOff += abi.decode(logs[i].data, (uint256));
            } else if (topic == IPoolTypes.Harvested.selector) {
                (uint256 received,) = abi.decode(logs[i].data, (uint256, uint256));
                ghostHarvestReceived += received;
            } else if (topic == IPoolTypes.HarvestShortfall.selector) {
                ++harvestShortfalls;
            } else if (topic == IPoolTypes.SurplusBooked.selector) {
                ghostSurplus += abi.decode(logs[i].data, (uint256));
            } else if (topic == IPoolTypes.Withdrawn.selector) {
                (,, uint256 enqueued) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                ghostClaimsQueued += enqueued;
            } else if (topic == IPoolTypes.ClaimPaid.selector) {
                _ingestClaimPaid(address(uint160(uint256(logs[i].topics[1]))), abi.decode(logs[i].data, (uint256)));
            } else if (topic == IPoolTypes.Liquidated.selector) {
                (, uint256 fee) = abi.decode(logs[i].data, (uint256, uint256));
                ghostLiquidationFees += fee;
                ++liquidatedItems;
                if (uint256(logs[i].topics[1]) != 0) ++liquidatedListed;
                if (_paidIndex >= _queuedAmount.length || fee > _queuedAmount[_paidIndex] - _paidInHead) {
                    i4Broken = true;
                } else {
                    _queuedAmount[_paidIndex] -= fee;
                }
            } else if (topic == IPoolTypes.GrailListed.selector) {
                ++_grailListedInCall;
            } else if (topic == IPoolTypes.Rotated.selector) {
                _grailListedInCall = 0;
                uint256 refund;
                (, _rotatedInventoryChanged, refund) = abi.decode(logs[i].data, (bool, bool, uint256));
                ghostRefunds += refund;
                _batchRefund += refund;
            } else if (topic == IPoolTypes.Settled.selector) {
                (uint256 listed, uint256 refund) = abi.decode(logs[i].data, (uint256, uint256));
                ghostRefunds += refund;
                _batchRefund += refund;
                settleListed += listed;
                if (refund != 0 && listed == 0 && _grailListedInCall == 0) settleBroken = true;
                _grailListedInCall = 0;
                if (refund != 0) ++settleRefunds;
            }
        }
        uint256 current = pool.maintenance();
        // Maintenance falls only inside a rotation that logged a refund.
        if (current < lastMaintenance && _batchRefund == 0) i6Broken = true;
        lastMaintenance = current;
    }

    /// @dev Splits `amount` between the two GRAIL ghost credits by `minorShareBps`.
    function _creditGrail(uint256 amount) internal {
        (,,, uint16 minorShareBps) = pool.feeSplit();
        uint256 minorPart = amount * minorShareBps / 10_000;
        ghostGrailIn[0] += minorPart;
        ghostGrailIn[1] += amount - minorPart;
    }

    /// @dev Step plus the mint fees of the Shapes in `defaultMakeup(step)` for track `t`.
    function _growthCost(uint256 t) internal view returns (uint256 cost) {
        (,,,,, uint256 step,,,,,,) = IPool(address(pool)).grail(t);
        uint32[] memory counts = IShapePacks(pool.drawPacks()).defaultMakeup(step);
        uint256 shapeCount;
        for (uint256 i; i < counts.length; ++i) {
            shapeCount += counts[i];
        }
        return step + shapeCount * shapes.mintFee();
    }

    /// @dev Claims are paid to the claimant at the head of the ghost queue, never past its current
    ///      amount, and the head advances once it is paid in full.
    function _ingestClaimPaid(address to, uint256 amount) internal {
        ghostClaimsPaid += amount;
        if (_paidIndex >= _queuedTo.length || to != _queuedTo[_paidIndex]) {
            i4Broken = true;
            return;
        }
        _paidInHead += amount;
        if (_paidInHead > _queuedAmount[_paidIndex]) {
            i4Broken = true;
        } else if (_paidInHead == _queuedAmount[_paidIndex]) {
            ++_paidIndex;
            _paidInHead = 0;
        }
    }

    /// @dev Appends the claims `PoolHandler.withdraw` enqueued since the last call, at their
    ///      requested amounts.
    function _syncQueue() internal {
        uint256 n = base.queuedLength();
        while (_queuedTo.length < n) {
            (address to,, uint256 amount) = IPool(address(pool)).claimQueue(_queuedTo.length);
            _queuedTo.push(to);
            _queuedAmount.push(amount);
        }
    }

    /// @notice Sum of unpaid claim amounts according to the ghost queue.
    function outstandingClaims() public view returns (uint256 total) {
        for (uint256 i = _paidIndex; i < _queuedAmount.length; ++i) {
            total += _queuedAmount[i];
        }
        total -= _paidInHead;
    }

    function paidIndex() external view returns (uint256) {
        return _paidIndex;
    }

    /// @dev Flags a pricing action that left the booking walk behind FWA's processing queue or a
    ///      receivable unharvested.
    function _checkPriced() internal {
        if (
            pool.nextSequenceToBook() != clone.nextSequenceToProcess() || pool.receivable() != 0
                || IPool(address(pool)).maintenanceReceivable() != 0 || pool.grailReceivable(0) != 0 || pool.grailReceivable(1) != 0
        ) booksBehindAfterPricing = true;
    }

    modifier recorded() {
        vm.recordLogs();
        _;
        _collect();
    }

    // ------------------------------------------------------------------ exit actions

    /// @dev True from `startExit` on.
    function _exiting() internal view returns (bool) {
        return pool.lifecycle() >= IPoolTypes.Lifecycle.Exiting;
    }

    /// @dev Starts a retirement. Once per campaign: only a Live pool can start an exit.
    function startExitRetire() external recorded {
        if (pool.lifecycle() != IPoolTypes.Lifecycle.Live) return;
        vm.prank(pool.admin());
        IPool(address(pool)).startExit(address(pool));
    }

    /// @dev Settles what FWA holds, then moves up to `1 + itemsSeed % 30` items. A step that
    ///      finishes the export folds `maintenance` into `cash`, which the maintenance ghost state
    ///      records as folded: the maintenance and maintenance receivable held before the call plus
    ///      the maintenance shares booked during it.
    function exportStep(uint8 itemsSeed, uint256 pick) external {
        if (pool.lifecycle() != IPoolTypes.Lifecycle.Exiting) return;
        _warpToResume();
        vm.recordLogs();
        _fulfillOutstanding(pick, false);
        pool.settle(20);
        _collect();
        if (clone.unsettledAcquisitionCount() != 0 || pool.nextSequenceToBook() != clone.nextSequenceToProcess()) {
            return;
        }
        uint256 held = pool.maintenance() + IPool(address(pool)).maintenanceReceivable();
        uint256 sharesBefore = ghostMaintenanceShares;
        vm.recordLogs();
        bool done = IPool(address(pool)).exportStep(1 + itemsSeed % 30);
        ++exportSteps;
        if (done) lastMaintenance = 0;
        _collect();
        if (done) ghostMaintenanceFolded += held + ghostMaintenanceShares - sharesBefore;
    }

    // ------------------------------------------------------------------ depositor actions

    function deposit(uint96 value, uint8 actorSeed) external recorded {
        if (_exiting() || pool.depositsPaused() || pool.nav() == 0) return;
        if (base.deposit(value, actorSeed)) _checkPriced();
    }

    function withdraw(uint256 shares, uint8 actorSeed) external recorded {
        if (base.withdraw(shares, actorSeed)) {
            _syncQueue();
            _checkPriced();
        }
    }

    /// @dev Removes ordinary cash, so later withdrawals exceed `cash` and queue a claim.
    function loseCash(uint16 fractionBps) external recorded {
        pool.loseCash(pool.cash() * bound(fractionBps, 0, 10_000) / 10_000);
    }

    /// @dev An actor deposits, all cash is removed and the actor withdraws every share, which
    ///      queues a claim that only listed items can cover.
    function exitIntoQueue(uint96 value, uint8 actorSeed) external recorded {
        if (_exiting() || pool.depositsPaused() || pool.claims() != 0 || pool.nav() == 0 || pool.nav() >= pool.navCap())
        {
            return;
        }
        base.deposit(value, actorSeed);
        // `PoolHandler.withdraw` clears the recorded logs when it previews, so read these first.
        _collect();
        pool.loseCash(pool.cash());
        if (base.withdraw(type(uint256).max, actorSeed)) {
            _syncQueue();
            _checkPriced();
        }
    }

    /// @dev A call redeems at most `MAX_LIQUIDATE_ITEMS` items and withdraws a listing only while FWA
    ///      holds no unsettled acquisition. Held items need no FWA call.
    function _checkLiquidationStop(uint256 items, uint256 listedItems) internal {
        if (items > 25) i4Broken = true;
        if (listedItems != 0 && clone.unsettledAcquisitionCount() != 0) i4Broken = true;
    }

    /// @dev Warps to the end of the rotation spacing, then calls `rotate` as this contract, which
    ///      receives the refund, when `rotateDue` is nonzero. The ETH received must equal the logged
    ///      refund. A `rotate` call while `rotateDue` is `None` must revert.
    function rotateIfDue() external {
        if (_exiting()) return;
        uint256 at = pool.lastRotateAt() + pool.rotateInterval();
        if (block.timestamp < at) vm.warp(at);
        if (pool.rotateDue() == IPoolTypes.RotateTrigger.None) {
            try pool.rotate() {
                rotateGateBroken = true;
            } catch {}
            return;
        }
        bool grailStepDue = pool.rotateDue() == IPoolTypes.RotateTrigger.GrailStep;
        vm.recordLogs();
        uint256 balanceBefore = address(this).balance;
        pool.rotate();
        uint256 received = address(this).balance - balanceBefore;
        uint256 itemsBefore = liquidatedItems;
        uint256 listedBefore = liquidatedListed;
        _rotatedInventoryChanged = false;
        _ingest(vm.getRecordedLogs());
        if (grailStepDue && !_rotatedInventoryChanged) rotateStalled = true;
        if (received != _batchRefund) i6Broken = true;
        _checkPriced();
        _checkLiquidationStop(liquidatedItems - itemsBefore, liquidatedListed - listedBefore);
        if (liquidatedItems != itemsBefore) ++liquidations;
        ++rotations;
    }

    /// @dev Pays queued claims from cash, in every lifecycle state.
    function payClaims() external recorded {
        pool.payClaims();
    }

    // ------------------------------------------------------------------ admin actions

    /// @dev Sets the pause flags as the admin. Pulls and deposits return early while a flag is set.
    function setPaused(bool pulls_, bool deposits_) external recorded {
        vm.prank(pool.admin());
        IPool(address(pool)).setPaused(pulls_, deposits_);
        ++paramChanges;
    }

    /// @dev Sets a fee split inside the bounds: the first three at most 1,000 bps together.
    function setFeeSplit(uint16 premium, uint16 maintenance_, uint16 feed, uint16 minorShare) external recorded {
        vm.prank(pool.admin());
        IPool(address(pool))
            .setFeeSplit(
                uint16(bound(premium, 0, 400)),
                uint16(bound(maintenance_, 0, 300)),
                uint16(bound(feed, 0, 300)),
                uint16(bound(minorShare, 0, 10_000))
            );
        ++paramChanges;
    }

    /// @dev FWA processes acquisitions without the pool booking them, then a holder withdraws.
    function withdrawAfterProcess(uint8 n, uint256 shares, uint8 actorSeed) external recorded {
        clone.processAcquisitions(bound(n, 1, 5));
        if (base.withdraw(shares, actorSeed)) {
            _syncQueue();
            _checkPriced();
        }
    }

    /// @dev A direct FWA purchase is fulfilled and processed, then a depositor prices against the
    ///      books.
    function directThenDeposit(uint8 playerSeed, uint256 pick, uint96 value, uint8 actorSeed) external recorded {
        if (_exiting() || pool.depositsPaused() || pool.nav() == 0) return;
        _direct(playerSeed, pick, true);
        if (base.deposit(value, actorSeed)) _checkPriced();
    }

    function warp(uint32 seconds_) external {
        base.warp(seconds_);
    }

    function warpToResume() external {
        _warpToResume();
    }

    function _warpToResume() internal {
        uint256 resumeAt = clone.purchasesResumeAt() + 1;
        if (resumeAt > block.timestamp) vm.warp(resumeAt);
    }

    function redeemAndDeposit(uint8 actorSeed) external recorded {
        if (_exiting() || pool.depositsPaused() || pool.nav() == 0) return;
        address actor = _actors[actorSeed % _actors.length];
        uint256 tokenId = mintShapes(actor, actorSeed % 2 == 0 ? 0.1 ether : 0.01 ether, 1);
        uint256 heldBefore = pool.heldCount();
        vm.startPrank(actor);
        IERC721(SHAPES_ADDR).approve(address(pool), tokenId);
        pool.redeemAndDeposit(tokenId);
        vm.stopPrank();
        if (pool.heldCount() > heldBefore) ++keptShapes;
        _checkPriced();
    }

    // ------------------------------------------------------------------ player actions

    /// @dev Pulls `count` as a player. `fulfillNow` delivers a word for every outstanding request.
    function pull(uint8 countSeed, uint8 playerSeed, uint256 pick, bool fulfillNow) external recorded {
        if (_exiting() || pool.pullsPaused()) return;
        _warpToResume();
        uint256 count = bound(countSeed, 1, 3);
        if (count > IPool(address(pool)).maxBatch()) return;
        if (pool.listedCount() < clone.unsettledAcquisitionCount() + count + IPool(address(pool)).concurrency()) return;
        address player = _players[playerSeed % _players.length];
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(count);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, player.balance + total);
        vm.prank(player);
        pool.acquireBatch{value: total}(player, count, fee, 0, slip, version, block.timestamp + 1 hours);
        ++pulls;
        if (fulfillNow) _fulfillOutstanding(pick, false);
    }

    /// @dev Pays a one ticket pull with a Shape of 0.01, 0.1 or 1 ETH backing. A Shape that matches a
    ///      single rung row and fits the spendable cash stays in the pool as a held item.
    function pullWithShapes(uint8 amountSeed, uint8 playerSeed, uint256 pick, bool fulfillNow) external recorded {
        if (_exiting() || pool.pullsPaused()) return;
        _warpToResume();
        if (pool.listedCount() < clone.unsettledAcquisitionCount() + 1 + IPool(address(pool)).concurrency()) return;
        address player = _players[playerSeed % _players.length];
        uint256[3] memory amounts = [uint256(0.01 ether), 0.1 ether, 1 ether];
        uint256 amount = amounts[amountSeed % 3];
        uint256 tokenId = mintShapes(player, amount, 1);
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        vm.deal(player, player.balance + total);
        uint256 heldBefore = pool.heldCount();
        vm.startPrank(player);
        IERC721(SHAPES_ADDR).approve(address(pool), tokenId);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        pool.pullWithShapes{value: total}(tokenIds, 1, fee, block.timestamp + 1 hours);
        vm.stopPrank();
        ++pulls;
        if (pool.heldCount() > heldBefore) ++keptShapes;
        if (fulfillNow) _fulfillOutstanding(pick, false);
    }

    /// @dev Moves the factory's `inventoryChangeCooldown` between 0, where `settle` lists, and 300,
    ///      where only `rotate` lists.
    function setCooldown(bool zero) external recorded {
        vm.prank(factory.owner());
        factory.setInventoryChangeCooldown(zero ? 0 : 300);
    }

    /// @dev A wallet acquires at the FWA pool without going through `Pool.pull`.
    function directAcquire(uint8 playerSeed, uint256 pick, bool fulfillNow) external recorded {
        _direct(playerSeed, pick, fulfillNow);
    }

    /// @dev Sets the purchase gate as the admin: the FWA purchase operator becomes the pool (`on`) or zero.
    function _setGate(bool on) internal {
        vm.prank(pool.admin());
        IPool(address(pool)).setPurchaseGate(on);
        ++gateToggles;
    }

    /// @dev Clears the purchase gate when it is set, so a wallet can acquire at the FWA pool directly.
    function _gateOff() internal {
        if (clone.purchaseOperator() != address(0)) _setGate(false);
    }

    /// @dev Flips the purchase gate. Pool acquisitions work in both states.
    function toggleGate(bool on) external recorded {
        if (clone.retired()) return;
        _setGate(on);
    }

    function _direct(uint8 playerSeed, uint256 pick, bool fulfillNow) internal {
        if (clone.retired() || !clone.localPurchasesEnabled()) return;
        _gateOff();
        _warpToResume();
        if (clone.totalWeight() == 0 || clone.unsettledAcquisitionCount() >= 3) return;
        address player = _players[playerSeed % _players.length];
        acquireAs(player, player, clone, block.timestamp + 1 hours);
        ++directPurchases;
        if (fulfillNow) _fulfillOutstanding(pick, false);
    }

    function fulfillOutstanding(uint256 pick) external recorded {
        _fulfillOutstanding(pick, false);
    }

    /// @dev Direct acquisition with the Shapes contract as purchaser, fulfilled on a Shape listing.
    ///      Delivery reverts in the Shapes contract, which leaves the acquisition DeliveryPending.
    function griefShapes(uint256 pick) external recorded {
        if (clone.retired() || !clone.localPurchasesEnabled()) return;
        _gateOff();
        _warpToResume();
        if (clone.totalWeight() == 0 || clone.unsettledAcquisitionCount() >= 3) return;
        acquireAs(SHAPES_ADDR, SHAPES_ADDR, clone, block.timestamp + 1 hours);
        ++griefs;
        _fulfillOutstanding(pick, true);
    }

    /// @dev Rolls past the word deadline of every pending request and lets FWA expire them.
    function expireOutstanding() external recorded {
        if (clone.unsettledAcquisitionCount() == 0) return;
        vm.roll(block.number + clone.selectionTimeoutBlocks() + 2);
        clone.processAcquisitions(50);
    }

    /// @dev FWA processing without pool booking.
    function processOnly(uint8 n) external recorded {
        clone.processAcquisitions(bound(n, 1, 5));
    }

    // ------------------------------------------------------------------ settlement actions

    /// @dev Calls `settle` as this contract, which receives the refund. The ETH received must equal
    ///      the logged refund.
    function settle(uint8 n) external {
        _settle(bound(n, 1, 20));
    }

    /// @dev Books up to `n` acquisitions without the harvest of `settle`.
    function bookOnly(uint8 n) external recorded {
        pool.bookOnly(bound(n, 1, 20));
    }

    function settleAndHarvest() external recorded {
        pool.settle(20);
        _harvest();
    }

    function _settle(uint256 count) internal {
        vm.recordLogs();
        uint256 balanceBefore = address(this).balance;
        pool.settle(count);
        uint256 received = address(this).balance - balanceBefore;
        _ingest(vm.getRecordedLogs());
        if (received != _batchRefund) i6Broken = true;
    }

    function harvest() external recorded {
        _harvest();
    }

    function _harvest() internal {
        uint256 ownerProceedsBefore = clone.ownerProceeds();
        uint256 cashBefore = pool.cash();
        bool done = pool.harvest();
        if (done) {
            if (
                pool.receivable() != 0 || IPool(address(pool)).maintenanceReceivable() != 0 || pool.grailReceivable(0) != 0
                    || pool.grailReceivable(1) != 0 || clone.ownerProceeds() != 0 || pool.cash() < cashBefore
                    || ownerProceedsBefore == 0
            ) harvestBroken = true;
            ++harvests;
        } else if (pool.cash() != cashBefore) {
            harvestBroken = true;
        }
    }

    // ------------------------------------------------------------------ FWA helpers

    function _activeListings(bool shapesOnly) internal view returns (uint256[] memory ids) {
        uint256 next = clone.nextListingId();
        ids = new uint256[](next);
        uint256 n;
        for (uint256 id = 1; id < next; ++id) {
            (address collection,,,,,,, IFWAClone.ListingStatus status) = clone.listings(id);
            if (status == IFWAClone.ListingStatus.Active && (!shapesOnly || collection == SHAPES_ADDR)) {
                ids[n++] = id;
            }
        }
        assembly {
            mstore(ids, n)
        }
    }

    /// @dev The Active FWA listing of a GRAIL track, trying track `seed % 2` first. Zero when
    ///      neither track has an Active listing.
    function _activeGrailListing(uint256 seed) internal view returns (uint256) {
        for (uint256 i; i < 2; ++i) {
            (,,,,,,,,,,, uint256 listingId) = IPool(address(pool)).grail((seed + i) % 2);
            if (listingId == 0) continue;
            (,,,,,,, IFWAClone.ListingStatus status) = clone.listings(listingId);
            if (status == IFWAClone.ListingStatus.Active) return listingId;
        }
        return 0;
    }

    /// @dev Delivers a word for every Pending request in sequence order. Each word selects an
    ///      Active listing chosen from `pick`.
    function _fulfillOutstanding(uint256 pick, bool shapesOnly) internal {
        uint64 last = clone.lastIssuedSequence();
        for (uint64 seq = clone.nextSequenceToProcess(); seq <= last; ++seq) {
            uint256 requestId = clone.requestIdAtSequence(seq);
            (,,,, IFWAClone.AcquisitionStatus status) = clone.acquisitions(requestId);
            if (status != IFWAClone.AcquisitionStatus.Pending) continue;
            (, uint64 wordDeadlineBlock,,,,) = clone.acquisitionMeta(requestId);
            if (block.number > wordDeadlineBlock) {
                clone.processAcquisitions(50);
                continue;
            }
            uint256[] memory active = _activeListings(shapesOnly);
            uint256 chosen = active.length == 0 ? 0 : active[uint256(keccak256(abi.encode(pick, seq))) % active.length];
            if (!shapesOnly && pick % 4 == 0) {
                uint256 grailListing = _activeGrailListing(pick / 4);
                if (grailListing != 0) chosen = grailListing;
            }
            fulfill(clone, requestId, chosen == 0 ? 0 : wordFor(clone, chosen));
        }
    }
}

contract PoolFwaInvariantsTest is ForkBase, PoolFixture {
    PoolHarness internal pool;
    IFWAClone internal clone;
    PoolFwaHandler internal handler;

    function setUp() public {
        setUpFork();
        openFactory();
        deployDrawPacks(admin);
        vm.deal(alice, 10_000 ether);

        IPoolTypes.Params memory p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        // Row 0 is a 0.1 Shape (5,000 bps), row 1 a pack of two 0.01 Shapes (3,000), row 2 a 0.01 Shape
        // (2,000). Held 0.01 Shapes fill row 2 and the components of row 1.
        p.mix = new PricingLib.MixRow[](3);
        p.mix[0].rungs = new uint8[](1);
        p.mix[0].rungs[0] = 2;
        p.mix[0].shareBps = 5_000;
        p.mix[1].rungs = new uint8[](2);
        p.mix[1].shareBps = 3_000;
        p.mix[2].rungs = new uint8[](1);
        p.mix[2].shareBps = 2_000;
        pool = new PoolHarness(p);
        vm.prank(admin);
        IPool(address(pool)).createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);

        // 60 item board: 30 Shapes of 0.1, 18 packs and 12 Shapes of 0.01.
        vm.prank(alice);
        pool.deposit{value: 200 ether}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.sizeBoard(60);
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
        warpPastCooldown(clone);

        address[] memory actors = new address[](4);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }
        address[] memory players = new address[](3);
        for (uint256 i; i < players.length; ++i) {
            players[i] = makeAddr(string.concat("player", vm.toString(i)));
        }
        handler = new PoolFwaHandler(pool, clone, actors, players);

        bytes4[] memory selectors = new bytes4[](33);
        selectors[0] = PoolFwaHandler.deposit.selector;
        selectors[1] = PoolFwaHandler.withdraw.selector;
        selectors[2] = PoolFwaHandler.payClaims.selector;
        selectors[3] = PoolFwaHandler.warp.selector;
        selectors[4] = PoolFwaHandler.warpToResume.selector;
        selectors[5] = PoolFwaHandler.redeemAndDeposit.selector;
        selectors[6] = PoolFwaHandler.pull.selector;
        selectors[7] = PoolFwaHandler.directAcquire.selector;
        selectors[8] = PoolFwaHandler.fulfillOutstanding.selector;
        selectors[9] = PoolFwaHandler.expireOutstanding.selector;
        selectors[10] = PoolFwaHandler.processOnly.selector;
        selectors[11] = PoolFwaHandler.settle.selector;
        selectors[12] = PoolFwaHandler.harvest.selector;
        selectors[13] = PoolFwaHandler.pullWithShapes.selector;
        selectors[14] = PoolFwaHandler.settleAndHarvest.selector;
        selectors[15] = PoolFwaHandler.griefShapes.selector;
        selectors[16] = PoolFwaHandler.withdrawAfterProcess.selector;
        selectors[17] = PoolFwaHandler.directThenDeposit.selector;
        selectors[18] = PoolFwaHandler.rotateIfDue.selector;
        selectors[19] = PoolFwaHandler.loseCash.selector;
        selectors[20] = PoolFwaHandler.exitIntoQueue.selector;
        selectors[21] = PoolFwaHandler.rotateIfDue.selector;
        // The exit actions are listed several times so a campaign usually reaches Exported.
        selectors[22] = PoolFwaHandler.startExitRetire.selector;
        selectors[23] = PoolFwaHandler.startExitRetire.selector;
        selectors[24] = PoolFwaHandler.exportStep.selector;
        selectors[25] = PoolFwaHandler.exportStep.selector;
        selectors[26] = PoolFwaHandler.exportStep.selector;
        selectors[27] = PoolFwaHandler.exportStep.selector;
        selectors[28] = PoolFwaHandler.setPaused.selector;
        selectors[29] = PoolFwaHandler.setFeeSplit.selector;
        selectors[30] = PoolFwaHandler.toggleGate.selector;
        selectors[31] = PoolFwaHandler.setCooldown.selector;
        selectors[32] = PoolFwaHandler.bookOnly.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Walks the handler through each path once so the invariant campaign is known to reach
    ///      captures, direct purchases, harvest surplus, deferred fulfillment and expiry.
    function test_handlerReachesEveryPath() public {
        for (uint256 i; i < 16; ++i) {
            handler.warpToResume();
            if (i == 5) {
                handler.setPaused(true, true);
                uint256 pullsBefore = handler.pulls();
                handler.pull(1, 1, 1, true);
                handler.deposit(1 ether, 0);
                assertEq(handler.pulls(), pullsBefore, "pulls are closed while paused");
            }
            if (i == 6) handler.setPaused(false, false);
            if (i == 8) handler.setFeeSplit(300, 200, 100, 7_500);
            if (i == 9) handler.toggleGate(true);
            handler.pull(uint8(i), uint8(i), i, i % 3 != 0);
            handler.directAcquire(uint8(i), i, i % 2 == 0);
            handler.fulfillOutstanding(i);
            handler.bookOnly(5);
            handler.harvest();
            handler.settle(5);
            handler.settleAndHarvest();
            handler.pullWithShapes(uint8(i), uint8(i), i, i % 2 == 0);
            if (i == 2) handler.setCooldown(true);
            if (i == 12) handler.setCooldown(false);
            handler.warp(uint32(i * 1000));
            if (i % 4 == 3) handler.griefShapes(i);
            handler.deposit(uint96(i * 1e17), uint8(i));
            handler.withdraw(i * 1e18, uint8(i));
            handler.payClaims();
            handler.rotateIfDue();
            handler.redeemAndDeposit(uint8(i));
            handler.directThenDeposit(uint8(i), i, uint96(i * 1e17), uint8(i));
            handler.withdrawAfterProcess(uint8(i), i * 1e18, uint8(i));
        }
        _exitIntoLiquidation();
        handler.directAcquire(0, 1, false);
        handler.expireOutstanding();
        handler.settle(5);
        handler.griefShapes(7);
        handler.settle(5);
        assertGt(handler.pulls(), 0);
        assertGt(handler.directPurchases(), 0);
        assertGt(handler.captures(), 0);
        assertGt(handler.harvests(), 0);
        assertGt(handler.ghostSurplus(), 0);
        assertGt(handler.ghostMaintenanceShares(), 0);
        assertGt(handler.griefs(), 0);
        assertGt(handler.ghostWrittenOff(), 0);
        assertGt(handler.rotations(), 0);
        assertGt(handler.keptShapes(), 0);
        assertGt(handler.settleListed(), 0);
        assertGt(handler.liquidations(), 0);
        assertGt(handler.liquidatedItems(), 0);
        assertGt(handler.ghostLiquidationFees(), 0);
        assertGt(handler.ghostRefunds(), 0);
        assertGt(handler.grailGrowths(), 0);
        assertGt(handler.grailCaptures(), 0);
        assertEq(handler.paramChanges(), 3);
        assertGt(handler.gateToggles(), 0);
        invariant_I1_balanceCoversBuckets();
        invariant_I2_backingMatchesRegistry();
        invariant_queueMatchesRowCounters();
        invariant_settleRefundsOnlyAWorkingCall();
        invariant_I3_withdrawalNeverExceedsNavShare();
        invariant_I4_claimsPaidInRequestOrder();
        invariant_I6_maintenanceFallsOnlyByRotateRefunds();
        invariant_claimsConserved();
        invariant_I7_bucketsCreditedOnlyFromSplitsAndContributions();
        invariant_proceedsConserved();
        invariant_harvestConsistency();
        invariant_booksNeverBehindAfterPricing();
        invariant_sharesSumToTotal();
        invariant_marginConserved();
        invariant_I5_grailBucketsPayOnlyForTheirTracks();
        invariant_grailTracksMatchTheirPacks();
        _retire();
        invariant_I1_balanceCoversBuckets();
        invariant_I2_backingMatchesRegistry();
        invariant_queueMatchesRowCounters();
        invariant_settleRefundsOnlyAWorkingCall();
        invariant_I3_withdrawalNeverExceedsNavShare();
        invariant_I4_claimsPaidInRequestOrder();
        invariant_I6_maintenanceFallsOnlyByRotateRefunds();
        invariant_claimsConserved();
        invariant_I7_bucketsCreditedOnlyFromSplitsAndContributions();
        invariant_proceedsConserved();
        invariant_harvestConsistency();
        invariant_booksNeverBehindAfterPricing();
        invariant_sharesSumToTotal();
        invariant_marginConserved();
        invariant_I5_grailBucketsPayOnlyForTheirTracks();
        invariant_grailTracksMatchTheirPacks();
        invariant_exportedPoolHoldsNoOrdinaryItems();
        emit log_named_uint("grail growths", handler.grailGrowths());
        emit log_named_uint("grail captures", handler.grailCaptures());
        emit log_named_uint("written off", handler.ghostWrittenOff());
        emit log_named_uint("pulls", handler.pulls());
        emit log_named_uint("direct purchases", handler.directPurchases());
        emit log_named_uint("captures", handler.captures());
        emit log_named_uint("harvests", handler.harvests());
        emit log_named_uint("held items", pool.heldCount());
        emit log_named_uint("rotations", handler.rotations());
        emit log_named_uint("liquidated items", handler.liquidatedItems());
        emit log_named_uint("refunds", handler.ghostRefunds());
    }

    /// @dev Starts a retirement, exports in steps of up to 30 items, then lets holders withdraw
    ///      and pays the queued claims.
    function _retire() internal {
        handler.startExitRetire();
        assertEq(uint8(pool.lifecycle()), uint8(IPoolTypes.Lifecycle.Exiting));
        for (uint256 i; i < 12 && pool.lifecycle() == IPoolTypes.Lifecycle.Exiting; ++i) {
            handler.exportStep(uint8(i * 7), i);
        }
        assertEq(uint8(pool.lifecycle()), uint8(IPoolTypes.Lifecycle.Exported), "export finished");
        assertGt(handler.exportSteps(), 1, "more than one step");
        assertEq(pool.backing(), 0);
        assertEq(pool.maintenance(), 0);
        handler.withdraw(type(uint256).max, 0);
        handler.withdraw(type(uint256).max, 1);
        handler.warp(3 hours);
        handler.payClaims();
        handler.pull(1, 1, 1, true);
        handler.deposit(1 ether, 0);
        handler.rotateIfDue();
        assertEq(pool.listedCount() + pool.heldCount(), 0, "no restock after export");
    }

    /// @dev Removes the cash, lets a depositor buy most shares and leave, and runs `rotateIfDue` past
    ///      the claim age. The exit queues a claim that only listed items can cover.
    function _exitIntoLiquidation() internal {
        handler.loseCash(10_000);
        handler.deposit(type(uint96).max, 0);
        handler.loseCash(10_000);
        handler.withdraw(type(uint256).max, 0);
        handler.warp(3 hours);
        handler.rotateIfDue();
    }

    function afterInvariant() public {
        emit log_named_uint("last run: rotations", handler.rotations());
        emit log_named_uint("last run: liquidated items", handler.liquidatedItems());
        emit log_named_uint("last run: pulls", handler.pulls());
        emit log_named_uint("last run: direct purchases", handler.directPurchases());
        emit log_named_uint("last run: captures", handler.captures());
        emit log_named_uint("last run: grail growths", handler.grailGrowths());
        emit log_named_uint("last run: grail captures", handler.grailCaptures());
        emit log_named_uint("last run: harvests", handler.harvests());
        emit log_named_uint("last run: export steps", handler.exportSteps());
        emit log_named_uint("last run: param changes", handler.paramChanges());
        emit log_named_uint("last run: gate toggles", handler.gateToggles());
        emit log_named_uint("last run: lifecycle", uint256(pool.lifecycle()));
    }

    function _grailBuckets() internal view returns (uint256 total) {
        (uint256 minorBucket,,,,,,,,,,,) = IPool(address(pool)).grail(0);
        (uint256 majorBucket,,,,,,,,,,,) = IPool(address(pool)).grail(1);
        return minorBucket + majorBucket;
    }

    function _grailReceivables() internal view returns (uint256) {
        return pool.grailReceivable(0) + pool.grailReceivable(1);
    }

    function _bookedReceivables() internal view returns (uint256) {
        return pool.receivable() + IPool(address(pool)).maintenanceReceivable() + _grailReceivables();
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I1_balanceCoversBuckets() public view {
        assertGe(address(pool).balance, pool.cash() + pool.maintenance() + _grailBuckets());
    }

    /// @dev `backing` equals the value of every held item and every listed item. Every held Shape is
    ///      indexed once under the ladder index of its value, and the denomination index holds no
    ///      other token. `rowCount` is the listed plus held items of each row.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I2_backingMatchesRegistry() public view {
        uint256 sum;
        uint256 heldShapes_;
        uint256 rows = IPool(address(pool)).mixLength();
        uint256[] memory heldPerRow = new uint256[](rows);
        for (uint256 i; i < pool.heldCount(); ++i) {
            IPoolTypes.Item memory held = pool.heldItem(i);
            sum += held.value;
            ++heldPerRow[held.row];
            if (held.collection != SHAPES_ADDR) continue;
            ++heldShapes_;
            uint256[] memory ids = IPool(address(pool)).heldShapes(_denominationIndex(held.value));
            uint256 matches;
            for (uint256 j; j < ids.length; ++j) {
                if (ids[j] == held.tokenId) ++matches;
            }
            assertEq(matches, 1, "held Shape indexed once under its denomination");
        }
        uint256 byDenomination;
        for (uint256 d; d < shapes.denominationCount(); ++d) {
            byDenomination += IPool(address(pool)).heldShapes(uint8(d)).length;
        }
        assertEq(byDenomination, heldShapes_, "the denomination index holds only held Shapes");
        uint256 listed;
        uint256 next = clone.nextListingId();
        for (uint256 id = 1; id < next; ++id) {
            uint256 value = pool.listedItem(id).value;
            if (value != 0) ++listed;
            sum += value;
        }
        assertEq(pool.backing(), sum);
        assertEq(pool.listedCount(), listed);
        uint256 inRows;
        for (uint256 r; r < rows; ++r) {
            uint256[] memory ids = pool.listedIds(r);
            inRows += ids.length;
            for (uint256 i; i < ids.length; ++i) {
                IPoolTypes.Item memory it = pool.listedItem(ids[i]);
                assertTrue(it.value != 0 && it.row == r);
            }
            assertEq(IPool(address(pool)).rowCount(r), ids.length + heldPerRow[r], "rowCount");
        }
        assertEq(inRows, listed);
    }

    function _denominationIndex(uint256 value) internal view returns (uint8) {
        for (uint256 d; d < shapes.denominationCount(); ++d) {
            if (shapes.denominationAt(uint8(d)) == value) return uint8(d);
        }
        revert("held Shape off the ladder");
    }

    /// @dev The queued rows add up to the queue length, and `oldestQueuedAt` is zero exactly while the
    ///      queue is empty.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_queueMatchesRowCounters() public view {
        uint256 queued;
        for (uint256 r; r < IPool(address(pool)).mixLength(); ++r) {
            queued += pool.queuedOf(r);
        }
        assertEq(queued, pool.replacementLength());
        assertEq(IPool(address(pool)).oldestQueuedAt() == 0, pool.replacementLength() == 0);
    }

    /// @dev `settle` pays a refund only for a call that listed an item or repriced a GRAIL track.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_settleRefundsOnlyAWorkingCall() public view {
        assertFalse(handler.settleBroken());
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I3_withdrawalNeverExceedsNavShare() public view {
        assertFalse(handler.base().i3Broken());
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I4_claimsPaidInRequestOrder() public view {
        assertFalse(handler.base().i4Broken());
        assertFalse(handler.i4Broken());
        assertEq(handler.paidIndex(), pool.claimHead());
        assertEq(pool.claims(), handler.outstandingClaims());
    }

    /// @dev Queued claims are either paid, deducted as liquidation fees, or still in `claims`.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_claimsConserved() public view {
        assertEq(
            pool.claims() + handler.ghostClaimsPaid() + handler.ghostLiquidationFees(), handler.ghostClaimsQueued()
        );
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I6_maintenanceFallsOnlyByRotateRefunds() public view {
        assertFalse(handler.i6Broken());
    }

    /// @dev Maintenance is credited only from margin splits and debited only by `rotate` refunds.
    ///      The GRAIL buckets are credited from deposit contributions, margin splits and captured
    ///      GRAIL proceeds, and debited only by growth steps (I5, below).
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I7_bucketsCreditedOnlyFromSplitsAndContributions() public view {
        assertEq(
            pool.maintenance() + IPool(address(pool)).maintenanceReceivable() + handler.ghostRefunds()
                + handler.ghostMaintenanceFolded(),
            handler.ghostMaintenanceShares()
        );
    }

    /// @dev I5: per track, bucket plus receivable equals the credits (entry contributions, feed
    ///      shares and captured proceeds) less the cost of every growth step. Growth is the only
    ///      debit, so a track's bucket pays only for its own mints and pack additions.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_I5_grailBucketsPayOnlyForTheirTracks() public view {
        for (uint256 t; t < 2; ++t) {
            (uint256 bucket,,,,,,,,,, uint256 receivable_,) = IPool(address(pool)).grail(t);
            assertEq(
                bucket + receivable_ + handler.ghostGrailSpend(t),
                handler.ghostGrailIn(t) + handler.ghostGrailProceeds(t),
                "I5"
            );
        }
    }

    /// @dev A track with a pack holds exactly the pack's value as backing, a listed track has a
    ///      pack, a track without a pack has no backing, listing or price, and the track's FWA
    ///      listing is not in the ordinary registry (the ordinary I2 does not count it).
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_grailTracksMatchTheirPacks() public view {
        for (uint256 t; t < 2; ++t) {
            (, uint256 packId, uint256 backing_, uint256 notional,,,,,,,, uint256 listingId) = IPool(address(pool)).grail(t);
            if (packId == 0) {
                assertEq(backing_, 0);
                assertEq(notional, 0);
                assertEq(listingId, 0);
            } else {
                assertEq(drawPacks.valueOf(packId), backing_);
                assertGt(backing_, 0);
            }
            if (listingId != 0) {
                assertTrue(packId != 0);
                assertEq(pool.listedItem(listingId).value, 0);
            }
        }
    }

    /// @dev Booked proceeds, ordinary and GRAIL, are either still a receivable or already received
    ///      at harvest. Surplus is the part of the received amount above the booked captures.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_proceedsConserved() public view {
        assertEq(
            handler.ghostCapturedProceeds() + handler.ghostSurplus() + handler.ghostGrailProceeds(0)
                + handler.ghostGrailProceeds(1),
            _bookedReceivables() + handler.ghostHarvestReceived()
        );
    }

    /// @dev Margin is the net of every captured proceeds, harvest surplus, captured value and
    ///      written-off value, less what splits have released. A write-off books no proceeds, so the
    ///      ETH-side equation above is unchanged and written-off value enters on the loss side only.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_marginConserved() public view {
        assertEq(
            IPool(address(pool)).margin(),
            int256(handler.ghostCapturedProceeds() + handler.ghostSurplus())
                - int256(handler.ghostCapturedValue() + handler.ghostWrittenOff() + handler.ghostMarginSplit())
        );
    }

    /// @dev FWA always pays at least the booked receivables, so no harvest writes a receivable down.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_harvestNeverFallsShort() public view {
        assertEq(handler.harvestShortfalls(), 0);
    }

    /// @dev Booked receivables are held at FWA as owner proceeds. A successful harvest leaves all four
    ///      receivables at zero.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_harvestConsistency() public view {
        assertFalse(handler.harvestBroken());
        assertLe(_bookedReceivables(), clone.ownerProceeds());
        assertLe(pool.nextSequenceToBook(), clone.nextSequenceToProcess());
    }

    /// @dev After a deposit, withdraw, rotate or redeemAndDeposit the booking walk equals FWA's
    ///      processing queue and every receivable has been harvested.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_booksNeverBehindAfterPricing() public view {
        assertFalse(handler.booksBehindAfterPricing());
    }

    /// @dev `rotate` reverts whenever `rotateDue` is `None` and changes inventory whenever it is
    ///      GrailStep.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_rotateRevertsWhileNotDue() public view {
        assertFalse(handler.rotateGateBroken());
        assertFalse(handler.rotateStalled());
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_sharesSumToTotal() public view {
        uint256 sum;
        PoolHandler base = handler.base();
        for (uint256 i; i < base.actorCount(); ++i) {
            sum += pool.sharesOf(base.actors(i));
        }
        assertEq(sum + pool.sharesOf(alice), pool.totalShares());
    }

    /// @dev An exported pool holds no ordinary items and its FWA pool is retired.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 40
    function invariant_exportedPoolHoldsNoOrdinaryItems() public view {
        if (pool.lifecycle() != IPoolTypes.Lifecycle.Exported) return;
        assertEq(pool.backing(), 0);
        assertEq(pool.listedCount(), 0);
        assertEq(pool.heldCount(), 0);
        assertTrue(clone.retired());
        assertGt(IPool(address(pool)).exportedShares(), 0);
    }
}
