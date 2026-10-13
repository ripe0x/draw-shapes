// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {Denominations} from "shapes/lib/Denominations.sol";
import {IShapePacks} from "draw-packs/interfaces/IShapePacks.sol";
import {PricingLib} from "./lib/PricingLib.sol";
import {IFWAClone} from "./interfaces/IFWAClone.sol";
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
///      Tracks are indexed `MINOR = 0` and `MAJOR = 1`. Share, claim and bucket amounts are in wei.
contract Pool is ReentrancyGuard {
    // ------------------------------------------------------------------ types

    enum Lifecycle {
        Opening,
        Live,
        Exiting,
        Exported
    }

    struct FeeSplit {
        uint16 premiumBps;
        uint16 maintenanceBps;
        uint16 feedBps;
        uint16 minorShareBps;
    }

    struct EntryCurve {
        uint32 baseBps;
        uint32 slopeBps;
        uint32 capBps;
        uint128 referenceWei;
    }

    struct GrailParams {
        uint256 targetWei;
        uint256 stepWei;
        uint256 listBps;
        uint256 decayWeiPerPull;
        uint256 floorWei;
    }

    struct Grail {
        uint256 bucket;
        uint256 packId;
        uint256 backing;
        uint256 notional;
        uint256 targetWei;
        uint256 stepWei;
        uint256 listBps;
        uint256 decayWeiPerPull;
        uint256 floorWei;
        uint256 pullsSinceList;
    }

    struct Claim {
        address to;
        uint64 requestedAt;
        uint256 amount;
    }

    /// @dev An ordinary token owned or listed by the pool. `value` is its backing. `listingId` is
    ///      the FWA listing id, zero while the token is held unlisted.
    struct Item {
        address collection;
        uint16 row;
        uint256 tokenId;
        uint256 value;
        uint256 listingId;
    }

    /// @dev Pulls recorded in one clock hour. `hour` is `block.timestamp / 1 hours`.
    struct PullSlot {
        uint64 hour;
        uint192 count;
    }

    struct Params {
        address shapes;
        address drawPacks;
        address fwaFactory;
        address admin;
        PricingLib.MixRow[] mix;
        FeeSplit feeSplit;
        GrailParams minor;
        GrailParams major;
        uint256 navCap;
        EntryCurve curve;
        uint256 rotateInterval;
        uint256 openingDeadline;
        uint256 minItems;
        uint256 grailProbCapBps;
    }

    // ------------------------------------------------------------------ errors

    error ZeroAddress();
    error ZeroAmount();
    error FeeSplitTooHigh();
    error MinorShareTooHigh();
    error CurveCapTooHigh();
    error CurveReferenceZero();
    error ListBpsOutOfRange();
    error NotAdmin();
    error DepositsPaused();
    error NavCapReached();
    error PoolExiting();
    error ZeroShares();
    error InsufficientShares();
    error ClaimNotDue();
    error GrailProbCapOutOfRange();
    error NotOpening();
    error FwaPoolExists();
    error FwaPoolMissing();
    error OpeningDeadlineNotReached();
    error PackValueMismatch();

    // ------------------------------------------------------------------ events

    event Deposited(address indexed to, uint256 value, uint256 contribution, uint256 shares);
    event Withdrawn(address indexed from, uint256 shares, uint256 paidNow, uint256 enqueued);
    event ClaimPaid(address indexed to, uint256 amount);
    event FwaPoolCreated(address indexed pool);
    event Opened();

    // ------------------------------------------------------------------ constants and immutables

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_CLAIM_ITEMS = 20;
    uint256 internal constant MINOR = 0;
    uint256 internal constant MAJOR = 1;
    uint256 internal constant MAX_FEE_SPLIT_BPS = 1_000;
    uint256 internal constant MAX_CURVE_CAP_BPS = 2_500;
    uint256 internal constant MAX_MINTS_PER_RESTOCK = 20;
    uint256 internal constant PULL_SLOTS = 5;

    address public immutable shapes;
    address public immutable drawPacks;
    address public immutable fwaFactory;

    // ------------------------------------------------------------------ storage

    address public admin;
    Lifecycle public lifecycle;
    bool public pullsPaused;
    bool public depositsPaused;

    uint256 public cash;
    uint256 public backing;
    uint256 public receivable;
    uint256 public claims;
    uint256 public maintenance;
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

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(Params memory p) {
        if (p.shapes == address(0) || p.drawPacks == address(0) || p.fwaFactory == address(0) || p.admin == address(0))
        {
            revert ZeroAddress();
        }
        if (uint256(p.feeSplit.premiumBps) + p.feeSplit.maintenanceBps + p.feeSplit.feedBps > MAX_FEE_SPLIT_BPS) {
            revert FeeSplitTooHigh();
        }
        if (p.feeSplit.minorShareBps > BPS) revert MinorShareTooHigh();
        if (p.curve.capBps > MAX_CURVE_CAP_BPS) revert CurveCapTooHigh();
        if (p.curve.referenceWei == 0) revert CurveReferenceZero();
        if (p.grailProbCapBps == 0 || p.grailProbCapBps > BPS) revert GrailProbCapOutOfRange();

        shapes = p.shapes;
        drawPacks = p.drawPacks;
        fwaFactory = p.fwaFactory;
        admin = p.admin;
        feeSplit = p.feeSplit;
        curve = p.curve;
        navCap = p.navCap;
        rotateInterval = p.rotateInterval;
        openingDeadline = p.openingDeadline;
        minItems = p.minItems;
        grailProbCapBps = p.grailProbCapBps;

        _initGrail(MINOR, p.minor);
        _initGrail(MAJOR, p.major);
        _setMix(p.mix);
    }

    // ------------------------------------------------------------------ views

    /// @notice Ordinary NAV: `cash + backing + receivable - claims`.
    function nav() public view returns (uint256) {
        return cash + backing + receivable - claims;
    }

    function mixLength() external view returns (uint256) {
        return _mix.length;
    }

    /// @notice Listed item for FWA `listingId`. `listingId` is zero in the result for an unknown id.
    function listedItem(uint256 listingId) external view returns (Item memory) {
        return _listed[listingId];
    }

    function heldCount() external view returns (uint256) {
        return _held.length;
    }

    function heldItem(uint256 index) external view returns (Item memory) {
        return _held[index];
    }

    /// @notice Listed plus held ordinary items of `row`.
    function rowCount(uint256 row) external view returns (uint256) {
        return _rowCount[row];
    }

    function replacementLength() external view returns (uint256) {
        return replacementQueue.length - replacementHead;
    }

    // ------------------------------------------------------------------ opening

    /// @notice Creates the FWA pool through the factory and approves it for both collections.
    ///         Starts the opening deadline. The factory pulls `expectedFee` of its FWA token from
    ///         this contract, so the pool must hold that balance first.
    function createFwaPool(uint256 expectedFee) external onlyAdmin nonReentrant {
        if (lifecycle != Lifecycle.Opening) revert NotOpening();
        if (address(fwaPool) != address(0)) revert FwaPoolExists();

        IFWACloneFactory factory = IFWACloneFactory(fwaFactory);
        if (expectedFee != 0) SafeTransferLib.safeApprove(factory.fwaToken(), address(factory), expectedFee);
        IFWAClone clone = IFWAClone(factory.createPool(bytes32(0), expectedFee));

        fwaPool = clone;
        maxBatch = factory.maxAcquisitionsPerTx();
        concurrency = factory.maxOutstandingRequestsPerPool();
        openingDeadlineAt = block.timestamp + openingDeadline;
        IShapes(shapes).setApprovalForAll(address(clone), true);
        IShapePacks(drawPacks).setApprovalForAll(address(clone), true);
        emit FwaPoolCreated(address(clone));
    }

    /// @notice Moves the pool to Live after the opening deadline and builds the first board.
    function open() external nonReentrant {
        if (lifecycle != Lifecycle.Opening) revert NotOpening();
        if (address(fwaPool) == address(0)) revert FwaPoolMissing();
        if (block.timestamp < openingDeadlineAt) revert OpeningDeadlineNotReached();
        lifecycle = Lifecycle.Live;
        _restock();
        emit Opened();
    }

    // ------------------------------------------------------------------ depositor paths

    /// @notice Deposits `msg.value` for shares at ordinary NAV, net of the entry contribution.
    function deposit() external payable nonReentrant {
        _deposit(msg.sender, msg.value);
    }

    /// @notice Burns `shares` and pays their claim at ordinary NAV. Pays `min(claim, cash)` now and
    ///         queues the remainder in `claimQueue`.
    function withdraw(uint256 shares) external nonReentrant {
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

    /// @notice Pays queued claims from `cash` in request order once the head claim is at least
    ///         `rotateInterval` old. Does nothing when the queue is empty.
    function liquidate() external nonReentrant {
        uint256 head = claimHead;
        if (head == claimQueue.length) return;
        if (block.timestamp < claimQueue[head].requestedAt + rotateInterval) revert ClaimNotDue();
        _payClaims(MAX_CLAIM_ITEMS);
    }

    /// @notice Accepts ETH from Shapes redemptions and FWA proceeds. The ETH is booked by the
    ///         function that triggered the transfer.
    receive() external payable {}

    /// @notice Accepts Shapes and Draw Packs from mints and FWA listing withdrawals. The calling
    ///         function books the token.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ internal

    /// @dev Mints shares to `to` for `value`. The entry contribution goes to the GRAIL buckets,
    ///      split by `minorShareBps`. Shares are priced on NAV before the deposit.
    function _deposit(address to, uint256 value) internal {
        if (depositsPaused) revert DepositsPaused();
        if (lifecycle >= Lifecycle.Exiting) revert PoolExiting();
        if (value == 0) revert ZeroAmount();
        uint256 currentNav = nav();
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

    /// @dev Pays claims from `cash` starting at `claimHead`, at most `maxItems` queue entries. A
    ///      partly paid head claim keeps its place with a reduced `amount`. Recipients are paid
    ///      with `forceSafeTransferETH`, so a recipient that rejects ETH cannot stall the queue.
    function _payClaims(uint256 maxItems) internal {
        uint256 head = claimHead;
        uint256 end = claimQueue.length;
        uint256 available = cash;
        uint256 paidTotal;
        for (uint256 n; n < maxItems && head < end && available != 0; ++n) {
            Claim storage c = claimQueue[head];
            uint256 amount = c.amount;
            uint256 pay = amount < available ? amount : available;
            available -= pay;
            paidTotal += pay;
            if (pay == amount) {
                ++head;
            } else {
                c.amount = amount - pay;
            }
            emit ClaimPaid(c.to, pay);
            SafeTransferLib.forceSafeTransferETH(c.to, pay);
        }
        claimHead = head;
        cash = available;
        claims -= paidTotal;
    }

    // ------------------------------------------------------------------ registry

    /// @dev Books `it` as held (`listingId == 0`) or listed. Every registry change goes through
    ///      `_addItem` and `_removeHeld` / `_removeListed`, which keep `backing` equal to the sum
    ///      of `value` over held and listed items (I2) and `_rowCount` equal to their number.
    function _addItem(Item memory it) internal {
        if (it.listingId == 0) _held.push(it);
        else _listed[it.listingId] = it;
        backing += it.value;
        ++_rowCount[it.row];
    }

    function _removeHeld(uint256 index) internal returns (Item memory it) {
        uint256 last = _held.length - 1;
        it = _held[index];
        if (index != last) _held[index] = _held[last];
        _held.pop();
        backing -= it.value;
        --_rowCount[it.row];
    }

    function _removeListed(uint256 listingId) internal returns (Item memory it) {
        it = _listed[listingId];
        delete _listed[listingId];
        backing -= it.value;
        --_rowCount[it.row];
    }

    // ------------------------------------------------------------------ pull counter

    /// @dev Adds `count` pulls to the current clock hour. A slot last written in an earlier hour
    ///      is reset first.
    function _recordPulls(uint256 count) internal {
        uint64 hour = uint64(block.timestamp / 1 hours);
        PullSlot storage slot = _pullSlots[hour % PULL_SLOTS];
        uint256 current = slot.hour == hour ? slot.count : 0;
        slot.hour = hour;
        slot.count = SafeCastLib.toUint192(current + count);
    }

    /// @dev Pulls in the current hour and the four hours before it.
    function _trailingPulls() internal view returns (uint256 total) {
        uint256 hour = block.timestamp / 1 hours;
        for (uint256 i; i < PULL_SLOTS; ++i) {
            PullSlot memory slot = _pullSlots[i];
            if (slot.hour + PULL_SLOTS - 1 >= hour) total += slot.count;
        }
    }

    // ------------------------------------------------------------------ restock

    /// @dev Mints replacements from the queue, then new inventory toward the target depth of each
    ///      row, then lists every held item. At most `MAX_MINTS_PER_RESTOCK` mints per call.
    ///      New inventory is minted only when the queue is empty and only from `cash` above one
    ///      step of the cheapest row. Returns whether any item was listed.
    function _restock() internal returns (bool changed) {
        uint256 fee = IShapes(shapes).mintFee();
        uint256 mints;

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

        if (head == queued) _mintToDepth(fee, mints);
        changed = _listHeld(fee) != 0;
    }

    function _mintToDepth(uint256 fee, uint256 mints) internal {
        uint256 rows = _mix.length;
        uint256 reserve = type(uint256).max;
        for (uint256 r; r < rows; ++r) {
            uint256 cost = _rowCost(r, fee);
            if (cost < reserve) reserve = cost;
        }
        uint256 pulls = _trailingPulls();
        for (uint256 r; r < rows; ++r) {
            uint256 target = PricingLib.rowDepth(minItems, pulls, _mix[r].shareBps);
            uint256 cost = _rowCost(r, fee);
            while (_rowCount[r] < target && mints < MAX_MINTS_PER_RESTOCK && cash >= reserve + cost) {
                _mintRow(r, fee);
                ++mints;
            }
        }
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
            tokenId = IShapes(collection).mintBatchTo{value: cost}(value, 1, address(this));
        } else {
            collection = drawPacks;
            uint32[] memory counts = new uint32[](Denominations.COUNT);
            for (uint256 i; i < rungs.length; ++i) {
                ++counts[rungs[i]];
            }
            tokenId = IShapePacks(collection).createPack{value: cost}(new uint256[](0), counts);
            if (IShapePacks(collection).valueOf(tokenId) != value) revert PackValueMismatch();
        }
        _addItem(Item(collection, uint16(row), tokenId, value, 0));
    }

    /// @dev Lists every held item on the FWA pool in chunks of `MAX_INVENTORY_BATCH` and moves
    ///      each to the listed map under its listing id. Returns the number listed.
    function _listHeld(uint256 fee) internal returns (uint256 listed) {
        listed = _held.length;
        if (listed == 0) return 0;
        uint256 batch = fwaPool.MAX_INVENTORY_BATCH();
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

    function _initGrail(uint256 track, GrailParams memory g) internal {
        if (g.listBps == 0 || g.listBps > BPS) revert ListBpsOutOfRange();
        Grail storage t = grail[track];
        t.targetWei = g.targetWei;
        t.stepWei = g.stepWei;
        t.listBps = g.listBps;
        t.decayWeiPerPull = g.decayWeiPerPull;
        t.floorWei = g.floorWei;
    }

    /// @dev Replaces the mix table. Each row must have rungs inside the Shapes ladder.
    function _setMix(PricingLib.MixRow[] memory rows) internal {
        delete _mix;
        delete _rowBackingWei;
        for (uint256 i; i < rows.length; ++i) {
            _rowBackingWei.push(PricingLib.rowBacking(rows[i]));
            if (_rowCount.length < rows.length) _rowCount.push();
            _mix.push();
            PricingLib.MixRow storage row = _mix[i];
            row.shareBps = rows[i].shareBps;
            for (uint256 j; j < rows[i].rungs.length; ++j) {
                row.rungs.push(rows[i].rungs[j]);
            }
        }
    }
}
