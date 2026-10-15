// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IShapes} from "shapes/interfaces/IShapes.sol";
import {Denominations} from "shapes/lib/Denominations.sol";
import {Pool} from "./Pool.sol";
import {PricingLib} from "./lib/PricingLib.sol";
import {IFWAClone} from "./interfaces/IFWAClone.sol";
import {IPool, IPoolTypes} from "./interfaces/IPool.sol";

/// @title Lens
/// @notice Read-only views over one `Pool`. Every value comes from the pool's public getters and
///         from the FWA pool the pool created. A new `Lens` can replace this one without a pool
///         change.
contract Lens {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    /// @dev First failing pull guard, in the order `Pool.acquireBatch` applies them.
    enum Reason {
        None,
        NotLive,
        Exiting,
        PullsPaused,
        InvalidCount,
        CoolingDown,
        Insolvent,
        BoardTooThin
    }

    struct Quote {
        uint256 fee;
        uint256 vrf;
        uint256 total;
        bool purchasable;
        Reason reason;
    }

    struct Position {
        uint256 shares;
        uint256 valueWei;
        bool migrated;
    }

    struct Row {
        uint8[] rungs;
        uint16 shareBps;
        uint256 backingWei;
        uint256 listingPrice;
        uint256 count;
        uint256 listed;
        uint256 target;
    }

    /// @dev A GRAIL item with its share of the FWA selection weight in bps, zero while it is unlisted.
    struct GrailItemView {
        address collection;
        bool done;
        uint256 tokenId;
        uint256 backing;
        uint256 notional;
        uint256 listingId;
        uint256 listedAtPull;
        uint256 weightBps;
    }

    struct GrailView {
        uint256 fund;
        uint256 receivable;
        uint256 targetWei;
        uint256 nextTargetWei;
        uint256 cycleId;
        uint256 listBps;
        uint256 decayWeiPerPull;
        uint256 pieceFloorWei;
        uint256 floorWei;
        uint256 pulls;
        uint256 cycleStartedAt;
        uint256 stepUpSeconds;
        uint256 stepDownSeconds;
        GrailItemView[] items;
    }

    struct QueuedClaim {
        address to;
        uint256 amount;
        uint256 requestedAt;
    }

    struct Claims {
        QueuedClaim[] queue;
        uint256 head;
        uint256 unpaidTotal;
        uint256 claimsBucket;
        uint256 cash;
    }

    /// @dev Each reopen guard with the numbers it compares.
    struct Reopen {
        bool live;
        bool pullsOpen;
        bool cooldownPassed;
        uint256 purchasesResumeAt;
        bool solvent;
        uint256 balance;
        uint256 required;
        bool boardDeep;
        uint256 listedCount;
        uint256 unsettled;
        uint256 concurrency;
    }

    /// @dev Deposit admission state. `contributionBps` is the entry fee a deposit pays now.
    ///      `open` holds when the pool is Opening, or Live with `depositsOpenAt` passed, deposits
    ///      are not paused and ordinary NAV is below `navCap`.
    struct Admission {
        uint256 navCap;
        uint256 navCapFloor;
        uint256 dailyVolume;
        uint256 headroom;
        uint256 depositsOpenAt;
        uint256 contributionBps;
        bool open;
    }

    struct Parameters {
        address shapes;
        address drawPacks;
        address fwaFactory;
        address fwaPool;
        address admin;
        address oldPool;
        address exitDest;
        IPoolTypes.Lifecycle lifecycle;
        bool pullsPaused;
        bool depositsPaused;
        IPoolTypes.FeeSplit feeSplit;
        uint256 floorBps;
        uint256 capBps;
        uint256 paybackDays;
        uint256 navCapFloor;
        uint256 turnoverBps;
        uint256 founderWindowSeconds;
        uint256 rotateInterval;
        uint256 openingDeadline;
        uint256 openingDeadlineAt;
        uint256 minItems;
        uint256 boardItems;
        uint256 grailProbCapBps;
        uint256 batchMin;
        uint256 batchMaxAge;
        uint256 surpriseBps;
        uint256 restoreK;
        uint256 bandBps;
        uint256 reserveBps;
        uint256 tipWei;
        bool listWhilePaused;
        uint256 maxBatch;
        uint256 concurrency;
        uint256 lastRotateAt;
        uint256 lastRefundAt;
    }

    Pool public immutable pool;

    constructor(Pool pool_) {
        pool = pool_;
    }

    /// @dev The pool through its full ABI, which includes the functions `PoolAdmin` serves through
    ///      the `fallback` of `Pool`.
    function _ip() internal view returns (IPool) {
        return IPool(address(pool));
    }

    // ------------------------------------------------------------------ quote

    /// @notice FWA price of `count` acquisitions and whether `Pool.acquireBatch` would accept them now.
    ///         `reason` names the first failing guard. The price is zero before the FWA pool exists.
    function quote(uint256 count) external view returns (Quote memory q) {
        IFWAClone fwa = pool.fwaPool();
        if (address(fwa) != address(0)) {
            try fwa.quoteAcquisitionPrice(count) returns (uint256 fee, uint256 vrf, uint256 total) {
                (q.fee, q.vrf, q.total) = (fee, vrf, total);
            } catch {}
        }
        q.reason = _reason(count);
        q.purchasable = q.reason == Reason.None;
    }

    function _reason(uint256 count) internal view returns (Reason) {
        IPoolTypes.Lifecycle state = pool.lifecycle();
        if (state >= IPoolTypes.Lifecycle.Exiting) return Reason.Exiting;
        if (state != IPoolTypes.Lifecycle.Live) return Reason.NotLive;
        if (pool.pullsPaused()) return Reason.PullsPaused;
        if (count == 0 || count > _ip().maxBatch()) return Reason.InvalidCount;
        Reopen memory r = _reopen();
        if (!r.cooldownPassed) return Reason.CoolingDown;
        if (!r.solvent) return Reason.Insolvent;
        if (!r.boardDeep) return Reason.BoardTooThin;
        return Reason.None;
    }

    // ------------------------------------------------------------------ shares

    /// @notice Ordinary NAV in wei.
    function nav() external view returns (uint256) {
        return pool.nav();
    }

    /// @notice NAV of one share scaled by 1e18. Equal to 1e18 while no shares exist.
    function sharePrice() public view returns (uint256) {
        uint256 supply = pool.totalShares();
        return supply == 0 ? WAD : pool.nav() * WAD / supply;
    }

    /// @notice Shares of `account`, their value at NAV and whether the account was converted by
    ///         `migrateHolder`.
    function position(address account) external view returns (Position memory p) {
        p.shares = pool.sharesOf(account);
        uint256 supply = pool.totalShares();
        p.valueWei = supply == 0 ? 0 : p.shares * pool.nav() / supply;
        p.migrated = _ip().migrated(account);
    }

    // ------------------------------------------------------------------ board

    /// @notice One entry per mix row: rungs, share, backing, live list price, item counts and the
    ///         target depth of `Pool.settle` and `Pool.open`.
    function board() external view returns (Row[] memory rows) {
        uint256 n = _ip().mixLength();
        rows = new Row[](n);
        (uint16 premium, uint16 maintenance, uint16 feed) = pool.feeSplit();
        uint256 fee = IShapes(pool.shapes()).mintFee();
        uint256 items = _ip().boardItems();
        for (uint256 i; i < n; ++i) {
            Row memory r = rows[i];
            (r.rungs, r.shareBps) = _ip().mixRow(i);
            for (uint256 j; j < r.rungs.length; ++j) {
                r.backingWei += Denominations.amountAt(r.rungs[j]);
            }
            r.listingPrice = PricingLib.listingPrice(
                r.backingWei, premium, maintenance, feed, PricingLib.mintLineBps(fee * r.rungs.length, r.backingWei)
            );
            r.count = _ip().rowCount(i);
            r.listed = _ip().listedRowCount(i);
            r.target = PricingLib.rowDepth(items, r.shareBps);
        }
    }

    // ------------------------------------------------------------------ GRAIL

    /// @notice The GRAIL fund, parameters and cycle, and every GRAIL item with its share of the FWA
    ///         selection weight. The share is zero while the item is unlisted.
    function grail() external view returns (GrailView memory g) {
        IPoolTypes.Grail memory s = _ip().grail();
        (g.fund, g.receivable, g.targetWei, g.nextTargetWei, g.cycleId) =
            (s.fund, s.receivable, s.targetWei, s.nextTargetWei, s.cycleId);
        (g.listBps, g.decayWeiPerPull, g.pieceFloorWei, g.floorWei) =
            (s.listBps, s.decayWeiPerPull, s.pieceFloorWei, s.floorWei);
        (g.pulls, g.cycleStartedAt, g.stepUpSeconds, g.stepDownSeconds) =
            (s.pulls, s.cycleStartedAt, s.stepUpSeconds, s.stepDownSeconds);
        IPoolTypes.GrailItem[] memory items = _ip().grailItems();
        g.items = new GrailItemView[](items.length);
        uint256 total = address(pool.fwaPool()) == address(0) ? 0 : pool.fwaPool().totalWeight();
        for (uint256 i; i < items.length; ++i) {
            IPoolTypes.GrailItem memory it = items[i];
            uint256 weightBps = it.listingId != 0 && total != 0 ? PricingLib.weightOf(it.notional) * BPS / total : 0;
            g.items[i] = GrailItemView(
                it.collection, it.done, it.tokenId, it.backing, it.notional, it.listingId, it.listedAtPull, weightBps
            );
        }
    }

    // ------------------------------------------------------------------ claims

    /// @notice Unpaid withdrawal claims in payment order, from `claimHead` to the end of the queue.
    function claims() external view returns (Claims memory c) {
        c.head = pool.claimHead();
        c.claimsBucket = pool.claims();
        c.cash = pool.cash();
        QueuedClaim[] memory buffer = new QueuedClaim[](_queueLength() - c.head);
        for (uint256 i; i < buffer.length; ++i) {
            (address to, uint64 requestedAt, uint256 amount) = _ip().claimQueue(c.head + i);
            buffer[i] = QueuedClaim(to, amount, requestedAt);
            c.unpaidTotal += amount;
        }
        c.queue = buffer;
    }

    /// @dev Length of `claimQueue`, found by doubling and bisection because the pool exposes no
    ///      length getter. An out of range read reverts.
    function _queueLength() internal view returns (uint256) {
        uint256 head = pool.claimHead();
        if (!_has(head)) return head;
        uint256 lo = head;
        uint256 step = 1;
        while (_has(lo + step)) {
            lo += step;
            step *= 2;
        }
        uint256 hi = lo + step;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_has(mid)) lo = mid;
            else hi = mid;
        }
        return lo + 1;
    }

    function _has(uint256 index) internal view returns (bool) {
        try _ip().claimQueue(index) returns (address, uint64, uint256) {
            return true;
        } catch {
            return false;
        }
    }

    // ------------------------------------------------------------------ reopen guards

    /// @notice Each guard `Pool.acquireBatch` applies, with the values it compares.
    function reopenStatus() external view returns (Reopen memory) {
        return _reopen();
    }

    function _reopen() internal view returns (Reopen memory r) {
        r.live = pool.lifecycle() == IPoolTypes.Lifecycle.Live;
        r.pullsOpen = !pool.pullsPaused();
        r.listedCount = pool.listedCount();
        r.concurrency = _ip().concurrency();
        r.balance = address(pool).balance;
        r.required = pool.cash() + pool.maintenance();
        IFWAClone fwa = pool.fwaPool();
        r.required += _ip().grail().fund;
        r.solvent = r.balance >= r.required;
        if (address(fwa) == address(0)) return r;
        r.purchasesResumeAt = fwa.purchasesResumeAt();
        r.cooldownPassed = block.timestamp >= r.purchasesResumeAt;
        r.unsettled = fwa.unsettledAcquisitionCount();
        r.boardDeep = r.listedCount >= r.unsettled + r.concurrency;
    }

    // ------------------------------------------------------------------ admission

    /// @notice The deposit cap, the volume it follows, the room left under it and the entry fee a
    ///         deposit pays now.
    function admission() external view returns (Admission memory a) {
        uint256 currentNav = pool.nav();
        a.navCap = pool.navCap();
        a.navCapFloor = pool.navCapFloor();
        a.dailyVolume = pool.dailyVolume();
        a.headroom = a.navCap > currentNav ? a.navCap - currentNav : 0;
        a.depositsOpenAt = pool.depositsOpenAt();
        (uint32 floorBps, uint32 capBps, uint32 paybackDays) = pool.entryFee();
        (uint16 premiumBps,,) = pool.feeSplit();
        a.contributionBps = PricingLib.entryFeeBps(premiumBps, a.dailyVolume, currentNav, floorBps, capBps, paybackDays);
        IPoolTypes.Lifecycle state = pool.lifecycle();
        a.open = (state == IPoolTypes.Lifecycle.Opening
                || (state == IPoolTypes.Lifecycle.Live && block.timestamp >= a.depositsOpenAt))
            && !pool.depositsPaused() && a.headroom != 0;
    }

    // ------------------------------------------------------------------ rotation

    /// @notice First reason `Pool.rotate` is due, or `None`. `None` includes the case where
    ///         `rotateInterval` has not passed since `lastRotateAt`.
    function rotateDue() external view returns (IPoolTypes.RotateTrigger) {
        return pool.rotateDue();
    }

    /// @notice First reason `Pool.settle` lists replacements, or `None`.
    function settleDue() external view returns (IPoolTypes.SettleTrigger) {
        return pool.settleDue();
    }

    // ------------------------------------------------------------------ parameters

    /// @notice Constructor parameters and admin-set values of the pool, with its runtime state.
    function parameters() external view returns (Parameters memory p) {
        p.shapes = pool.shapes();
        p.drawPacks = pool.drawPacks();
        p.fwaFactory = pool.fwaFactory();
        p.fwaPool = address(pool.fwaPool());
        p.admin = pool.admin();
        p.oldPool = pool.oldPool();
        p.exitDest = pool.exitDest();
        p.lifecycle = pool.lifecycle();
        p.pullsPaused = pool.pullsPaused();
        p.depositsPaused = pool.depositsPaused();
        (p.feeSplit.premiumBps, p.feeSplit.maintenanceBps, p.feeSplit.feedBps) = pool.feeSplit();
        (uint32 floorBps, uint32 capBps, uint32 paybackDays) = pool.entryFee();
        p.floorBps = floorBps;
        p.capBps = capBps;
        p.paybackDays = paybackDays;
        p.navCapFloor = pool.navCapFloor();
        p.turnoverBps = pool.turnoverBps();
        p.founderWindowSeconds = pool.founderWindowSeconds();
        p.rotateInterval = pool.rotateInterval();
        p.openingDeadline = _ip().openingDeadline();
        p.openingDeadlineAt = _ip().openingDeadlineAt();
        p.minItems = pool.minItems();
        p.boardItems = _ip().boardItems();
        p.grailProbCapBps = _ip().grailProbCapBps();
        p.batchMin = _ip().batchMin();
        p.batchMaxAge = _ip().batchMaxAge();
        p.surpriseBps = _ip().surpriseBps();
        p.restoreK = _ip().restoreK();
        p.bandBps = _ip().bandBps();
        p.reserveBps = _ip().reserveBps();
        p.tipWei = _ip().tipWei();
        p.listWhilePaused = _ip().listWhilePaused();
        p.maxBatch = _ip().maxBatch();
        p.concurrency = _ip().concurrency();
        p.lastRotateAt = pool.lastRotateAt();
        p.lastRefundAt = _ip().lastRefundAt();
    }
}
