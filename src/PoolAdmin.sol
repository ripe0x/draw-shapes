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
/// @notice Admin setters, `createFwaPool`, `sweep`, `adminCall`, exit, successor import and
///         `canImport`.
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

    /// @notice Sets the address besides the admin that may call `registerForeign`. Zero clears it.
    function setRegistrar(address registrar_) external onlyDelegated {
        _admin();
        registrar = registrar_;
        emit RegistrarSet(registrar_);
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
    ///         for a held or listed ordinary item and for a GRAIL item. A token whose foreign release
    ///         failed (`ForeignReleaseFailed`) goes to its controller whatever `to` is.
    function sweep(address token, uint256 id, address to) external onlyDelegated onlyAdmin {
        if (_registered[token][id]) revert Accounted();
        address controller = _heldFor[token][id];
        if (controller != address(0)) {
            delete _heldFor[token][id];
            to = controller;
        }
        _transfer(token, address(this), to, id);
    }

    /// @notice Calls `target` with `data` and `msg.value` as value, then requires I1 and I2.
    ///         `msg.value` must equal `value`, so the call is funded by the admin and not by the
    ///         buckets. Reverts `AdminCallDenied` for `withdrawOwnerProceeds`, `withdrawListing`,
    ///         `withdrawListingTo` and `updatePrice` on the FWA pool, and for any call to the collection
    ///         of a foreign listing. Reverts with the target's revert data and `InvariantBroken`
    ///         when a check fails.
    function adminCall(address target, bytes calldata data, uint256 value)
        external
        payable
        onlyDelegated
        onlyAdmin
        nonReentrant
    {
        if (msg.value != value) revert AdminValueMismatch();
        if (target == address(fwaPool) && data.length >= 4) {
            bytes4 sel = bytes4(data[:4]);
            if (
                sel == IFWAClone.withdrawOwnerProceeds.selector || sel == IFWAClone.withdrawListing.selector
                    || sel == IFWAClone.withdrawListingTo.selector || sel == IFWAClone.updatePrice.selector
            ) revert AdminCallDenied();
        }
        for (uint256 i; i < _foreign.length; ++i) {
            if (_foreign[i].collection == target) revert AdminCallDenied();
        }
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

    /// @notice Releases every foreign listing to its controller, then moves up to `maxItems` ordinary
    ///         listings, held items and the GRAIL estate out of the
    ///         pool, then settles the exit. Ordinary items are redeemed into `cash` on retirement.
    ///         On migration they go to the successor while `cash` covers `claims` and the successor
    ///         accepts the token (`canImport`), and are redeemed into `cash` otherwise. The GRAIL estate (the
    ///         fund and every GRAIL item) moves on migration only and counts as one item. The call that moves
    ///         the last item folds `maintenance` into `cash`, records `exportedShares` and
    ///         `exportedNav`, sends `cash - claims` to the successor, sets Exported, retires the FWA
    ///         pool and finalizes the import. Reverts `FwaBusy` while FWA holds unsettled
    ///         acquisitions or the booking walk is behind, and `InsufficientGas` when a release
    ///         could not be given its gas. A foreign release that fails emits `ForeignReleaseFailed`
    ///         and the export continues. Returns whether the export is complete.
    function exportStep(uint256 maxItems) external onlyDelegated nonReentrant returns (bool) {
        if (lifecycle != Lifecycle.Exiting) revert NotExiting();
        _processAndSettle(MAX_SETTLE_ITEMS);
        if (_busy()) revert FwaBusy();
        _harvest();

        while (_foreign.length != 0) {
            _releaseForeignOrHold(_foreign.length - 1);
        }

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

    /// @dev Removes the foreign listing at `index` and unregisters its token. Withdraws the FWA listing
    ///      when it is listed, then transfers the token to the entry's controller, forwarding at most
    ///      `FOREIGN_CALL_GAS` to the collection. A failed step emits `ForeignReleaseFailed`, leaves
    ///      the token where it is and records the controller in `_heldFor`, which `sweep` pays.
    function _releaseForeignOrHold(uint256 index) internal {
        ForeignListing memory f = _removeForeign(index);
        bool ok = true;
        if (f.notional != 0) {
            _requireCallGas();
            ok = _tryTransferCall(
                address(fwaPool), IFWAClone.withdrawListingTo.selector, f.listingId, uint160(address(this)), 0, gasleft()
            );
        }
        if (ok) {
            _requireCallGas();
            ok = _tryTransferCall(
                f.collection,
                IERC721.transferFrom.selector,
                uint160(address(this)),
                uint160(f.controller),
                f.tokenId,
                FOREIGN_CALL_GAS
            );
        }
        if (ok) emit ForeignWithdrawn(f.listingId, f.collection, f.tokenId, f.controller);
        else {
            _heldFor[f.collection][f.tokenId] = f.controller;
            emit ForeignReleaseFailed(f.listingId, f.tokenId);
        }
    }

    /// @dev Calls `selector` on `target` with three word arguments, forwarding at most `gasLimit`.
    ///      Returns whether the call succeeded and ignores the return data.
    function _tryTransferCall(address target, bytes4 selector, uint256 a, uint256 b, uint256 c, uint256 gasLimit)
        internal
        returns (bool ok)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), a)
            mstore(add(m, 0x24), b)
            mstore(add(m, 0x44), c)
            ok := call(gasLimit, target, 0, m, 0x64, 0, 0)
        }
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

    /// @dev Completes the `PoolBooks` hook for the bookings that run inside exit.
    function _chooseRow(uint256 requestId, uint256 capturedRow)
        internal
        view
        override
        returns (uint256 row, bool surprise)
    {
        return _pickRow(_randomWord(requestId), requestId, capturedRow);
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
    ///         when it is not a piece, and listed by the next `rotate`. When the cap of the arriving kind
    ///         (`MAX_DONE_ITEMS` done, `MAX_BUILDING_ITEMS` otherwise) is reached, the arriving item is redeemed and its proceeds join the fund.
    function importGrail(address collection, uint256 tokenId, bool done) external payable onlyDelegated onlyOldPool {
        _grail.fund += msg.value;
        if (collection == address(0)) return;
        _requireOwned(collection, tokenId);
        if (_registered[collection][tokenId]) revert AlreadyRegistered();
        if (_grailFull(done)) {
            uint256 before = address(this).balance;
            _call(collection, IShapes.redeem.selector, tokenId, 0);
            _grail.fund += address(this).balance - before;
            return;
        }
        bool pack = collection == drawPacks;
        if (!pack && collection != shapes) revert NoMatchingRow();
        uint256 value = _read(collection, pack ? IERC721Value.valueOf.selector : IShapes.backingOf.selector, tokenId);
        _addGrailItem(
            GrailItem(
                collection, done, tokenId, value, value == GRAIL_PIECE ? value : value * _grail.listBps / BPS, 0, 0
            )
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
                _callFull(
                    to,
                    i == n ? fund : 0,
                    this.importGrail.selector,
                    uint160(it.collection),
                    it.tokenId,
                    it.done ? 1 : 0
                );
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
