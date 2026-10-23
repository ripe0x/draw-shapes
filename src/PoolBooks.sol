// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {IShapePacks} from "draw-packs/interfaces/IShapePacks.sol";
import {IERC721Value} from "shapes/interfaces/IERC721Value.sol";
import {PricingLib} from "./lib/PricingLib.sol";
import {PoolStorage} from "./PoolStorage.sol";
import {IFWAClone} from "./interfaces/IFWAClone.sol";
import {IForeignController} from "./interfaces/IForeignController.sol";

/// @title PoolBooks
/// @notice Settlement of FWA acquisitions and harvest of FWA owner proceeds into the buckets,
///         shared by `Pool`, `PoolAdmin` and `PoolListing`.
abstract contract PoolBooks is PoolStorage {
    /// @dev Address of the deployed module, compared with `address(this)` to detect a direct call.
    address private immutable self = address(this);

    /// @dev Reverts `NotDelegated` on a direct call to a module.
    modifier onlyDelegated() {
        if (address(this) == self) revert NotDelegated();
        _;
    }

    /// @dev Brings the books level with FWA before share pricing: processes and books up to
    ///      `MAX_SETTLE_ITEMS` acquisitions, requires the booking walk to reach FWA's processing
    ///      queue, then harvests. FWA processes acquisitions permissionlessly, so share pricing
    ///      must follow the books, never lead them. No-op before the FWA pool exists.
    function _sync() internal {
        if (address(fwaPool) == address(0)) return;
        _processAndSettle(MAX_SETTLE_ITEMS);
        if (nextSequenceToBook != _nextToProcess()) revert BooksBehind();
        _harvest();
    }

    /// @dev Advances FWA's processing queue by `maxItems`, then books the results.
    function _processAndSettle(uint256 maxItems) internal {
        _call(address(fwaPool), IFWAClone.processAcquisitions.selector, maxItems, 0);
        _settle(maxItems);
    }

    /// @dev Books up to `maxItems` FWA acquisitions, then books the owner proceeds of requests
    ///      opened directly at the FWA pool once the walk has reached FWA's processing queue.
    function _settle(uint256 maxItems) internal {
        IFWAClone fwa = fwaPool;
        uint64 end = _nextToProcess();
        if (_walk(fwa, end, maxItems) == end) _bookSurplus(_ownerProceeds());
    }

    /// @dev Books up to `maxItems` FWA acquisitions in sequence order from `nextSequenceToBook`
    ///      to `end`. Returns the new `nextSequenceToBook`. Every sequence passed adds one to
    ///      `grail.pulls`, whatever its status. A Fulfilled acquisition is a capture:
    ///      FWA pays the owner `paid - (paid - base) / 2`, and a request without a recorded base
    ///      books zero proceeds, which `_bookSurplus` books from FWA's owner proceeds. A refunded
    ///      delivery returns its token to held items. A DeliveryPending acquisition is written off:
    ///      its item leaves backing and its value is charged to `margin`, with no proceeds and no
    ///      replacement. If the delivery later completes, FWA accrues owner proceeds and
    ///      `_bookSurplus` books them. If the purchaser later refunds, the admin recovers the token
    ///      with `adminCall(recoverRefundedNFT)` and `sweep`. Expired, Refunded and TimedOut
    ///      acquisitions book nothing. FWA only advances its processing queue past acquisitions in
    ///      those statuses, so any other status books nothing and the walk passes it. A foreign
    ///      listing follows `_closeForeign` on capture and in `_recoverRefunded` and `_writeOff`. The `paid`
    ///      values of the captures add to the fee volume of the current UTC day.
    function _walk(IFWAClone fwa, uint64 end, uint256 maxItems) internal returns (uint64 seq) {
        seq = nextSequenceToBook;
        if (seq >= end) return seq;

        uint64 start = seq;
        uint256 mintFee = _mintFee();
        uint256 fees;
        for (uint256 n; seq < end && n < maxItems; ++n) {
            uint256 requestId = _read(address(fwa), IFWAClone.requestIdAtSequence.selector, seq);
            (uint256 paid, uint256 listingId, uint256 status) = _acquisition(requestId);
            if (status == uint256(IFWAClone.AcquisitionStatus.Fulfilled)) {
                fees += paid;
                _capture(requestId, listingId, paid, mintFee);
            } else if (status == uint256(IFWAClone.AcquisitionStatus.DeliveryRefunded)) {
                _recoverRefunded(fwa, listingId);
            } else if (status == uint256(IFWAClone.AcquisitionStatus.DeliveryPending)) {
                _writeOff(requestId, listingId);
            }
            ++seq;
        }
        if (fees != 0) _recordFees(fees);
        if (seq != start) {
            nextSequenceToBook = seq;
            _recordPulls(seq - start);
            emit Booked(seq);
        }
    }

    /// @dev Books one Fulfilled acquisition. A foreign listing is closed by `_closeForeign`. A GRAIL
    ///      listing credits its proceeds to the GRAIL receivable and removes the item. An ordinary item leaves backing, its proceeds join
    ///      `receivable` and `margin`, and the row chosen by `_chooseRow` is queued for a
    ///      replacement. No replacement is queued when no row is below its target.
    function _capture(uint256 requestId, uint256 listingId, uint256 paid, uint256 mintFee) internal {
        uint256 stored = _basePlusOne[requestId];
        uint256 proceeds = stored == 0 ? 0 : paid - (paid - (stored - 1)) / 2;
        if (_grailAt[listingId] != 0) {
            _closeGrail(listingId, requestId, proceeds);
            return;
        }
        uint256 foreignAt = _foreignAt[listingId];
        if (foreignAt != 0) {
            _closeForeign(foreignAt - 1, proceeds);
            return;
        }
        Item memory it = _removeListed(listingId);
        receivable += proceeds;
        _margin += SafeCastLib.toInt256(proceeds) - SafeCastLib.toInt256(it.value);
        _mintLineOwed += mintFee * _mix[it.row].rungs.length;
        (uint256 row, bool surprise) = _chooseRow(requestId, it.row);
        if (row != type(uint256).max) {
            _enqueue(row);
            emit ReplacementChosen(requestId, it.row, row, surprise);
        }
        emit Captured(requestId, listingId, it.row, it.value, proceeds);
        _splitMargin();
    }

    /// @dev Appends `row` to the replacement queue. `oldestQueuedAt` is set when the queue was empty.
    function _enqueue(uint256 row) internal {
        if (_replacementQueue.length == replacementHead) _oldestQueuedAt = block.timestamp;
        _replacementQueue.push(uint16(row));
        ++_queuedByRow[row];
    }

    /// @dev Row that replaces the capture of `requestId` and whether the surprise step chose it.
    ///      `Pool` reads it from `PoolListing.chooseRow`.
    function _chooseRow(uint256 requestId, uint256 capturedRow)
        internal
        view
        virtual
        returns (uint256 row, bool surprise);

    /// @dev Row that replaces a capture of `capturedRow`, drawn by `PricingLib.chooseRow` from
    ///      `keccak256(abi.encode(randomWord, requestId))`. A row's count is its listed, held and
    ///      queued items.
    function _pickRow(uint256 randomWord, uint256 requestId, uint256 capturedRow)
        internal
        view
        returns (uint256 row, bool surprise)
    {
        uint256 n = _mix.length;
        PricingLib.RowState[] memory rows = new PricingLib.RowState[](n);
        uint256 items = _boardItems();
        for (uint256 i; i < n; ++i) {
            uint256 share = _mix[i].shareBps;
            rows[i] = PricingLib.RowState(
                share,
                _rowCount[i] + _queuedByRow[i],
                PricingLib.rowDepth(items, share),
                _rowBackingWei[i],
                _mix[i].rungs.length == 1
            );
        }
        return PricingLib.chooseRow(
            keccak256(abi.encode(randomWord, requestId)), rows, _restoreK, _surpriseBps, _bandBps, capturedRow
        );
    }

    /// @dev Removes the GRAIL item listed under `listingId`. `proceeds` joins the GRAIL receivable.
    function _closeGrail(uint256 listingId, uint256 requestId, uint256 proceeds) internal {
        GrailItem memory it = _removeGrailItem(_grailAt[listingId] - 1);
        _grail.receivable += proceeds;
        emit GrailCaptured(requestId, listingId, it.backing, proceeds);
    }

    /// @dev Removes the foreign listing at `index` after its capture. `proceeds` is booked as
    ///      `_foreignReceivable` and, with a due of the same value, reported to the controller by the
    ///      next harvest, which is when the ETH reaches the pool. A due with zero proceeds is
    ///      reported the same way.
    function _closeForeign(uint256 index, uint256 proceeds) internal {
        ForeignListing memory f = _removeForeign(index);
        _foreignReceivable += proceeds;
        _foreignDue.push(ForeignDue(f.controller, f.listingId, f.tokenId, proceeds));
    }

    /// @dev Reports the captured foreign listings to their controllers and pays them their proceeds,
    ///      which the harvest has just withdrawn from FWA. Each due is paid in order, capped by what
    ///      remains of `_foreignReceivable` after any write-down. The proceeds of a call that fails
    ///      are booked as `receivable` and `margin`, and the margin is split once after the last due.
    function _payForeign() internal {
        ForeignDue[] memory due = _foreignDue;
        if (due.length == 0) return;
        uint256 available = _foreignReceivable;
        delete _foreignDue;
        _foreignReceivable = 0;
        bool failed;
        for (uint256 i; i < due.length; ++i) {
            ForeignDue memory d = due[i];
            uint256 amount = d.proceeds < available ? d.proceeds : available;
            available -= amount;
            bool delivered = _callController(d.controller, d.listingId, d.tokenId, amount);
            if (!delivered) {
                receivable += amount;
                _margin += SafeCastLib.toInt256(amount);
                failed = true;
            }
            emit ForeignCaptured(d.listingId, d.tokenId, amount, delivered);
        }
        if (failed) _splitMargin();
    }

    /// @dev Calls `onForeignCapture` on `controller` with `amount` wei, forwarding `FOREIGN_CALL_GAS`
    ///      and ignoring the return data. Returns whether the call succeeded. Reverts
    ///      `InsufficientGas` when the remaining gas could not fund the full forwarded amount.
    function _callController(address controller, uint256 listingId, uint256 tokenId, uint256 amount)
        internal
        returns (bool ok)
    {
        _requireCallGas();
        bytes4 selector = IForeignController.onForeignCapture.selector;
        uint256 gasLimit = FOREIGN_CALL_GAS;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), listingId)
            mstore(add(m, 0x24), tokenId)
            mstore(add(m, 0x44), amount)
            ok := call(gasLimit, controller, amount, m, 0x64, 0, 0)
        }
    }

    /// @dev Removes the listed item from backing and charges its value to `margin`. A GRAIL
    ///      item is removed with no proceeds. A foreign listing is removed with no proceeds.
    function _writeOff(uint256 requestId, uint256 listingId) internal {
        if (_grailAt[listingId] != 0) {
            _closeGrail(listingId, requestId, 0);
            return;
        }
        uint256 foreignAt = _foreignAt[listingId];
        if (foreignAt != 0) {
            ForeignListing memory f = _removeForeign(foreignAt - 1);
            emit ForeignCaptured(f.listingId, f.tokenId, 0, false);
            return;
        }
        Item memory it = _removeListed(listingId);
        _margin -= SafeCastLib.toInt256(it.value);
        emit WrittenOff(requestId, listingId, it.value);
    }

    /// @dev Takes back a token that FWA quarantined after a refunded delivery and holds it
    ///      unlisted. Backing is unchanged. A GRAIL item stays in `_grailItems` and is listed again
    ///      by the next `rotate`. A foreign listing keeps its entry and listing id with `notional`
    ///      zero until its controller withdraws it.
    function _recoverRefunded(IFWAClone fwa, uint256 listingId) internal {
        uint256 at = _grailAt[listingId];
        uint256 foreignAt = _foreignAt[listingId];
        if (at != 0) {
            _grailItems[at - 1].listingId = 0;
            delete _grailAt[listingId];
        } else if (foreignAt != 0) {
            _foreign[foreignAt - 1].notional = 0;
        } else {
            Item memory it = _removeListed(listingId);
            it.listingId = 0;
            _addItem(it);
        }
        _call(address(fwa), IFWAClone.recoverRefundedNFT.selector, listingId, 0);
    }

    /// @dev Splits positive `margin`. The mint line owed is covered first and stays in ordinary
    ///      NAV. The rest divides by `premiumBps : maintenanceBps : feedBps`. The premium share
    ///      stays in ordinary NAV. The maintenance and feed shares move from `receivable` to
    ///      `maintenanceReceivable` and the GRAIL receivable.
    function _splitMargin() internal {
        int256 signedMargin = _margin;
        if (signedMargin <= 0 || lifecycle == Lifecycle.Exported) return;
        uint256 amount = uint256(signedMargin);
        uint256 cover = amount < _mintLineOwed ? amount : _mintLineOwed;
        _mintLineOwed -= cover;
        uint256 rest = amount - cover;

        FeeSplit memory split = feeSplit;
        uint256 totalBps = uint256(split.premiumBps) + split.maintenanceBps + split.feedBps;
        uint256 maintenanceShare;
        uint256 feedShare;
        if (totalBps != 0) {
            maintenanceShare = rest * split.maintenanceBps / totalBps;
            feedShare = rest * split.feedBps / totalBps;
        }

        receivable -= maintenanceShare + feedShare;
        _maintenanceReceivable += maintenanceShare;
        _grail.receivable += feedShare;
        _margin = 0;
        emit MarginSplit(cover, rest - maintenanceShare - feedShare, maintenanceShare, feedShare);
    }

    /// @dev Sum of the receivables, including the proceeds owed to foreign controllers.
    function _bookedReceivables() internal view returns (uint256) {
        return receivable + _maintenanceReceivable + _grail.receivable + _foreignReceivable;
    }

    /// @dev Books `actual` FWA owner proceeds above the booked receivables as `receivable` and
    ///      `margin`, then splits the margin. The excess is the proceeds of requests opened directly
    ///      at the FWA pool, whose captures booked zero proceeds. Callers pass a value read while the
    ///      booking walk is level with FWA's processing queue. Returns the excess.
    function _bookSurplus(uint256 actual) internal returns (uint256 surplus) {
        uint256 booked = _bookedReceivables();
        if (actual <= booked) return 0;
        surplus = actual - booked;
        receivable += surplus;
        _margin += SafeCastLib.toInt256(surplus);
        _splitMargin();
        emit SurplusBooked(surplus);
    }

    /// @dev Withdraws FWA owner proceeds and credits them to the buckets. Returns false when
    ///      the booking walk is behind FWA's processing queue, or when no proceeds are held and no
    ///      foreign due is waiting. Proceeds
    ///      above the booked receivables enter as margin through `_bookSurplus`. Proceeds below them
    ///      emit `HarvestShortfall` and the gap is written down through `_writeDownReceivables`.
    function _harvest() internal returns (bool) {
        uint256 held = _ownerProceeds();
        if (nextSequenceToBook < _nextToProcess() || (held == 0 && _foreignDue.length == 0)) return false;

        uint256 received = held == 0 ? 0 : _call(address(fwaPool), IFWAClone.withdrawOwnerProceeds.selector, 0, 0);
        uint256 expected = _bookedReceivables();
        if (received < expected) {
            _writeDownReceivables(expected - received);
            emit HarvestShortfall(received, expected);
        }

        uint256 surplus = _bookSurplus(received);
        _payForeign();
        cash += receivable;
        maintenance += _maintenanceReceivable;
        _grail.fund += _grail.receivable;
        receivable = 0;
        _maintenanceReceivable = 0;
        _grail.receivable = 0;
        emit Harvested(received, surplus);
        return true;
    }

    /// @dev Lowers the booked receivables by `gap`: `receivable` first, then `maintenanceReceivable`,
    ///      then the GRAIL receivable, then the foreign receivable. `gap` is at most their sum.
    function _writeDownReceivables(uint256 gap) internal {
        uint256 cut = gap < receivable ? gap : receivable;
        receivable -= cut;
        gap -= cut;
        cut = gap < _maintenanceReceivable ? gap : _maintenanceReceivable;
        _maintenanceReceivable -= cut;
        gap -= cut;
        cut = gap < _grail.receivable ? gap : _grail.receivable;
        _grail.receivable -= cut;
        gap -= cut;
        _foreignReceivable -= gap;
    }

    /// @dev Cash that a mint or a kept Shape may use: `cash` less `claims` and the reserve of
    ///      `reserveBps` of ordinary NAV, or zero.
    function _spendable() internal view returns (uint256) {
        return _spendableAbove(nav() * _reserveBps / BPS);
    }

    /// @dev `cash` less `claims` and `reserve`, or zero. A batch passes the reserve read before its
    ///      first mint, so the items it has taken out of the books do not lower it.
    function _spendableAbove(uint256 reserve) internal view returns (uint256) {
        uint256 held = claims + reserve;
        return cash > held ? cash - held : 0;
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

    /// @dev `grail.pulls` rises by `count`, at most `MAX_SETTLE_ITEMS` per walk.
    function _recordPulls(uint256 count) internal {
        _grail.pulls += uint64(count);
    }

    /// @dev Board depth in items: `max(minItems, (nav - nav * reserveBps / 10_000) / meanRowCost)`,
    ///      with `nav` capped at `boardNavCap` when that is set, so NAV above the cap stays in `cash`.
    ///      `meanRowCost` is the share-weighted cost of a mix row at the current mint fee: its
    ///      backing plus the mint fee of each rung. `nav()` is net of `claims`. The target depth of a
    ///      mix row is `rowDepth(_boardItems(), shareBps)`.
    function _boardItems() internal view returns (uint256 items) {
        uint256 mean = _meanRowCost();
        if (mean != 0) {
            uint256 value = nav();
            uint256 cap = _boardNavCap;
            if (cap != 0 && value > cap) value = cap;
            items = (value - value * _reserveBps / BPS) / mean;
        }
        uint256 floor = minItems;
        return items > floor ? items : floor;
    }

    /// @dev Share-weighted cost of a mix row at the current mint fee, or zero when the mix is empty.
    function _meanRowCost() internal view returns (uint256) {
        uint256 shares = _mixShares;
        return shares == 0 ? 0 : (_mixBacking + _mintFee() * _mixRungs) / shares;
    }

    /// @dev FWA and Shapes reads used at several call sites. Each is one function so the external
    ///      call is compiled once.
    function _mintFee() internal view returns (uint256) {
        return _read(shapes, IShapes.mintFee.selector, 0);
    }

    function _totalWeight() internal view returns (uint256) {
        return _read(address(fwaPool), IFWAClone.totalWeight.selector, 0);
    }

    function _ownerProceeds() internal view returns (uint256) {
        return _read(address(fwaPool), IFWAClone.ownerProceeds.selector, 0);
    }

    function _nextToProcess() internal view returns (uint64) {
        return uint64(_read(address(fwaPool), IFWAClone.nextSequenceToProcess.selector, 0));
    }

    /// @dev True while FWA holds unsettled acquisitions or the booking walk is behind its processing queue.
    function _busy() internal view returns (bool) {
        return _unsettled() != 0 || nextSequenceToBook != _nextToProcess();
    }

    function _unsettled() internal view returns (uint256) {
        return _read(address(fwaPool), IFWAClone.unsettledAcquisitionCount.selector, 0);
    }

    /// @dev `priceEscrowed`, `listingId` and `status` of FWA acquisition `requestId`, which are the
    ///      third to fifth words of `acquisitions(requestId)`.
    function _acquisition(uint256 requestId) internal view returns (uint256 paid, uint256 listingId, uint256 status) {
        address fwa = address(fwaPool);
        bytes4 selector = IFWAClone.acquisitions.selector;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), requestId)
            if iszero(staticcall(gas(), fwa, m, 0x24, m, 0xa0)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            if lt(returndatasize(), 0xa0) { revert(0, 0) }
            paid := mload(add(m, 0x40))
            listingId := mload(add(m, 0x60))
            status := mload(add(m, 0x80))
        }
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

    /// @dev `randomWord` of FWA acquisition `requestId`, the sixth word of `acquisitionMeta(requestId)`.
    function _randomWord(uint256 requestId) internal view returns (uint256 word) {
        address fwa = address(fwaPool);
        bytes4 selector = IFWAClone.acquisitionMeta.selector;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), requestId)
            if iszero(staticcall(gas(), fwa, m, 0x24, m, 0xc0)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            if lt(returndatasize(), 0xc0) { revert(0, 0) }
            word := mload(add(m, 0xa0))
        }
    }
}
