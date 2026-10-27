// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {Governed} from "../Governed.sol";
import {IFWAPool, IFWAFactory, FWA_ACQUISITIONS_ENABLED} from "../interfaces/IFWA.sol";
import {
    IFwaGame,
    IPrizeVault,
    IGenesisFarm,
    IKeeperFund,
    IEngineBuyer,
    IBoardPolicy,
    IPricingPolicy,
    IGrailPolicy,
    IBurnable
} from "../interfaces/IDrawShapes.sol";

/// @title FwaGame
/// @notice Creates and permanently owns the Draw Shapes FWA V2 pool. It mints prizes (Shapes) with vault ETH and
///         lists them; walks FWA's request sequence (`sync`) to count every pull in the farm's ledger and
///         book its economics; protects its working capital before routing revenue; replaces won prizes at
///         maintenance windows; lists GRAILs from the GRAIL reserve; and on retirement returns everything to the
///         vault. Prize conversion lives in the Converter module, which reads delivery from FWA's own records.
/// @dev Every policy question goes to a module (BoardPolicy, PricingPolicy, GrailPolicy, EngineBuyer); every
///      bound is enforced here. ETH leaves only to the vault, the Shapes contract (mint cost), the Treasury
///      (margin line) and KeeperFund (markup line). Revenue: docs/IMPLEMENTOR_DECISIONS.md D7 and D23; the walk: D6 and D24.
contract FwaGame is IFwaGame, ReentrancyGuard, Governed {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WEIGHT_NUMERATOR = 1e36; // FWA's inverse-weight numerator
    uint8 internal constant KIND_SHAPE = 0;
    uint16 internal constant GRAIL_ROW = type(uint16).max;

    uint256 public constant MAX_BOARD = 200;
    uint256 public constant MAX_LIST_BATCH = 20;
    uint256 public constant MAX_MARKUP_BPS = 500;
    uint256 public constant MAX_BONUS_BPS = 500;
    uint256 public constant MIN_GRAIL_PRICE_BPS = 5_000;
    uint256 public constant MAX_GRAIL_PROB_BPS = 1_000;
    uint256 public constant MAX_MAINTENANCE_INTERVAL = 1 days;
    uint256 public constant MAX_RESERVE_TARGET = 1_000 ether;
    /// @notice Blocks after a request before a delivery still pending counts as resolved without a unit: FWA's
    ///         7-day refund window plus one epoch.
    uint256 public constant DELIVERY_GRACE_BLOCKS = 50_400 + 7_200;

    IShapes public immutable shapes;
    IFWAFactory public immutable factory;
    address public immutable expectedImplementation;
    IPrizeVault public immutable vault;
    IGenesisFarm public immutable farm;
    address public immutable treasury;
    IKeeperFund public immutable keeperFund;
    uint256 public immutable EPOCH_BLOCKS;

    IFWAPool public pool;
    IBoardPolicy public board;
    IPricingPolicy public pricing;
    IGrailPolicy public grail;
    IEngineBuyer public buyer; // read by the Converter
    uint256 public reserveTarget;
    uint256 public maintenanceInterval;

    /// @notice One record per listing this game made.
    struct Item {
        uint48 tokenId;
        uint80 backing;
        uint80 cost; // backing + mint fees paid
        uint16 row; // board row, or GRAIL_ROW
        uint16 markupBps;
        bool live;
    }

    mapping(uint256 listingId => Item) public items;
    uint256[] internal _live;
    mapping(uint256 listingId => uint256) internal _liveIndex; // index + 1
    uint256[] internal _relist; // recovered listings waiting to be listed again
    /// @notice Board rows with a live listing, one bit per row.
    uint256 public liveRows;

    // ledger: every issued request is seen once (accepted), then resolved once it is terminal
    struct Open {
        uint64 seq;
        uint32 epoch;
        bool rewardResolved; // counted resolved (without a unit) after the delivery grace period
    }

    uint64 public seenSeq = 1;
    Open[] internal _open;
    mapping(uint256 epoch => uint256) public epochAccepted;
    mapping(uint256 epoch => uint256) public epochResolved;
    mapping(uint256 epoch => uint256) public epochUnits;
    mapping(uint256 epoch => mapping(address => uint256)) public userUnits;
    uint256 public pullsBooked;

    // capital and revenue
    uint256 public lent;
    uint256 public inventoryBacking;
    uint256 public replacementsOwed;
    uint256 public mintFeesPaid;
    uint256 public markupRouted;
    uint256 public marginRouted;
    uint256 public bookedGain;
    uint256 public bookedLoss;
    uint256 public grailReserve;
    uint256 public grailCapturedBacking;
    uint256 public pendingMarkup;
    uint256 public pendingMargin;

    // GRAIL
    uint256 public grailListing;
    uint256 public grailStep;
    uint256 public grailListedAtPull;

    bool public retiring;
    bool public retired;
    uint256 public lastSyncAt;
    uint256 public lastMaintenanceAt;

    event PoolCreated(address pool, uint256 creationFee);
    event Funded(uint256 amount);
    event GrailFunded(address indexed from, uint256 amount);
    event GameOpened(uint256 openBlock);
    event Listed(uint256 indexed listingId, uint256 indexed row, uint256 price);
    event Resolved(uint256 indexed sequence, uint256 indexed epoch, uint8 status, bool unit);
    event Captured(uint256 indexed listingId, uint256 markup, uint256 margin, uint256 expectedCost);
    event RevenueRouted(uint256 markup, uint256 margin);
    event GrailRepriced(uint256 indexed listingId, uint256 price);
    event RetireStarted();
    event Retired(uint256 returned);
    event ModuleSet(bytes32 indexed kind, address module);
    event CapitalSet(uint256 reserveTarget, uint256 maintenanceInterval);

    error PoolExists();
    error NoPool();
    error NotVault();
    error Retiring();
    error NotRetiring();
    error NoWork();

    /// @notice Constructor arguments.
    struct Config {
        address governance;
        address shapes;
        address factory;
        address expectedImplementation;
        address vault;
        address farm;
        address treasury;
        address keeperFund;
        address board;
        address pricing;
        address grail;
        address buyer;
        uint256 reserveTarget;
        uint256 maintenanceInterval;
    }

    constructor(Config memory c) Governed(c.governance, false) {
        if (
            c.shapes == address(0) || c.factory == address(0) || c.vault == address(0) || c.farm == address(0)
                || c.treasury == address(0) || c.keeperFund == address(0)
        ) revert ZeroAddress();
        shapes = IShapes(c.shapes);
        factory = IFWAFactory(c.factory);
        expectedImplementation = c.expectedImplementation;
        vault = IPrizeVault(c.vault);
        farm = IGenesisFarm(c.farm);
        treasury = c.treasury;
        keeperFund = IKeeperFund(c.keeperFund);
        EPOCH_BLOCKS = IGenesisFarm(c.farm).EPOCH_BLOCKS();
        _setModule("board", c.board);
        _setModule("pricing", c.pricing);
        _setModule("grail", c.grail);
        _setModule("buyer", c.buyer);
        _setCapital(c.reserveTarget, c.maintenanceInterval);
        lastSyncAt = block.timestamp;
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ setup

    /// @notice Creates the FWA pool, paying the factory's FWA creation fee from FWA this contract holds
    ///         (docs/IMPLEMENTOR_DECISIONS.md D4). Once. Leftover FWA is burned.
    function createPool(bytes32 salt) external nonReentrant returns (address created) {
        if (address(pool) != address(0)) revert PoolExists();
        address fwa = factory.fwaToken();
        uint256 fee = factory.poolCreationFee();
        SafeTransferLib.safeApprove(fwa, address(factory), fee);
        created = factory.createPool(salt, fee, expectedImplementation);
        pool = IFWAPool(created);
        shapes.setApprovalForAll(created, true);
        uint256 left = SafeTransferLib.balanceOf(fwa, address(this));
        if (left != 0) IBurnable(fwa).burn(left);
        emit PoolCreated(created, fee);
    }

    /// @notice ETH from the vault.
    function receiveFunding() external payable {
        if (msg.sender != address(vault)) revert NotVault();
        lent += msg.value;
        emit Funded(msg.value);
    }

    /// @notice Adds to the GRAIL reserve: the GrailFund sink, or the owner seeding the first GRAIL. Not while
    ///         retiring.
    function fundGrail() external payable {
        if (retiring) revert Retiring();
        grailReserve += msg.value;
        emit GrailFunded(msg.sender, msg.value);
    }

    /// @notice Opens purchases on the FWA pool and starts the farm clock if it has not started.
    function openGame() external onlyGovernance {
        if (address(pool) == address(0)) revert NoPool();
        if (retiring) revert Retiring();
        pool.setBool(FWA_ACQUISITIONS_ENABLED, true);
        if (farm.openBlock() == 0) farm.start();
        emit GameOpened(farm.openBlock());
    }

    /// @notice Pauses or resumes purchases on the FWA pool.
    function setAcquisitionsEnabled(bool enabled) external onlyGovernance {
        if (retiring) revert Retiring();
        pool.setBool(FWA_ACQUISITIONS_ENABLED, enabled);
    }

    // ------------------------------------------------------------------ keeper work

    /// @notice Sees and resolves up to `maxCount` requests, routes distributable revenue and, at a maintenance
    ///         window, lists replacements and steps the GRAIL. Anyone may call; tipped per item of progress.
    ///         Reverts `NoWork` when there is nothing to do.
    function sync(uint256 maxCount) external nonReentrant returns (uint256 work) {
        uint256 gasStart = gasleft();
        if (address(pool) == address(0)) revert NoPool();
        if (retiring) revert Retiring();
        work = _advance(maxCount);
        if (!pool.retired() && !factory.globalWithdrawOnly() && _maintenanceDue()) {
            uint256 changes = _restock() + _grailStep();
            if (changes != 0) lastMaintenanceAt = block.timestamp;
            work += changes;
        }
        _tip(gasStart, work, false);
    }

    /// @notice Retirement, step by step: settle and book, then withdraw and burn every prize, then return
    ///         everything to the vault. Anyone may call; tipped. Works while the factory is withdraw-only.
    function retireStep(uint256 maxCount) external nonReentrant returns (uint256 work) {
        uint256 gasStart = gasleft();
        if (!retiring || retired) revert NotRetiring();
        bool caughtUp = true;
        if (address(pool) != address(0)) {
            work = _advance(maxCount);
            caughtUp = pool.unsettledAcquisitionCount() == 0 && seenSeq > pool.lastIssuedSequence() && _open.length == 0;
            if (caughtUp && _live.length != 0) work += _withdrawSome();
        }
        while (_relist.length != 0) {
            uint256 id = _relist[_relist.length - 1];
            _relist.pop();
            _burnItem(id);
            ++work;
        }
        if (caughtUp && _live.length == 0) {
            retired = true;
            uint256 amount = address(this).balance;
            grailReserve = 0;
            pendingMarkup = 0;
            pendingMargin = 0;
            replacementsOwed = 0;
            vault.repay{value: amount}(true);
            emit Retired(amount);
            ++work;
        }
        _tip(gasStart, work, true);
    }

    /// @notice Starts retirement. Called by the vault (`PrizeVault.retireGame`, timelock).
    function retire() external {
        if (msg.sender != address(vault)) revert NotVault();
        if (retiring) revert Retiring();
        retiring = true;
        if (address(pool) != address(0) && !pool.retired()) pool.retirePool();
        emit RetireStarted();
    }

    function _tip(uint256 gasStart, uint256 work, bool retirement) internal {
        if (work == 0) revert NoWork();
        uint256 age = block.timestamp - lastSyncAt;
        lastSyncAt = block.timestamp;
        keeperFund.tip(msg.sender, gasStart - gasleft(), age, work, retirement);
    }

    /// @dev Cranks FWA settlement, sees new requests, resolves terminal ones, collects owner proceeds and routes
    ///      what is distributable.
    function _advance(uint256 maxCount) internal returns (uint256 work) {
        try pool.processAcquisitions(maxCount) {} catch {}
        uint256 edge = factory.edgeBps();
        work = _resolveOpen(maxCount, edge);
        work += _see(maxCount, edge);
        if (pool.ownerProceeds() != 0) pool.withdrawOwnerProceeds();
        _route();
    }

    /// @notice Cash the game may spend on prizes: its balance less the GRAIL reserve.
    function cash() public view returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > grailReserve ? bal - grailReserve : 0;
    }

    /// @notice What may leave the game now: cash beyond the replacements owed and the reserve target.
    function distributable() public view returns (uint256) {
        uint256 c = cash();
        uint256 keep = replacementsOwed + reserveTarget;
        return c > keep ? c - keep : 0;
    }

    /// @notice Cash plus the backing of every prize this game holds or has listed.
    function nav() external view returns (uint256) {
        return cash() + inventoryBacking;
    }

    /// @dev Routes the booked markup and margin lines, markup first, up to what is distributable. The rest waits.
    function _route() internal {
        uint256 room = distributable();
        uint256 markup = pendingMarkup < room ? pendingMarkup : room;
        room -= markup;
        uint256 margin = pendingMargin < room ? pendingMargin : room;
        if (markup + margin == 0) return;
        pendingMarkup -= markup;
        pendingMargin -= margin;
        markupRouted += markup;
        marginRouted += margin;
        if (markup != 0) keeperFund.fundKeeper{value: markup}();
        if (margin != 0) SafeTransferLib.forceSafeTransferETH(treasury, margin);
        emit RevenueRouted(markup, margin);
    }

    /// @dev First cursor: every issued request is seen once, counted accepted in its epoch, and resolved at once
    ///      if it is already terminal; otherwise it joins the open set.
    function _see(uint256 maxCount, uint256 edge) internal returns (uint256 n) {
        uint64 seq = seenSeq;
        uint64 last = pool.lastIssuedSequence();
        uint256 open = farm.openBlock();
        while (n < maxCount && seq <= last) {
            uint256 requestId = pool.requestIdAtSequence(seq);
            uint256 requestBlock = _request(requestId).requestBlock;
            uint256 epoch = open == 0 || requestBlock < open ? 0 : (requestBlock - open) / EPOCH_BLOCKS;
            ++epochAccepted[epoch];
            Open memory o = Open(seq, uint32(epoch), false);
            if (!_tryResolve(o, requestId, edge)) _open.push(o);
            ++seq;
            ++n;
        }
        seenSeq = seq;
    }

    /// @dev Second cursor: resolves open requests that have become terminal, in any order.
    function _resolveOpen(uint256 maxCount, uint256 edge) internal returns (uint256 n) {
        uint256 i;
        while (i < _open.length && n < maxCount) {
            Open memory o = _open[i];
            bool wasResolved = o.rewardResolved;
            if (_tryResolve(o, pool.requestIdAtSequence(o.seq), edge)) {
                _open[i] = _open[_open.length - 1];
                _open.pop();
                ++n;
            } else {
                if (!wasResolved && o.rewardResolved) {
                    _open[i].rewardResolved = true; // grace passed: resolved for rewards, still open
                    ++n;
                }
                ++i;
            }
        }
    }

    /// @dev Resolves `o` if its request is terminal. A delivery still pending after the grace period is counted
    ///      resolved without a unit and stays open until its economics settle.
    struct Req {
        address purchaser;
        uint256 requestBlock;
        uint256 paid;
        uint256 listingId;
        IFWAPool.AcquisitionStatus status;
    }

    function _request(uint256 requestId) internal view returns (Req memory r) {
        (r.purchaser, r.requestBlock, r.paid, r.listingId, r.status) = pool.acquisitions(requestId);
    }

    function _tryResolve(Open memory o, uint256 requestId, uint256 edge) internal returns (bool done) {
        Req memory r = _request(requestId);
        IFWAPool.AcquisitionStatus st = r.status;
        if (
            st == IFWAPool.AcquisitionStatus.Pending || st == IFWAPool.AcquisitionStatus.Ready
                || st == IFWAPool.AcquisitionStatus.None
        ) return false;
        if (st == IFWAPool.AcquisitionStatus.DeliveryPending) {
            if (!o.rewardResolved && block.number > r.requestBlock + DELIVERY_GRACE_BLOCKS) {
                ++epochResolved[o.epoch];
                o.rewardResolved = true;
                emit Resolved(o.seq, o.epoch, uint8(st), false);
            }
            return false;
        }
        bool unit = st == IFWAPool.AcquisitionStatus.Fulfilled && !o.rewardResolved;
        if (!o.rewardResolved) ++epochResolved[o.epoch];
        if (st == IFWAPool.AcquisitionStatus.Fulfilled) {
            if (unit) {
                ++epochUnits[o.epoch];
                ++userUnits[o.epoch][r.purchaser];
            }
            ++pullsBooked;
            _bookCapture(r.listingId, r.paid, edge);
        } else if (st == IFWAPool.AcquisitionStatus.DeliveryRefunded) {
            _recover(r.listingId);
        }
        emit Resolved(o.seq, o.epoch, uint8(st), unit);
        return true;
    }

    function _recover(uint256 listingId) internal {
        pool.recoverRefundedNFT(listingId);
        _removeLive(listingId);
        if (items[listingId].row == GRAIL_ROW) {
            // A recovered GRAIL goes back to the reserve; the next window lists a fresh one.
            grailReserve += items[listingId].backing;
            _burnItem(listingId);
        } else {
            _relist.push(listingId);
        }
    }

    function _bookCapture(uint256 listingId, uint256 paid, uint256 edge) internal {
        Item memory it = items[listingId];
        _removeLive(listingId);
        inventoryBacking -= it.backing;
        uint256 base = paid * BPS / (BPS + edge);
        uint256 proceeds = paid - (paid - base) / 2;
        uint256 markup = base * it.markupBps / (BPS + it.markupBps);
        uint256 margin = proceeds - base;
        uint256 expected = base - markup;
        pendingMarkup += markup;
        pendingMargin += margin;
        if (it.row == GRAIL_ROW) {
            grailListing = 0;
            ++grailStep;
            grailCapturedBacking += it.backing;
        } else {
            liveRows &= ~(uint256(1) << it.row);
            replacementsOwed += it.cost;
            if (expected >= it.cost) bookedGain += expected - it.cost;
            else bookedLoss += it.cost - expected;
        }
        emit Captured(listingId, markup, margin, expected);
    }

    // ------------------------------------------------------------------ inventory

    /// @notice True when replacements may be listed now: a full batch is waiting, or `maintenanceInterval` has
    ///         passed since the last inventory change. Every FWA inventory change restarts its purchase cooldown
    ///         and invalidates in-flight purchases, so changes are batched (docs/IMPLEMENTOR_DECISIONS.md D25).
    function _maintenanceDue() internal view returns (bool) {
        if (block.timestamp >= lastMaintenanceAt + maintenanceInterval) return true;
        uint256 rows = board.rowCount();
        if (rows > MAX_BOARD) rows = MAX_BOARD;
        uint256 waiting = _relist.length + rows - _popcount(liveRows & ((uint256(1) << rows) - 1));
        uint256 batch = board.listBatch();
        return waiting >= (batch > MAX_LIST_BATCH ? MAX_LIST_BATCH : batch);
    }

    function _popcount(uint256 x) internal pure returns (uint256 c) {
        while (x != 0) {
            x &= x - 1;
            ++c;
        }
    }

    /// @dev Lists recovered prizes, then mints and lists prizes for board rows without a live listing, while cash
    ///      pays for them.
    function _restock() internal returns (uint256 count) {
        uint256 maxList = board.listBatch();
        if (maxList > MAX_LIST_BATCH) maxList = MAX_LIST_BATCH;
        uint256 rows = board.rowCount();
        if (rows > MAX_BOARD) rows = MAX_BOARD;
        IFWAPool.ListingInput[] memory inputs = new IFWAPool.ListingInput[](maxList);
        Item[] memory made = new Item[](maxList);
        while (count < maxList && _relist.length != 0) {
            uint256 id = _relist[_relist.length - 1];
            _relist.pop();
            Item memory it = items[id];
            delete items[id];
            (inputs[count], made[count]) = _input(it);
            ++count;
        }
        uint256 bits = liveRows;
        for (uint256 r; r < rows && count < maxList; ++r) {
            if (bits & (uint256(1) << r) != 0) continue;
            (Item memory it, bool stop) = _mintRow(r);
            if (stop) break;
            if (it.cost == 0) continue;
            bits |= uint256(1) << r;
            (inputs[count], made[count]) = _input(it);
            ++count;
        }
        liveRows = bits;
        if (count == 0) return 0;
        assembly ("memory-safe") {
            mstore(inputs, count)
        }
        _list(inputs, made);
    }

    /// @dev Mints the Shape of board row `r` if cash pays for it. `stop` when it does not; a zero-cost item for a row
    ///      this game cannot mint (Pack rows: docs/IMPLEMENTOR_DECISIONS.md D3).
    function _mintRow(uint256 r) internal returns (Item memory it, bool stop) {
        (uint8 kind, uint96 backing) = board.rowAt(r);
        if (kind != KIND_SHAPE) return (it, false);
        it.cost = uint80(backing + shapes.mintFee());
        if (cash() < it.cost) return (it, true);
        it.tokenId = uint48(shapes.mintTo{value: it.cost}(backing, address(this)));
        it.backing = uint80(backing);
        it.row = uint16(r);
        inventoryBacking += backing;
        mintFeesPaid += it.cost - backing;
        replacementsOwed = replacementsOwed > it.cost ? replacementsOwed - it.cost : 0;
    }

    /// @dev Prices an item within bounds: at least its cost, at most cost × (1 + MAX_MARKUP_BPS).
    function _input(Item memory it) internal view returns (IFWAPool.ListingInput memory input, Item memory out) {
        uint256 price = pricing.listPrice(KIND_SHAPE, it.backing, it.cost);
        uint256 cap = uint256(it.cost) * (BPS + MAX_MARKUP_BPS) / BPS;
        if (price < it.cost) price = it.cost;
        if (price > cap) price = cap;
        it.markupBps = uint16((price - it.cost) * BPS / it.cost);
        input = IFWAPool.ListingInput(address(shapes), it.tokenId, price);
        out = it;
    }

    function _list(IFWAPool.ListingInput[] memory inputs, Item[] memory made) internal {
        uint256[] memory ids = pool.listNFTs(inputs);
        for (uint256 i; i < ids.length; ++i) {
            Item memory it = made[i];
            it.live = true;
            items[ids[i]] = it;
            _liveIndex[ids[i]] = _live.length + 1;
            _live.push(ids[i]);
            emit Listed(ids[i], it.row, inputs[i].price);
        }
    }

    function _removeLive(uint256 listingId) internal {
        uint256 idx = _liveIndex[listingId];
        if (idx == 0) return;
        uint256 lastId = _live[_live.length - 1];
        _live[idx - 1] = lastId;
        _liveIndex[lastId] = idx;
        _live.pop();
        delete _liveIndex[listingId];
        items[listingId].live = false;
    }

    /// @dev Withdraws up to MAX_LIST_BATCH live listings and burns them for their backing.
    function _withdrawSome() internal returns (uint256 n) {
        n = _live.length < MAX_LIST_BATCH ? _live.length : MAX_LIST_BATCH;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = _live[_live.length - 1 - i];
        }
        pool.withdrawListingsTo(ids, address(this));
        for (uint256 i; i < n; ++i) {
            _removeLive(ids[i]);
            _burnItem(ids[i]);
        }
    }

    function _burnItem(uint256 listingId) internal {
        Item memory it = items[listingId];
        if (it.row != GRAIL_ROW) liveRows &= ~(uint256(1) << it.row);
        else if (grailListing == listingId) grailListing = 0;
        inventoryBacking -= it.backing;
        shapes.burn(it.tokenId);
        delete items[listingId];
    }

    // ------------------------------------------------------------------ GRAIL

    /// @dev Lists the next GRAIL when the reserve covers it, or reprices the live one per the policy.
    function _grailStep() internal returns (uint256) {
        uint256 id = grailListing;
        if (id == 0) {
            uint256 backing = grail.grailBacking(grailStep);
            if (backing == 0) return 0;
            uint256 cost = backing + shapes.mintFee();
            if (grailReserve < cost) return 0;
            grailReserve -= cost;
            Item memory it;
            it.cost = uint80(cost);
            it.backing = uint80(backing);
            it.row = GRAIL_ROW;
            it.tokenId = uint48(shapes.mintTo{value: cost}(backing, address(this)));
            inventoryBacking += backing;
            mintFeesPaid += cost - backing;
            IFWAPool.ListingInput[] memory inputs = new IFWAPool.ListingInput[](1);
            inputs[0] = IFWAPool.ListingInput(address(shapes), it.tokenId, _grailPrice(backing, 0, 0));
            Item[] memory made = new Item[](1);
            made[0] = it;
            _list(inputs, made);
            grailListing = _live[_live.length - 1];
            grailListedAtPull = pullsBooked;
            return 1;
        }
        if (pool.unsettledAcquisitionCount() != 0) return 0;
        (uint256 weight, uint256 current, IFWAPool.ListingStatus status) = _listing(id);
        if (status != IFWAPool.ListingStatus.Active) return 0;
        uint256 newPrice = _grailPrice(items[id].backing, pullsBooked - grailListedAtPull, weight);
        if (newPrice == current) return 0;
        pool.updatePrice(id, newPrice);
        emit GrailRepriced(id, newPrice);
        return 1;
    }

    function _listing(uint256 id) internal view returns (uint256 weight, uint256 price, IFWAPool.ListingStatus status) {
        (,,,, weight, price,, status) = pool.listings(id);
    }

    /// @dev GRAIL price within the hard bounds: at least MIN_GRAIL_PRICE_BPS of backing, and high enough that its
    ///      win probability is at most MAX_GRAIL_PROB_BPS. `ownWeight` is its current weight in the pool.
    function _grailPrice(uint256 backing, uint256 pulls, uint256 ownWeight) internal view returns (uint256 price) {
        price = grail.grailPrice(backing, pulls);
        uint256 floor = backing * MIN_GRAIL_PRICE_BPS / BPS;
        if (price < floor) price = floor;
        uint256 others = pool.totalWeight() - ownWeight;
        if (others != 0) {
            // weight / (others + weight) <= MAX  <=>  weight <= MAX × others / (BPS − MAX)
            uint256 maxWeight = MAX_GRAIL_PROB_BPS * others / (BPS - MAX_GRAIL_PROB_BPS);
            uint256 probFloor = maxWeight == 0 ? type(uint128).max : WEIGHT_NUMERATOR / maxWeight + 1;
            if (price < probFloor) price = probFloor;
        }
    }

    // ------------------------------------------------------------------ ledger

    /// @notice `(accepted, resolved, units)` of `epoch`.
    function epochTotals(uint256 epoch) external view returns (uint256, uint256, uint256) {
        return (epochAccepted[epoch], epochResolved[epoch], epochUnits[epoch]);
    }

    /// @notice True once `epoch` has ended, every request FWA issued in it has been seen (accepted), and every
    ///         accepted request is resolved.
    function isEpochFinal(uint256 epoch) external view returns (bool) {
        uint256 open = farm.openBlock();
        if (open == 0) return false;
        uint256 end = open + (epoch + 1) * EPOCH_BLOCKS;
        if (block.number < end || epochAccepted[epoch] != epochResolved[epoch]) return false;
        if (address(pool) == address(0)) return true;
        uint64 seq = seenSeq;
        if (seq > pool.lastIssuedSequence()) return true;
        return _request(pool.requestIdAtSequence(seq)).requestBlock >= end;
    }

    function liveCount() external view returns (uint256) {
        return _live.length;
    }

    function liveAt(uint256 i) external view returns (uint256) {
        return _live[i];
    }

    function relistCount() external view returns (uint256) {
        return _relist.length;
    }

    function openCount() external view returns (uint256) {
        return _open.length;
    }

    // ------------------------------------------------------------------ governance

    function setModule(bytes32 kind, address module) external onlyGovernance {
        _setModule(kind, module);
    }

    /// @notice Sets the reserve target (at least twice the cost of the board's most expensive prize) and the
    ///         maintenance interval.
    function setCapital(uint256 reserveTarget_, uint256 maintenanceInterval_) external onlyGovernance {
        _setCapital(reserveTarget_, maintenanceInterval_);
    }

    function _setCapital(uint256 reserveTarget_, uint256 maintenanceInterval_) internal {
        if (reserveTarget_ > MAX_RESERVE_TARGET || maintenanceInterval_ > MAX_MAINTENANCE_INTERVAL) revert OutOfBounds();
        uint256 rows = board.rowCount();
        uint256 maxBacking;
        for (uint256 r; r < rows && r < MAX_BOARD; ++r) {
            (, uint96 b) = board.rowAt(r);
            if (b > maxBacking) maxBacking = b;
        }
        if (reserveTarget_ < 2 * maxBacking) revert OutOfBounds();
        reserveTarget = reserveTarget_;
        maintenanceInterval = maintenanceInterval_;
        emit CapitalSet(reserveTarget_, maintenanceInterval_);
    }

    function _setModule(bytes32 kind, address module) internal {
        if (module.code.length == 0) revert ZeroAddress();
        if (kind == "board") board = IBoardPolicy(module);
        else if (kind == "pricing") pricing = IPricingPolicy(module);
        else if (kind == "grail") grail = IGrailPolicy(module);
        else if (kind == "buyer") buyer = IEngineBuyer(module);
        else revert OutOfBounds();
        emit ModuleSet(kind, module);
    }
}
