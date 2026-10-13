// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, console2} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAdmin} from "../../src/PoolAdmin.sol";
import {PoolListing} from "../../src/PoolListing.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";
import {ForkBase} from "../fork/ForkBase.sol";

/// @notice Plays the pool against the pinned mainnet fork for `PLAY_DAYS` days of simulated traffic and
///         writes `pulls.csv`, `hourly.csv`, `claims.csv` and `run.txt` under `evidence/play/<test>/`.
///         `script/report.py` reads that directory.
/// @dev Launch values come from `PLAY_ENV_FILE` (default `script/env/anvil.env`) and are parsed by the
///      same `Deploy._params` the deploy script uses. Any key `K` of that file is overridden by the
///      environment variable `PLAY_K`. Run settings: `PLAY_DAYS`, `PLAY_SEED`, `PLAY_PULLS_PER_DAY`,
///      `PLAY_OPENING_ETH`, `PLAY_DEPOSIT_ETH_PER_DAY`, `PLAY_WITHDRAW_SHARE_BPS_PER_DAY`,
///      `PLAY_VRF_LATENCY_SECONDS`. The run is deterministic for a given seed and fork block.
///      Timeline: baseline row `hour` 0 after the pool is Live, then `hour` h covers the h-th hour.
///      The factory's `inventoryChangeCooldown` is set to `PLAY_COOLDOWN` seconds (default 0) after the
///      factory opens. Keeper ticks run every 300 s: each tick calls `settle` when `settleDue` is
///      nonzero and `rotate` when `rotateDue` is nonzero. A purchase made while FWA's purchase pause
///      is active waits for `purchasesResumeAt`. Requests are fulfilled in sequence order once the FWA outstanding cap is
///      reached or a keeper tick, deposit or withdrawal needs settled books.
contract PlayMonthTest is ForkBase, Deploy {
    uint256 internal constant TICK_SECONDS = 300;
    uint256 internal constant PLAYERS = 20;
    uint256 internal constant HOUR = 3600;
    string internal constant ROOT = "evidence/play/";

    struct Pending {
        uint256 id;
        uint256 player;
        uint256 paid;
        uint256 hour;
    }

    struct OpenClaim {
        address to;
        uint256 hour;
        uint256 at;
        uint256 shares;
        uint256 paidNow;
        uint256 enqueued;
        uint256 queueIndex;
        bool closed;
    }

    // ------------------------------------------------------------------ run state

    IPool internal pool;
    IFWAClone internal fwa;
    address internal poolAdmin;
    address internal keeper = makeAddr("keeper");
    string internal dir;
    string internal runInfo;
    uint256 internal seed;
    uint256 internal rctr;
    uint256 internal t0;
    uint256 internal curHour;
    uint256 internal outstandingCap;
    uint256 internal vrfLatency;
    uint256 internal playerCtr;
    uint256 internal carry;
    /// @dev Factory cooldown in seconds when `PLAY_COOLDOWN` is unset.
    uint256 internal cooldownDefault;
    address[] internal depositors;
    bool[] internal rowIsPack;

    Pending[] internal pending;
    mapping(uint256 => Pending) internal info;
    mapping(uint256 => bool) internal logged;
    OpenClaim[] internal openClaims;
    uint256[] internal pauseSec;
    uint256[2] internal grailBacking;
    uint256 internal queued;

    // per-hour accumulators
    uint256[3] internal rotTrig;
    uint256[3] internal setTrig;
    uint256 internal settleListedHour;
    uint256 internal settleRefundHour;
    uint256 internal rotates;
    uint256 internal settles;
    uint256 internal inventoryChanged;
    uint256 internal pullsHour;
    uint256 internal rejectedHour;
    uint256 internal waitHour;
    uint256 internal overrunPulls;

    // run totals
    uint256 internal totalPulls;
    uint256 internal totalRejected;
    uint256 internal rotateFailures;
    uint256 internal settleFailures;
    uint256 internal totalSettleListed;
    uint256 internal totalSettleRefund;
    uint256 internal totalRotateRefund;
    uint256 internal depositFailures;
    uint256 internal withdrawFailures;
    bytes4[] internal rejectSel;
    uint256[] internal rejectCount;

    // ------------------------------------------------------------------ tests

    function test_play100PerDay() public {
        _play("test_play100PerDay", 100);
    }

    function test_play500PerDay() public {
        _play("test_play500PerDay", 500);
    }

    function test_play2000PerDay() public {
        _play("test_play2000PerDay", 2000);
    }

    /// @dev A purchase pause or VRF wait carries a pull past the end of its hour. Seed 1 at 10,000 pulls
    ///      per day with a 300 s factory cooldown does so within hour 1. Clock reads in the runner must
    ///      follow `vm.warp` there. A stale `block.timestamp` read reverts the `acquireBatch` deadline
    ///      sum with panic 0x11.
    function test_playPullPastHourEnd() public {
        cooldownDefault = 300;
        _run("test_playPullPastHourEnd", 10_000, 1, 2, 1);
        assertGt(overrunPulls, 0);
    }

    /// @dev Runs only when `PLAY_PULLS_PER_DAY` is set.
    function test_playCustom() public {
        if (!vm.envExists("PLAY_PULLS_PER_DAY")) {
            vm.skip(true);
            return;
        }
        _play("test_playCustom", vm.envUint("PLAY_PULLS_PER_DAY"));
    }

    // ------------------------------------------------------------------ run

    function _play(string memory name, uint256 perDay) internal {
        uint256 days_ = vm.envOr("PLAY_DAYS", uint256(7));
        _run(name, perDay, days_, days_ * 24, vm.envOr("PLAY_SEED", uint256(1)));
    }

    function _run(string memory name, uint256 perDay, uint256 days_, uint256 total, uint256 seed_) internal {
        vm.pauseGasMetering();
        seed = seed_;
        vrfLatency = vm.envOr("PLAY_VRF_LATENCY_SECONDS", uint256(24));
        dir = string.concat(ROOT, name, "/");
        vm.createDir(dir, true);
        runInfo = string.concat("pullsPerDay=", vm.toString(perDay), "\ndays=", vm.toString(days_));
        runInfo = string.concat(runInfo, "\nseed=", vm.toString(seed));
        runInfo = string.concat(runInfo, "\nforkBlock=", vm.toString(vm.envOr("FORK_BLOCK", FORK_BLOCK)));

        setUpFork();
        openFactory();
        vm.prank(factory.owner());
        factory.setInventoryChangeCooldown(uint32(vm.envOr("PLAY_COOLDOWN", cooldownDefault)));
        runInfo = string.concat(runInfo, "\ncooldown=", vm.toString(uint256(factory.inventoryChangeCooldown())));
        _initFiles();
        _deployPool();
        _openBoard();
        _baseline();

        pauseSec = new uint256[](total + 2);
        for (uint256 h = 1; h <= total; ++h) {
            this.playHour(h, perDay);
        }
        _flush();
        _closeClaims();
        _summary(name, total);
    }

    function _deployPool() internal {
        poolAdmin = _loadEnv();
        deployDrawPacks(poolAdmin);
        IPoolTypes.Params memory p = _params();
        p.drawPacks = address(drawPacks);
        PoolAdmin module = new PoolAdmin();
        pool = IPool(address(new Pool(p, address(module), address(new PoolListing()))));

        rowIsPack = new bool[](p.mix.length);
        for (uint256 i; i < p.mix.length; ++i) {
            rowIsPack[i] = p.mix[i].rungs.length > 1;
        }
        outstandingCap = factory.maxOutstandingRequestsPerPool();
    }

    /// @dev Opening cohort, FWA pool creation, opening deadline, `open()` until Live.
    function _openBoard() internal {
        uint256 openingEth = _ether(vm.envOr("PLAY_OPENING_ETH", string("50")));
        for (uint256 i; i < 5; ++i) {
            address d = _depositor();
            vm.deal(d, openingEth / 5);
            vm.prank(d);
            pool.deposit{value: openingEth / 5}();
        }
        vm.prank(poolAdmin);
        IPool(address(pool)).createFwaPool(0);
        fwa = pool.fwaPool();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        vm.recordLogs();
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
        _drain();
        warpPastCooldown(fwa);
        t0 = _now();
    }

    function _depositor() internal returns (address d) {
        d = address(uint160(uint256(keccak256(abi.encode("depositor", depositors.length)))));
        depositors.push(d);
    }

    function _player(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("player", i)))));
    }

    // ------------------------------------------------------------------ hour loop

    /// @dev One simulated hour. Runs as an external self-call so the EVM frees its memory when the hour
    ///      ends. Solidity never frees memory inside a frame, and the recorded logs of a long run exceed
    ///      the EVM memory limit otherwise.
    function playHour(uint256 h, uint256 perDay) external {
        require(msg.sender == address(this), "PlayMonth: internal");
        _warpTo(t0 + (h - 1) * HOUR);
        curHour = h;
        _scheduled(h);

        uint256 acc = carry + perDay * (5_000 + _rnd() % 10_001) / 24;
        uint256 n = acc / 10_000;
        carry = acc % 10_000;

        (uint256[] memory times, uint256[] memory sizes) = _chunks(n);
        uint256 start = t0 + (h - 1) * HOUR;
        uint256 k;
        for (uint256 i; i < times.length; ++i) {
            while (k < HOUR / TICK_SECONDS && k * TICK_SECONDS <= times[i]) {
                _warpTo(start + k * TICK_SECONDS);
                _tick();
                ++k;
            }
            _warpTo(start + times[i]);
            _pull(sizes[i]);
        }
        while (k < HOUR / TICK_SECONDS) {
            _warpTo(start + k * TICK_SECONDS);
            _tick();
            ++k;
        }
        _warpTo(start + HOUR);
        _flush();
        _hourRow(h);
    }

    /// @dev Splits `n` pulls into batches of 1 to 5 at random seconds of the hour, sorted by time.
    function _chunks(uint256 n) internal returns (uint256[] memory times, uint256[] memory sizes) {
        uint256 m;
        uint256[] memory tmp = new uint256[](n);
        uint256 left = n;
        while (left != 0) {
            uint256 c = 1 + _rnd() % 5;
            if (c > left) c = left;
            tmp[m++] = c;
            left -= c;
        }
        times = new uint256[](m);
        sizes = new uint256[](m);
        for (uint256 i; i < m; ++i) {
            uint256 t = _rnd() % HOUR;
            uint256 j = i;
            while (j != 0 && times[j - 1] > t) {
                times[j] = times[j - 1];
                sizes[j] = sizes[j - 1];
                --j;
            }
            times[j] = t;
            sizes[j] = tmp[i];
        }
    }

    /// @dev Current timestamp read through the cheatcode. The optimizer reuses an earlier
    ///      `block.timestamp` read within a function after `vm.warp`, so every clock read in the runner
    ///      goes through this helper.
    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _warpTo(uint256 ts) internal {
        if (ts > _now()) vm.warp(ts);
    }

    /// @dev One deposit and one withdrawal per schedule, at a seeded hour of the day.
    function _scheduled(uint256 h) internal {
        uint256 day = (h - 1) / 24;
        uint256 hod = (h - 1) % 24;
        if (hod == uint256(keccak256(abi.encode(seed, "deposit", day))) % 24) {
            uint256 amount = _ether(vm.envOr("PLAY_DEPOSIT_ETH_PER_DAY", string("2")));
            if (amount != 0) _deposit(amount);
        }
        uint256 bps = vm.envOr("PLAY_WITHDRAW_SHARE_BPS_PER_DAY", uint256(200));
        if (day % 2 == 1 && bps != 0 && hod == uint256(keccak256(abi.encode(seed, "withdraw", day))) % 24) {
            _withdraw(bps);
        }
    }

    function _deposit(uint256 amount) internal {
        _flush();
        address d = _depositor();
        vm.deal(d, amount);
        vm.prank(d);
        try pool.deposit{value: amount}() {}
        catch {
            ++depositFailures;
        }
        _drain();
    }

    function _withdraw(uint256 bps) internal {
        _flush();
        uint256 len = depositors.length;
        uint256 first = _rnd() % len;
        for (uint256 i; i < len; ++i) {
            address d = depositors[(first + i) % len];
            uint256 shares = pool.sharesOf(d) * bps / 10_000;
            if (shares == 0) continue;
            vm.prank(d);
            try pool.withdraw(shares) {}
            catch {
                ++withdrawFailures;
            }
            _drain();
            return;
        }
    }

    // ------------------------------------------------------------------ pulls

    function _pull(uint256 count) internal {
        if (pending.length + count > outstandingCap) {
            vm.warp(_now() + vrfLatency);
            _flush();
        }
        uint256 resume = fwa.purchasesResumeAt();
        if (_now() < resume) {
            waitHour += (resume - _now()) * count;
            vm.warp(resume);
        }
        if (_now() >= t0 + curHour * HOUR) ++overrunPulls;
        uint256 idx = playerCtr++ % PLAYERS;
        address who = _player(idx);
        (uint256 fee,, uint256 total) = fwa.quoteAcquisitionPrice(count);
        uint256 slip = fwa.selectionSlippageBps();
        uint256 version = fwa.inventoryVersion();
        vm.deal(who, who.balance + total);
        vm.prank(who);
        try pool.acquireBatch{value: total}(who, count, fee, 0, slip, version, _now() + 1 hours) returns (
            uint256[] memory ids
        ) {
            for (uint256 i; i < ids.length; ++i) {
                Pending memory p = Pending(ids[i], idx, total / count, curHour);
                pending.push(p);
                info[ids[i]] = p;
            }
            pullsHour += count;
            totalPulls += count;
        } catch (bytes memory err) {
            rejectedHour += count;
            totalRejected += count;
            _tally(bytes4(err));
        }
        _drain();
    }

    function _tally(bytes4 sel) internal {
        for (uint256 i; i < rejectSel.length; ++i) {
            if (rejectSel[i] == sel) {
                ++rejectCount[i];
                return;
            }
        }
        rejectSel.push(sel);
        rejectCount.push(1);
    }

    /// @dev Fulfills every pending request in sequence order with seeded words and books them.
    function _flush() internal {
        uint256 n = pending.length;
        if (n == 0) return;
        for (uint256 i; i < n; ++i) {
            fulfill(fwa, pending[i].id, _rnd());
        }
        for (uint256 i; i < 40 && pool.nextSequenceToBook() <= fwa.lastIssuedSequence(); ++i) {
            _keeperSettle();
        }
        _drain();
        for (uint256 i; i < n; ++i) {
            Pending memory p = pending[i];
            if (!logged[p.id]) _pullRow(p, 0, "Unbooked", "");
        }
        delete pending;
    }

    // ------------------------------------------------------------------ keeper

    function _tick() internal {
        _flush();
        if (pool.claims() != 0) {
            try pool.payClaims() {}
            catch {}
            _drain();
        }
        if (pool.settleDue() != IPoolTypes.SettleTrigger.None) {
            _keeperSettle();
            _drain();
            _notePause();
        }
        IPoolTypes.RotateTrigger trig = pool.rotateDue();
        if (trig == IPoolTypes.RotateTrigger.None) return;
        vm.prank(keeper);
        try pool.rotate() {
            ++rotates;
            ++rotTrig[uint8(trig) - 1];
        } catch {
            ++rotateFailures;
        }
        _drain();
        _notePause();
    }

    /// @dev `settle(20)` as the keeper. The trigger read before the call is tallied; a call that becomes
    ///      due only after it books the captures is counted in `settles` without a trigger.
    function _keeperSettle() internal {
        IPoolTypes.SettleTrigger due = pool.settleDue();
        vm.prank(keeper);
        try pool.settle(20) {
            if (due != IPoolTypes.SettleTrigger.None) ++setTrig[uint8(due) - 1];
        } catch {
            ++settleFailures;
        }
    }

    /// @dev Books the part of the FWA purchase pause after now to the hours it covers.
    function _notePause() internal {
        uint256 until = fwa.purchasesResumeAt();
        uint256 from = _now();
        while (from < until && from >= t0) {
            uint256 idx = (from - t0) / HOUR + 1;
            uint256 hourEnd = t0 + idx * HOUR;
            uint256 to = until < hourEnd ? until : hourEnd;
            if (idx < pauseSec.length) pauseSec[idx] += to - from;
            from = to;
        }
    }

    // ------------------------------------------------------------------ logs

    /// @dev Reads the pool's events since the last call: pull outcomes, rotate results, claim payments.
    function _drain() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(pool)) continue;
            bytes32 t = l.topics[0];
            if (t == IPoolTypes.Captured.selector) {
                (uint16 row, uint256 value,) = abi.decode(l.data, (uint16, uint256, uint256));
                Pending memory p = info[uint256(l.topics[1])];
                _pullRow(p, value, rowIsPack[row] ? "Pack" : "Shape", "");
                logged[p.id] = true;
            } else if (t == IPoolTypes.GrailCaptured.selector) {
                uint256 track = uint256(l.topics[1]);
                uint256 proceeds = abi.decode(l.data, (uint256));
                Pending memory p = info[uint256(l.topics[2])];
                _pullRow(p, grailBacking[track], proceeds == 0 ? "GrailPending" : "Grail", track == 0 ? "minor" : "major");
                logged[p.id] = true;
            } else if (t == IPoolTypes.WrittenOff.selector) {
                Pending memory p = info[uint256(l.topics[1])];
                _pullRow(p, 0, "WrittenOff", "");
                logged[p.id] = true;
            } else if (t == IPoolTypes.Settled.selector) {
                (uint256 listed, uint256 refund) = abi.decode(l.data, (uint256, uint256));
                if (listed != 0) ++settles;
                settleListedHour += listed;
                settleRefundHour += refund;
                totalSettleListed += listed;
                totalSettleRefund += refund;
            } else if (t == IPoolTypes.Rotated.selector) {
                (, bool inv, uint256 refund) = abi.decode(l.data, (bool, bool, uint256));
                if (inv) ++inventoryChanged;
                totalRotateRefund += refund;
            } else if (t == IPoolTypes.Withdrawn.selector) {
                _onWithdrawn(address(uint160(uint256(l.topics[1]))), l.data);
            }
        }
        _closePaidClaims();
        for (uint256 tr; tr < 2; ++tr) {
            (,, uint256 b,,,,,,,,,) = IPool(address(pool)).grail(tr);
            grailBacking[tr] = b;
        }
    }

    function _onWithdrawn(address from, bytes memory data) internal {
        (uint256 shares, uint256 paidNow, uint256 enqueued) = abi.decode(data, (uint256, uint256, uint256));
        OpenClaim memory c = OpenClaim(from, curHour, _now(), shares, paidNow, enqueued, queued, false);
        if (enqueued == 0) {
            _claimRow(c, 0, 0);
        } else {
            ++queued;
            openClaims.push(c);
        }
    }

    /// @dev Each withdrawal that leaves a remainder appends one entry to the pool's claim queue, so entry
    ///      `queueIndex` is settled once `claimHead` has moved past it. A claim reduced by re-mint cost
    ///      settles the same way.
    function _closePaidClaims() internal {
        uint256 head = pool.claimHead();
        for (uint256 i; i < openClaims.length; ++i) {
            OpenClaim storage c = openClaims[i];
            if (!c.closed && c.queueIndex < head) {
                c.closed = true;
                _claimRow(c, _now() - c.at, 0);
            }
        }
    }

    function _closeClaims() internal {
        for (uint256 i; i < openClaims.length; ++i) {
            OpenClaim storage c = openClaims[i];
            if (!c.closed) _claimRow(c, _now() - c.at, 1);
        }
    }

    // ------------------------------------------------------------------ csv

    function _initFiles() internal {
        _truncate("pulls.csv", "hour,player,paid,backingReceived,kind,track");
        _truncate(
            "hourly.csv",
            "hour,navPerShare,cash,backing,receivable,claims,listedCount,grailBacking0,grailNotional0,grailOddsBps0,"
            "grailBacking1,grailNotional1,grailOddsBps1,rotates,rotClaim,rotGrailStep,rotHeld,"
            "inventoryChanged,pauseSecondsAccrued,pulls,rejected,pullWaitSeconds,"
            "settles,setBatch,setAge,setThin,settleListed,settleRefund"
        );
        _truncate("claims.csv", "hour,depositor,shares,paidNow,enqueued,waitSeconds,open");
    }

    function _truncate(string memory file, string memory header) internal {
        string memory path = string.concat(dir, file);
        vm.writeFile(path, "");
        vm.writeLine(path, header);
    }

    function _pullRow(Pending memory p, uint256 backingReceived, string memory kind, string memory track) internal {
        string memory line = _c(_c(vm.toString(p.hour), p.player), p.paid);
        vm.writeLine(string.concat(dir, "pulls.csv"), string.concat(_c(line, backingReceived), ",", kind, ",", track));
    }

    function _claimRow(OpenClaim memory c, uint256 wait, uint256 open_) internal {
        string memory line = string.concat(vm.toString(c.hour), ",d", vm.toString(_depositorIndex(c.to)));
        line = _c(_c(_c(line, c.shares), c.paidNow), c.enqueued);
        vm.writeLine(string.concat(dir, "claims.csv"), _c(_c(line, wait), open_));
    }

    function _depositorIndex(address d) internal view returns (uint256) {
        for (uint256 i; i < depositors.length; ++i) {
            if (depositors[i] == d) return i;
        }
        return type(uint256).max;
    }

    function _baseline() internal {
        _hourRow(0);
    }

    function _hourRow(uint256 h) internal {
        uint256 shares = pool.totalShares();
        string memory line = _c(vm.toString(h), shares == 0 ? 0 : pool.nav() * 1e18 / shares);
        line = _c(_c(_c(_c(line, pool.cash()), pool.backing()), pool.receivable()), pool.claims());
        line = _c(line, pool.listedCount());
        for (uint256 t; t < 2; ++t) {
            (uint256 b, uint256 notional, uint256 odds) = _grailStats(t);
            line = string.concat(_c(_c(line, b), notional), ",", _fixed4(odds));
        }
        line = _c(_c(line, rotates), rotTrig[0]);
        line = _c(_c(line, rotTrig[1]), rotTrig[2]);
        line = _c(_c(line, inventoryChanged), h < pauseSec.length ? pauseSec[h] : 0);
        line = _c(_c(_c(line, pullsHour), rejectedHour), waitHour);
        line = _c(_c(_c(_c(line, settles), setTrig[0]), setTrig[1]), setTrig[2]);
        line = _c(_c(line, settleListedHour), settleRefundHour);
        vm.writeLine(string.concat(dir, "hourly.csv"), line);

        delete rotTrig;
        delete setTrig;
        settles = 0;
        settleListedHour = 0;
        settleRefundHour = 0;
        rotates = 0;
        inventoryChanged = 0;
        pullsHour = 0;
        rejectedHour = 0;
        waitHour = 0;
    }

    /// @dev Backing and list price of a track's pack, and its selection probability at FWA in bps of
    ///      the total weight times 10^4 (zero while unlisted).
    function _grailStats(uint256 t) internal view returns (uint256 b, uint256 notional, uint256 oddsBps) {
        uint256 listingId;
        (,, b, notional,,,,,,,, listingId) = IPool(address(pool)).grail(t);
        if (listingId == 0) return (b, notional, 0);
        (,,,, uint256 weight,,, IFWAClone.ListingStatus status) = fwa.listings(listingId);
        uint256 totalWeight = fwa.totalWeight();
        if (status == IFWAClone.ListingStatus.Active && totalWeight != 0) oddsBps = weight * 1e8 / totalWeight;
    }

    /// @dev Decimal string of `v / 10^4` with four fractional digits.
    function _fixed4(uint256 v) internal pure returns (string memory) {
        string memory frac = vm.toString(v % 1e4);
        while (bytes(frac).length < 4) frac = string.concat("0", frac);
        return string.concat(vm.toString(v / 1e4), ".", frac);
    }

    function _c(string memory s, uint256 v) internal pure returns (string memory) {
        return string.concat(s, ",", vm.toString(v));
    }

    function _summary(string memory name, uint256 hours_) internal {
        vm.writeFile(string.concat(dir, "run.txt"), runInfo);
        uint256 shares = pool.totalShares();
        console2.log(name);
        console2.log("hours", hours_);
        console2.log("pulls", totalPulls);
        console2.log("rejected", totalRejected);
        console2.log("navPerShare", shares == 0 ? 0 : pool.nav() * 1e18 / shares);
        console2.log("rotateFailures", rotateFailures);
        console2.log("settleFailures", settleFailures);
        console2.log("settleListed", totalSettleListed);
        console2.log("settleRefund", totalSettleRefund);
        console2.log("rotateRefund", totalRotateRefund);
        console2.log("maintenanceEnd", pool.maintenance());
        console2.log("depositFailures", depositFailures);
        console2.log("withdrawFailures", withdrawFailures);
        for (uint256 i; i < rejectSel.length; ++i) {
            console2.logBytes4(rejectSel[i]);
            console2.log("  count", rejectCount[i]);
        }
    }

    // ------------------------------------------------------------------ inputs

    function _rnd() internal returns (uint256) {
        return uint256(keccak256(abi.encode(seed, ++rctr)));
    }

    /// @dev Exports every key of the env file as an environment variable, applying `PLAY_<KEY>`
    ///      overrides, so `Deploy._params` reads the same values the deploy wrapper exports. Returns
    ///      the pool admin address.
    function _loadEnv() internal returns (address) {
        string memory path = vm.envOr("PLAY_ENV_FILE", string("script/env/anvil.env"));
        string[] memory lines = vm.split(vm.readFile(path), "\n");
        for (uint256 i; i < lines.length; ++i) {
            bytes memory b = bytes(lines[i]);
            if (b.length == 0 || b[0] == "#") continue;
            uint256 eq = type(uint256).max;
            for (uint256 j; j < b.length; ++j) {
                if (b[j] == "=") {
                    eq = j;
                    break;
                }
            }
            if (eq == type(uint256).max) continue;
            string memory key = _slice(b, 0, eq);
            string memory val = _unquote(_slice(b, eq + 1, b.length));
            if (_eq(key, "DRAW_PACKS") || _eq(key, "OLD_POOL")) continue;
            val = vm.envOr(string.concat("PLAY_", key), val);
            if (bytes(val).length == 0) continue;
            vm.setEnv(key, val);
            runInfo = string.concat(runInfo, "\n", key, "=", val);
        }
        return vm.envAddress("ADMIN");
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (string memory) {
        bytes memory out = new bytes(to - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[from + i];
        }
        return string(out);
    }

    function _unquote(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= 2 && b[0] == '"' && b[b.length - 1] == '"') return _slice(b, 1, b.length - 1);
        return s;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev Parses a decimal ETH amount such as `0.5` into wei.
    function _ether(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 whole;
        uint256 frac;
        uint256 fracDigits;
        bool dot;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == ".") {
                dot = true;
                continue;
            }
            require(b[i] >= "0" && b[i] <= "9", "PlayMonth: bad ETH amount");
            uint256 d = uint8(b[i]) - 48;
            if (!dot) {
                whole = whole * 10 + d;
            } else if (fracDigits < 18) {
                frac = frac * 10 + d;
                ++fracDigits;
            }
        }
        return whole * 1e18 + frac * 10 ** (18 - fracDigits);
    }
}
