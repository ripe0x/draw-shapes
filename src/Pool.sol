// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {Denominations} from "shapes/lib/Denominations.sol";
import {IShapePacks} from "draw-packs/interfaces/IShapePacks.sol";
import {IERC721Value} from "shapes/interfaces/IERC721Value.sol";
import {PricingLib} from "./lib/PricingLib.sol";
import {PoolBooks} from "./PoolBooks.sol";
import {IFWAClone, FWAConfigKeys} from "./interfaces/IFWAClone.sol";
import {IFWACloneFactory} from "./interfaces/IFWACloneFactory.sol";

/// @title Pool
/// @notice Depositors hold nontransferable shares of ordinary NAV. ETH held by the pool is
///         accounted in buckets: `cash`, `backing`, `receivable`, `claims`, `maintenance` and, per
///         GRAIL track, `grail[t].bucket` and `grail[t].backing`.
/// @dev Ordinary NAV = `cash + backing + receivable - claims`. GRAIL buckets and GRAIL backing are
///      outside ordinary NAV. A deposit routes an entry contribution to the two GRAIL buckets and
///      mints shares for the remainder at NAV before the deposit. A withdrawal burns shares and
///      pays `min(claim, cash)` at once. The remainder is booked in `claims` and appended to
///      `claimQueue`, which is paid in request order from `cash`.
///
///      `claims` is the unpaid part of withdrawn shares. It reduces NAV and is paid from `cash`
///      as `cash` is replenished by deposits and by backing turning into ETH.
///
///      Invariant I1: `address(this).balance >= cash + maintenance + grail[0].bucket +
///      grail[1].bucket`. ETH received outside the accounted paths raises the balance and stays
///      unaccounted, so I1 is an inequality.
///
///      Exit: `startExit(dest)` closes pulls, deposits, rotation and GRAIL growth. `exportStep` moves
///      ordinary items in bounded steps, and GRAIL tracks on migration, then records
///      `exportedShares` and `exportedNav` and sets Exported. A successor imports through functions
///      restricted to its `oldPool` and mints holder shares with `migrateHolder`.
///
///      Admin, exit and successor-import functions are implemented by `PoolAdmin`. `fallback`
///      delegates to it on the storage layout of `PoolStorage`.
///
///      Tracks are indexed `MINOR = 0` and `MAJOR = 1`. Share, claim and bucket amounts are in wei.
contract Pool is PoolBooks {
    // ------------------------------------------------------------------ constants

    uint256 internal constant MAX_CLAIM_ITEMS = 20;
    uint256 internal constant MAX_MINTS_PER_RESTOCK = 20;
    uint256 internal constant SETTLE_BUDGET = 3;
    uint256 internal constant MAX_LIQUIDATE_ITEMS = 10;
    uint256 internal constant MAX_ACTIVATIONS = 20;
    /// @dev Added to the refund of every `rotate` that changed state.
    uint256 internal constant ROTATE_TIP = 0.0005 ether;
    /// @dev Intrinsic transaction gas plus the refund transfer, added to the measured gas.
    uint256 internal constant ROTATE_GAS_OVERHEAD = 30_000;

    /// @notice `PoolAdmin` instance that `fallback` delegates to.
    address public immutable adminModule;

    constructor(Params memory p, address adminModule_) {
        if (
            p.shapes == address(0) || p.drawPacks == address(0) || p.fwaFactory == address(0) || p.admin == address(0)
                || adminModule_ == address(0)
        ) {
            revert ZeroAddress();
        }
        adminModule = adminModule_;
        shapes = p.shapes;
        drawPacks = p.drawPacks;
        fwaFactory = p.fwaFactory;
        oldPool = p.oldPool;
        admin = p.admin;
        navCap = p.navCap;
        rotateInterval = p.rotateInterval;
        openingDeadline = p.openingDeadline;
        minItems = p.minItems;
        _setFeeSplit(p.feeSplit);
        _setCurve(p.curve);
        _setProbCap(p.grailProbCapBps);

        _initGrail(MINOR, p.minor);
        _initGrail(MAJOR, p.major);
        _setMix(p.mix);
    }

    // ------------------------------------------------------------------ views

    /// @notice Listed plus held ordinary items of `row`.
    function rowCount(uint256 row) external view returns (uint256) {
        return _rowCount[row];
    }

    /// @notice Number of mix rows.
    function mixLength() external view returns (uint256) {
        return _mix.length;
    }

    /// @notice Listed items of `row`.
    function listedRowCount(uint256 row) external view returns (uint256) {
        return _listedByRow[row].length;
    }

    /// @notice Pulls in the current clock hour and the four hours before it.
    function trailingPulls() public view returns (uint256 total) {
        uint256 hour = block.timestamp / 1 hours;
        for (uint256 i; i < PULL_SLOTS; ++i) {
            PullSlot memory slot = _pullSlots[i];
            if (slot.hour + PULL_SLOTS - 1 >= hour) total += slot.count;
        }
    }

    /// @notice Rungs and weight share of mix row `i`.
    function mixRow(uint256 i) external view returns (uint8[] memory rungs, uint16 shareBps) {
        uint8[] storage stored = _mix[i].rungs;
        rungs = new uint8[](stored.length);
        for (uint256 j; j < rungs.length; ++j) {
            rungs[j] = stored[j];
        }
        shareBps = _mix[i].shareBps;
    }

    // ------------------------------------------------------------------ paths

    /// @notice Creates the FWA pool through the factory and approves it for both collections.
    ///         Starts the opening deadline. The factory pulls `expectedFee` of its FWA token from
    ///         this contract, so the pool must hold that balance first.
    function createFwaPool(uint256 expectedFee) external onlyAdmin nonReentrant {
        if (lifecycle != Lifecycle.Opening) revert NotOpening();
        if (address(fwaPool) != address(0)) revert FwaPoolExists();

        IFWACloneFactory factory = IFWACloneFactory(fwaFactory);
        if (expectedFee != 0) {
            SafeTransferLib.safeApprove(
                address(uint160(_read(fwaFactory, IFWACloneFactory.fwaToken.selector, 0))), fwaFactory, expectedFee
            );
        }
        IFWAClone clone = IFWAClone(factory.createPool(bytes32(0), expectedFee));

        fwaPool = clone;
        maxBatch = _read(fwaFactory, IFWACloneFactory.maxAcquisitionsPerTx.selector, 0);
        concurrency = _read(fwaFactory, IFWACloneFactory.maxOutstandingRequestsPerPool.selector, 0);
        nextSequenceToBook = 1;
        openingDeadlineAt = block.timestamp + openingDeadline;
        _call(shapes, IERC721.setApprovalForAll.selector, uint160(address(clone)), 1);
        _call(drawPacks, IERC721.setApprovalForAll.selector, uint160(address(clone)), 1);
        emit FwaPoolCreated(address(clone));
    }

    /// @notice Enables FWA acquisitions and builds the board after the opening deadline. Each call
    ///         runs one restock. The pool becomes Live on the first call that mints fewer than
    ///         `MAX_MINTS_PER_RESTOCK` tokens, and stays callable while Opening.
    function open() external nonReentrant {
        _notExiting();
        if (lifecycle != Lifecycle.Opening) revert NotOpening();
        IFWAClone fwa = fwaPool;
        if (address(fwa) == address(0)) revert FwaPoolMissing();
        if (block.timestamp < openingDeadlineAt) revert OpeningDeadlineNotReached();
        if (_read(address(fwa), IFWAClone.localPurchasesEnabled.selector, 0) == 0) {
            _call(address(fwa), IFWAClone.setBool.selector, FWAConfigKeys.ACQUISITIONS_ENABLED, 1);
        }
        if (_restock() < MAX_MINTS_PER_RESTOCK) {
            lifecycle = Lifecycle.Live;
            lastRotateAt = block.timestamp;
            emit Opened();
        }
    }

    /// @notice Deposits `msg.value` for shares at ordinary NAV, net of the entry contribution.
    function deposit() external payable nonReentrant {
        _notExiting();
        _sync();
        _deposit(msg.sender, msg.value);
    }

    /// @notice Burns `shares` and pays their claim at ordinary NAV. Pays `min(claim, cash)` now and
    ///         queues the remainder in `claimQueue`. Reverts `UseMigrateHolder` once an exit to a
    ///         successor has started and `ImportInProgress` on a successor during its import.
    function withdraw(uint256 shares) external nonReentrant {
        if (lifecycle >= Lifecycle.Exiting && exitDest != address(this)) revert UseMigrateHolder();
        _notImporting();
        _sync();
        if (shares == 0) revert ZeroAmount();
        uint256 balance = sharesOf[msg.sender];
        if (shares > balance) revert InsufficientShares();

        uint256 supply = totalShares;
        uint256 claim = PricingLib.claimFor(shares, nav(), supply);
        sharesOf[msg.sender] = balance - shares;
        totalShares = supply - shares;

        uint256 available = cash;
        uint256 paidNow = claim < available ? claim : available;
        uint256 remainder = claim - paidNow;
        cash = available - paidNow;
        if (remainder != 0) {
            claims += remainder;
            claimQueue.push(Claim(msg.sender, uint64(block.timestamp), remainder));
        }
        emit Withdrawn(msg.sender, shares, paidNow, remainder);
        if (paidNow != 0) SafeTransferLib.safeTransferETH(msg.sender, paidNow);
    }

    /// @notice Pays queued claims in request order once the head claim is at least `rotateInterval`
    ///         old. Pays from `cash`, then redeems up to `MAX_LIQUIDATE_ITEMS` held items and
    ///         withdrawn listed items until the head claim is covered. Does nothing when the queue
    ///         is empty.
    function liquidate() external nonReentrant {
        _sync();
        uint256 head = claimHead;
        if (head == claimQueue.length) return;
        if (block.timestamp < claimQueue[head].requestedAt + rotateInterval) revert ClaimNotDue();
        _clearClaims();
    }

    /// @notice Runs one rotation: settles, harvests, pays or liquidates for queued claims, restocks
    ///         and lists the board, activates staged FWA listings, reprices or grows the GRAIL
    ///         tracks, then refunds the caller from `maintenance`. Callable once `rotateInterval`
    ///         has passed since `lastRotateAt`. The refund is paid once per `rotateInterval`.
    function rotate() external nonReentrant {
        _requireLive();
        if (block.timestamp < lastRotateAt + rotateInterval) revert RotateTooSoon();
        uint256 gasStart = gasleft();

        bool changed = _settleAndHarvest();
        uint256 claimsBefore = claims;
        bool inventoryChanged = _clearClaims();
        bool heldPending = _held.length != 0;
        bool minted = _restock() != 0;
        bool busy = _busy();
        if (!busy) _call(address(fwaPool), IFWAClone.activateListings.selector, MAX_ACTIVATIONS, 0);
        bool grailChanged = _rotateGrail(MINOR, busy);
        grailChanged = _rotateGrail(MAJOR, busy) || grailChanged;
        inventoryChanged = inventoryChanged || heldPending || minted || grailChanged;
        if (inventoryChanged) lastRotateAt = block.timestamp;
        _refund(gasStart, changed || inventoryChanged || claims != claimsBefore, inventoryChanged);
    }

    /// @notice Adds one `stepWei` of backing to GRAIL track `t` from `grail[t].bucket` and lists
    ///         the pack at `backing * listBps / 10_000`. Books FWA results first. Reverts
    ///         `GrailNotReady` unless the bucket covers the step and its mint fees and `backing`
    ///         is below `targetWei`, and `FwaBusy` while FWA holds unsettled acquisitions.
    function growGrail(uint8 t) external nonReentrant {
        _requireLive();
        if (t > MAJOR) revert GrailNotReady();
        _sync();
        uint256 status = _growGrail(t, _unsettled() != 0);
        if (status == 1) revert GrailNotReady();
        if (status == 2) revert FwaBusy();
    }

    /// @notice Buys `count` FWA acquisitions for `msg.sender` at the quoted fee. Overpayment is
    ///         refunded. Settles up to `SETTLE_BUDGET` FWA acquisitions, harvests, pays queued
    ///         claims and mints one queued replacement from `cash`.
    function pull(uint256 count, uint256 maxFee, uint256 deadline) external payable nonReentrant {
        _pull(msg.sender, count, maxFee, deadline, msg.value);
    }

    /// @notice Redeems the caller's Shapes `tokenIds` and applies the proceeds and `msg.value` to
    ///         `pull`. The caller must have approved this contract for each token.
    function pullWithShapes(uint256[] calldata tokenIds, uint256 count, uint256 maxFee, uint256 deadline)
        external
        payable
        nonReentrant
    {
        _requireLive();
        _pull(msg.sender, count, maxFee, deadline, msg.value + _redeemShapes(tokenIds));
    }

    /// @notice Redeems the caller's Shape `tokenId` and deposits the proceeds. The caller must have
    ///         approved this contract for the token.
    function redeemAndDeposit(uint256 tokenId) external nonReentrant {
        _notExiting();
        _sync();
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        _deposit(msg.sender, _redeemShapes(ids));
    }

    /// @notice Processes up to `maxCount` FWA acquisitions and books their results.
    function settle(uint256 maxCount) external nonReentrant {
        if (address(fwaPool) == address(0)) revert FwaPoolMissing();
        _processAndSettle(maxCount < MAX_SETTLE_ITEMS ? maxCount : MAX_SETTLE_ITEMS);
    }

    /// @notice Accepts ETH from Shapes redemptions and FWA proceeds. The ETH is booked by the
    ///         function that triggered the transfer.
    receive() external payable {}

    /// @notice Accepts Shapes and Draw Packs from mints and FWA listing withdrawals. The calling
    ///         function books the token.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @notice Delegates every other call to `adminModule` and returns its return data or revert
    ///         data.
    fallback() external payable {
        address module = adminModule;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), module, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    // ------------------------------------------------------------------ internal

    /// @dev Reverts `ImportInProgress` on a successor between its first import and `finalizeImport`.
    function _notImporting() internal view {
        if (importedNav != 0 && !importFinalized) revert ImportInProgress();
    }

    /// @dev Reverts unless the pool is Live: `PoolExiting` from `Exiting` on, `NotLive` before.
    function _requireLive() internal view {
        if (lifecycle != Lifecycle.Live) {
            _notExiting();
            revert NotLive();
        }
    }

    /// @dev Mints shares to `to` for `value`. The entry contribution goes to the GRAIL buckets,
    ///      split by `minorShareBps`. Shares are priced on NAV before the deposit.
    function _deposit(address to, uint256 value) internal {
        _notImporting();
        if (depositsPaused) revert DepositsPaused();
        if (value == 0) revert ZeroAmount();
        uint256 currentNav = nav();
        if (currentNav == 0 && totalShares != 0) revert NavZero();
        if (currentNav >= navCap) revert NavCapReached();

        EntryCurve memory c = curve;
        uint256 contribution = PricingLib.entryContribution(
            value, PricingLib.entryCurveBps(currentNav, c.baseBps, c.slopeBps, c.capBps, c.referenceWei)
        );
        uint256 net = value - contribution;
        uint256 shares = PricingLib.sharesFor(net, currentNav, totalShares);
        if (shares == 0) revert ZeroShares();

        uint256 minorPart = contribution * feeSplit.minorShareBps / BPS;
        grail[MINOR].bucket += minorPart;
        grail[MAJOR].bucket += contribution - minorPart;
        cash += net;
        totalShares += shares;
        sharesOf[to] += shares;
        emit Deposited(to, value, contribution, shares);
    }

    /// @dev Pays claims from `cash` starting at `claimHead`, at most `MAX_CLAIM_ITEMS` queue entries. A
    ///      partly paid head claim keeps its place with a reduced `amount`. Storage is updated
    ///      before any transfer. Recipients are paid with `forceSafeTransferETH`, so a recipient
    ///      that rejects ETH cannot stall the queue.
    function _payClaims() internal {
        uint256 head = claimHead;
        uint256 pending = claimQueue.length - head;
        uint256 limit = pending < MAX_CLAIM_ITEMS ? pending : MAX_CLAIM_ITEMS;
        address[] memory recipients = new address[](limit);
        uint256[] memory payouts = new uint256[](limit);
        uint256 available = cash;
        uint256 paidTotal;
        uint256 paidCount;
        while (paidCount < limit && available != 0) {
            Claim storage c = claimQueue[head];
            uint256 amount = c.amount;
            uint256 pay = amount < available ? amount : available;
            available -= pay;
            paidTotal += pay;
            recipients[paidCount] = c.to;
            payouts[paidCount] = pay;
            ++paidCount;
            if (pay == amount) {
                ++head;
            } else {
                c.amount = amount - pay;
            }
        }
        claimHead = head;
        cash = available;
        claims -= paidTotal;
        for (uint256 i; i < paidCount; ++i) {
            emit ClaimPaid(recipients[i], payouts[i]);
            SafeTransferLib.forceSafeTransferETH(recipients[i], payouts[i]);
        }
    }

    /// @dev Pays claims from `cash`, then liquidates for the head claim and pays again. Returns
    ///      whether an item was redeemed.
    function _clearClaims() internal returns (bool redeemed) {
        _payClaims();
        redeemed = _liquidateForClaims(MAX_LIQUIDATE_ITEMS);
        if (redeemed) _payClaims();
    }

    /// @dev Settles up to `MAX_SETTLE_ITEMS` acquisitions and harvests. Returns whether a booking
    ///      or a harvest happened.
    function _settleAndHarvest() internal returns (bool) {
        uint64 booked = nextSequenceToBook;
        _processAndSettle(MAX_SETTLE_ITEMS);
        bool harvested = _harvest();
        return harvested || nextSequenceToBook != booked;
    }

    /// @dev Pays the caller `min(maintenance, gas cost + ROTATE_TIP)` when the rotation changed
    ///      state and `rotateInterval` has passed since `lastRefundAt`. The transfer is the last
    ///      step.
    function _refund(uint256 gasStart, bool changed, bool inventoryChanged) internal {
        uint256 refund;
        uint256 bucket = maintenance;
        if (changed && bucket != 0 && block.timestamp >= lastRefundAt + rotateInterval) {
            lastRefundAt = block.timestamp;
            uint256 cost = (gasStart - gasleft() + ROTATE_GAS_OVERHEAD) * block.basefee + ROTATE_TIP;
            refund = cost < bucket ? cost : bucket;
            maintenance = bucket - refund;
        }
        emit Rotated(changed, inventoryChanged, refund);
        if (refund != 0) SafeTransferLib.safeTransferETH(msg.sender, refund);
    }

    /// @dev Redeems up to `maxItems` ordinary items while `cash` is below the head claim, if the
    ///      head claim is at least `rotateInterval` old. Held items go first and need no FWA call.
    ///      Listed items follow, each the last listed item of the row most over its share. They are
    ///      skipped while FWA holds unsettled acquisitions, which lock withdrawals, or while the
    ///      booking walk is behind FWA's processing queue, which leaves captured listings in
    ///      `_listed`. Stops when the head claim does not exceed the mint fees of the next item.
    ///      Returns whether an item was redeemed.
    function _liquidateForClaims(uint256 maxItems) internal returns (bool redeemed) {
        uint256 head = claimHead;
        if (head == claimQueue.length || block.timestamp < claimQueue[head].requestedAt + rotateInterval) {
            return false;
        }
        if (_held.length == 0 && listedCount == 0) return false;
        uint256 mintFee = _mintFee();
        bool locked = listedCount != 0 && _busy();
        for (uint256 n; n < maxItems && cash < claimQueue[head].amount; ++n) {
            if (!_liquidateOne(head, mintFee, locked)) break;
            redeemed = true;
        }
    }

    /// @dev Redeems the last held item, or else the last listed item of the most overweight row,
    ///      into `cash` and deducts the mint fees of the redeemed Shapes from the claim at `head`.
    ///      The deducted ETH stays in `cash` for the replacement mint. Returns false and changes
    ///      nothing when there is no item to redeem or the claim does not exceed the fee.
    function _liquidateOne(uint256 head, uint256 mintFee, bool locked) internal returns (bool) {
        uint256 held = _held.length;
        uint256 row;
        if (held != 0) {
            row = _held[held - 1].row;
        } else if (listedCount != 0 && !locked) {
            row = _mostOverweightListedRow();
        } else {
            return false;
        }
        Claim storage c = claimQueue[head];
        uint256 amount = c.amount;
        uint256 fee = mintFee * _mix[row].rungs.length;
        if (amount <= fee) return false;

        Item memory it;
        if (held != 0) {
            it = _removeHeld(held - 1);
        } else {
            uint256 listingId = _lastListed(row);
            _withdrawListing(listingId, address(this));
            it = _removeListed(listingId);
        }
        _redeemItem(it);
        c.amount = amount - fee;
        claims -= fee;
        emit Liquidated(it.listingId, it.value, fee);
        return true;
    }

    /// @dev Row with listed items that maximizes `rowCount / shareBps`, compared by cross
    ///      multiplication. A listed row with zero share ranks above every row with a share.
    function _mostOverweightListedRow() internal view returns (uint256 best) {
        uint256 bestCount;
        uint256 bestShare;
        for (uint256 r; r < _mix.length; ++r) {
            if (_listedByRow[r].length == 0) continue;
            uint256 count = _rowCount[r];
            uint256 share = _mix[r].shareBps;
            if (bestCount == 0 || count * bestShare > bestCount * share) {
                best = r;
                bestCount = count;
                bestShare = share;
            }
        }
    }

    /// @dev Buys `count` acquisitions for `purchaser` with `value` wei available. `value` is
    ///      already in the pool balance and outside every bucket.
    function _pull(address purchaser, uint256 count, uint256 maxFee, uint256 deadline, uint256 value) internal {
        _requireLive();
        if (pullsPaused) revert PullsPaused();
        if (count == 0 || count > maxBatch) revert InvalidCount();
        _requirePurchasable(value);

        IFWAClone fwa = fwaPool;
        (uint256 fee, uint256 total) = _quote(count);
        if (fee > maxFee) revert FeeAboveMax(fee, maxFee);
        if (value < total) revert InsufficientValue(value, total);

        uint256[] memory ids = fwa.acquireBatch{value: total}(
            purchaser,
            count,
            maxFee,
            0,
            _read(address(fwa), IFWAClone.selectionSlippageBps.selector, 0),
            _read(address(fwa), IFWAClone.inventoryVersion.selector, 0),
            deadline
        );
        _recordBases(fwa, fee, ids);
        _recordPulls(count);
        emit Pulled(purchaser, count, fee, ids);

        _upkeep();
        if (value > total) SafeTransferLib.safeTransferETH(purchaser, value - total);
    }

    /// @dev Transfers `tokenIds` from the caller and redeems them. Returns the ETH redeemed.
    function _redeemShapes(uint256[] memory tokenIds) internal returns (uint256) {
        for (uint256 i; i < tokenIds.length; ++i) {
            _transfer(shapes, msg.sender, address(this), tokenIds[i]);
        }
        return IShapes(shapes).redeemBatch(tokenIds);
    }

    /// @dev Records the FWA base price of each request opened by one `acquireBatch`. The batch
    ///      reserves staged listings without activating them, so `weightedBackingTotal` and
    ///      `totalWeight` read after the call equal their values at every request.
    function _recordBases(IFWAClone fwa, uint256 fee, uint256[] memory ids) internal {
        uint256 base = _read(address(fwa), IFWAClone.weightedBackingTotal.selector, 0) / _totalWeight();
        if (base > fee) base = fee;
        for (uint256 i; i < ids.length; ++i) {
            _basePlusOne[ids[i]] = base + 1;
        }
    }

    /// @dev Per-pull upkeep: settles up to `SETTLE_BUDGET` acquisitions, harvests, pays queued
    ///      claims from `cash`, then mints one queued replacement when `cash` covers it. The
    ///      replacement stays held. A listing here would start the FWA inventory change cooldown
    ///      and block the next pull.
    function _upkeep() internal {
        _processAndSettle(SETTLE_BUDGET);
        _harvest();
        _payClaims();
        uint256 head = replacementHead;
        if (head == replacementQueue.length) return;
        uint256 mintFee = _mintFee();
        uint256 row = replacementQueue[head];
        if (cash < _rowCost(row, mintFee)) return;
        replacementHead = head + 1;
        _mintRow(row, mintFee);
    }

    /// @dev Reverts unless a pull may open: the FWA cooldown has passed, the balance covers the
    ///      buckets plus the `incoming` wei still outside them, the listed ordinary items exceed
    ///      the unsettled acquisitions by `concurrency`, and the listed GRAIL tracks hold at most
    ///      `grailProbCapBps` of the FWA selection weight.
    function _requirePurchasable(uint256 incoming) internal view {
        IFWAClone fwa = fwaPool;
        if (block.timestamp < _read(address(fwa), IFWAClone.purchasesResumeAt.selector, 0)) {
            revert PurchasesCoolingDown();
        }
        if (!_covered(incoming)) revert Insolvent();
        if (listedCount < _unsettled() + concurrency) revert BoardTooThin();

        if (_grailCapExceeded(MAJOR + 1, 0)) revert GrailProbTooHigh();
    }

    /// @dev True when the listed GRAIL tracks hold more than `grailProbCapBps` of the FWA selection
    ///      weight with track `t` priced at `price`. A `t` above `MAJOR` leaves every track at its
    ///      current price.
    function _grailCapExceeded(uint256 t, uint256 price) internal view returns (bool) {
        uint256 total = _totalWeight();
        uint256 grailWeight;
        for (uint256 i; i <= MAJOR; ++i) {
            Grail storage g = grail[i];
            bool listed = g.listingId != 0;
            if (i == t) {
                uint256 w = PricingLib.weightOf(price);
                if (listed) total -= PricingLib.weightOf(g.notional);
                total += w;
                grailWeight += w;
            } else if (listed) {
                grailWeight += PricingLib.weightOf(g.notional);
            }
        }
        return grailWeight * BPS > total * grailProbCapBps;
    }

    /// @dev Adds `count` pulls to the current clock hour. A slot last written in an earlier hour
    ///      is reset first.
    function _recordPulls(uint256 count) internal {
        uint64 hour = uint64(block.timestamp / 1 hours);
        PullSlot storage slot = _pullSlots[hour % PULL_SLOTS];
        uint256 current = slot.hour == hour ? slot.count : 0;
        slot.hour = hour;
        slot.count = SafeCastLib.toUint192(current + count);
        for (uint256 t; t <= MAJOR; ++t) {
            Grail storage g = grail[t];
            if (g.listingId != 0) g.pullsSinceList += count;
        }
    }

    /// @dev Pays queued claims, mints replacements from the queue, then new inventory toward the
    ///      target depth of each row, then lists every held item. At most `MAX_MINTS_PER_RESTOCK`
    ///      mints per call. New inventory is minted only when the queue is empty and only from
    ///      `cash` above one step of the cheapest row. Returns the number of tokens minted.
    function _restock() internal returns (uint256 mints) {
        _payClaims();
        uint256 fee = _mintFee();

        uint256 head = replacementHead;
        uint256 queued = replacementQueue.length;
        while (head < queued && mints < MAX_MINTS_PER_RESTOCK) {
            uint256 row = replacementQueue[head];
            if (cash < _rowCost(row, fee)) break;
            ++head;
            _mintRow(row, fee);
            ++mints;
        }
        replacementHead = head;

        if (head == queued) mints = _mintToDepth(fee, mints);
        _listHeld(fee);
    }

    /// @dev Mints toward each row's target depth. Returns `mints` plus the tokens minted here.
    function _mintToDepth(uint256 fee, uint256 mints) internal returns (uint256) {
        uint256 rows = _mix.length;
        uint256 reserve = type(uint256).max;
        for (uint256 r; r < rows; ++r) {
            uint256 cost = _rowCost(r, fee);
            if (cost < reserve) reserve = cost;
        }
        uint256 pulls = trailingPulls();
        for (uint256 r; r < rows; ++r) {
            uint256 target = PricingLib.rowDepth(minItems, pulls, _mix[r].shareBps);
            uint256 cost = _rowCost(r, fee);
            while (_rowCount[r] < target && mints < MAX_MINTS_PER_RESTOCK && cash >= reserve + cost) {
                _mintRow(r, fee);
                ++mints;
            }
        }
        return mints;
    }

    /// @dev Row backing plus the mint fee of every Shape the row mints.
    function _rowCost(uint256 row, uint256 fee) internal view returns (uint256) {
        return _rowBackingWei[row] + fee * _mix[row].rungs.length;
    }

    /// @dev Mints one token of `row` to this contract and books it as held. A one rung row is a
    ///      Shape. A row of two or more rungs is a Draw Pack created with one Shape per rung.
    function _mintRow(uint256 row, uint256 fee) internal {
        uint8[] storage rungs = _mix[row].rungs;
        uint256 value = _rowBackingWei[row];
        uint256 cost = value + fee * rungs.length;
        cash -= cost;

        address collection;
        uint256 tokenId;
        if (rungs.length == 1) {
            collection = shapes;
            tokenId = _callFull(collection, cost, IShapes.mintBatchTo.selector, value, 1, uint160(address(this)));
        } else {
            collection = drawPacks;
            uint32[] memory counts = new uint32[](Denominations.COUNT);
            for (uint256 i; i < rungs.length; ++i) {
                ++counts[rungs[i]];
            }
            tokenId = _createPack(new uint256[](0), counts, cost, value);
        }
        _addItem(Item(collection, uint16(row), tokenId, value, 0));
    }

    /// @dev `status` of FWA listing `listingId`, the eighth word of `listings(listingId)`.
    function _listingStatus(uint256 listingId) internal view returns (uint256 status) {
        address fwa = address(fwaPool);
        bytes4 selector = IFWAClone.listings.selector;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), listingId)
            if iszero(staticcall(gas(), fwa, m, 0x24, m, 0x100)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            if lt(returndatasize(), 0x100) { revert(0, 0) }
            status := mload(add(m, 0xe0))
        }
    }

    /// @dev First and third word of FWA `quoteAcquisitionPrice(count)`: `fee` and `total`.
    function _quote(uint256 count) internal view returns (uint256 fee, uint256 total) {
        address fwa = address(fwaPool);
        bytes4 selector = bytes4(keccak256("quoteAcquisitionPrice(uint256)"));
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), count)
            if iszero(staticcall(gas(), fwa, m, 0x24, m, 0x60)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            if lt(returndatasize(), 0x60) { revert(0, 0) }
            fee := mload(m)
            total := mload(add(m, 0x40))
        }
    }

    /// @dev Creates a Draw Pack owned by this contract from the Shapes `shapeIds` it owns and the
    ///      Shapes minted by `counts`, paying `value`. Reverts unless the pack's value is
    ///      `expected`.
    function _createPack(uint256[] memory shapeIds, uint32[] memory counts, uint256 value, uint256 expected)
        internal
        returns (uint256 packId)
    {
        packId = IShapePacks(drawPacks).createPack{value: value}(shapeIds, counts);
        _checkPackValue(packId, expected);
    }

    /// @dev Reverts `PackValueMismatch` unless Draw Pack `packId` holds `expected` wei of backing.
    function _checkPackValue(uint256 packId, uint256 expected) internal view {
        if (_read(drawPacks, IERC721Value.valueOf.selector, packId) != expected) revert PackValueMismatch();
    }

    /// @dev Lists every held item on the FWA pool in chunks of `MAX_INVENTORY_BATCH` and moves
    ///      each to the listed map under its listing id.
    function _listHeld(uint256 fee) internal {
        uint256 listed = _held.length;
        if (listed == 0) return;
        uint256 batch = _read(address(fwaPool), IFWAClone.MAX_INVENTORY_BATCH.selector, 0);
        FeeSplit memory split = feeSplit;
        uint256 remaining = listed;
        while (remaining != 0) {
            uint256 n = remaining < batch ? remaining : batch;
            IFWAClone.InventoryInput[] memory inputs = new IFWAClone.InventoryInput[](n);
            for (uint256 i; i < n; ++i) {
                Item storage it = _held[remaining - 1 - i];
                inputs[i] = IFWAClone.InventoryInput(it.collection, it.tokenId, _listingPrice(it, fee, split));
            }
            uint256[] memory ids = fwaPool.listNFTs(inputs);
            for (uint256 i; i < n; ++i) {
                Item memory it = _removeHeld(remaining - 1 - i);
                it.listingId = ids[i];
                _addItem(it);
            }
            remaining -= n;
        }
    }

    function _listingPrice(Item storage it, uint256 fee, FeeSplit memory split) internal view returns (uint256) {
        uint256 value = it.value;
        return PricingLib.listingPrice(
            value,
            split.premiumBps,
            split.maintenanceBps,
            split.feedBps,
            PricingLib.mintLineBps(fee * _mix[it.row].rungs.length, value)
        );
    }

    /// @dev One rotation step for track `t`: grows it when ready, otherwise lists an unlisted pack
    ///      or lowers the list price by the decay accrued since the last listing or reprice. The
    ///      new price is `PricingLib.decayedNotional`, which is at least `floorWei`. A listed
    ///      track is repriced only when its listing is Active and the new price is below the
    ///      current one, and any track only when the new price keeps the listed GRAIL weight within
    ///      `grailProbCapBps`. Returns whether the FWA listing changed. `busy` is true while FWA
    ///      holds unsettled acquisitions, which lock repricing and withdrawal.
    function _rotateGrail(uint256 t, bool busy) internal returns (bool) {
        if (_growGrail(t, busy) == 0) return true;
        Grail storage g = grail[t];
        if (g.packId == 0 || busy) return false;
        uint256 listingId = g.listingId;
        uint256 next = PricingLib.decayedNotional(g.notional, g.decayWeiPerPull, g.pullsSinceList, g.floorWei);
        if (
            listingId != 0
                && (next >= g.notional || _listingStatus(listingId) != uint256(IFWAClone.ListingStatus.Active))
        ) {
            return false;
        }
        if (_grailCapExceeded(t, next)) return false;
        _priceGrail(t, g, next);
        return true;
    }

    /// @dev Adds `stepWei` of backing to track `t`, paid from `grail[t].bucket` with the mint fees
    ///      of the Shapes in `defaultMakeup(stepWei)`, then lists the pack. The track's FWA listing
    ///      is withdrawn first. Returns 0 on success, 1 when the track is not ready and 2 when
    ///      `busy`. A listing made while acquisitions are unsettled is staged and cannot be
    ///      repriced or withdrawn, so the busy check applies whether or not the pack is listed.
    ///      When the new `backing` equals a native denomination, the pack is opened, its Shapes
    ///      (ids from `contentsOf` before `open`) are composed into the first one, and that Shape
    ///      is packed again.
    function _growGrail(uint256 t, bool busy) internal returns (uint256) {
        Grail storage g = grail[t];
        if (g.backing >= g.targetWei) return 1;
        uint256 step = g.stepWei;
        uint32[] memory counts = IShapePacks(drawPacks).defaultMakeup(step);
        uint256 shapeCount;
        for (uint256 i; i < counts.length; ++i) {
            shapeCount += counts[i];
        }
        uint256 cost = step + _mintFee() * shapeCount;
        if (g.bucket < cost) return 1;
        if (busy) return 2;
        _unlistGrail(g);

        g.bucket -= cost;
        uint256 total = g.backing + step;
        g.backing = total;
        uint256 packId = g.packId;
        uint256[] memory shapeIds = new uint256[](0);
        if (packId != 0) {
            IShapePacks(drawPacks).addToPack{value: cost}(packId, shapeIds, counts);
            if (Denominations.isSupported(total)) {
                shapeIds = _composePack(packId);
                counts = new uint32[](Denominations.COUNT);
                cost = 0;
                packId = 0;
            } else {
                _checkPackValue(packId, total);
            }
        }
        if (packId == 0) g.packId = _createPack(shapeIds, counts, cost, total);

        uint256 notional = PricingLib.grailNotional(total, g.listBps);
        _priceGrail(t, g, notional);
        emit GrailGrown(t, g.packId, total, notional);
        return 0;
    }

    /// @dev Opens pack `packId`, composes its Shapes into the first one and returns that Shape's
    ///      id in a one element array.
    function _composePack(uint256 packId) internal returns (uint256[] memory survivor) {
        IShapePacks packs = IShapePacks(drawPacks);
        uint256[] memory ids = packs.contentsOf(packId);
        packs.open(packId);
        uint256[] memory burn = new uint256[](ids.length - 1);
        for (uint256 i; i < burn.length; ++i) {
            burn[i] = ids[i + 1];
        }
        IShapes(shapes).compose(ids[0], burn);
        _call(shapes, IERC721.approve.selector, uint160(address(packs)), ids[0]);
        survivor = new uint256[](1);
        survivor[0] = ids[0];
    }

    /// @dev Sets track `t`'s FWA list price to `notional`: lists the pack when it is unlisted,
    ///      otherwise reprices the listing. Restarts the decay count.
    function _priceGrail(uint256 t, Grail storage g, uint256 notional) internal {
        uint256 id = g.listingId;
        if (id == 0) {
            id = _callFull(address(fwaPool), 0, IFWAClone.listNFT.selector, uint160(drawPacks), g.packId, notional);
        } else {
            _call(address(fwaPool), IFWAClone.updatePrice.selector, id, notional);
        }
        g.listingId = id;
        g.notional = notional;
        g.pullsSinceList = 0;
        emit GrailListed(t, id, notional);
    }
}
