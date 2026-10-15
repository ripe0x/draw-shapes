// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {Denominations} from "shapes/lib/Denominations.sol";
import {PricingLib} from "./lib/PricingLib.sol";
import {IFWAClone} from "./interfaces/IFWAClone.sol";
import {IPoolTypes} from "./interfaces/IPool.sol";

/// @title PoolStorage
/// @notice Storage layout, constants and internal helpers shared by `Pool`, `PoolAdmin` and
///         `PoolListing`.
/// @dev `PoolAdmin` and `PoolListing` run by delegatecall from the `fallback` of `Pool`, so the
///      three contracts inherit this layout and the reentrancy guard slot.
abstract contract PoolStorage is IPoolTypes, ReentrancyGuard {
    // ------------------------------------------------------------------ constants

    uint256 internal constant BPS = 10_000;
    /// @dev Backing of one GRAIL piece, 100 ladder units.
    uint256 internal constant GRAIL_PIECE = 100 * Denominations.UNIT;
    /// @dev Smallest GRAIL target, 500 ladder units. Bounds `floorWei` with `listBps`.
    uint256 internal constant GRAIL_MIN_TARGET = 500 * Denominations.UNIT;
    uint256 internal constant MAX_BUILDING_ITEMS = 16;
    uint256 internal constant MAX_DONE_ITEMS = 32;
    uint256 internal constant MAX_PIECES = 6;
    uint256 internal constant MAX_FEE_SPLIT_BPS = 1_000;
    uint256 internal constant VOLUME_DAYS = 7;
    uint256 internal constant MAX_SETTLE_ITEMS = 20;
    uint256 internal constant MAX_OPEN_MINTS = 20;
    uint256 internal constant MAX_TIP = 0.01 ether;
    uint256 internal constant MAX_RESTORE_K = 100;
    uint256 internal constant MAX_BAND_BPS = 100_000;
    /// @dev Cap on `_foreign` entries.
    uint256 internal constant MAX_FOREIGN = 8;
    /// @dev Gas forwarded to `IForeignController.onForeignCapture`.
    uint256 internal constant FOREIGN_CALL_GAS = 200_000;

    // ------------------------------------------------------------------ storage

    address public shapes;
    address public drawPacks;
    address public fwaFactory;
    /// @notice Pool this one succeeds, or zero. Only `oldPool` may call the import functions.
    address public oldPool;

    address public admin;
    Lifecycle public lifecycle;
    bool public pullsPaused;
    bool public depositsPaused;
    bool internal importFinalized;

    uint256 public cash;
    uint256 public backing;
    uint256 public receivable;
    uint256 public claims;
    uint256 public maintenance;
    /// @dev Maintenance share of booked margin, still held as FWA owner proceeds.
    uint256 internal _maintenanceReceivable;
    Grail internal _grail;
    /// @dev GRAIL items owned by the pool, listed or not. At most `MAX_BUILDING_ITEMS` not done and `MAX_DONE_ITEMS` done.
    GrailItem[] internal _grailItems;
    /// @dev Position plus one of each listed GRAIL item inside `_grailItems`, by FWA listing id.
    mapping(uint256 listingId => uint256) internal _grailAt;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    Claim[] internal _claimQueue;
    uint256 public claimHead;

    PricingLib.MixRow[] internal _mix;
    FeeSplit public feeSplit;
    EntryFee public entryFee;
    /// @notice Lower bound of `navCap()`: deposits are admitted while ordinary NAV is below it.
    uint256 public navCapFloor;
    uint256 public rotateInterval;
    /// @dev Duration in seconds from FWA pool creation to the earliest `open()`.
    uint256 internal _openingDeadline;
    uint256 internal _openingDeadlineAt;
    uint256 public minItems;
    uint256 internal _grailProbCapBps;
    /// @dev Queued replacements at which `settleDue` returns `Batch`. At least one.
    uint256 internal _batchMin;
    /// @dev Seconds since the queue became nonempty after which `settleDue` returns `Age`.
    uint256 internal _batchMaxAge;
    /// @dev Probability, in bps, that a replacement draw takes the surprise step.
    uint256 internal _surpriseBps;
    /// @dev Multiplier of a row's relative deficit in its replacement draw weight.
    uint256 internal _restoreK;
    /// @dev Headroom above its target, in bps, up to which a row may be chosen as a replacement.
    uint256 internal _bandBps;
    /// @dev Share of ordinary NAV, in bps, that cash must keep after a mint or a kept Shape.
    uint256 internal _reserveBps;
    /// @dev When true `settle` lists while FWA's inventory change cooldown is nonzero.
    bool internal _listWhilePaused;
    /// @dev Wei added to the gas cost in every `settle` and `rotate` refund.
    uint256 internal _tipWei;

    IFWAClone public fwaPool;
    uint256 internal _maxBatch;
    uint256 internal _concurrency;

    /// @dev Backing of one token of each row, indexed like `_mix`.
    uint256[] internal _rowBackingWei;
    /// @dev Listed plus held ordinary items per row.
    uint256[] internal _rowCount;
    /// @dev Queued replacements per row.
    uint256[] internal _queuedByRow;
    mapping(uint256 listingId => Item) internal _listed;
    /// @dev Held ordinary items: unlisted Shapes and Draw Packs counted in `backing`.
    Item[] internal _held;
    /// @dev Position plus one of each held token inside `_held`.
    mapping(address collection => mapping(uint256 tokenId => uint256)) internal _heldPos;
    /// @dev Token ids of held Shapes by ladder index.
    mapping(uint8 denom => uint256[]) internal _heldByDenom;
    /// @dev Position of each held Shape inside `_heldByDenom[denom]`.
    mapping(uint256 tokenId => uint256) internal _denomPos;
    /// @dev Held Draw Packs.
    uint256 internal _heldPacks;

    /// @dev FIFO of row indices awaiting a replacement listing.
    uint16[] internal _replacementQueue;
    uint256 public replacementHead;
    /// @dev Time the queue last went from empty to nonempty, zero while it is empty.
    uint256 internal _oldestQueuedAt;

    /// @dev `base + 1` of each request id opened by `acquire` or `acquireBatch`, where `base` is the
    ///      FWA base price at request time. Zero marks a request opened directly at the FWA pool.
    mapping(uint256 requestId => uint256) internal _basePlusOne;
    /// @notice First FWA acquisition sequence the pool has not yet booked.
    uint64 public nextSequenceToBook;
    /// @dev Booked proceeds minus captured backing, netted across captures. Positive margin is
    ///         split at once, negative margin carries forward.
    int256 internal _margin;
    /// @dev Replacement mint fees of captured items, covered by margin before it is split.
    uint256 internal _mintLineOwed;
    /// @notice Listed ordinary items.
    uint256 public listedCount;
    /// @notice Timestamp of the last `rotate` that changed inventory, or of `open()` going Live.
    uint256 public lastRotateAt;
    /// @dev Timestamp of the last `rotate` that paid a refund.
    uint256 internal _lastRefundAt;
    /// @dev FWA listing ids of listed ordinary items, by row.
    uint256[][] internal _listedByRow;
    /// @dev Position of each listing id inside its row's `_listedByRow` array.
    mapping(uint256 listingId => uint256) internal _listedIndex;

    /// @notice Destination of the export: this pool for retirement, a successor for migration.
    address public exitDest;
    /// @dev Share supply at export.
    uint256 internal _exportedShares;
    /// @dev Ordinary NAV plus maintenance at export, including items already moved to the
    ///         successor.
    uint256 internal _exportedNav;
    /// @notice Successor side: NAV received from `oldPool`, and the shares minted against it.
    uint256 public importedNav;
    uint256 internal _importedShares;
    /// @dev Successor side: share supply of `oldPool` at its export, set by `finalizeImport`.
    uint256 internal _importedFromShares;
    /// @dev Successor side: holders whose `oldPool` shares were converted by `migrateHolder`.
    mapping(address holder => bool) internal _migrated;
    /// @dev True while the token is a held or listed ordinary item or a GRAIL item of this pool.
    mapping(address collection => mapping(uint256 tokenId => bool)) internal _registered;

    /// @dev FWA acquisition fees of booked captures, per UTC day in slot `day % 8`. A slot holds
    ///      the day in `_dailyFeesDay` and reads as zero for any other day.
    uint128[8] internal _dailyFees;
    uint32[8] internal _dailyFeesDay;
    /// @dev Target daily fee volume over NAV, in bps. Sets the volume term of `navCap()`.
    uint16 internal _turnoverBps;
    /// @dev UTC day index of the Opening to Live transition.
    uint32 internal _liveDay;
    /// @dev Seconds after the Opening to Live transition during which deposits revert.
    uint32 internal _founderWindowSeconds;
    /// @dev Timestamp from which `deposit` is admitted while Live.
    uint64 internal _depositsOpenAt;
    /// @dev Sums over the mix rows, set by `_setMix`: `shareBps * rowBacking`, `shareBps * rungs`
    ///      and `shareBps`. The mean cost of a row is `(_mixBacking + mintFee * _mixRungs) / _mixShares`.
    uint256 internal _mixBacking;
    uint256 internal _mixRungs;
    uint256 internal _mixShares;

    /// @dev Foreign listings, at most `MAX_FOREIGN`. Outside `backing`, ordinary NAV and the GRAIL fund.
    ForeignListing[] internal _foreign;
    /// @dev Position plus one of each foreign listing inside `_foreign`, by FWA listing id.
    mapping(uint256 listingId => uint256) internal _foreignAt;
    /// @dev Proceeds of captured foreign listings awaiting the next harvest.
    ForeignDue[] internal _foreignDue;
    /// @dev Sum of `proceeds` over `_foreignDue`. Part of the booked receivables, held as FWA owner
    ///      proceeds until harvest pays it to the controllers.
    uint256 internal _foreignReceivable;
    /// @dev Controller of a foreign token whose release in `exportStep` failed, by collection and token id.
    ///      `sweep` sends such a token to that controller.
    mapping(address collection => mapping(uint256 tokenId => address)) internal _heldFor;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @dev Reverts `NotAdmin` for any other caller and logs the setter selector.
    function _admin() internal {
        if (msg.sender != admin) revert NotAdmin();
        emit ParamSet(msg.sig);
    }

    // ------------------------------------------------------------------ views

    /// @notice Ordinary NAV: `cash + backing + receivable - claims`, or zero when `claims` exceed
    ///         the assets.
    function nav() public view returns (uint256) {
        uint256 assets = cash + backing + receivable;
        return assets > claims ? assets - claims : 0;
    }

    // ------------------------------------------------------------------ internal

    /// @dev Mean booked fee volume per day over the complete UTC days after the Live day and
    ///      before today, at most `VOLUME_DAYS` of them. The Live day and today are partial days.
    function _dailyVolume() internal view returns (uint256 sum) {
        uint256 today = block.timestamp / 1 days;
        uint256 live = _liveDay;
        if (today <= live + 1) return 0;
        uint256 n = today - live - 1;
        if (n > VOLUME_DAYS) n = VOLUME_DAYS;
        for (uint256 i = 1; i <= n; ++i) {
            uint256 day = today - i;
            if (_dailyFeesDay[day % 8] == day) sum += _dailyFees[day % 8];
        }
        sum /= n;
    }

    /// @dev Adds `fees` to today's slot, resetting the slot first when it holds an older day. Each
    ///      amount is an ETH sum below 2^128.
    function _recordFees(uint256 fees) internal {
        uint256 day = block.timestamp / 1 days;
        uint256 slot = day % 8;
        if (_dailyFeesDay[slot] != day) {
            _dailyFeesDay[slot] = uint32(day);
            _dailyFees[slot] = 0;
        }
        _dailyFees[slot] += SafeCastLib.toUint128(fees);
    }

    /// @dev Reverts `PoolExiting` from `Exiting` on.
    function _notExiting() internal view {
        if (lifecycle >= Lifecycle.Exiting) revert PoolExiting();
    }

    /// @dev I1 with `incoming` wei of the balance still outside the buckets.
    function _covered(uint256 incoming) internal view returns (bool) {
        return address(this).balance >= incoming + cash + maintenance + _grail.fund;
    }

    /// @dev Last listing id of `row`.
    function _lastListed(uint256 row) internal view returns (uint256) {
        uint256[] storage ids = _listedByRow[row];
        return ids[ids.length - 1];
    }

    /// @dev Withdraws FWA listing `listingId`; the token goes to `to`.
    function _withdrawListing(uint256 listingId, address to) internal {
        _call(address(fwaPool), IFWAClone.withdrawListingTo.selector, listingId, uint160(to));
    }

    /// @dev Redeems ordinary item `it`, which this contract owns, at its collection into `cash`.
    function _redeemItem(Item memory it) internal {
        uint256 balanceBefore = address(this).balance;
        _call(it.collection, IShapes.redeem.selector, it.tokenId, 0);
        if (address(this).balance - balanceBefore != it.value) revert RedeemMismatch();
        cash += it.value;
    }

    /// @dev ERC-721 `transferFrom` of `tokenId` of `collection`.
    function _transfer(address collection, address from, address to, uint256 tokenId) internal {
        _callFull(collection, 0, IERC721.transferFrom.selector, uint160(from), uint160(to), tokenId);
    }

    /// @dev Appends GRAIL item `it` to `_grailItems` and registers its token. A nonzero
    ///      `it.listingId` is indexed in `_grailAt`. The caller checks
    ///      `_grailFull(it.done)`.
    function _addGrailItem(GrailItem memory it) internal {
        _grailItems.push(it);
        if (it.listingId != 0) _grailAt[it.listingId] = _grailItems.length;
        _registered[it.collection][it.tokenId] = true;
    }

    /// @dev True when the number of GRAIL items whose `done` flag equals `done` has reached the
    ///      cap of that kind.
    function _grailFull(bool done) internal view returns (bool) {
        uint256 n;
        for (uint256 i; i < _grailItems.length; ++i) {
            if (_grailItems[i].done == done) ++n;
        }
        return n >= (done ? MAX_DONE_ITEMS : MAX_BUILDING_ITEMS);
    }

    /// @dev Removes the GRAIL item at `index` from `_grailItems`, `_grailAt` and `_registered`.
    function _removeGrailItem(uint256 index) internal returns (GrailItem memory it) {
        uint256 last = _grailItems.length - 1;
        it = _grailItems[index];
        if (index != last) {
            GrailItem memory moved = _grailItems[last];
            _grailItems[index] = moved;
            if (moved.listingId != 0) _grailAt[moved.listingId] = index + 1;
        }
        _grailItems.pop();
        delete _grailAt[it.listingId];
        delete _registered[it.collection][it.tokenId];
    }

    /// @dev Reverts `InsufficientGas` unless the remaining gas funds a call that forwards
    ///      `FOREIGN_CALL_GAS` after the 63/64 rule, plus 20,000 for the code that follows it.
    function _requireCallGas() internal view {
        if (gasleft() < FOREIGN_CALL_GAS * 64 / 63 + 20_000) revert InsufficientGas();
    }

    /// @dev Removes the foreign listing at `index` from `_foreign`, `_foreignAt` and `_registered`.
    function _removeForeign(uint256 index) internal returns (ForeignListing memory f) {
        uint256 last = _foreign.length - 1;
        f = _foreign[index];
        if (index != last) {
            ForeignListing memory moved = _foreign[last];
            _foreign[index] = moved;
            _foreignAt[moved.listingId] = index + 1;
        }
        _foreign.pop();
        delete _foreignAt[f.listingId];
        delete _registered[f.collection][f.tokenId];
    }

    /// @dev Removes the foreign listing at `index`, withdraws its FWA listing when it is listed and
    ///      transfers the token to `to`. FWA rejects the withdrawal while it holds unsettled acquisitions.
    function _releaseForeign(uint256 index, address to) internal {
        ForeignListing memory f = _removeForeign(index);
        if (f.notional != 0) _withdrawListing(f.listingId, address(this));
        _transfer(f.collection, address(this), to, f.tokenId);
        emit ForeignWithdrawn(f.listingId, f.collection, f.tokenId, to);
    }

    /// @dev Books `it` as held (`listingId == 0`) or listed. Every registry change goes through
    ///      `_addItem` and `_removeHeld` / `_removeListed`, which keep `backing` equal to the sum
    ///      of `value` over held and listed items (I2), `_rowCount` equal to their number,
    ///      `_listedByRow` equal to the listing ids of the listed items, `_heldByDenom` equal to the
    ///      held Shapes and `registered` true exactly for their tokens.
    function _addItem(Item memory it) internal {
        if (it.listingId == 0) {
            _held.push(it);
            _heldPos[it.collection][it.tokenId] = _held.length;
            if (it.collection == shapes) {
                uint256[] storage ids = _heldByDenom[uint8(Denominations.requireIndexOf(it.value))];
                ids.push(it.tokenId);
                _denomPos[it.tokenId] = ids.length;
            } else {
                ++_heldPacks;
            }
        } else {
            _listed[it.listingId] = it;
            ++listedCount;
            uint256[] storage ids = _listedByRow[it.row];
            _listedIndex[it.listingId] = ids.length;
            ids.push(it.listingId);
        }
        _registered[it.collection][it.tokenId] = true;
        backing += it.value;
        ++_rowCount[it.row];
    }

    function _removeHeld(uint256 index) internal returns (Item memory it) {
        uint256 last = _held.length - 1;
        it = _held[index];
        if (index != last) {
            Item memory moved = _held[last];
            _held[index] = moved;
            _heldPos[moved.collection][moved.tokenId] = index + 1;
        }
        _held.pop();
        delete _heldPos[it.collection][it.tokenId];
        if (it.collection == shapes) {
            uint256[] storage ids = _heldByDenom[uint8(Denominations.requireIndexOf(it.value))];
            uint256 pos = _denomPos[it.tokenId] - 1;
            uint256 lastId = ids[ids.length - 1];
            ids[pos] = lastId;
            _denomPos[lastId] = pos + 1;
            ids.pop();
            delete _denomPos[it.tokenId];
        } else {
            --_heldPacks;
        }
        delete _registered[it.collection][it.tokenId];
        backing -= it.value;
        --_rowCount[it.row];
    }

    function _removeListed(uint256 listingId) internal returns (Item memory it) {
        it = _listed[listingId];
        if (it.value == 0) revert UnknownListing(listingId);
        delete _listed[listingId];
        uint256[] storage ids = _listedByRow[it.row];
        uint256 lastId = ids[ids.length - 1];
        uint256 index = _listedIndex[listingId];
        ids[index] = lastId;
        _listedIndex[lastId] = index;
        ids.pop();
        delete _registered[it.collection][it.tokenId];
        backing -= it.value;
        --_rowCount[it.row];
        --listedCount;
    }

    /// @dev Static call of `selector` on `target` with the word argument `a`. The calldata is 36
    ///      bytes: solc-compiled targets ignore arguments a getter does not read. Returns the first
    ///      word of the return data. Reverts with the target's revert data and when the target
    ///      returns less than one word, which includes a target without code.
    function _read(address target, bytes4 selector, uint256 a) internal view returns (uint256 r) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), a)
            if iszero(staticcall(gas(), target, m, 0x24, 0, 0x20)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            if lt(returndatasize(), 0x20) { revert(0, 0) }
            r := mload(0)
        }
    }

    /// @dev Calls `selector` on `target` with the word arguments `a` and `b` and no value. The
    ///      calldata is 68 bytes: solc-compiled targets ignore arguments a function does not read.
    ///      Returns the first word of the return data, zero when there is none. Reverts with the
    ///      target's revert data and when the target has no code.
    function _call(address target, bytes4 selector, uint256 a, uint256 b) internal returns (uint256 r) {
        assembly ("memory-safe") {
            if iszero(extcodesize(target)) { revert(0, 0) }
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), a)
            mstore(add(m, 0x24), b)
            mstore(0, 0)
            if iszero(call(gas(), target, 0, m, 0x44, 0, 0x20)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            r := mload(0)
        }
    }

    /// @dev `_call` that returns the failure instead of reverting. On failure `r` is zero, `ok` is false
    ///      and `sel` holds the first four bytes of the revert data (zero when empty). The callee's
    ///      state changes are rolled back.
    function _tryCall(address target, bytes4 selector) internal returns (bool ok, uint256 r, bytes4 sel) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(0, 0)
            ok := call(gas(), target, 0, m, 0x04, 0, 0x20)
            switch ok
            case 0 {
                if gt(returndatasize(), 3) {
                    returndatacopy(m, 0, 0x04)
                    sel := mload(m)
                }
            }
            default { r := mload(0) }
        }
    }

    /// @dev `_call` with `value` wei and a third word argument `c`. The calldata is 100 bytes.
    function _callFull(address target, uint256 value, bytes4 selector, uint256 a, uint256 b, uint256 c)
        internal
        returns (uint256 r)
    {
        assembly ("memory-safe") {
            if iszero(extcodesize(target)) { revert(0, 0) }
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), a)
            mstore(add(m, 0x24), b)
            mstore(add(m, 0x44), c)
            mstore(0, 0)
            if iszero(call(gas(), target, value, m, 0x64, 0, 0x20)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            r := mload(0)
        }
    }

    /// @dev Stores the GRAIL parameters. `listBps` is 1 to 10,000. `pieceFloorWei` is nonzero and
    ///      at most one piece. `floorWei` is nonzero and at most the list price of the smallest
    ///      target, `GRAIL_MIN_TARGET * listBps / 10_000`.
    function _setGrail(uint256 decayWeiPerPull, uint256 pieceFloorWei, uint256 floorWei, uint256 listBps) internal {
        if (listBps == 0 || listBps > BPS) revert ListBpsOutOfRange();
        if (
            pieceFloorWei == 0 || pieceFloorWei > GRAIL_PIECE || floorWei == 0
                || floorWei > GRAIL_MIN_TARGET * listBps / BPS
        ) revert GrailFloorInvalid();
        Grail storage g = _grail;
        g.listBps = listBps;
        g.decayWeiPerPull = decayWeiPerPull;
        g.pieceFloorWei = pieceFloorWei;
        g.floorWei = floorWei;
    }

    /// @dev Stores the ladder step thresholds. `stepUpSeconds` is below `stepDownSeconds`.
    function _setGrailStep(uint32 stepUpSeconds, uint32 stepDownSeconds) internal {
        if (stepUpSeconds >= stepDownSeconds) revert GrailStepInvalid();
        _grail.stepUpSeconds = stepUpSeconds;
        _grail.stepDownSeconds = stepDownSeconds;
    }

    /// @dev Sets the target of the next cycle. It is 500, 1,000, 2,500, 5,000 or 10,000 ladder
    ///      units.
    function _setGrailTarget(uint256 targetWei) internal {
        uint256 units = targetWei / Denominations.UNIT;
        if (
            targetWei != units * Denominations.UNIT
                || (units != 500 && units != 1_000 && units != 2_500 && units != 5_000 && units != 10_000)
        ) revert GrailTargetInvalid();
        _grail.nextTargetWei = targetWei;
    }

    function _setFeeSplit(FeeSplit memory s) internal {
        if (uint256(s.premiumBps) + s.maintenanceBps + s.feedBps > MAX_FEE_SPLIT_BPS) revert FeeSplitTooHigh();
        feeSplit = s;
    }

    function _setEntryFee(EntryFee memory f) internal {
        if (f.floorBps > f.capBps || f.capBps > BPS || f.paybackDays == 0) revert EntryFeeOutOfRange();
        entryFee = f;
    }

    function _setTurnover(uint16 bps) internal {
        if (bps == 0 || bps > BPS) revert TurnoverOutOfRange();
        _turnoverBps = bps;
    }

    function _setProbCap(uint256 bps) internal {
        if (bps == 0 || bps > BPS) revert GrailProbCapOutOfRange();
        _grailProbCapBps = bps;
    }

    function _setBatch(uint256 minQueued, uint256 maxAge) internal {
        if (minQueued == 0 || maxAge == 0) revert LimitOutOfRange();
        _batchMin = minQueued;
        _batchMaxAge = maxAge;
    }

    function _setReplacement(uint256 surprise, uint256 restore, uint256 band) internal {
        if (surprise > BPS || restore > MAX_RESTORE_K || band > MAX_BAND_BPS) revert LimitOutOfRange();
        _surpriseBps = surprise;
        _restoreK = restore;
        _bandBps = band;
    }

    function _setTip(uint256 tip) internal {
        if (tip > MAX_TIP) revert LimitOutOfRange();
        _tipWei = tip;
    }

    function _setReserve(uint256 bps) internal {
        if (bps > BPS) revert LimitOutOfRange();
        _reserveBps = bps;
    }

    /// @dev Replaces the mix table. Each row must have rungs inside the Shapes ladder. A row that
    ///      holds items keeps its rungs, and no row that holds items or has a queued replacement may
    ///      be dropped (`RowInUse`). The row count may grow.
    function _setMix(PricingLib.MixRow[] memory rows) internal {
        uint256 n = rows.length;
        if (n == 0) revert PricingLib.EmptyRow();
        for (uint256 i; i < _mix.length; ++i) {
            if (_rowCount[i] == 0) continue;
            uint8[] storage old = _mix[i].rungs;
            if (i >= n || old.length != rows[i].rungs.length) revert RowInUse();
            for (uint256 j; j < old.length; ++j) {
                if (old[j] != rows[i].rungs[j]) revert RowInUse();
            }
        }
        for (uint256 q = replacementHead; q < _replacementQueue.length; ++q) {
            if (_replacementQueue[q] >= n) revert RowInUse();
        }
        delete _mix;
        delete _rowBackingWei;
        uint256 weighted;
        uint256 rungs;
        uint256 shares;
        for (uint256 i; i < n; ++i) {
            _rowBackingWei.push(PricingLib.rowBacking(rows[i]));
            weighted += uint256(rows[i].shareBps) * _rowBackingWei[i];
            rungs += uint256(rows[i].shareBps) * rows[i].rungs.length;
            shares += rows[i].shareBps;
            if (_rowCount.length < n) {
                _rowCount.push();
                _queuedByRow.push();
                _listedByRow.push();
            }
            _mix.push();
            PricingLib.MixRow storage row = _mix[i];
            row.shareBps = rows[i].shareBps;
            for (uint256 j; j < rows[i].rungs.length; ++j) {
                row.rungs.push(rows[i].rungs[j]);
            }
        }
        (_mixBacking, _mixRungs, _mixShares) = (weighted, rungs, shares);
    }
}
