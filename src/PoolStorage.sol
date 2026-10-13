// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {Denominations} from "shapes/lib/Denominations.sol";
import {PricingLib} from "./lib/PricingLib.sol";
import {IFWAClone} from "./interfaces/IFWAClone.sol";
import {IPoolTypes} from "./interfaces/IPool.sol";

/// @title PoolStorage
/// @notice Storage layout, constants and internal helpers shared by `Pool` and `PoolAdmin`.
/// @dev `PoolAdmin` runs by delegatecall from the `fallback` of `Pool`, so both contracts inherit
///      this layout and the reentrancy guard slot.
abstract contract PoolStorage is IPoolTypes, ReentrancyGuard {
    // ------------------------------------------------------------------ constants

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MINOR = 0;
    uint256 internal constant MAJOR = 1;
    uint256 internal constant MAX_FEE_SPLIT_BPS = 1_000;
    uint256 internal constant MAX_CURVE_CAP_BPS = 2_500;
    uint256 internal constant PULL_SLOTS = 5;
    uint256 internal constant MAX_SETTLE_ITEMS = 20;

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
    /// @notice Maintenance share of booked margin, still held as FWA owner proceeds.
    uint256 public maintenanceReceivable;
    Grail[2] public grail;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    Claim[] public claimQueue;
    uint256 public claimHead;

    PricingLib.MixRow[] internal _mix;
    FeeSplit public feeSplit;
    EntryCurve public curve;
    uint256 public navCap;
    uint256 public rotateInterval;
    /// @notice Duration in seconds from FWA pool creation to the earliest `open()`.
    uint256 public openingDeadline;
    uint256 public openingDeadlineAt;
    uint256 public minItems;
    uint256 public grailProbCapBps;
    /// @notice Smallest GRAIL list price decrease, in bps of the current price, that `rotate` applies
    ///         as a reprice.
    uint256 public repriceMinBps;

    IFWAClone public fwaPool;
    uint256 public maxBatch;
    uint256 public concurrency;

    /// @dev Backing of one token of each row, indexed like `_mix`.
    uint256[] internal _rowBackingWei;
    /// @dev Listed plus held ordinary items per row.
    uint256[] internal _rowCount;
    mapping(uint256 listingId => Item) internal _listed;
    Item[] internal _held;

    /// @notice FIFO of row indices awaiting a replacement mint.
    uint16[] public replacementQueue;
    uint256 public replacementHead;

    PullSlot[PULL_SLOTS] internal _pullSlots;

    /// @dev `base + 1` of each pull request id, where `base` is the FWA base price at request time.
    ///      Zero marks a request opened outside `pull`.
    mapping(uint256 requestId => uint256) internal _basePlusOne;
    /// @notice First FWA acquisition sequence the pool has not yet booked.
    uint64 public nextSequenceToBook;
    /// @notice Booked proceeds minus captured backing, netted across captures. Positive margin is
    ///         split at once, negative margin carries forward.
    int256 public margin;
    /// @notice Replacement mint fees of captured items, covered by margin before it is split.
    uint256 public mintLineOwed;
    /// @notice Listed ordinary items.
    uint256 public listedCount;
    /// @notice Timestamp of the last `rotate` that changed inventory, or of `open()` going Live.
    uint256 public lastRotateAt;
    /// @notice Timestamp of the last `rotate` that paid a refund.
    uint256 public lastRefundAt;
    /// @dev FWA listing ids of listed ordinary items, by row.
    uint256[][] internal _listedByRow;
    /// @dev Position of each listing id inside its row's `_listedByRow` array.
    mapping(uint256 listingId => uint256) internal _listedIndex;

    /// @notice Destination of the export: this pool for retirement, a successor for migration.
    address public exitDest;
    /// @notice Share supply at export.
    uint256 public exportedShares;
    /// @notice Ordinary NAV plus maintenance at export, including items already moved to the
    ///         successor.
    uint256 public exportedNav;
    /// @notice Successor side: NAV received from `oldPool`, and the shares minted against it.
    uint256 public importedNav;
    uint256 public importedShares;
    /// @notice Successor side: share supply of `oldPool` at its export, set by `finalizeImport`.
    uint256 public importedFromShares;
    /// @notice Successor side: holders whose `oldPool` shares were converted by `migrateHolder`.
    mapping(address holder => bool) public migrated;
    /// @notice True while the token is a held or listed ordinary item of this pool.
    mapping(address collection => mapping(uint256 tokenId => bool)) public registered;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ------------------------------------------------------------------ views

    /// @notice Ordinary NAV: `cash + backing + receivable - claims`, or zero when `claims` exceed
    ///         the assets.
    function nav() public view returns (uint256) {
        uint256 assets = cash + backing + receivable;
        return assets > claims ? assets - claims : 0;
    }

    // ------------------------------------------------------------------ internal

    /// @dev Reverts `PoolExiting` from `Exiting` on.
    function _notExiting() internal view {
        if (lifecycle >= Lifecycle.Exiting) revert PoolExiting();
    }

    /// @dev I1 with `incoming` wei of the balance still outside the buckets.
    function _covered(uint256 incoming) internal view returns (bool) {
        return address(this).balance >= incoming + cash + maintenance + grail[MINOR].bucket + grail[MAJOR].bucket;
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

    /// @dev Clears the pack fields of a track whose pack left the pool.
    function _resetGrail(Grail storage g) internal {
        g.packId = 0;
        g.backing = 0;
        g.notional = 0;
        g.listingId = 0;
        g.pullsSinceList = 0;
    }

    /// @dev Withdraws the track's FWA listing to this contract when it is listed.
    function _unlistGrail(Grail storage g) internal {
        uint256 id = g.listingId;
        if (id != 0) {
            _withdrawListing(id, address(this));
            g.listingId = 0;
        }
    }

    /// @dev Books `it` as held (`listingId == 0`) or listed. Every registry change goes through
    ///      `_addItem` and `_removeHeld` / `_removeListed`, which keep `backing` equal to the sum
    ///      of `value` over held and listed items (I2), `_rowCount` equal to their number,
    ///      `_listedByRow` equal to the listing ids of the listed items and `registered` true
    ///      exactly for their tokens.
    function _addItem(Item memory it) internal {
        if (it.listingId == 0) {
            _held.push(it);
        } else {
            _listed[it.listingId] = it;
            ++listedCount;
            uint256[] storage ids = _listedByRow[it.row];
            _listedIndex[it.listingId] = ids.length;
            ids.push(it.listingId);
        }
        registered[it.collection][it.tokenId] = true;
        backing += it.value;
        ++_rowCount[it.row];
    }

    function _removeHeld(uint256 index) internal returns (Item memory it) {
        uint256 last = _held.length - 1;
        it = _held[index];
        if (index != last) _held[index] = _held[last];
        _held.pop();
        delete registered[it.collection][it.tokenId];
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
        delete registered[it.collection][it.tokenId];
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

    /// @dev Stores the parameters of track `track`. `stepWei` is a multiple of `Denominations.UNIT`
    ///      and at least two units. `floorWei` is nonzero and at most the list price at full
    ///      backing, `targetWei * listBps / 10_000`.
    function _initGrail(uint256 track, GrailParams memory g) internal {
        if (g.listBps == 0 || g.listBps > BPS) revert ListBpsOutOfRange();
        if (g.stepWei < 2 * Denominations.UNIT || g.stepWei % Denominations.UNIT != 0) revert GrailStepInvalid();
        if (g.floorWei == 0 || g.floorWei > g.targetWei * g.listBps / BPS) revert GrailFloorInvalid();
        Grail storage t = grail[track];
        t.targetWei = g.targetWei;
        t.stepWei = g.stepWei;
        t.listBps = g.listBps;
        t.decayWeiPerPull = g.decayWeiPerPull;
        t.floorWei = g.floorWei;
    }

    function _setFeeSplit(FeeSplit memory s) internal {
        if (uint256(s.premiumBps) + s.maintenanceBps + s.feedBps > MAX_FEE_SPLIT_BPS) revert FeeSplitTooHigh();
        if (s.minorShareBps > BPS) revert MinorShareTooHigh();
        feeSplit = s;
    }

    function _setCurve(EntryCurve memory c) internal {
        if (c.capBps > MAX_CURVE_CAP_BPS) revert CurveCapTooHigh();
        if (c.referenceWei == 0) revert CurveReferenceZero();
        curve = c;
    }

    function _setProbCap(uint256 bps) internal {
        if (bps == 0 || bps > BPS) revert GrailProbCapOutOfRange();
        grailProbCapBps = bps;
    }

    function _setRepriceMinBps(uint256 bps) internal {
        if (bps > BPS) revert RepriceBpsOutOfRange();
        repriceMinBps = bps;
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
        for (uint256 q = replacementHead; q < replacementQueue.length; ++q) {
            if (replacementQueue[q] >= n) revert RowInUse();
        }
        delete _mix;
        delete _rowBackingWei;
        for (uint256 i; i < n; ++i) {
            _rowBackingWei.push(PricingLib.rowBacking(rows[i]));
            if (_rowCount.length < n) {
                _rowCount.push();
                _listedByRow.push();
            }
            _mix.push();
            PricingLib.MixRow storage row = _mix[i];
            row.shareBps = rows[i].shareBps;
            for (uint256 j; j < rows[i].rungs.length; ++j) {
                row.rungs.push(rows[i].rungs[j]);
            }
        }
    }
}
