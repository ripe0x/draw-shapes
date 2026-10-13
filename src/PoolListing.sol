// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {Denominations} from "shapes/lib/Denominations.sol";
import {PricingLib} from "./lib/PricingLib.sol";
import {PoolBooks} from "./PoolBooks.sol";
import {IFWAClone} from "./interfaces/IFWAClone.sol";

/// @title PoolListing
/// @notice Listing engine of `Pool`: fills queued replacements and held items and lists them on the
///         FWA pool.
/// @dev Runs by delegatecall from the `fallback` of `Pool` on the `PoolStorage` layout. `Pool`
///      reaches the entrypoints by calling itself, so they run inside the `nonReentrant` frame of
///      `open`, `settle` or `rotate` and carry no guard of their own. A direct call to this
///      contract reverts `NotDelegated`. A call to `Pool` from any other sender reverts `NotSelf`.
contract PoolListing is PoolBooks {
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    // ------------------------------------------------------------------ entrypoints

    /// @notice Queues the items each row lacks against its target depth, `MAX_OPEN_MINTS` entries
    ///         in all, then fills and lists the queue and the held items, `MAX_OPEN_MINTS` at most.
    ///         Returns the number listed.
    function openBoard() external onlyDelegated onlySelf returns (uint256) {
        uint256 queued = _replacementQueue.length - replacementHead;
        for (uint256 r; r < _mix.length; ++r) {
            uint256 target = PricingLib.rowDepth(minItems, _mix[r].shareBps);
            for (; queued < MAX_OPEN_MINTS && _rowCount[r] + _queuedByRow[r] < target; ++queued) {
                _enqueue(r);
            }
        }
        return _listBatch(MAX_OPEN_MINTS);
    }

    /// @notice Fills the queued replacements in order and lists them, then lists held items, at
    ///         most `max` items in all. Returns the number listed.
    function listBatch(uint256 max) external onlyDelegated onlySelf returns (uint256) {
        return _listBatch(max);
    }

    // ------------------------------------------------------------------ internal

    /// @dev Same rule as `PoolAdmin`. Completes the `PoolBooks` hook.
    function _chooseRow(uint256 requestId, uint256 capturedRow)
        internal
        view
        override
        returns (uint256 row, bool surprise)
    {
        return _pickRow(_randomWord(requestId), requestId, capturedRow);
    }

    /// @dev Fills the queued replacements in order and lists them, then lists held items, at most
    ///      `max` items in all. Returns the number listed.
    function _listBatch(uint256 max) internal returns (uint256 n) {
        uint256 fee = _mintFee();
        Item[] memory batch = new Item[](max);
        n = _collectQueue(batch, max, fee, nav() * _reserveBps / BPS);
        while (n < max && _held.length != 0) {
            batch[n++] = _removeHeld(_held.length - 1);
        }
        _listItems(batch, n, fee);
    }

    /// @dev Fills queue entries from `replacementHead` into `batch[n..max)`. Stops at the first
    ///      entry `_fill` cannot fund. Sets `oldestQueuedAt` to zero when the queue empties. Returns
    ///      the new item count.
    function _collectQueue(Item[] memory batch, uint256 max, uint256 fee, uint256 reserve)
        internal
        returns (uint256 n)
    {
        uint256 head = replacementHead;
        uint256 length = _replacementQueue.length;
        while (head < length && n < max) {
            uint256 row = _replacementQueue[head];
            (Item memory it, bool ok) = _fill(row, fee, reserve);
            if (!ok) break;
            batch[n++] = it;
            --_queuedByRow[row];
            ++head;
        }
        replacementHead = head;
        if (head == length) _oldestQueuedAt = 0;
        return n;
    }

    /// @dev Builds one token of `row` owned by this contract and not yet booked. A Shape row takes
    ///      a held Shape of its rung, else mints one. A Draw Pack row takes a held pack of equal
    ///      backing, else creates a pack from one held Shape per rung that has one and mints the
    ///      other rungs. Held items taken here leave the books until `_listItems` books the
    ///      result. Minting needs `_spendable()` to cover the backing and mint fees of the minted
    ///      Shapes. Returns `ok` false and changes nothing when it does not.
    function _fill(uint256 row, uint256 fee, uint256 reserve) internal returns (Item memory it, bool ok) {
        uint8[] storage rungs = _mix[row].rungs;
        uint256 n = rungs.length;
        uint256 value = _rowBackingWei[row];
        it.row = uint16(row);
        it.value = value;
        if (n == 1) {
            uint256[] storage held = _heldByDenom[rungs[0]];
            if (held.length != 0) {
                it = _removeHeld(_heldPos[shapes][held[held.length - 1]] - 1);
                it.row = uint16(row);
                return (it, true);
            }
            if (_spendableAbove(reserve) < value + fee) return (it, false);
            cash -= value + fee;
            it.collection = shapes;
            it.tokenId = _callFull(shapes, value + fee, IShapes.mintBatchTo.selector, value, 1, uint160(address(this)));
            return (it, true);
        }

        if (_heldPacks != 0) {
            for (uint256 i = _held.length; i != 0; --i) {
                Item storage candidate = _held[i - 1];
                if (candidate.collection == drawPacks && candidate.value == value) {
                    it = _removeHeld(i - 1);
                    it.row = uint16(row);
                    return (it, true);
                }
            }
        }
        uint256[] memory used = new uint256[](Denominations.COUNT);
        bool[] memory fromHeld = new bool[](n);
        uint32[] memory counts = new uint32[](Denominations.COUNT);
        uint256 cost;
        uint256 minted;
        for (uint256 i; i < n; ++i) {
            uint8 d = rungs[i];
            if (_heldByDenom[d].length > used[d]) {
                ++used[d];
                fromHeld[i] = true;
            } else {
                ++counts[d];
                ++minted;
                cost += Denominations.amountAt(d) + fee;
            }
        }
        if (cost != 0 && _spendableAbove(reserve) < cost) return (it, false);
        cash -= cost;
        uint256[] memory ids = new uint256[](n - minted);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            if (!fromHeld[i]) continue;
            uint256[] storage held = _heldByDenom[rungs[i]];
            uint256 id = held[held.length - 1];
            _removeHeld(_heldPos[shapes][id] - 1);
            _call(shapes, IERC721.approve.selector, uint160(drawPacks), id);
            ids[k++] = id;
        }
        it.collection = drawPacks;
        it.tokenId = _createPack(ids, counts, cost, value);
        return (it, true);
    }

    /// @dev Lists `batch[0..n)` on the FWA pool in chunks of `MAX_INVENTORY_BATCH` and books each
    ///      item as listed.
    function _listItems(Item[] memory batch, uint256 n, uint256 fee) internal {
        if (n == 0) return;
        uint256 chunk = _read(address(fwaPool), IFWAClone.MAX_INVENTORY_BATCH.selector, 0);
        FeeSplit memory split = feeSplit;
        for (uint256 start; start < n; start += chunk) {
            uint256 m = n - start < chunk ? n - start : chunk;
            IFWAClone.InventoryInput[] memory inputs = new IFWAClone.InventoryInput[](m);
            for (uint256 i; i < m; ++i) {
                Item memory it = batch[start + i];
                inputs[i] = IFWAClone.InventoryInput(it.collection, it.tokenId, _listingPrice(it, fee, split));
            }
            uint256[] memory ids = fwaPool.listNFTs(inputs);
            for (uint256 i; i < m; ++i) {
                Item memory it = batch[start + i];
                it.listingId = ids[i];
                _addItem(it);
            }
        }
    }

    function _listingPrice(Item memory it, uint256 fee, FeeSplit memory split) internal view returns (uint256) {
        uint256 value = it.value;
        return PricingLib.listingPrice(
            value,
            split.premiumBps,
            split.maintenanceBps,
            split.feedBps,
            PricingLib.mintLineBps(fee * _mix[it.row].rungs.length, value)
        );
    }
}
