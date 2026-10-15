// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {Denominations} from "shapes/lib/Denominations.sol";
import {IShapePacks} from "draw-packs/interfaces/IShapePacks.sol";
import {PricingLib} from "./lib/PricingLib.sol";
import {PoolBooks} from "./PoolBooks.sol";
import {IFWAClone} from "./interfaces/IFWAClone.sol";

/// @title PoolListing
/// @notice Listing engine of `Pool`: fills queued replacements and held items and lists them on the
///         FWA pool. Runs the GRAIL: mint, merge, opening five and price decay. Serves the read-only
///         getters of parameters, rows, queues, held Shapes and migration state.
/// @dev Runs by delegatecall from the `fallback` of `Pool` on the `PoolStorage` layout. `Pool`
///      reaches the entrypoints by calling itself, so they run inside the `nonReentrant` frame of
///      `open`, `settle` or `rotate` and carry no guard of their own. A direct call to this
///      contract reverts `NotDelegated`. A call to `Pool` from any other sender reverts `NotSelf`.
contract PoolListing is PoolBooks {
    /// @dev Pieces minted by one `grailStep`.
    uint256 internal constant MAX_GRAIL_MINTS_PER_ROTATE = 3;
    /// @dev Merges run by one `grailStep`.
    uint256 internal constant MAX_GRAIL_MERGES_PER_ROTATE = 2;
    /// @dev Pieces composed into one item of five pieces.
    uint256 internal constant FIVE_PIECES = 5;

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    // ------------------------------------------------------------------ entrypoints

    /// @notice Forms the opening GRAIL item when the fund covers it, queues the items each row lacks
    ///         against its target depth, `MAX_OPEN_MINTS` entries in all, then fills and lists the queue and the held items, `MAX_OPEN_MINTS` at most.
    ///         Returns the number listed.
    function openBoard() external onlyDelegated onlySelf returns (uint256) {
        if (_grail.cycleStartedAt == 0) _grail.cycleStartedAt = uint64(block.timestamp);
        _openGrail();
        _queueMissing(MAX_OPEN_MINTS);
        return _listBatch(MAX_OPEN_MINTS);
    }

    /// @notice Queues the items each row lacks against its target depth, until the queue holds
    ///         `cap` entries. A row's count is its listed, held and queued items.
    function queueMissing(uint256 cap) external onlyDelegated onlySelf {
        _queueMissing(cap);
    }

    /// @notice Fills the queued replacements in order and lists them, then lists held items, at
    ///         most `max` items in all. Returns the number listed.
    function listBatch(uint256 max) external onlyDelegated onlySelf returns (uint256) {
        return _listBatch(max);
    }

    /// @dev `listBps` is 1 to 10,000. `pieceFloorWei` is nonzero and at most one piece. `floorWei` is
    ///      nonzero and at most `5 ETH * listBps / 10_000` on the mainnet ladder.
    function setGrail(uint256 decayWeiPerPull, uint256 pieceFloorWei, uint256 floorWei, uint256 listBps)
        external
        onlyDelegated
    {
        _admin();
        _setGrail(decayWeiPerPull, pieceFloorWei, floorWei, listBps);
    }

    /// @dev `stepUpSeconds` is below `stepDownSeconds`. A completed cycle steps `nextTargetWei` one
    ///      rung up when it took less than `stepUpSeconds` and one rung down when it took more than
    ///      `stepDownSeconds`.
    function setGrailStep(uint32 stepUpSeconds, uint32 stepDownSeconds) external onlyDelegated {
        _admin();
        _setGrailStep(stepUpSeconds, stepDownSeconds);
    }

    /// @dev `targetWei` is 5, 10, 25, 50 or 100 ETH on the mainnet ladder. The running cycle keeps
    ///      its target, and the next cycle reads this one.
    function setGrailTarget(uint256 targetWei) external onlyDelegated {
        _admin();
        _setGrailTarget(targetWei);
    }

    /// @notice The GRAIL fund, receivable and parameters.
    function grail() external view onlyDelegated returns (Grail memory) {
        return _grail;
    }

    /// @notice The GRAIL items, listed or not.
    function grailItems() external view onlyDelegated returns (GrailItem[] memory) {
        return _grailItems;
    }

    /// @notice The foreign listings.
    function foreignListings() external view onlyDelegated returns (ForeignListing[] memory) {
        return _foreign;
    }

    /// @notice Takes `tokenId` of `collection` from the admin, lists it on the FWA pool at `priceWei`
    ///         and records it as a foreign listing of `controller`, keyed by the FWA listing id.
    ///         The admin approves this contract for the token first. Live only. Reverts `ForeignFull`
    ///         at `MAX_FOREIGN` entries, `AlreadyRegistered` for a token the pool accounts for,
    ///         `ZeroAddress` for a zero `collection` or `controller`, `PriceOutOfRange` for a price
    ///         with no selection weight and `ProbCapExceeded` when the Active and Staged GRAIL and foreign weight
    ///         plus the new listing's weight would pass `grailProbCapBps` of the FWA selection weight.
    function registerForeign(address collection, uint256 tokenId, address controller, uint256 priceWei)
        external
        onlyDelegated
        onlyAdmin
        nonReentrant
    {
        if (lifecycle != Lifecycle.Live) revert NotLive();
        if (collection == address(0) || controller == address(0)) revert ZeroAddress();
        if (_registered[collection][tokenId]) revert AlreadyRegistered();
        if (_foreign.length >= MAX_FOREIGN) revert ForeignFull();
        uint256 weight = _boundedWeight(priceWei);
        (uint256 capped, uint256 total) = _capWeights();
        if ((capped + weight) * BPS > (total + weight) * _grailProbCapBps) revert ProbCapExceeded();
        _transfer(collection, msg.sender, address(this), tokenId);
        _call(collection, IERC721.approve.selector, uint160(address(fwaPool)), tokenId);
        uint256 id =
            _callFull(address(fwaPool), 0, IFWAClone.listNFT.selector, uint160(collection), tokenId, priceWei);
        _foreign.push(ForeignListing(collection, tokenId, controller, id, priceWei, 0));
        _foreignAt[id] = _foreign.length;
        _registered[collection][tokenId] = true;
        emit ForeignRegistered(collection, tokenId, controller, id, priceWei);
    }

    /// @notice Sets the list price of foreign listing `listingId` to `priceWei`. Controller only,
    ///         while the listing is Active and FWA holds no unsettled acquisition and the booking walk
    ///         is level (`FwaBusy`). The price must differ from the current one by at least 1 percent of
    ///         it (`RepriceTooSmall`), at most one reprice per `rotateInterval` is accepted
    ///         (`RepriceTooSoon`) and a price with no selection weight reverts `PriceOutOfRange`. A price
    ///         that raises the entry's selection weight is refused with `ProbCapExceeded` when the
    ///         Active and Staged GRAIL and foreign weight would pass `grailProbCapBps` of the FWA selection weight.
    function repriceForeign(uint256 listingId, uint256 priceWei) external onlyDelegated nonReentrant {
        ForeignListing storage f = _foreignOf(listingId);
        if (msg.sender != f.controller) revert NotController();
        if (_busy()) revert FwaBusy();
        uint256 old = f.notional;
        if (old == 0 || _listingStatus(listingId) != uint256(IFWAClone.ListingStatus.Active)) {
            revert ListingNotActive(listingId);
        }
        uint256 newWeight = _boundedWeight(priceWei);
        if ((priceWei > old ? priceWei - old : old - priceWei) * 100 < old) revert RepriceTooSmall();
        if (f.lastRepriceAt != 0 && block.timestamp < f.lastRepriceAt + rotateInterval) revert RepriceTooSoon();
        uint256 oldWeight = PricingLib.weightOf(old);
        if (newWeight > oldWeight) {
            (uint256 capped, uint256 total) = _capWeights();
            if ((capped - oldWeight + newWeight) * BPS > (total - oldWeight + newWeight) * _grailProbCapBps) {
                revert ProbCapExceeded();
            }
        }
        _call(address(fwaPool), IFWAClone.updatePrice.selector, listingId, priceWei);
        f.notional = priceWei;
        f.lastRepriceAt = uint64(block.timestamp);
        emit ForeignRepriced(listingId, priceWei);
    }

    /// @notice Withdraws foreign listing `listingId` and sends its token to `to`. Controller only.
    ///         A listed entry needs FWA to hold no unsettled acquisition and the booking walk to be
    ///         level (`FwaBusy`). An entry left unlisted by a refunded delivery needs neither.
    function withdrawForeign(uint256 listingId, address to) external onlyDelegated nonReentrant {
        ForeignListing storage f = _foreignOf(listingId);
        if (msg.sender != f.controller) revert NotController();
        if (to == address(0)) revert ZeroAddress();
        if (f.notional != 0 && _busy()) revert FwaBusy();
        _releaseForeign(_foreignAt[listingId] - 1, to);
    }

    /// @notice Board depth in items: `max(minItems, (nav - nav * reserveBps / 10_000) /
    ///         meanRowCost)`, with `meanRowCost` the share-weighted backing plus mint fee of the mix rows.
    function boardItems() external view onlyDelegated returns (uint256) {
        return _boardItems();
    }

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

    /// @notice Largest share of the FWA selection weight, in bps, that the listed GRAIL ladder holds.
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
    ///         requestId)`. A row's count is its listed, held and queued items. Returns
    ///         `type(uint256).max` when no row is below its target.
    function chooseRow(uint256 requestId, uint256 capturedRow) external view onlyDelegated returns (uint256, bool) {
        return _chooseRow(requestId, capturedRow);
    }

    /// @notice Number of held ordinary items.
    function heldCount() external view onlyDelegated returns (uint256) {
        return _held.length;
    }

    /// @notice Token ids of the held Shapes of ladder index `denom`.
    function heldShapes(uint8 denom) external view onlyDelegated returns (uint256[] memory) {
        return _heldByDenom[denom];
    }

    /// @notice Lists unlisted GRAIL items, mints pieces from the fund and runs merges. At most
    ///         `MAX_GRAIL_MINTS_PER_ROTATE` pieces and `MAX_GRAIL_MERGES_PER_ROTATE` merges per call.
    ///         The caller ensures FWA holds no unsettled acquisition. Returns whether anything changed.
    function grailStep() external onlyDelegated onlySelf returns (bool changed) {
        changed = _relistGrail();
        uint256 fee = _mintFee();
        for (uint256 n; n < MAX_GRAIL_MINTS_PER_ROTATE && _canMint(fee); ++n) {
            _grail.fund -= GRAIL_PIECE + fee;
            uint256 id = _mintPieces(1, fee);
            _publish(shapes, id, GRAIL_PIECE, GRAIL_PIECE);
            changed = true;
        }
        for (uint256 n; n < MAX_GRAIL_MERGES_PER_ROTATE && _merge(); ++n) {
            changed = true;
        }
    }

    /// @notice Applies the price decay to every Active GRAIL listing: the price falls to `max(floor,
    ///         notional - decayWeiPerPull * (grail.pulls - listedAtPull))` when that is at least 1 percent below
    ///         the notional and the Active and Staged GRAIL and foreign weight at the new price stays within
    ///         `grailProbCapBps` of the FWA selection weight. The caller ensures FWA holds no
    ///         unsettled acquisition. Returns whether a price changed.
    function grailReprice() external onlyDelegated onlySelf returns (bool changed) {
        uint256 n = _grailItems.length;
        (uint256 weight, uint256 total) = _capWeights();
        Grail memory g = _grail;
        for (uint256 i; i < n; ++i) {
            GrailItem storage it = _grailItems[i];
            if (it.listingId == 0 || _listingStatus(it.listingId) != uint256(IFWAClone.ListingStatus.Active)) continue;
            uint256 old = it.notional;
            uint256 next = PricingLib.decayedNotional(
                old,
                g.decayWeiPerPull,
                g.pulls - it.listedAtPull,
                it.backing == GRAIL_PIECE ? g.pieceFloorWei : g.floorWei
            );
            if (next >= old || old - next < old / 100) continue;
            uint256 oldWeight = PricingLib.weightOf(old);
            uint256 nextWeight = PricingLib.weightOf(next);
            uint256 newWeight = weight - oldWeight + nextWeight;
            uint256 newTotal = total - oldWeight + nextWeight;
            if (newWeight * BPS > newTotal * _grailProbCapBps) continue;
            (weight, total) = (newWeight, newTotal);
            _call(address(fwaPool), IFWAClone.updatePrice.selector, it.listingId, next);
            it.notional = next;
            it.listedAtPull = g.pulls;
            emit GrailListed(it.listingId, it.collection, it.tokenId, it.backing, next);
            changed = true;
        }
    }

    /// @dev Foreign listing `listingId`, or reverts `UnknownListing`.
    function _foreignOf(uint256 listingId) internal view returns (ForeignListing storage) {
        uint256 at = _foreignAt[listingId];
        if (at == 0) revert UnknownListing(listingId);
        return _foreign[at - 1];
    }

    /// @dev `PricingLib.weightOf(priceWei)`, or reverts `PriceOutOfRange` where `weightOf` would revert:
    ///      a zero price or a price above `PricingLib.NUM`.
    function _boundedWeight(uint256 priceWei) internal pure returns (uint256) {
        if (priceWei == 0 || priceWei > PricingLib.NUM) revert PriceOutOfRange();
        return PricingLib.weightOf(priceWei);
    }

    /// @dev Selection weight of the Active and Staged GRAIL and foreign listings, and the FWA
    ///      selection weight once the Staged ones are activated (`totalWeight` plus their weight).
    function _capWeights() internal view returns (uint256 weight, uint256 total) {
        (uint256 grailWeight, uint256 grailStaged) = _grailWeight();
        (uint256 foreignWeight, uint256 foreignStaged) = _foreignWeight();
        weight = grailWeight + foreignWeight;
        total = _totalWeight() + grailStaged + foreignStaged;
    }

    /// @dev Selection weight of the Active and Staged GRAIL listings, and of the Staged ones alone.
    ///      A Staged listing joins FWA `totalWeight` when it is activated.
    function _grailWeight() internal view returns (uint256 weight, uint256 staged) {
        for (uint256 i; i < _grailItems.length; ++i) {
            uint256 id = _grailItems[i].listingId;
            if (id == 0) continue;
            (uint256 w, uint256 s) = _liveWeight(id, _grailItems[i].notional);
            weight += w;
            staged += s;
        }
    }

    /// @dev Selection weight of the Active and Staged foreign listings, and of the Staged ones alone.
    function _foreignWeight() internal view returns (uint256 weight, uint256 staged) {
        for (uint256 i; i < _foreign.length; ++i) {
            if (_foreign[i].notional == 0) continue;
            (uint256 w, uint256 s) = _liveWeight(_foreign[i].listingId, _foreign[i].notional);
            weight += w;
            staged += s;
        }
    }

    /// @dev Weight of FWA listing `id` at `notional` when it is Active or Staged, and the same weight
    ///      as `staged` when it is Staged. Zero otherwise.
    function _liveWeight(uint256 id, uint256 notional) internal view returns (uint256 weight, uint256 staged) {
        uint256 status = _listingStatus(id);
        if (status == uint256(IFWAClone.ListingStatus.Active)) {
            weight = PricingLib.weightOf(notional);
        } else if (status == uint256(IFWAClone.ListingStatus.Staged)) {
            weight = PricingLib.weightOf(notional);
            staged = weight;
        }
    }

    /// @notice True when `grailStep` has work: an unlisted item, a piece the fund can mint, or a
    ///         merge whose inputs are listed.
    function grailReady() external view onlyDelegated returns (bool) {
        for (uint256 i; i < _grailItems.length; ++i) {
            if (_grailItems[i].listingId == 0) return true;
        }
        if (_canMint(_mintFee())) return true;
        (uint256 out,) = _recipe();
        return out != 0;
    }

    // ------------------------------------------------------------------ GRAIL

    /// @dev Mints five pieces from the fund, composes them into one item of five pieces and lists
    ///      it at its backing. Runs when no GRAIL item exists and the fund covers the five mints.
    function _openGrail() internal {
        uint256 fee = _mintFee();
        uint256 cost = FIVE_PIECES * (GRAIL_PIECE + fee);
        if (_grailItems.length != 0 || _grail.fund < cost) return;
        _grail.fund -= cost;
        uint256 first = _mintPieces(FIVE_PIECES, fee);
        uint256[] memory burn = new uint256[](FIVE_PIECES - 1);
        for (uint256 i; i < burn.length; ++i) {
            burn[i] = first + 1 + i;
        }
        IShapes(shapes).compose(first, burn);
        _publish(shapes, first, FIVE_PIECES * GRAIL_PIECE, FIVE_PIECES * GRAIL_PIECE);
    }

    /// @dev True when the fund covers a piece and its mint fee and the caps on pieces and items
    ///      allow another. Done items do not count against the building cap.
    function _canMint(uint256 fee) internal view returns (bool) {
        if (_grail.fund < GRAIL_PIECE + fee) return false;
        uint256 pieces;
        uint256 building;
        for (uint256 i; i < _grailItems.length; ++i) {
            GrailItem storage it = _grailItems[i];
            if (it.done) continue;
            ++building;
            if (it.backing == GRAIL_PIECE) ++pieces;
        }
        return building < MAX_BUILDING_ITEMS && pieces < MAX_PIECES;
    }

    /// @dev Mints `quantity` pieces to this contract and returns the first token id. The ids are
    ///      consecutive. The caller reduces the fund.
    function _mintPieces(uint256 quantity, uint256 fee) internal returns (uint256 first) {
        uint256 cost = quantity * (GRAIL_PIECE + fee);
        first = _callFull(shapes, cost, IShapes.mintBatchTo.selector, GRAIL_PIECE, quantity, uint160(address(this)));
        emit GrailMinted(first, quantity, cost);
    }

    /// @dev Lists the GRAIL item `tokenId` of `collection` at `notional` and books it. An item
    ///      whose backing equals the cycle's target is the completed GRAIL: the cycle ends and the
    ///      next one starts with `nextTargetWei`.
    function _publish(address collection, uint256 tokenId, uint256 backing_, uint256 notional) internal {
        bool done = backing_ == _grail.targetWei;
        if (_grailFull(done)) revert GrailItemsFull();
        uint256 id = _callFull(address(fwaPool), 0, IFWAClone.listNFT.selector, uint160(collection), tokenId, notional);
        _addGrailItem(GrailItem(collection, done, tokenId, backing_, notional, id, _grail.pulls));
        emit GrailListed(id, collection, tokenId, backing_, notional);
        if (done) {
            _stepTarget();
            emit GrailCycleCompleted(_grail.cycleId++, _grail.nextTargetWei);
            _grail.targetWei = _grail.nextTargetWei;
            _grail.cycleStartedAt = uint64(block.timestamp);
        }
    }

    /// @dev Moves `nextTargetWei` one rung up the 5, 10, 25, 50, 100 ETH ladder when the cycle took
    ///      less than `stepUpSeconds`, and one rung down when it took more than `stepDownSeconds`.
    ///      The ends of the ladder stay.
    function _stepTarget() internal {
        Grail storage g = _grail;
        uint256 elapsed = block.timestamp - g.cycleStartedAt;
        uint256 units = g.nextTargetWei / Denominations.UNIT;
        if (elapsed < g.stepUpSeconds) {
            units = units == 500 ? 1_000 : units == 1_000 ? 2_500 : units == 2_500 ? 5_000 : 10_000;
        } else if (elapsed > g.stepDownSeconds) {
            units = units == 10_000 ? 5_000 : units == 5_000 ? 2_500 : units == 2_500 ? 1_000 : 500;
        }
        g.nextTargetWei = units * Denominations.UNIT;
    }

    /// @dev Lists every unlisted GRAIL item at its stored `notional`. Returns whether one was listed.
    function _relistGrail() internal returns (bool listed) {
        for (uint256 i; i < _grailItems.length; ++i) {
            GrailItem storage it = _grailItems[i];
            if (it.listingId != 0) continue;
            uint256 id = _callFull(
                address(fwaPool), 0, IFWAClone.listNFT.selector, uint160(it.collection), it.tokenId, it.notional
            );
            it.listingId = id;
            it.listedAtPull = _grail.pulls;
            _grailAt[id] = i + 1;
            emit GrailListed(id, it.collection, it.tokenId, it.backing, it.notional);
            listed = true;
        }
    }

    /// @dev Picks the largest recipe whose output fits the cycle target and whose inputs are
    ///      eligible, and returns the output backing in wei and the positions in `_grailItems` of
    ///      the inputs in ascending order. `out` is zero when no recipe is ready. Eligible items
    ///      are listed with an Active FWA listing and are not the completed GRAIL. A recipe whose output is the
    ///      completed GRAIL waits while `MAX_DONE_ITEMS` done items exist. Recipes, by
    ///      output in ladder units: 10,000 from two 5,000; 5,000 from two 2,500; 2,500 from two
    ///      1,000 and one 500; 1,000 from two 500; 500 from five pieces.
    function _recipe() internal view returns (uint256 out, uint256[] memory idx) {
        uint256 n = _grailItems.length;
        uint256[] memory units = new uint256[](n);
        uint256[5] memory count; // eligible items of 100, 500, 1000, 2500, 5000 units
        uint256 doneItems;
        for (uint256 i; i < n; ++i) {
            GrailItem storage it = _grailItems[i];
            if (it.done) {
                ++doneItems;
                continue;
            }
            uint256 id = it.listingId;
            if (id == 0 || _listingStatus(id) != uint256(IFWAClone.ListingStatus.Active)) continue;
            uint256 u = it.backing / Denominations.UNIT;
            units[i] = u;
            if (u == 100) ++count[0];
            else if (u == 500) ++count[1];
            else if (u == 1_000) ++count[2];
            else if (u == 2_500) ++count[3];
            else if (u == 5_000) ++count[4];
        }
        uint256 target = _grail.targetWei / Denominations.UNIT;
        uint256 outUnits;
        uint256 kindA;
        uint256 nA;
        uint256 kindB;
        if (target >= 10_000 && count[4] >= 2) (outUnits, kindA, nA) = (10_000, 5_000, 2);
        else if (target >= 5_000 && count[3] >= 2) (outUnits, kindA, nA) = (5_000, 2_500, 2);
        else if (target >= 2_500 && count[2] >= 2 && count[1] >= 1) (outUnits, kindA, nA, kindB) =
        (2_500, 1_000, 2, 500);
        else if (target >= 1_000 && count[1] >= 2) (outUnits, kindA, nA) = (1_000, 500, 2);
        else if (target >= 500 && count[0] >= FIVE_PIECES) (outUnits, kindA, nA) = (500, 100, FIVE_PIECES);
        else return (0, idx);
        if (outUnits * Denominations.UNIT == _grail.targetWei && doneItems >= MAX_DONE_ITEMS) return (0, idx);

        uint256 needB = kindB == 0 ? 0 : 1;
        idx = new uint256[](nA + needB);
        uint256 found;
        for (uint256 i; i < n && found < idx.length; ++i) {
            if (units[i] == kindA && nA != 0) {
                idx[found++] = i;
                --nA;
            } else if (units[i] == kindB && needB != 0) {
                idx[found++] = i;
                --needB;
            }
        }
        out = outUnits * Denominations.UNIT;
    }

    /// @dev Runs the ready recipe, if any. Withdraws the inputs' listings, then composes them into
    ///      one Shape when the output backing is a ladder denomination, or packs them into a Draw
    ///      Pack otherwise, and lists the output at `backing * listBps / 10_000`. Returns whether a
    ///      recipe ran.
    function _merge() internal returns (bool) {
        (uint256 out, uint256[] memory idx) = _recipe();
        if (out == 0) return false;
        uint256[] memory ids = new uint256[](0);
        for (uint256 k = idx.length; k != 0; --k) {
            GrailItem memory it = _removeGrailItem(idx[k - 1]);
            _withdrawListing(it.listingId, address(this));
            ids = _concat(ids, _shapesOf(it));
        }
        address collection = shapes;
        uint256 tokenId = ids[0];
        if (Denominations.isSupported(out)) {
            uint256[] memory burn = new uint256[](ids.length - 1);
            for (uint256 i; i < burn.length; ++i) {
                burn[i] = ids[i + 1];
            }
            IShapes(shapes).compose(tokenId, burn);
        } else {
            for (uint256 i; i < ids.length; ++i) {
                _call(shapes, IERC721.approve.selector, uint160(drawPacks), ids[i]);
            }
            collection = drawPacks;
            tokenId = _createPack(ids, new uint32[](Denominations.COUNT), 0, out);
        }
        uint256 listBps = _grail.listBps;
        uint256 cycle = _grail.cycleId;
        _publish(collection, tokenId, out, out * listBps / BPS);
        emit GrailMerged(tokenId, out, idx.length, _grail.cycleId != cycle);
        return true;
    }

    /// @dev Shape ids held by GRAIL item `it`: the Shape itself, or the contents of a Draw Pack,
    ///      which is opened to this contract.
    function _shapesOf(GrailItem memory it) internal returns (uint256[] memory ids) {
        if (it.collection == shapes) {
            ids = new uint256[](1);
            ids[0] = it.tokenId;
            return ids;
        }
        IShapePacks packs = IShapePacks(drawPacks);
        ids = packs.contentsOf(it.tokenId);
        packs.open(it.tokenId);
    }

    function _concat(uint256[] memory a, uint256[] memory b) internal pure returns (uint256[] memory c) {
        c = new uint256[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            c[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            c[a.length + i] = b[i];
        }
    }

    // ------------------------------------------------------------------ internal

    /// @dev Appends rows to the replacement queue in row order, each up to its target depth
    ///      `rowDepth(_boardItems(), shareBps)`, until the queue holds `cap` entries.
    function _queueMissing(uint256 cap) internal {
        uint256 queued = _replacementQueue.length - replacementHead;
        uint256 items = _boardItems();
        for (uint256 r; r < _mix.length; ++r) {
            uint256 target = PricingLib.rowDepth(items, _mix[r].shareBps);
            for (; queued < cap && _rowCount[r] + _queuedByRow[r] < target; ++queued) {
                _enqueue(r);
            }
        }
    }

    /// @dev Completes the `PoolBooks` hook.
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
