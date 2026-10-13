// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {PoolStorage} from "./PoolStorage.sol";
import {IFWAClone} from "./interfaces/IFWAClone.sol";

/// @title PoolBooks
/// @notice Settlement of FWA acquisitions and harvest of FWA owner proceeds into the buckets,
///         shared by `Pool` and `PoolAdmin`.
abstract contract PoolBooks is PoolStorage {
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
    ///      to `end`. Returns the new `nextSequenceToBook`. Every sequence passed counts as one pull
    ///      of demand, whatever its status, at the hour of booking. A Fulfilled acquisition is a capture:
    ///      FWA pays the owner `paid - (paid - base) / 2`, and a request without a recorded base
    ///      books zero proceeds, which `_bookSurplus` books from FWA's owner proceeds. A refunded
    ///      delivery returns its token to held items. A DeliveryPending acquisition is written off:
    ///      its item leaves backing and its value is charged to `margin`, with no proceeds and no
    ///      replacement. If the delivery later completes, FWA accrues owner proceeds and
    ///      `_bookSurplus` books them. If the purchaser later refunds, the admin recovers the token
    ///      with `adminCall(recoverRefundedNFT)` and `sweep`. Expired, Refunded and TimedOut
    ///      acquisitions book nothing. FWA only advances its processing queue past acquisitions in
    ///      those statuses, so any other status books nothing and the walk passes it.
    function _walk(IFWAClone fwa, uint64 end, uint256 maxItems) internal returns (uint64 seq) {
        seq = nextSequenceToBook;
        if (seq >= end) return seq;

        uint64 start = seq;
        uint256 mintFee = _mintFee();
        for (uint256 n; seq < end && n < maxItems; ++n) {
            uint256 requestId = _read(address(fwa), IFWAClone.requestIdAtSequence.selector, seq);
            (uint256 paid, uint256 listingId, uint256 status) = _acquisition(requestId);
            if (status == uint256(IFWAClone.AcquisitionStatus.Fulfilled)) {
                _capture(requestId, listingId, paid, mintFee);
            } else if (status == uint256(IFWAClone.AcquisitionStatus.DeliveryRefunded)) {
                _recoverRefunded(fwa, listingId);
            } else if (status == uint256(IFWAClone.AcquisitionStatus.DeliveryPending)) {
                _writeOff(requestId, listingId);
            }
            ++seq;
        }
        if (seq != start) {
            nextSequenceToBook = seq;
            _recordPulls(seq - start);
            emit Settled(seq);
        }
    }

    /// @dev Books one Fulfilled acquisition. A GRAIL listing credits its proceeds to the track's
    ///      receivable and resets the track. An ordinary item leaves backing, its proceeds join
    ///      `receivable` and `margin`, and its row is queued for a replacement.
    function _capture(uint256 requestId, uint256 listingId, uint256 paid, uint256 mintFee) internal {
        uint256 stored = _basePlusOne[requestId];
        uint256 proceeds = stored == 0 ? 0 : paid - (paid - (stored - 1)) / 2;
        uint256 t = _grailTrack(listingId);
        if (t <= MAJOR) {
            _closeGrail(t, requestId, proceeds);
            return;
        }
        Item memory it = _removeListed(listingId);
        receivable += proceeds;
        margin += SafeCastLib.toInt256(proceeds) - SafeCastLib.toInt256(it.value);
        mintLineOwed += mintFee * _mix[it.row].rungs.length;
        replacementQueue.push(it.row);
        emit Captured(requestId, listingId, it.row, it.value, proceeds);
        _splitMargin();
    }

    /// @dev Track whose pack is listed under `listingId`, or 2 when none is.
    function _grailTrack(uint256 listingId) internal view returns (uint256 t) {
        while (t <= MAJOR && grail[t].listingId != listingId) ++t;
    }

    /// @dev Clears track `t` after its pack left the pool. `proceeds` joins the track's receivable.
    function _closeGrail(uint256 t, uint256 requestId, uint256 proceeds) internal {
        Grail storage g = grail[t];
        g.receivable += proceeds;
        _resetGrail(g);
        emit GrailCaptured(t, requestId, proceeds);
    }

    /// @dev Removes the listed item from backing and charges its value to `margin`. A GRAIL
    ///      listing is cleared with no proceeds.
    function _writeOff(uint256 requestId, uint256 listingId) internal {
        uint256 t = _grailTrack(listingId);
        if (t <= MAJOR) {
            _closeGrail(t, requestId, 0);
            return;
        }
        Item memory it = _removeListed(listingId);
        margin -= SafeCastLib.toInt256(it.value);
        emit WrittenOff(requestId, listingId, it.value);
    }

    /// @dev Takes back a token that FWA quarantined after a refunded delivery and holds it
    ///      unlisted. Backing is unchanged. A GRAIL pack stays the track's pack and is listed again
    ///      by the next `rotate`.
    function _recoverRefunded(IFWAClone fwa, uint256 listingId) internal {
        uint256 t = _grailTrack(listingId);
        if (t <= MAJOR) {
            grail[t].listingId = 0;
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
    ///      `maintenanceReceivable` and the GRAIL receivables, split by `minorShareBps`.
    function _splitMargin() internal {
        int256 signedMargin = margin;
        if (signedMargin <= 0 || lifecycle == Lifecycle.Exported) return;
        uint256 amount = uint256(signedMargin);
        uint256 cover = amount < mintLineOwed ? amount : mintLineOwed;
        mintLineOwed -= cover;
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
        maintenanceReceivable += maintenanceShare;
        uint256 minorFeed = feedShare * split.minorShareBps / BPS;
        grail[MINOR].receivable += minorFeed;
        grail[MAJOR].receivable += feedShare - minorFeed;
        margin = 0;
        emit MarginSplit(cover, rest - maintenanceShare - feedShare, maintenanceShare, feedShare);
    }

    /// @dev Sum of the four receivables.
    function _bookedReceivables() internal view returns (uint256) {
        return receivable + maintenanceReceivable + grail[MINOR].receivable + grail[MAJOR].receivable;
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
        margin += SafeCastLib.toInt256(surplus);
        _splitMargin();
        emit SurplusBooked(surplus);
    }

    /// @dev Withdraws FWA owner proceeds and credits them to the buckets. Returns false when
    ///      the booking walk is behind FWA's processing queue or no proceeds are held. Proceeds
    ///      above the booked receivables enter as margin through `_bookSurplus`. Proceeds below them
    ///      emit `HarvestShortfall` and the gap is written down through `_writeDownReceivables`.
    function _harvest() internal returns (bool) {
        if (nextSequenceToBook < _nextToProcess() || _ownerProceeds() == 0) return false;

        uint256 received = _call(address(fwaPool), IFWAClone.withdrawOwnerProceeds.selector, 0, 0);
        uint256 expected = _bookedReceivables();
        if (received < expected) {
            _writeDownReceivables(expected - received);
            emit HarvestShortfall(received, expected);
        }

        uint256 surplus = _bookSurplus(received);
        cash += receivable;
        maintenance += maintenanceReceivable;
        grail[MINOR].bucket += grail[MINOR].receivable;
        grail[MAJOR].bucket += grail[MAJOR].receivable;
        receivable = 0;
        maintenanceReceivable = 0;
        grail[MINOR].receivable = 0;
        grail[MAJOR].receivable = 0;
        emit Harvested(received, surplus);
        return true;
    }

    /// @dev Lowers the booked receivables by `gap`: `receivable` first, then `maintenanceReceivable`,
    ///      then the MINOR and MAJOR GRAIL receivables. `gap` is at most their sum.
    function _writeDownReceivables(uint256 gap) internal {
        uint256 cut = gap < receivable ? gap : receivable;
        receivable -= cut;
        gap -= cut;
        cut = gap < maintenanceReceivable ? gap : maintenanceReceivable;
        maintenanceReceivable -= cut;
        gap -= cut;
        for (uint256 t; t <= MAJOR; ++t) {
            Grail storage g = grail[t];
            cut = gap < g.receivable ? gap : g.receivable;
            g.receivable -= cut;
            gap -= cut;
        }
    }

    /// @dev Adds `count` pulls to the current clock hour. A slot last written in an earlier hour
    ///      is reset first. Each listed GRAIL track's `pullsSinceList` rises by `count`.
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
}
