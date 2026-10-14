// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {IERC721Value} from "shapes/interfaces/IERC721Value.sol";
import {PricingLib} from "./lib/PricingLib.sol";
import {PoolBooks} from "./PoolBooks.sol";
import {IFWAClone, FWAConfigKeys} from "./interfaces/IFWAClone.sol";
import {IFWACloneFactory} from "./interfaces/IFWACloneFactory.sol";
import {IPool} from "./interfaces/IPool.sol";

/// @title PoolAdmin
/// @notice Admin setters, `createFwaPool`, `sweep`, `adminCall`, exit, successor import and the getters
///         of `Pool` that `Pool` does not serve itself.
/// @dev Runs by delegatecall from the `fallback` of `Pool` and acts on the storage of the calling
///      pool. A direct call to this contract reverts `NotDelegated`.
contract PoolAdmin is PoolBooks {
    // ------------------------------------------------------------------ admin

    /// @notice Creates the FWA pool through the factory, approves it for both collections and sets
    ///         this contract as its purchase operator. Starts the opening deadline. The factory pulls `expectedFee` of its FWA token from
    ///         this contract, so the pool must hold that balance first.
    function createFwaPool(uint256 expectedFee) external onlyDelegated onlyAdmin nonReentrant {
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
        _maxBatch = _read(fwaFactory, IFWACloneFactory.maxAcquisitionsPerTx.selector, 0);
        _concurrency = _read(fwaFactory, IFWACloneFactory.maxOutstandingRequestsPerPool.selector, 0);
        nextSequenceToBook = 1;
        _openingDeadlineAt = block.timestamp + _openingDeadline;
        _call(shapes, IERC721.setApprovalForAll.selector, uint160(address(clone)), 1);
        _call(drawPacks, IERC721.setApprovalForAll.selector, uint160(address(clone)), 1);
        _call(address(clone), IFWAClone.setPurchaseOperator.selector, uint160(address(this)), 0);
        emit FwaPoolCreated(address(clone));
    }

    function setFeeSplit(uint16 premiumBps, uint16 maintenanceBps, uint16 feedBps) external onlyDelegated {
        _admin();
        _setFeeSplit(FeeSplit(premiumBps, maintenanceBps, feedBps));
    }

    /// @dev `floorBps` is at most `capBps`, `capBps` is at most 10,000 and `paybackDays` is at
    ///      least one.
    function setEntryFee(uint32 floorBps, uint32 capBps, uint32 paybackDays) external onlyDelegated {
        _admin();
        _setEntryFee(EntryFee(floorBps, capBps, paybackDays));
    }

    function setNavCapFloor(uint256 wei_) external onlyDelegated {
        _admin();
        navCapFloor = wei_;
    }

    /// @dev `bps` is between 1 and 10,000.
    function setTurnover(uint16 bps) external onlyDelegated {
        _admin();
        _setTurnover(bps);
    }

    /// @dev Applies to the next `open()` only.
    function setFounderWindow(uint32 seconds_) external onlyDelegated {
        _admin();
        _founderWindowSeconds = seconds_;
    }

    /// @notice Replaces the mix table. A row that holds items keeps its rungs, and rows that hold
    ///         items or queued replacements keep their index.
    function setMix(PricingLib.MixRow[] memory rows) external onlyDelegated {
        _admin();
        _setMix(rows);
    }

    /// @dev `n` is at most the FWA factory's `maxAcquisitionsPerTx` and at least one.
    function setMaxBatch(uint256 n) external onlyDelegated {
        _admin();
        if (n == 0 || n > _read(fwaFactory, IFWACloneFactory.maxAcquisitionsPerTx.selector, 0)) {
            revert LimitOutOfRange();
        }
        _maxBatch = n;
    }

    /// @dev `n` is at most the FWA factory's `maxOutstandingRequestsPerPool`.
    function setConcurrency(uint256 n) external onlyDelegated {
        _admin();
        if (n > _read(fwaFactory, IFWACloneFactory.maxOutstandingRequestsPerPool.selector, 0)) {
            revert LimitOutOfRange();
        }
        _concurrency = n;
    }

    /// @dev `seconds_` is at least the FWA factory's `inventoryChangeCooldown`.
    function setRotateInterval(uint256 seconds_) external onlyDelegated {
        _admin();
        if (seconds_ < _read(fwaFactory, IFWACloneFactory.inventoryChangeCooldown.selector, 0)) {
            revert LimitOutOfRange();
        }
        rotateInterval = seconds_;
    }

    function setMinItems(uint256 n) external onlyDelegated {
        _admin();
        minItems = n;
    }

    function setGrailProbCap(uint256 bps) external onlyDelegated {
        _admin();
        _setProbCap(bps);
    }

    /// @dev `batchMin_` and `batchMaxAge_` are nonzero.
    function setBatch(uint256 batchMin_, uint256 batchMaxAge_) external onlyDelegated {
        _admin();
        _setBatch(batchMin_, batchMaxAge_);
    }

    /// @dev `surpriseBps_` is at most 10,000, `restoreK_` at most 100 and `bandBps_` at most 100,000.
    function setReplacement(uint256 surpriseBps_, uint256 restoreK_, uint256 bandBps_) external onlyDelegated {
        _admin();
        _setReplacement(surpriseBps_, restoreK_, bandBps_);
    }

    /// @dev `reserveBps_` is at most 10,000.
    function setReserve(uint256 reserveBps_) external onlyDelegated {
        _admin();
        _setReserve(reserveBps_);
    }

    /// @dev `tipWei_` is at most 0.01 ether.
    function setTip(uint256 tipWei_) external onlyDelegated {
        _admin();
        _setTip(tipWei_);
    }

    /// @notice Allows `settle` to list while FWA's inventory change cooldown is nonzero.
    function setListWhilePaused(bool on) external onlyDelegated {
        _admin();
        _listWhilePaused = on;
    }

    function setPaused(bool pulls, bool deposits) external onlyDelegated {
        _admin();
        pullsPaused = pulls;
        depositsPaused = deposits;
    }

    function setAdmin(address newAdmin) external onlyDelegated {
        _admin();
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
    }

    /// @notice Sends an ERC-721 token the pool does not account for to `to`. Reverts `Accounted`
    ///         for a held or listed ordinary item and for a GRAIL item.
    function sweep(address token, uint256 id, address to) external onlyDelegated onlyAdmin {
        if (_registered[token][id]) revert Accounted();
        _transfer(token, address(this), to, id);
    }

    /// @notice Calls `target` with `data` and `msg.value` as value, then requires I1 and I2.
    ///         `msg.value` must equal `value`, so the call is funded by the admin and not by the
    ///         buckets. Reverts with the target's revert data and `InvariantBroken` when a check
    ///         fails.
    function adminCall(address target, bytes calldata data, uint256 value)
        external
        payable
        onlyDelegated
        onlyAdmin
        nonReentrant
    {
        if (msg.value != value) revert AdminValueMismatch();
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        uint256 sum;
        for (uint256 i; i < _held.length; ++i) {
            sum += _held[i].value;
        }
        for (uint256 r; r < _listedByRow.length; ++r) {
            uint256[] storage ids = _listedByRow[r];
            for (uint256 j; j < ids.length; ++j) {
                sum += _listed[ids[j]].value;
            }
        }
        if (!_covered(0) || sum != backing) revert InvariantBroken();
    }

    /// @notice Closes pulls, deposits, rotation and GRAIL growth and disables FWA acquisitions.
    ///         `dest` is this pool for retirement or a successor for migration. A successor must
    ///         have code, name this pool as `oldPool`, not be Exiting and use the same Shapes and
    ///         Draw Packs collections. Callable in Opening and Live once the FWA pool exists.
    function startExit(address dest) external onlyDelegated onlyAdmin {
        _notExiting();
        if (address(fwaPool) == address(0)) revert FwaPoolMissing();
        if (
            dest != address(this)
                && (dest.code.length == 0
                    || address(uint160(_read(dest, this.oldPool.selector, 0))) != address(this)
                    || _read(dest, this.lifecycle.selector, 0) >= uint256(Lifecycle.Exiting)
                    || address(uint160(_read(dest, this.shapes.selector, 0))) != shapes
                    || address(uint160(_read(dest, this.drawPacks.selector, 0))) != drawPacks)
        ) {
            revert InvalidDest();
        }
        _call(address(fwaPool), IFWAClone.setBool.selector, FWAConfigKeys.ACQUISITIONS_ENABLED, 0);
        exitDest = dest;
        lifecycle = Lifecycle.Exiting;
        emit ExitStarted(dest);
    }

    /// @notice Moves up to `maxItems` ordinary listings, held items and the GRAIL estate out of the
    ///         pool, then settles the exit. Ordinary items are redeemed into `cash` on retirement.
    ///         On migration they go to the successor while `cash` covers `claims` and the successor
    ///         accepts the token (`canImport`), and are redeemed into `cash` otherwise. The GRAIL estate (the
    ///         fund and every GRAIL item) moves on migration only and counts as one item. The call that moves
    ///         the last item folds `maintenance` into `cash`, records `exportedShares` and
    ///         `exportedNav`, sends `cash - claims` to the successor, sets Exported, retires the FWA
    ///         pool and finalizes the import. Reverts `FwaBusy` while FWA holds unsettled
    ///         acquisitions or the booking walk is behind. Returns whether the export is complete.
    function exportStep(uint256 maxItems) external onlyDelegated nonReentrant returns (bool) {
        if (lifecycle != Lifecycle.Exiting) revert NotExiting();
        _processAndSettle(MAX_SETTLE_ITEMS);
        if (_busy()) revert FwaBusy();
        _harvest();

        address dest = exitDest;
        bool migrate = dest != address(this);
        uint256 movedNav;
        while (maxItems != 0 && (listedCount != 0 || _held.length != 0)) {
            --maxItems;
            uint256 listingId;
            Item memory it;
            if (listedCount != 0) {
                uint256 row;
                while (_listedByRow[row].length == 0) ++row;
                listingId = _lastListed(row);
                it = _listed[listingId];
            } else {
                it = _held[_held.length - 1];
            }
            bool move = migrate && cash >= claims && _canImport(dest, it);
            if (listingId != 0) {
                _withdrawListing(listingId, move ? dest : address(this));
                _removeListed(listingId);
            } else {
                _removeHeld(_held.length - 1);
                if (move) _transfer(it.collection, address(this), dest, it.tokenId);
            }
            if (move) {
                _call(dest, this.importItem.selector, uint160(it.collection), it.tokenId);
                movedNav += it.value;
            } else {
                _redeemItem(it);
            }
        }
        bool pending = listedCount != 0 || _held.length != 0;
        if (migrate && (_grail.fund != 0 || _grailItems.length != 0)) {
            if (maxItems == 0) {
                pending = true;
            } else {
                _sendGrailEstate(dest, true);
            }
        }
        _exportedNav += movedNav;
        if (pending) return false;

        cash += maintenance;
        maintenance = 0;
        uint256 exported = _exportedNav + nav();
        uint256 shares = totalShares;
        _exportedNav = exported;
        _exportedShares = shares;
        lifecycle = Lifecycle.Exported;
        if (_read(address(fwaPool), IFWAClone.retired.selector, 0) == 0) {
            _call(address(fwaPool), IFWAClone.retirePool.selector, 0, 0);
        }
        if (migrate) {
            uint256 out = cash > claims ? cash - claims : 0;
            cash -= out;
            _callFull(dest, out, this.importCash.selector, 0, 0, 0);
            _call(dest, this.finalizeImport.selector, shares, 0);
        }
        emit Exported(shares, exported);
        return true;
    }

    /// @notice Sends the GRAIL fund and every GRAIL item to `to` and empties the estate. Callable
    ///         by the admin from `Exiting` on. Withdraws the items' FWA listings first, which FWA
    ///         rejects while it holds unsettled acquisitions.
    function transferGrailEstate(address to) external onlyDelegated onlyAdmin nonReentrant {
        if (lifecycle < Lifecycle.Exiting) revert NotExiting();
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidDest();
        _sync();
        _sendGrailEstate(to, false);
    }

    // ------------------------------------------------------------------ views

    /// @notice Listed plus held ordinary items of `row`.
    function rowCount(uint256 row) external view onlyDelegated returns (uint256) {
        return _rowCount[row];
    }

    /// @notice Number of mix rows.
    function mixLength() external view onlyDelegated returns (uint256) {
        return _mix.length;
    }

    /// @notice Listed items of `row`.
    function listedRowCount(uint256 row) external view onlyDelegated returns (uint256) {
        return _listedByRow[row].length;
    }

    /// @notice Rungs and weight share of mix row `i`.
    function mixRow(uint256 i) external view onlyDelegated returns (uint8[] memory rungs, uint16 shareBps) {
        uint8[] storage stored = _mix[i].rungs;
        rungs = new uint8[](stored.length);
        for (uint256 j; j < rungs.length; ++j) {
            rungs[j] = stored[j];
        }
        shareBps = _mix[i].shareBps;
    }


    /// @notice Queued replacements at which `settleDue` returns `Batch`.
    function batchMin() external view onlyDelegated returns (uint256) {
        return _batchMin;
    }

    /// @notice Seconds since the queue became nonempty after which `settleDue` returns `Age`.
    function batchMaxAge() external view onlyDelegated returns (uint256) {
        return _batchMaxAge;
    }

    /// @notice Probability, in bps, that a replacement draw takes the surprise step.
    function surpriseBps() external view onlyDelegated returns (uint256) {
        return _surpriseBps;
    }

    /// @notice Multiplier of a row's relative deficit in its replacement draw weight.
    function restoreK() external view onlyDelegated returns (uint256) {
        return _restoreK;
    }

    /// @notice Headroom above its target, in bps, up to which a row may be chosen as a replacement.
    function bandBps() external view onlyDelegated returns (uint256) {
        return _bandBps;
    }

    /// @notice Share of ordinary NAV, in bps, that cash keeps after a mint or a kept Shape.
    function reserveBps() external view onlyDelegated returns (uint256) {
        return _reserveBps;
    }

    /// @notice True when `settle` lists while FWA's inventory change cooldown is nonzero.
    function listWhilePaused() external view onlyDelegated returns (bool) {
        return _listWhilePaused;
    }

    /// @notice Time the replacement queue last went from empty to nonempty, zero while it is empty.
    function oldestQueuedAt() external view onlyDelegated returns (uint256) {
        return _oldestQueuedAt;
    }

    /// @notice Queued withdrawal claim at `index`.
    function claimQueue(uint256 index) external view onlyDelegated returns (Claim memory) {
        return _claimQueue[index];
    }

    /// @notice Row index of the replacement queue entry at `index`.
    function replacementQueue(uint256 index) external view onlyDelegated returns (uint16) {
        return _replacementQueue[index];
    }

    /// @notice Seconds from FWA pool creation to the earliest `open()`.
    function openingDeadline() external view onlyDelegated returns (uint256) {
        return _openingDeadline;
    }

    /// @notice Earliest `open()` time, set by `createFwaPool`.
    function openingDeadlineAt() external view onlyDelegated returns (uint256) {
        return _openingDeadlineAt;
    }

    /// @notice Largest acquisition count of one `acquireBatch`.
    function maxBatch() external view onlyDelegated returns (uint256) {
        return _maxBatch;
    }

    /// @notice Listed ordinary items required above the unsettled acquisitions for a purchase.
    function concurrency() external view onlyDelegated returns (uint256) {
        return _concurrency;
    }

    /// @notice Time of the last `rotate` refund.
    function lastRefundAt() external view onlyDelegated returns (uint256) {
        return _lastRefundAt;
    }

    /// @notice Largest share of the FWA selection weight, in bps, that the listed GRAIL tracks hold.
    function grailProbCapBps() external view onlyDelegated returns (uint256) {
        return _grailProbCapBps;
    }

    /// @notice Booked share of `ownerProceeds` awaiting harvest for `maintenance`.
    function maintenanceReceivable() external view onlyDelegated returns (uint256) {
        return _maintenanceReceivable;
    }

    /// @notice Net proceeds of settled captures not yet split. Negative while captures sold below value.
    function margin() external view onlyDelegated returns (int256) {
        return _margin;
    }

    /// @notice Replacement mint fees of booked captures not yet covered by margin.
    function mintLineOwed() external view onlyDelegated returns (uint256) {
        return _mintLineOwed;
    }

    /// @notice Share supply recorded when the export completed.
    function exportedShares() external view onlyDelegated returns (uint256) {
        return _exportedShares;
    }

    /// @notice Ordinary NAV recorded when the export completed.
    function exportedNav() external view onlyDelegated returns (uint256) {
        return _exportedNav;
    }

    /// @notice Shares minted to the importing holders at `finalizeImport`.
    function importedShares() external view onlyDelegated returns (uint256) {
        return _importedShares;
    }

    /// @notice Old pool share supply that `importedShares` represents.
    function importedFromShares() external view onlyDelegated returns (uint256) {
        return _importedFromShares;
    }

    /// @notice True once `holder` called `migrateHolder`.
    function migrated(address holder) external view onlyDelegated returns (bool) {
        return _migrated[holder];
    }

    /// @notice True while the token is a held or listed ordinary item of this pool.
    function registered(address collection, uint256 tokenId) external view onlyDelegated returns (bool) {
        return _registered[collection][tokenId];
    }

    /// @notice Row that replaces the capture of FWA request `requestId`, and whether the surprise
    ///         step chose it. Drawn by `PricingLib.chooseRow` from `keccak256(randomWord,
    ///         requestId)`. A row's count is its listed, held and queued items.
    function chooseRow(uint256 requestId, uint256 capturedRow)
        external
        view
        onlyDelegated
        returns (uint256, bool)
    {
        return _chooseRow(requestId, capturedRow);
    }

    function _chooseRow(uint256 requestId, uint256 capturedRow)
        internal
        view
        override
        returns (uint256 row, bool surprise)
    {
        return _pickRow(_randomWord(requestId), requestId, capturedRow);
    }

    // ------------------------------------------------------------------ held items

    /// @notice Number of held ordinary items.
    function heldCount() external view onlyDelegated returns (uint256) {
        return _held.length;
    }

    /// @notice Token ids of the held Shapes of ladder index `denom`.
    function heldShapes(uint8 denom) external view onlyDelegated returns (uint256[] memory) {
        return _heldByDenom[denom];
    }

    // ------------------------------------------------------------------ successor import

    /// @notice Registers a Shape or Draw Pack that `oldPool` transferred to this pool as a held
    ///         ordinary item of the first mix row with the token's value and kind. The next
    ///         `rotate` or `open` lists it.
    function importItem(address collection, uint256 tokenId) external onlyDelegated onlyOldPool {
        _requireOwned(collection, tokenId);
        if (_registered[collection][tokenId]) revert AlreadyRegistered();
        (uint256 row, uint256 value) = _importRow(collection, tokenId);
        if (row == type(uint256).max) revert NoMatchingRow();
        _addItem(Item(collection, uint16(row), tokenId, value, 0));
        importedNav += value;
    }

    /// @notice Whether `oldPool` could import the token now: the import is open, the token is not
    ///         registered and a mix row matches its collection and value.
    function canImport(address collection, uint256 tokenId) external view onlyDelegated returns (bool) {
        if (importFinalized || lifecycle >= Lifecycle.Exiting || _registered[collection][tokenId]) return false;
        (uint256 row,) = _importRow(collection, tokenId);
        return row != type(uint256).max;
    }

    /// @notice Credits `msg.value` to the GRAIL fund and, when `collection` is nonzero, takes the
    ///         GRAIL item `tokenId` of `collection` from `oldPool`. `done` keeps the completed-GRAIL
    ///         flag. The item is unlisted on arrival, priced at its backing or at `listBps` of it
    ///         when it is not a piece, and listed by the next `rotate`. When `MAX_GRAIL_ITEMS` items
    ///         are held, the arriving item is redeemed and its proceeds join the fund.
    function importGrail(address collection, uint256 tokenId, bool done) external payable onlyDelegated onlyOldPool {
        _grail.fund += msg.value;
        if (collection == address(0)) return;
        _requireOwned(collection, tokenId);
        if (_registered[collection][tokenId]) revert AlreadyRegistered();
        if (_grailItems.length >= MAX_GRAIL_ITEMS) {
            uint256 before = address(this).balance;
            _call(collection, IShapes.redeem.selector, tokenId, 0);
            _grail.fund += address(this).balance - before;
            return;
        }
        bool pack = collection == drawPacks;
        if (!pack && collection != shapes) revert NoMatchingRow();
        uint256 value = _read(collection, pack ? IERC721Value.valueOf.selector : IShapes.backingOf.selector, tokenId);
        _addGrailItem(
            GrailItem(collection, done, tokenId, value, value == GRAIL_PIECE ? value : value * _grail.listBps / BPS, 0, 0)
        );
    }

    /// @notice Credits `msg.value` from `oldPool` to `cash`. It counts toward `importedNav` and
    ///         bypasses `navCap()` and the founder window.
    function importCash() external payable onlyDelegated onlyOldPool {
        cash += msg.value;
        importedNav += msg.value;
    }

    /// @notice Closes the import and mints `importedShares` for `importedNav` at the NAV per share
    ///         before the import, 1:1 when there are no shares or that NAV is zero. `fromShares` is
    ///         the share supply of `oldPool`.
    function finalizeImport(uint256 fromShares) external onlyDelegated onlyOldPool {
        _sync();
        uint256 imported = importedNav;
        uint256 total = nav();
        uint256 preNav = total > imported ? total - imported : 0;
        uint256 minted =
            totalShares == 0 || preNav == 0 ? imported : PricingLib.sharesFor(imported, preNav, totalShares);
        _importedShares = minted;
        totalShares += minted;
        _importedFromShares = fromShares;
        importFinalized = true;
        emit Imported(imported, minted);
    }

    /// @notice Mints `holder` the share of `importedShares` that matches `holder`'s share of
    ///         `oldPool`. Once per holder. The rounding remainder stays in `totalShares`.
    function migrateHolder(address holder) external onlyDelegated {
        if (!importFinalized) revert ImportNotFinal();
        if (_migrated[holder]) revert AlreadyMigrated();
        _migrated[holder] = true;
        uint256 shares = _read(oldPool, this.sharesOf.selector, uint160(holder)) * _importedShares / _importedFromShares;
        sharesOf[holder] += shares;
        emit Migrated(holder, shares);
    }

    // ------------------------------------------------------------------ internal

    function _checkOldPool() internal view {
        if (msg.sender != oldPool) revert NotOldPool();
        _notExiting();
        if (importFinalized) revert ImportClosed();
    }

    /// @dev First mix row whose backing equals the value of the token and whose kind (Shape or Draw
    ///      Pack) matches its collection, with that value. The row is `type(uint256).max` when none
    ///      matches.
    function _importRow(address collection, uint256 tokenId) internal view returns (uint256 row, uint256 value) {
        bool pack = collection == drawPacks;
        if (pack || collection == shapes) {
            value = _read(collection, pack ? IERC721Value.valueOf.selector : IShapes.backingOf.selector, tokenId);
            for (; row < _mix.length; ++row) {
                if (_rowBackingWei[row] == value && (_mix[row].rungs.length > 1) == pack) return (row, value);
            }
        }
        return (type(uint256).max, value);
    }

    /// @dev `canImport` of the successor `dest` for `it`.
    function _canImport(address dest, Item memory it) internal view returns (bool) {
        return IPool(dest).canImport(it.collection, it.tokenId);
    }

    /// @dev Withdraws the listing of every GRAIL item and transfers the items and the fund to
    ///      `to`. With `migrate` each item is registered at `to` through `importGrail`, and the first
    ///      call carries the fund. Otherwise the fund is sent as ETH.
    function _sendGrailEstate(address to, bool migrate) internal {
        uint256 n = _grailItems.length;
        uint256 fund = _grail.fund;
        _grail.fund = 0;
        emit GrailEstateTransferred(to, fund, n);
        if (migrate && n == 0) _callFull(to, fund, this.importGrail.selector, 0, 0, 0);
        for (uint256 i = n; i != 0; --i) {
            GrailItem memory it = _removeGrailItem(i - 1);
            if (it.listingId != 0) _withdrawListing(it.listingId, address(this));
            _transfer(it.collection, address(this), to, it.tokenId);
            if (migrate) {
                _callFull(to, i == n ? fund : 0, this.importGrail.selector, uint160(it.collection), it.tokenId, it.done ? 1 : 0);
            }
        }
        if (!migrate) SafeTransferLib.safeTransferETH(to, fund);
    }

    /// @dev Reverts `TokenNotReceived` unless this contract owns `tokenId` of `collection`.
    function _requireOwned(address collection, uint256 tokenId) internal view {
        if (address(uint160(_read(collection, IERC721.ownerOf.selector, tokenId))) != address(this)) {
            revert TokenNotReceived();
        }
    }

    /// @dev Restricts a function to `oldPool` while the pool is Opening or Live and the import is
    ///      open.
    modifier onlyOldPool() {
        _checkOldPool();
        _;
    }
}
