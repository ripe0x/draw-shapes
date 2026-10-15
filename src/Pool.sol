// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {PricingLib} from "./lib/PricingLib.sol";
import {PoolBooks} from "./PoolBooks.sol";
import {IFWAClone, FWAConfigKeys} from "./interfaces/IFWAClone.sol";
import {IFWACloneFactory} from "./interfaces/IFWACloneFactory.sol";
import {IPool} from "./interfaces/IPool.sol";

/// @title Pool
/// @notice Depositors hold nontransferable shares of ordinary NAV. ETH held by the pool is
///         accounted in buckets: `cash`, `backing`, `receivable`, `claims`, `maintenance` and the GRAIL
///         `fund`.
/// @dev Ordinary NAV = `cash + backing + receivable - claims`. The GRAIL fund and the GRAIL items are
///      outside ordinary NAV. A deposit routes an entry contribution to the GRAIL fund and
///      mints shares for the remainder at NAV before the deposit. A withdrawal burns shares and
///      pays `min(claim, cash)` at once. The remainder is booked in `claims` and appended to
///      `claimQueue`, which is paid in request order from `cash`.
///
///      `claims` is the unpaid part of withdrawn shares. It reduces NAV and is paid from `cash`
///      as `cash` is replenished by deposits and by backing turning into ETH.
///
///      Invariant I1: `address(this).balance >= cash + maintenance + grail.fund`. ETH received outside the accounted paths raises the balance and stays
///      unaccounted, so I1 is an inequality.
///
///      Exit: `startExit(dest)` closes pulls, deposits, rotation and GRAIL growth. `exportStep` moves
///      ordinary items in bounded steps, and the GRAIL estate on migration, then records
///      `exportedShares` and `exportedNav` and sets Exported. A successor imports through functions
///      restricted to its `oldPool` and mints holder shares with `migrateHolder`.
///
///      Admin, exit and successor-import functions are implemented by `PoolAdmin`. The listing
///      engine and the GRAIL (mint, merge, decay, probability cap) are implemented by `PoolListing`.
///      `fallback` delegates `listBatch`, `openBoard`, `queueMissing`, `grailStep`, `grailReprice` and `grailReady`
///      to `listingModule` and every other call to `adminModule`, on the storage layout of
///      `PoolStorage`. Share, claim and bucket amounts are in wei.
contract Pool is PoolBooks {
    // ------------------------------------------------------------------ constants

    uint256 internal constant MAX_CLAIM_ITEMS = 20;
    uint256 internal constant MAX_LIST_PER_SETTLE = 25;
    /// @dev Queued replacements and held items listed by one `rotate`.
    uint256 internal constant MAX_LIST_PER_ROTATE = 20;
    /// @dev Listed items above `concurrency` below which `settleDue` returns `Thin`.
    uint256 internal constant THIN_MARGIN = 5;
    uint256 internal constant SETTLE_BUDGET = 3;
    uint256 internal constant MAX_LIQUIDATE_ITEMS = 25;
    uint256 internal constant MAX_ACTIVATIONS = 20;
    /// @dev Intrinsic transaction gas plus the refund transfer, added to the measured gas.
    uint256 internal constant ROTATE_GAS_OVERHEAD = 30_000;

    /// @dev Transient storage slot that holds the purchaser while `_acquire` is inside its call to
    ///      the FWA pool. Zero outside that call.
    uint256 private constant PURCHASER_SLOT = uint256(keccak256("draw-shapes.Pool.purchaser"));

    /// @notice `PoolAdmin` instance that `fallback` delegates to.
    address public immutable adminModule;
    /// @notice `PoolListing` instance that `fallback` delegates the listing and GRAIL entrypoints to.
    address public immutable listingModule;

    constructor(Params memory p, address adminModule_, address listingModule_) {
        if (
            p.shapes == address(0) || p.drawPacks == address(0) || p.fwaFactory == address(0) || p.admin == address(0)
                || adminModule_ == address(0) || listingModule_ == address(0)
        ) {
            revert ZeroAddress();
        }
        adminModule = adminModule_;
        listingModule = listingModule_;
        shapes = p.shapes;
        drawPacks = p.drawPacks;
        fwaFactory = p.fwaFactory;
        oldPool = p.oldPool;
        admin = p.admin;
        navCapFloor = p.navCapFloor;
        _founderWindowSeconds = p.founderWindowSeconds;
        rotateInterval = p.rotateInterval;
        _openingDeadline = p.openingDeadline;
        minItems = p.minItems;
        _setFeeSplit(p.feeSplit);
        _setEntryFee(p.entryFee);
        _setTurnover(p.turnoverBps);
        _setProbCap(p.grailProbCapBps);
        _setBatch(p.batchMin, p.batchMaxAge);
        _setReplacement(p.surpriseBps, p.restoreK, p.bandBps);
        _setReserve(p.reserveBps);
        _setTip(p.tipWei);

        _setGrail(p.grail.decayWeiPerPull, p.grail.pieceFloorWei, p.grail.floorWei, p.grail.listBps);
        _setGrailStep(p.grail.stepUpSeconds, p.grail.stepDownSeconds);
        _setGrailTarget(p.grail.targetWei);
        _grail.targetWei = p.grail.targetWei;
        _grail.cycleId = 1;
        _setMix(p.mix);
    }

    // ------------------------------------------------------------------ paths

    /// @notice Enables FWA acquisitions and builds the board after the opening deadline. Each call
    ///         pays queued claims, queues the items each row lacks against its target depth, then
    ///         fills and lists the queue and the held items, at most `MAX_OPEN_MINTS` in all
    ///         (`PoolListing.openBoard`). The pool becomes Live on the first call after which
    ///         `listedCount` is at least `minItems`, or which lists fewer than `MAX_OPEN_MINTS`
    ///         items. `open` stays callable while Opening. Once Live, the `Deep` settle trigger
    ///         lists the rest of the board.
    function open() external nonReentrant {
        _notExiting();
        if (lifecycle != Lifecycle.Opening) revert NotOpening();
        IFWAClone fwa = fwaPool;
        if (address(fwa) == address(0)) revert FwaPoolMissing();
        if (block.timestamp < _openingDeadlineAt) revert OpeningDeadlineNotReached();
        if (_read(address(fwa), IFWAClone.localPurchasesEnabled.selector, 0) == 0) {
            _call(address(fwa), IFWAClone.setBool.selector, FWAConfigKeys.ACQUISITIONS_ENABLED, 1);
        }
        _payClaims();
        if (_call(address(this), IPool.openBoard.selector, 0, 0) < MAX_OPEN_MINTS || listedCount >= minItems) {
            lifecycle = Lifecycle.Live;
            lastRotateAt = block.timestamp;
            _liveDay = uint32(block.timestamp / 1 days);
            _depositsOpenAt = uint64(block.timestamp + _founderWindowSeconds);
            emit Opened();
        }
    }

    /// @notice Deposits `msg.value` for shares at ordinary NAV, net of the entry contribution.
    function deposit() external payable nonReentrant {
        _notExiting();
        _sync();
        _deposit(msg.sender, msg.value, 0);
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
            _claimQueue.push(Claim(msg.sender, uint64(block.timestamp), remainder));
        }
        emit Withdrawn(msg.sender, shares, paidNow, remainder);
        if (paidNow != 0) SafeTransferLib.safeTransferETH(msg.sender, paidNow);
    }

    /// @notice Runs one rotation: settles, harvests, pays or liquidates for queued claims, lists the
    ///         queued replacements and held items while `settle` may not list, activates staged
    ///         FWA listings, runs the GRAIL step (mint and merge) and skips it with `GrailStepSkipped` when it reverts, then refunds the caller from
    ///         `maintenance`. Reverts `RotateTooSoon` until `rotateInterval` has passed since
    ///         `lastRotateAt` and `RotateNotDue` while `rotateDue` is `None`. `lastRotateAt` moves
    ///         when the rotation changed inventory. The refund is paid only when inventory
    ///         changed, once per `rotateInterval`.
    function rotate() external nonReentrant {
        _requireLive();
        uint256 gasStart = gasleft();
        if (block.timestamp < lastRotateAt + rotateInterval) revert RotateTooSoon();
        if (_rotateTrigger() == RotateTrigger.None) revert RotateNotDue();

        bool changed = _settleAndHarvest();
        uint256 claimsBefore = claims;
        bool inventoryChanged = _clearClaims();
        if (!_listingAllowed() && _listBatch(MAX_LIST_PER_ROTATE) != 0) inventoryChanged = true;
        bool busy = _busy();
        if (!busy) _call(address(fwaPool), IFWAClone.activateListings.selector, MAX_ACTIVATIONS, 0);
        if (!busy) {
            (bool ok, uint256 stepChanged, bytes4 sel) = _tryCall(address(this), IPool.grailStep.selector);
            if (!ok) emit GrailStepSkipped(sel);
            else if (stepChanged != 0) inventoryChanged = true;
        }
        if (inventoryChanged) lastRotateAt = block.timestamp;
        _refund(gasStart, changed || inventoryChanged || claims != claimsBefore, inventoryChanged);
    }

    /// @notice First reason `rotate` is due, in the order Claim, GrailStep, Held. `None`
    ///         when no reason holds, when `rotateInterval` has not passed since `lastRotateAt`, and
    ///         when the pool is not Live. `rotate` is callable exactly when this returns a value
    ///         other than `None`.
    function rotateDue() external view returns (RotateTrigger) {
        if (lifecycle != Lifecycle.Live || block.timestamp < lastRotateAt + rotateInterval) {
            return RotateTrigger.None;
        }
        return _rotateTrigger();
    }

    /// @notice Wei added to the gas cost in every `settle` and `rotate` refund.
    function tipWei() external view returns (uint256) {
        return _tipWei;
    }

    /// @notice First reason `settle` lists replacements: `Batch` when `batchMin` replacements are
    ///         queued, `Age` when the queue has been nonempty for `batchMaxAge`, `Thin` when the
    ///         listed items beyond the unsettled acquisitions are fewer than `concurrency +
    ///         THIN_MARGIN`, `Deep` when the listed, held and queued items are fewer than
    ///         `boardItems()` by at least `batchMin`. `None` when no reason holds, when a nonempty
    ///         queue cannot be filled (no held item and the head of the queue is unaffordable) and
    ///         when the pool is not Live.
    function settleDue() public view returns (SettleTrigger) {
        if (lifecycle != Lifecycle.Live) return SettleTrigger.None;
        uint256 queued = _replacementQueue.length - replacementHead;
        if (_listWork()) {
            if (queued >= _batchMin) return SettleTrigger.Batch;
            if (queued != 0 && block.timestamp >= _oldestQueuedAt + _batchMaxAge) return SettleTrigger.Age;
            if (listedCount < _unsettled() + _concurrency + THIN_MARGIN) return SettleTrigger.Thin;
        } else if (queued != 0) {
            return SettleTrigger.None;
        }
        if (listedCount + _held.length + queued + _batchMin <= _boardItems()) return SettleTrigger.Deep;
        return SettleTrigger.None;
    }

    /// @notice FWA `acquire` through the pool: opens one acquisition for `purchaser`, which must be
    ///         `msg.sender`. Equal to `acquireBatch` with `count` 1. Returns the request id.
    function acquire(
        address purchaser,
        uint256 maxAcquisitionFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps,
        uint256 expectedInventoryVersion,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 requestId) {
        if (purchaser != msg.sender) revert PurchaserMismatch();
        requestId = _acquire(
            purchaser,
            1,
            maxAcquisitionFee,
            minWeightedValue,
            maxNegativeSlippageBps,
            expectedInventoryVersion,
            deadline,
            msg.value
        )[0];
    }

    /// @notice FWA `acquireBatch` through the pool: opens `count` acquisitions for `purchaser`, which
    ///         must be `msg.sender`. The slippage, minimum weighted value, inventory version and
    ///         deadline arguments go to the FWA pool as given. Overpayment is refunded to the
    ///         caller. Books up to `SETTLE_BUDGET` FWA acquisitions, harvests and pays queued claims
    ///         from `cash`. Returns the request ids.
    function acquireBatch(
        address purchaser,
        uint256 count,
        uint256 maxAcquisitionFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps,
        uint256 expectedInventoryVersion,
        uint256 deadline
    ) external payable nonReentrant returns (uint256[] memory requestIds) {
        if (purchaser != msg.sender) revert PurchaserMismatch();
        requestIds = _acquire(
            purchaser,
            count,
            maxAcquisitionFee,
            minWeightedValue,
            maxNegativeSlippageBps,
            expectedInventoryVersion,
            deadline,
            msg.value
        );
    }

    /// @notice Takes the caller's Shapes `tokenIds` and applies their value and `msg.value` to an
    ///         `acquireBatch` of `count` with `minWeightedValue` 0 and the FWA pool's own
    ///         `selectionSlippageBps` and `inventoryVersion`. A Shape that matches a single rung mix
    ///         row stays in the pool as a held item, and `cash` pays for the part of the ticket it
    ///         covers. A Shape that does not match a row, or that `cash` above the reserve cannot
    ///         cover, is redeemed. Excess value returns to the caller. The caller must have
    ///         approved this contract for each token.
    function pullWithShapes(uint256[] calldata tokenIds, uint256 count, uint256 maxFee, uint256 deadline)
        external
        payable
        nonReentrant
    {
        _requireLive();
        (uint256 redeemed, Item[] memory kept, uint256 keptValue) = _intakeShapes(tokenIds);
        cash -= keptValue;
        _registerKept(kept);
        address fwa = address(fwaPool);
        _acquire(
            msg.sender,
            count,
            maxFee,
            0,
            _read(fwa, IFWAClone.selectionSlippageBps.selector, 0),
            _read(fwa, IFWAClone.inventoryVersion.selector, 0),
            deadline,
            msg.value + redeemed + keptValue
        );
    }

    /// @notice FWA price of `count` acquisitions: fee and VRF fee per acquisition and the total.
    function quoteAcquisitionPrice(uint256 count) external view returns (uint256 fee, uint256 vrf, uint256 total) {
        return fwaPool.quoteAcquisitionPrice(count);
    }

    /// @notice FWA price of one acquisition. Same ABI as the FWA pool's bare quote.
    function quoteAcquisitionPrice() external view returns (uint256 fee, uint256 vrf, uint256 total) {
        return fwaPool.quoteAcquisitionPrice();
    }

    /// @notice FWA purchase operator hook. True while this pool is inside its call to the FWA pool
    ///         and `wallet` is the purchaser of that call.
    function canPurchase(address wallet) external view returns (bool) {
        uint256 slot = PURCHASER_SLOT;
        uint256 purchaser;
        assembly ("memory-safe") {
            purchaser := tload(slot)
        }
        return purchaser != 0 && purchaser == uint160(wallet);
    }

    /// @notice Deposits the value of the caller's Shape `tokenId`. A Shape that matches a single
    ///         rung mix row stays in the pool as a held item, and the entry contribution comes from
    ///         `cash`. Any other Shape is redeemed and the proceeds are deposited. The caller must
    ///         have approved this contract for the token.
    function redeemAndDeposit(uint256 tokenId) external nonReentrant {
        _notExiting();
        _sync();
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        (uint256 redeemed, Item[] memory kept, uint256 keptValue) = _intakeShapes(ids);
        _deposit(msg.sender, redeemed + keptValue, keptValue);
        _registerKept(kept);
    }

    /// @notice Processes up to `maxCount` FWA acquisitions, books their results, harvests and
    ///         activates staged FWA listings. When `settleDue` is not `None`, it lists at most
    ///         `MAX_LIST_PER_SETTLE` items from the replacement queue and the held items while
    ///         listing is allowed, after `Deep` first queues the items each row lacks against its
    ///         target depth (`PoolListing.queueMissing`, at most `MAX_LIST_PER_SETTLE` queued), then applies the GRAIL decay
    ///         (`PoolListing.grailReprice`) while FWA holds no unsettled acquisition and the
    ///         booking walk is level. A due call that listed an item or repriced a GRAIL item
    ///         refunds the caller `(gasUsed + ROTATE_GAS_OVERHEAD) *
    ///         basefee + tipWei` from `maintenance`, capped by the bucket. Listing is allowed
    ///         while the factory's `inventoryChangeCooldown` is zero or `listWhilePaused` is set.
    function settle(uint256 maxCount) external nonReentrant {
        uint256 gasStart = gasleft();
        if (address(fwaPool) == address(0)) revert FwaPoolMissing();
        _processAndSettle(maxCount < MAX_SETTLE_ITEMS ? maxCount : MAX_SETTLE_ITEMS);
        _harvest();
        bool busy = _busy();
        if (!busy) _call(address(fwaPool), IFWAClone.activateListings.selector, MAX_ACTIVATIONS, 0);
        uint256 listed;
        uint256 refund;
        SettleTrigger due = settleDue();
        if (due != SettleTrigger.None && _listingAllowed()) {
            if (due == SettleTrigger.Deep) _call(address(this), IPool.queueMissing.selector, MAX_LIST_PER_SETTLE, 0);
            listed = _listBatch(MAX_LIST_PER_SETTLE);
            bool repriced = !busy && _call(address(this), IPool.grailReprice.selector, 0, 0) != 0;
            if (listed != 0 || repriced) refund = _chargeRefund(gasStart);
        }
        emit Settled(listed, refund);
        if (refund != 0) SafeTransferLib.safeTransferETH(msg.sender, refund);
    }

    /// @notice Pays queued claims from `cash` in request order, at most `MAX_CLAIM_ITEMS` entries.
    ///         Callable in every lifecycle state, so claims left after an export are payable.
    function payClaims() external nonReentrant {
        _payClaims();
    }

    /// @notice Adds `msg.value` to `maintenance`. Anyone may call it; the operator tops the bucket
    ///         up from Shapes mint fee revenue when the basefee outruns the maintenance inflow.
    function fundMaintenance() external payable {
        if (msg.value == 0) revert ZeroAmount();
        maintenance += msg.value;
        emit MaintenanceFunded(msg.sender, msg.value);
    }

    /// @notice Adds `msg.value` to the GRAIL fund. Anyone may call it.
    function fundGrail() external payable {
        if (msg.value == 0) revert ZeroAmount();
        _grail.fund += msg.value;
        emit GrailFunded(msg.sender, msg.value);
    }

    /// @notice Accepts ETH from Shapes redemptions and FWA proceeds. The ETH is booked by the
    ///         function that triggered the transfer.
    receive() external payable {}

    /// @notice Accepts Shapes and Draw Packs from mints and FWA listing withdrawals. The calling
    ///         function books the token.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @notice Delegates `listBatch`, `openBoard`, `queueMissing`, `grailStep`, `grailReprice`, `grailReady`,
    ///         `setGrail`, `setGrailStep`, `setGrailTarget`, `grail`, `grailItems` and `boardItems` to `listingModule` and every other call to
    ///         `adminModule`, and returns the module's return data or revert data.
    fallback() external payable {
        address module = adminModule;
        bytes4 sig = msg.sig;
        if (
            sig == IPool.listBatch.selector || sig == IPool.openBoard.selector || sig == IPool.queueMissing.selector
                || sig == IPool.grailStep.selector
                || sig == IPool.grailReprice.selector || sig == IPool.grailReady.selector
                || sig == IPool.setGrail.selector || sig == IPool.setGrailStep.selector
                || sig == IPool.setGrailTarget.selector
                || sig == IPool.grail.selector || sig == IPool.grailItems.selector
                || sig == IPool.boardItems.selector
        ) module = listingModule;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), module, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    // ------------------------------------------------------------------ internal

    /// @dev Lists up to `max` items through `PoolListing.listBatch`. Returns the number listed.
    function _listBatch(uint256 max) internal returns (uint256) {
        return _call(address(this), IPool.listBatch.selector, max, 0);
    }

    /// @dev Reads the row choice from `PoolAdmin.chooseRow`, which holds the sampling code.
    function _chooseRow(uint256 requestId, uint256 capturedRow)
        internal
        view
        override
        returns (uint256, bool)
    {
        return IPool(address(this)).chooseRow(requestId, capturedRow);
    }

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

    /// @notice Ordinary NAV below which deposits are admitted:
    ///         `max(navCapFloor, dailyVolume() * 10_000 / turnoverBps)`.
    function navCap() public view returns (uint256) {
        return _navCap(_dailyVolume());
    }

    /// @notice Mean booked FWA acquisition fees per day over the complete UTC days since the pool
    ///         went Live, at most seven. Today's partial day is excluded.
    function dailyVolume() external view returns (uint256) {
        return _dailyVolume();
    }

    function turnoverBps() external view returns (uint16) {
        return _turnoverBps;
    }

    function founderWindowSeconds() external view returns (uint32) {
        return _founderWindowSeconds;
    }

    /// @notice Timestamp from which deposits are admitted while Live. Zero before `open()`.
    function depositsOpenAt() external view returns (uint64) {
        return _depositsOpenAt;
    }

    function _navCap(uint256 volume) internal view returns (uint256) {
        uint256 dynamic = volume * BPS / _turnoverBps;
        return dynamic > navCapFloor ? dynamic : navCapFloor;
    }

    /// @dev Share of a deposit made at ordinary NAV `currentNav` that goes to the GRAIL fund.
    function _entryFeeBps(uint256 currentNav, uint256 volume) internal view returns (uint256) {
        EntryFee memory f = entryFee;
        return PricingLib.entryFeeBps(feeSplit.premiumBps, volume, currentNav, f.floorBps, f.capBps, f.paybackDays);
    }

    /// @dev Mints shares to `to` for `value`. The entry contribution goes to the GRAIL buckets,
    ///      split by `minorShareBps`. Reverts `DepositsClosed` while Live before `depositsOpenAt`
    ///      and `NavCapReached` at or above `navCap()`. Shares are priced on NAV before the
    ///      deposit. `keptValue` is the part of `value` that arrived as held Shapes: `cash` is
    ///      reduced by it, so `cash` changes by `net - keptValue`.
    function _deposit(address to, uint256 value, uint256 keptValue) internal {
        _notImporting();
        if (depositsPaused) revert DepositsPaused();
        if (value == 0) revert ZeroAmount();
        uint256 currentNav = nav();
        if (currentNav == 0 && totalShares != 0) revert NavZero();
        if (lifecycle == Lifecycle.Live && block.timestamp < _depositsOpenAt) revert DepositsClosed();
        uint256 volume = _dailyVolume();
        if (currentNav >= _navCap(volume)) revert NavCapReached();

        uint256 contribution = PricingLib.entryContribution(value, _entryFeeBps(currentNav, volume));
        uint256 net = value - contribution;
        uint256 shares = PricingLib.sharesFor(net, currentNav, totalShares);
        if (shares == 0) revert ZeroShares();

        _grail.fund += contribution;
        cash = cash + net - keptValue;
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
        uint256 pending = _claimQueue.length - head;
        uint256 limit = pending < MAX_CLAIM_ITEMS ? pending : MAX_CLAIM_ITEMS;
        address[] memory recipients = new address[](limit);
        uint256[] memory payouts = new uint256[](limit);
        uint256 available = cash;
        uint256 paidTotal;
        uint256 paidCount;
        while (paidCount < limit && available != 0) {
            Claim storage c = _claimQueue[head];
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

    /// @dev Pays the caller `min(maintenance, gas cost + tipWei)` when the rotation changed
    ///      inventory and `rotateInterval` has passed since `lastRefundAt`. The transfer is the
    ///      last step.
    function _refund(uint256 gasStart, bool changed, bool inventoryChanged) internal {
        uint256 refund;
        if (inventoryChanged && block.timestamp >= _lastRefundAt + rotateInterval) {
            _lastRefundAt = block.timestamp;
            refund = _chargeRefund(gasStart);
        }
        emit Rotated(changed, inventoryChanged, refund);
        if (refund != 0) SafeTransferLib.safeTransferETH(msg.sender, refund);
    }

    /// @dev Deducts `min(maintenance, (gas used + ROTATE_GAS_OVERHEAD) * basefee + tipWei)` from
    ///      `maintenance` and returns it. The caller pays it out.
    function _chargeRefund(uint256 gasStart) internal returns (uint256 refund) {
        uint256 bucket = maintenance;
        uint256 cost = (gasStart - gasleft() + ROTATE_GAS_OVERHEAD) * block.basefee + _tipWei;
        refund = cost < bucket ? cost : bucket;
        maintenance = bucket - refund;
    }

    /// @dev Redeems up to `maxItems` ordinary items while `cash` is below the head claim, if the
    ///      head claim is at least `rotateInterval` old. Held items go first and need no FWA call.
    ///      Listed items follow, each the last listed item of the row most over its share. They are
    ///      skipped while FWA holds unsettled acquisitions, which lock withdrawals, and while the
    ///      booking walk is behind FWA's processing queue, which leaves captured listings in
    ///      `_listed`. Stops when the head claim does not exceed the re-mint cost of the next
    ///      item. Returns whether an item was redeemed.
    function _liquidateForClaims(uint256 maxItems) internal returns (bool redeemed) {
        uint256 head = claimHead;
        if (head == _claimQueue.length || block.timestamp < _claimQueue[head].requestedAt + rotateInterval) {
            return false;
        }
        if (_held.length == 0 && listedCount == 0) return false;
        uint256 mintFee = _mintFee();
        bool locked = listedCount != 0 && _busy();
        for (uint256 n; n < maxItems && cash < _claimQueue[head].amount; ++n) {
            if (!_liquidateOne(head, mintFee, locked)) break;
            redeemed = true;
        }
    }

    /// @dev Redeems the last held item, or else the last listed item of the most overweight row,
    ///      into `cash` and deducts the re-mint cost of its row (`fee`, the mint fees of its Shapes)
    ///      from the claim at `head`. The deducted ETH stays in `cash` to fund the re-mint of the row
    ///      for the remaining holders. Returns false and changes nothing when there is no item to
    ///      redeem or the claim does not exceed the fee.
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
        Claim storage c = _claimQueue[head];
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

    /// @dev Opens `count` FWA acquisitions for `purchaser` with `value` wei available. `value` is
    ///      already in the pool balance and outside every bucket. The slippage, minimum weighted
    ///      value, inventory version and deadline arguments go to the FWA pool unchanged. The
    ///      purchaser is held in transient storage during the FWA call, which is when `canPurchase`
    ///      answers true for it.
    function _acquire(
        address purchaser,
        uint256 count,
        uint256 maxFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps,
        uint256 expectedInventoryVersion,
        uint256 deadline,
        uint256 value
    ) internal returns (uint256[] memory ids) {
        _requireLive();
        if (pullsPaused) revert PullsPaused();
        if (count == 0 || count > _maxBatch) revert InvalidCount();
        _requirePurchasable(value);

        IFWAClone fwa = fwaPool;
        (uint256 fee, uint256 total) = _quote(count);
        if (fee > maxFee) revert FeeAboveMax(fee, maxFee);
        if (value < total) revert InsufficientValue(value, total);

        uint256 slot = PURCHASER_SLOT;
        assembly ("memory-safe") {
            tstore(slot, purchaser)
        }
        ids = fwa.acquireBatch{value: total}(
            purchaser, count, maxFee, minWeightedValue, maxNegativeSlippageBps, expectedInventoryVersion, deadline
        );
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
        _recordBases(fwa, fee, ids);
        emit Pulled(purchaser, count, fee, ids);

        _upkeep();
        if (value > total) SafeTransferLib.safeTransferETH(purchaser, value - total);
    }

    /// @dev Transfers `tokenIds` from the caller. A Shape whose backing equals a single rung mix row
    ///      is kept while the running total of kept value stays within `_spendable()`, and every
    ///      other Shape is redeemed. Returns the ETH redeemed, the kept Shapes as unregistered
    ///      held items (`_registerKept` books them) and their total value.
    function _intakeShapes(uint256[] memory tokenIds)
        internal
        returns (uint256 redeemed, Item[] memory kept, uint256 keptValue)
    {
        uint256 n = tokenIds.length;
        kept = new Item[](n);
        uint256[] memory sold = new uint256[](n);
        uint256 keptCount;
        uint256 soldCount;
        uint256 budget = _spendable();
        for (uint256 i; i < n; ++i) {
            uint256 id = tokenIds[i];
            _transfer(shapes, msg.sender, address(this), id);
            uint256 value = _read(shapes, IShapes.backingOf.selector, id);
            uint256 row = _shapeRow(value);
            if (row != type(uint256).max && value <= budget) {
                budget -= value;
                keptValue += value;
                kept[keptCount++] = Item(shapes, uint16(row), id, value, 0);
            } else {
                sold[soldCount++] = id;
            }
        }
        assembly ("memory-safe") {
            mstore(kept, keptCount)
            mstore(sold, soldCount)
        }
        if (soldCount != 0) redeemed = IShapes(shapes).redeemBatch(sold);
    }

    /// @dev Books the items returned by `_intakeShapes` as held.
    function _registerKept(Item[] memory kept) internal {
        for (uint256 i; i < kept.length; ++i) {
            _addItem(kept[i]);
        }
    }

    /// @dev First one rung mix row whose backing is `value`, or `type(uint256).max`.
    function _shapeRow(uint256 value) internal view returns (uint256 row) {
        for (; row < _mix.length; ++row) {
            if (_rowBackingWei[row] == value && _mix[row].rungs.length == 1) return row;
        }
        return type(uint256).max;
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

    /// @dev Per-pull upkeep: books up to `SETTLE_BUDGET` acquisitions, harvests and pays queued
    ///      claims from `cash`. A listing inside a purchase would restart FWA's inventory change
    ///      cooldown, so replacements are listed by `settle` and `rotate`.
    function _upkeep() internal {
        _processAndSettle(SETTLE_BUDGET);
        _harvest();
        _payClaims();
    }

    /// @dev Reverts unless a pull may open: the FWA cooldown has passed, the balance covers the
    ///      buckets plus the `incoming` wei still outside them, and the listed ordinary items exceed
    ///      the unsettled acquisitions by `concurrency`.
    function _requirePurchasable(uint256 incoming) internal view {
        IFWAClone fwa = fwaPool;
        if (block.timestamp < _read(address(fwa), IFWAClone.purchasesResumeAt.selector, 0)) {
            revert PurchasesCoolingDown();
        }
        if (!_covered(incoming)) revert Insolvent();
        if (listedCount < _unsettled() + _concurrency) revert BoardTooThin();
    }

    /// @dev First reason `rotate` is due. The spacing since `lastRotateAt` is checked by the
    ///      callers. Claim: the head claim is at least `rotateInterval` old. GrailStep: FWA is not
    ///      busy and `PoolListing.grailReady` holds (the fund covers a piece and the caps allow it,
    ///      a recipe's inputs are listed, or a GRAIL item is unlisted). Held: `settle` may not list and a
    ///      replacement or held item can be listed.
    function _rotateTrigger() internal view returns (RotateTrigger) {
        uint256 head = claimHead;
        if (head < _claimQueue.length && block.timestamp >= _claimQueue[head].requestedAt + rotateInterval) {
            return RotateTrigger.Claim;
        }
        if (!_busy() && IPool(address(this)).grailReady()) return RotateTrigger.GrailStep;
        if (!_listingAllowed() && _listWork()) return RotateTrigger.Held;
        return RotateTrigger.None;
    }

    /// @dev True when `settle` may list: FWA's `inventoryChangeCooldown` is zero or `listWhilePaused`
    ///      is set.
    function _listingAllowed() internal view returns (bool) {
        return _listWhilePaused || _read(fwaFactory, IFWACloneFactory.inventoryChangeCooldown.selector, 0) == 0;
    }

    /// @dev True when a held item exists or the cash above the reserve covers the full cost of the
    ///      queue head.
    function _listWork() internal view returns (bool) {
        if (_held.length != 0) return true;
        uint256 head = replacementHead;
        return head < _replacementQueue.length
            && _spendable() >= _rowCost(_replacementQueue[head], _mintFee());
    }

    /// @dev Row backing plus the mint fee of every Shape the row mints.
    function _rowCost(uint256 row, uint256 fee) internal view returns (uint256) {
        return _rowBackingWei[row] + fee * _mix[row].rungs.length;
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
}
