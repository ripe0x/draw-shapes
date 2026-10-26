// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {IShapePacks} from "draw-packs/interfaces/IShapePacks.sol";
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
/// @notice Creates and permanently owns the Draw Shapes FWA V2 pool. It mints prizes (Shapes, Packs) with
///         vault ETH and lists them; walks FWA's acquisition sequence to book every pull (`sync`), crediting
///         the farm's ledger and routing revenue; replaces won prizes; lists GRAILs from the GRAIL reserve;
///         converts delivered Shapes into ENGINE; and on retirement returns everything to the vault.
/// @dev Every policy question is asked of a module (BoardPolicy, PricingPolicy, GrailPolicy, EngineBuyer);
///      every bound is enforced here. ETH leaves only to the vault, the Shapes/Packs contracts (mint cost),
///      the Treasury (margin line), KeeperFund (markup line), and EngineBuyer (a converting player's own
///      backing, with the ENGINE going to that player). Revenue routing: docs/IMPLEMENTOR_DECISIONS.md D7.
contract FwaGame is IFwaGame, ReentrancyGuard, Governed {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WEIGHT_NUMERATOR = 1e36; // FWA's inverse-weight numerator
    uint8 internal constant KIND_SHAPE = 0;
    uint8 internal constant KIND_PACK = 1;
    uint16 internal constant GRAIL_ROW = type(uint16).max;

    uint256 public constant MAX_BOARD = 200;
    uint256 public constant MAX_LIST_BATCH = 20;
    uint256 public constant MAX_MARKUP_BPS = 500;
    uint256 public constant MAX_BONUS_BPS = 500;
    uint256 public constant MIN_GRAIL_PRICE_BPS = 5_000;
    uint256 public constant MAX_GRAIL_PROB_BPS = 1_000;

    IShapes public immutable shapes;
    IShapePacks public immutable packs;
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
    IEngineBuyer public buyer;

    /// @notice One record per listing this game made.
    struct Item {
        uint48 tokenId;
        uint80 backing;
        uint80 cost; // backing + mint fees paid
        uint16 row; // board row, or GRAIL_ROW
        uint16 markupBps;
        uint8 kind;
        bool live;
    }

    mapping(uint256 listingId => Item) public items;
    uint256[] internal _live;
    mapping(uint256 listingId => uint256) internal _liveIndex; // index + 1
    uint256[] internal _relist; // recovered listings waiting to be listed again
    /// @notice Board rows with a live listing, one bit per row.
    uint256 public liveRows;

    // ledger
    uint64 public nextSeq = 1;
    mapping(uint256 epoch => uint256) public epochBooked;
    mapping(uint256 epoch => uint256) internal _epochUnits;
    mapping(uint256 epoch => mapping(address => uint256)) internal _userUnits;
    uint256 public pullsBooked;

    // accounting
    uint256 public lent;
    uint256 public inventoryBacking;
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

    /// @notice 1 = a Shape this pool delivered, 2 = converted.
    mapping(uint256 tokenId => uint8) public delivered;

    bool public retiring;
    bool public retired;
    uint256 public lastSyncAt;

    event PoolCreated(address pool, uint256 creationFee);
    event Funded(uint256 amount);
    event GrailFunded(address indexed from, uint256 amount);
    event GameOpened(uint256 openBlock);
    event Listed(uint256 indexed listingId, uint256 indexed row, uint256 tokenId, uint256 backing, uint256 cost, uint256 price);
    event Booked(uint256 indexed sequence, uint256 indexed epoch, address indexed purchaser, uint8 status);
    event Captured(
        uint256 indexed listingId, uint256 row, uint256 paid, uint256 markup, uint256 margin, uint256 expectedCost, uint256 cost
    );
    event Recovered(uint256 indexed listingId);
    event RevenueRouted(uint256 markup, uint256 margin);
    event GrailRepriced(uint256 indexed listingId, uint256 price);
    event Converted(address indexed player, uint256 indexed tokenId, uint256 backing, uint256 engineOut, uint256 bonus);
    event RetireStarted();
    event Withdrawn(uint256 indexed listingId);
    event Retired(uint256 returned);
    event ModuleSet(bytes32 indexed kind, address module);

    error PoolExists();
    error NoPool();
    error NotVault();
    error Retiring();
    error NotRetiring();
    error NoWork();
    error NotConvertible();
    error BonusUnavailable();

    constructor(
        address governance_,
        address shapes_,
        address packs_,
        address factory_,
        address expectedImplementation_,
        address vault_,
        address farm_,
        address treasury_,
        address keeperFund_,
        address[4] memory modules // board, pricing, grail, buyer
    ) Governed(governance_, false) {
        if (
            shapes_ == address(0) || factory_ == address(0) || vault_ == address(0) || farm_ == address(0)
                || treasury_ == address(0) || keeperFund_ == address(0)
        ) revert ZeroAddress();
        shapes = IShapes(shapes_);
        packs = IShapePacks(packs_);
        factory = IFWAFactory(factory_);
        expectedImplementation = expectedImplementation_;
        vault = IPrizeVault(vault_);
        farm = IGenesisFarm(farm_);
        treasury = treasury_;
        keeperFund = IKeeperFund(keeperFund_);
        EPOCH_BLOCKS = IGenesisFarm(farm_).EPOCH_BLOCKS();
        _setModule("board", modules[0]);
        _setModule("pricing", modules[1]);
        _setModule("grail", modules[2]);
        _setModule("buyer", modules[3]);
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
        if (address(packs) != address(0)) packs.setApprovalForAll(created, true);
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

    /// @notice Adds to the GRAIL reserve (the GrailFund sink). Not while retiring.
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

    /// @notice Settles and books up to `maxCount` pulls, routes revenue, lists replacements and steps the
    ///         GRAIL. Anyone may call; tipped from KeeperFund. Reverts `NoWork` when there is nothing to do.
    function sync(uint256 maxCount) external nonReentrant returns (uint256 work) {
        uint256 gasStart = gasleft();
        if (address(pool) == address(0)) revert NoPool();
        if (retiring) revert Retiring();
        work = _advance(maxCount);
        if (!pool.retired() && !factory.globalWithdrawOnly()) {
            work += _restock();
            work += _grailStep();
        }
        _tip(gasStart, work);
    }

    /// @notice Retirement, step by step: settle and book, then withdraw and burn every prize, then return
    ///         everything to the vault. Anyone may call; tipped. Works while the factory is withdraw-only.
    function retireStep(uint256 maxCount) external nonReentrant returns (uint256 work) {
        uint256 gasStart = gasleft();
        if (!retiring || retired) revert NotRetiring();
        bool caughtUp = true;
        if (address(pool) != address(0)) {
            work = _advance(maxCount);
            caughtUp = pool.unsettledAcquisitionCount() == 0 && nextSeq > pool.lastIssuedSequence();
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
            vault.repay{value: amount}(true);
            emit Retired(amount);
            ++work;
        }
        _tip(gasStart, work);
    }

    /// @notice Starts retirement. Called by the vault (`PrizeVault.retireGame`, timelock).
    function retire() external {
        if (msg.sender != address(vault)) revert NotVault();
        if (retiring) revert Retiring();
        retiring = true;
        if (address(pool) != address(0) && !pool.retired()) pool.retirePool();
        emit RetireStarted();
    }

    function _tip(uint256 gasStart, uint256 work) internal {
        if (work == 0) revert NoWork();
        uint256 age = block.timestamp - lastSyncAt;
        lastSyncAt = block.timestamp;
        keeperFund.tip(msg.sender, gasStart - gasleft(), age);
    }

    /// @dev Cranks FWA settlement, books terminal pulls, collects owner proceeds and routes revenue.
    function _advance(uint256 maxCount) internal returns (uint256 walked) {
        try pool.processAcquisitions(maxCount) {} catch {}
        walked = _walk(maxCount);
        if (pool.ownerProceeds() != 0) pool.withdrawOwnerProceeds();
        uint256 markup = pendingMarkup;
        uint256 margin = pendingMargin;
        if (markup + margin != 0 && address(this).balance >= markup + margin) {
            pendingMarkup = 0;
            pendingMargin = 0;
            markupRouted += markup;
            marginRouted += margin;
            if (markup != 0) keeperFund.fundKeeper{value: markup}();
            if (margin != 0) SafeTransferLib.forceSafeTransferETH(treasury, margin);
            emit RevenueRouted(markup, margin);
        }
    }

    /// @dev Walks FWA's request sequence from the last booked one while requests are terminal.
    function _walk(uint256 maxCount) internal returns (uint256 n) {
        uint64 seq = nextSeq;
        uint64 last = pool.lastIssuedSequence();
        uint256 open = farm.openBlock();
        uint256 edge = factory.edgeBps();
        while (n < maxCount && seq <= last) {
            (address purchaser, uint256 requestBlock, uint256 paid, uint256 listingId, IFWAPool.AcquisitionStatus st) =
                pool.acquisitions(pool.requestIdAtSequence(seq));
            if (
                st == IFWAPool.AcquisitionStatus.Pending || st == IFWAPool.AcquisitionStatus.Ready
                    || st == IFWAPool.AcquisitionStatus.DeliveryPending
            ) break;
            uint256 epoch = open == 0 || requestBlock < open ? 0 : (requestBlock - open) / EPOCH_BLOCKS;
            ++epochBooked[epoch];
            if (st == IFWAPool.AcquisitionStatus.Fulfilled) {
                ++_epochUnits[epoch];
                ++_userUnits[epoch][purchaser];
                ++pullsBooked;
                _bookCapture(listingId, paid, edge);
            } else if (st == IFWAPool.AcquisitionStatus.DeliveryRefunded) {
                pool.recoverRefundedNFT(listingId);
                _removeLive(listingId);
                if (items[listingId].row == GRAIL_ROW) {
                    // A recovered GRAIL goes back to the reserve; the next step lists a fresh one.
                    grailReserve += items[listingId].backing;
                    _burnItem(listingId);
                } else {
                    _relist.push(listingId);
                }
                emit Recovered(listingId);
            }
            emit Booked(seq, epoch, purchaser, uint8(st));
            ++seq;
            ++n;
        }
        nextSeq = seq;
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
            if (expected >= it.cost) bookedGain += expected - it.cost;
            else bookedLoss += it.cost - expected;
        }
        if (it.kind == KIND_SHAPE) delivered[it.tokenId] = 1;
        emit Captured(listingId, it.row, paid, markup, margin, expected, it.cost);
    }

    // ------------------------------------------------------------------ inventory

    /// @notice ETH available to mint board prizes: the balance less the GRAIL reserve and unrouted revenue.
    function bankroll() public view returns (uint256) {
        uint256 held = grailReserve + pendingMarkup + pendingMargin;
        uint256 bal = address(this).balance;
        return bal > held ? bal - held : 0;
    }

    /// @notice Bankroll plus the backing of every prize this game holds or has listed.
    function nav() external view returns (uint256) {
        return bankroll() + inventoryBacking;
    }

    /// @dev Lists recovered prizes, then mints and lists prizes for board rows without a live listing.
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
        uint256 mintFee = shapes.mintFee();
        for (uint256 r; r < rows && count < maxList; ++r) {
            if (bits & (uint256(1) << r) != 0) continue;
            (uint8 kind, uint96 backing) = board.rowAt(r);
            Item memory it;
            if (kind == KIND_SHAPE) {
                it.cost = uint80(backing + mintFee);
                if (bankroll() < it.cost) break;
                it.tokenId = uint48(shapes.mintTo{value: it.cost}(backing, address(this)));
            } else if (address(packs) != address(0)) {
                uint32[] memory makeup = packs.defaultMakeup(backing);
                (,, uint256 total,) = packs.quoteMint(makeup);
                if (bankroll() < total) break;
                it.cost = uint80(total);
                it.tokenId = uint48(packs.createPackTo{value: total}(new uint256[](0), makeup, address(this)));
            } else {
                continue;
            }
            it.backing = uint80(backing);
            it.row = uint16(r);
            it.kind = kind;
            bits |= uint256(1) << r;
            inventoryBacking += backing;
            mintFeesPaid += it.cost - backing;
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

    /// @dev Prices an item within bounds: at least its cost, at most cost × (1 + MAX_MARKUP_BPS).
    function _input(Item memory it) internal view returns (IFWAPool.ListingInput memory input, Item memory out) {
        uint256 price = pricing.listPrice(it.kind, it.backing, it.cost);
        uint256 cap = uint256(it.cost) * (BPS + MAX_MARKUP_BPS) / BPS;
        if (price < it.cost) price = it.cost;
        if (price > cap) price = cap;
        it.markupBps = uint16((price - it.cost) * BPS / it.cost);
        input = IFWAPool.ListingInput(_collection(it.kind), it.tokenId, price);
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
            emit Listed(ids[i], it.row, it.tokenId, it.backing, it.cost, inputs[i].price);
        }
    }

    function _collection(uint8 kind) internal view returns (address) {
        return kind == KIND_SHAPE ? address(shapes) : address(packs);
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
            emit Withdrawn(ids[i]);
        }
    }

    function _burnItem(uint256 listingId) internal {
        Item memory it = items[listingId];
        if (it.row != GRAIL_ROW) liveRows &= ~(uint256(1) << it.row);
        else if (grailListing == listingId) grailListing = 0;
        inventoryBacking -= it.backing;
        if (it.kind == KIND_SHAPE) shapes.burn(it.tokenId);
        else packs.redeem(it.tokenId);
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
            uint256 price = _grailPrice(backing, 0, 0);
            IFWAPool.ListingInput[] memory inputs = new IFWAPool.ListingInput[](1);
            inputs[0] = IFWAPool.ListingInput(address(shapes), it.tokenId, price);
            Item[] memory made = new Item[](1);
            made[0] = it;
            _list(inputs, made);
            grailListing = _live[_live.length - 1];
            grailListedAtPull = pullsBooked;
            return 1;
        }
        if (pool.unsettledAcquisitionCount() != 0) return 0;
        (,,,, uint256 weight, uint256 current,, IFWAPool.ListingStatus status) = pool.listings(id);
        if (status != IFWAPool.ListingStatus.Active) return 0;
        uint256 newPrice = _grailPrice(items[id].backing, pullsBooked - grailListedAtPull, weight);
        if (newPrice == current) return 0;
        pool.updatePrice(id, newPrice);
        emit GrailRepriced(id, newPrice);
        return 1;
    }

    /// @notice GRAIL price within the hard bounds: at least MIN_GRAIL_PRICE_BPS of backing, and high enough
    ///         that its win probability is at most MAX_GRAIL_PROB_BPS. `ownWeight` is the GRAIL's current
    ///         weight in the pool (0 when not active).
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

    // ------------------------------------------------------------------ conversion

    /// @notice Converts a Shape this pool delivered into ENGINE: burns it for its backing, buys ENGINE with
    ///         that ETH (fee-exempt) for the caller, and adds the conversion bonus from the farm's bonus pool
    ///         at the executed price. Once per token. Reverts if the bonus pool cannot cover the bonus unless
    ///         `allowNoBonus`, in which case whatever the pool holds is paid.
    function convert(uint256 tokenId, uint256 minEngineOut, bool allowNoBonus)
        external
        nonReentrant
        returns (uint256 engineOut, uint256 bonus)
    {
        if (delivered[tokenId] != 1) revert NotConvertible();
        delivered[tokenId] = 2;
        shapes.transferFrom(msg.sender, address(this), tokenId);
        uint256 before = address(this).balance;
        shapes.burn(tokenId);
        uint256 value = address(this).balance - before;
        uint256 spent;
        (engineOut, spent) = buyer.buy{value: value}(minEngineOut, msg.sender, BPS);
        if (spent < value) SafeTransferLib.forceSafeTransferETH(msg.sender, value - spent);
        uint256 bps = pricing.conversionBonusBps();
        if (bps > MAX_BONUS_BPS) bps = MAX_BONUS_BPS;
        bonus = engineOut * bps / BPS;
        if (bonus != 0) {
            if (farm.bonusPool() < bonus && !allowNoBonus) revert BonusUnavailable();
            bonus = farm.payBonus(msg.sender, bonus);
        }
        emit Converted(msg.sender, tokenId, value, engineOut, bonus);
    }

    // ------------------------------------------------------------------ ledger

    function epochUnits(uint256 epoch) external view returns (uint256) {
        return _epochUnits[epoch];
    }

    function userUnits(uint256 epoch, address purchaser) external view returns (uint256) {
        return _userUnits[epoch][purchaser];
    }

    /// @notice `(booked, units)` of `epoch`: pulls booked in it (any terminal status) and delivered pulls.
    function epochTotals(uint256 epoch) external view returns (uint256 booked, uint256 units) {
        return (epochBooked[epoch], _epochUnits[epoch]);
    }

    /// @notice True once `epoch` has ended and every request made in it is terminal and booked
    ///         (docs/IMPLEMENTOR_DECISIONS.md D6).
    function isEpochFinal(uint256 epoch) external view returns (bool) {
        uint256 open = farm.openBlock();
        if (open == 0) return false;
        uint256 end = open + (epoch + 1) * EPOCH_BLOCKS;
        if (block.number < end) return false;
        if (address(pool) == address(0)) return true;
        uint64 seq = nextSeq;
        if (seq > pool.lastIssuedSequence()) return true;
        (, uint256 requestBlock,,,) = pool.acquisitions(pool.requestIdAtSequence(seq));
        return requestBlock >= end;
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

    // ------------------------------------------------------------------ governance

    function setModule(bytes32 kind, address module) external onlyGovernance {
        _setModule(kind, module);
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
