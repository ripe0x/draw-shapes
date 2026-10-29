// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Governed} from "../Governed.sol";
import {IFWAPool, IFWAFactory} from "../interfaces/IFWA.sol";
import {
    IFwaGame,
    IPrizeVault,
    IGenesisFarm,
    IKeeperFund,
    IEngineBuyer,
    IBoardPolicy,
    IPricingPolicy,
    IPoolOwner,
    ILaunched
} from "../interfaces/IDrawShapes.sol";

/// @title FwaGame
/// @notice The Draw Shapes ledger. It walks FWA's request sequence (`sync`) to record every pull's ticket ETH in the
///         farm's ledger and book its economics; pays the PoolOwner to mint and list replacement prizes (Shapes and
///         Shape Packs) at maintenance windows; switches FWA purchases by its admission rules and sets the PoolOwner's
///         purchase gate; runs pre-funded promotions; pays the operating allocation to KeeperFund; and sends only
///         realised, distributable profit to the buyback. On retirement it returns everything to the vault.
/// @dev Accounting (docs/IMPLEMENTOR_DECISIONS.md D31-D34, D47). Inventory is capital carried at cost (backing plus
///      mint fees). A capture books owner proceeds as revenue and the prize's carried cost as its one expense; the
///      replacement purchase is a capital movement. Proceeds are booked at the highest FWA edge the game has ever
///      accepted (a lower bound) and trued up to what FWA actually paid once nothing is outstanding; the operating
///      allocation and markup are frozen on each listing; so no configuration change between listing, request and
///      booking can create profit. Profit is cumulative and signed. A distribution needs both undistributed profit and
///      cash above every protected amount. `sync` runs each step in its own `try` (D46): a failing step emits
///      `StepFailed` and leaves the others working; booking and retirement read no module. ETH leaves only to the vault,
///      the PoolOwner (exactly the prize cost it mints with), KeeperFund (operating allocation) and the buyback (profit).
contract FwaGame is IFwaGame, ReentrancyGuard, Governed {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WEIGHT_NUMERATOR = 1e36; // FWA's inverse-weight numerator
    uint16 internal constant PROMO_ROW = type(uint16).max;

    uint256 internal constant MAX_BOARD = 200;
    uint256 internal constant MAX_LIST_PER_CALL = 20; // FWA's listing batch maximum
    uint256 internal constant MAX_MARKUP_BPS = 500;
    uint256 internal constant MAX_OPS_BPS = 500;
    uint256 internal constant MIN_PROMO_PRICE_BPS = 5_000;
    uint256 internal constant MAX_PROMO_PROB_BPS = 1_000;
    uint256 internal constant MAX_PROMO_BLOCKS = 30 * 7_200;
    uint256 internal constant MAX_COOLDOWN = 1 days;
    uint256 internal constant MAX_MAINTENANCE_INTERVAL = 1 days;
    uint256 internal constant MAX_RESERVE_TARGET = 1_000 ether;
    uint256 internal constant MAX_MARKET_LEAD = 7 days;
    /// @notice Blocks after a request before a delivery still pending counts as resolved without weight: FWA's
    ///         7-day refund window plus one epoch.
    uint256 public constant DELIVERY_GRACE_BLOCKS = 50_400 + 7_200;

    IFWAFactory public immutable factory;
    IPoolOwner public immutable poolOwner;
    IPrizeVault public immutable vault;
    IGenesisFarm public immutable farm;
    address public immutable buyback;
    IKeeperFund public immutable keeperFund;
    uint256 public immutable EPOCH_BLOCKS;
    /// @notice Minimum time between the ENGINE market opening and `openGame`.
    uint256 public immutable marketLead;

    IFWAPool public pool;
    IBoardPolicy public board;
    IPricingPolicy public pricing;
    IEngineBuyer public buyer; // read by the Converter

    /// @notice Capital and admission settings (`setCapital`).
    struct Capital {
        uint256 reserveTarget; // cash kept before any distribution, beyond replacements and exposure
        uint256 maintenanceInterval; // longest wait before replacements list
        uint256 minLiveBps; // board fill below which new purchases close (and the purchase gate's floor)
        uint256 maxInFlight; // unsettled requests at which the purchase gate refuses (a full batch assumed on top)
        uint256 maxEdgeBps; // FWA edge above which new purchases close
        uint256 maxCooldown; // FWA inventory cooldown above which new purchases close
    }

    uint256 public reserveTarget;
    uint256 public maintenanceInterval;
    uint256 public minLiveBps;
    uint256 public maxInFlight;
    uint256 public maxEdgeBps;
    uint256 public maxCooldown;
    /// @notice The highest `maxEdgeBps` ever set: proceeds are booked at this edge, a lower bound on what FWA pays.
    uint256 public bookingEdgeBps;
    uint256 internal _gateMinListed; // the floor last given to the purchase gate

    /// @notice One record per listing this game made.
    struct Item {
        uint48 tokenId;
        uint72 backing;
        uint72 cost; // backing + mint fees paid
        uint16 row; // board row, or PROMO_ROW
        uint16 markupBps; // frozen at listing
        uint16 opsBps; // frozen at listing
        uint8 kind; // 0 Shape, 1 Pack
        bool live;
    }

    mapping(uint256 listingId => Item) public items;
    uint256[] internal _live;
    mapping(uint256 listingId => uint256) internal _liveIndex; // index + 1
    /// @notice Board rows with a live listing, one bit per row.
    uint256 public liveRows;

    // ledger: every issued request is seen once (accepted), then resolved once it is terminal
    struct Open {
        uint64 seq;
        uint32 epoch;
        bool rewardResolved; // counted resolved (without weight) for the farm; economics may still be open
        bool promo; // seen while a promotion was live
    }

    uint64 public seenSeq = 1;
    Open[] internal _open;
    mapping(uint256 epoch => uint256) public epochAccepted;
    mapping(uint256 epoch => uint256) public epochResolved;
    /// @notice Ticket ETH (FWA fee paid, excluding the VRF fee) of delivered pulls, by request epoch.
    mapping(uint256 epoch => uint256) public epochWeight;
    mapping(uint256 epoch => mapping(address => uint256)) public userWeight;
    uint256 public pullsBooked;

    // capital
    uint256 public capitalIn; // vault funding: opening capital, trading fees, contributions
    uint256 public inventoryBacking; // backing of every prize held or listed
    uint256 public inventoryCost; // carried cost of board prizes held or listed
    uint256 public replacementsOwed; // cost of vacated board rows not yet replaced
    uint256 public maxItemCost; // largest prize cost minted, for settlement exposure

    // profit and loss of the ordinary game
    uint256 public turnover; // ticket ETH of delivered pulls
    uint256 public promoTurnover; // the part of `turnover` seen while a promotion was live
    uint256 public revenue; // owner proceeds of captured board prizes (and the true-up)
    uint256 public prizeExpense; // carried cost of captured board prizes, plus mint fees written off on burns
    uint256 public opsAccrued; // operating allocation
    uint256 public opsPaid;
    uint256 public opsReturned; // KeeperFund overflow
    uint256 public distributed; // profit sent to the buyback
    uint256 public proceedsBooked; // owner proceeds booked (board and promotion), at the booking edge
    uint256 public proceedsCollected; // owner proceeds FWA actually paid

    // promotions: a separate budget, never profit
    uint256 public promoBudget;
    uint256 public promoFunded;
    uint256 public promoProceeds;
    uint256 public promoSpent; // cost of promotion prizes won, plus mint fees written off
    uint256 public promoReleased;
    uint256 public promoListing;
    uint256 public promoEndBlock;

    bool public opened;
    bool public paused;
    bool public retiring;
    bool public retired;
    uint256 public lastSyncAt;
    uint256 public lastMaintenanceAt;

    event Funded(uint256 amount);
    event PromotionFunded(address indexed from, uint256 amount);
    event GameOpened(uint256 openBlock);
    event Admission(bool open);
    event Listed(uint256 indexed listingId, uint256 indexed row, uint256 price);
    event Resolved(uint256 indexed sequence, uint256 indexed epoch, uint8 status, uint256 weight);
    event Captured(uint256 indexed listingId, uint256 proceeds, uint256 cost, uint256 ops);
    event TrueUp(uint256 amount);
    event Distributed(uint256 amount);
    event OpsPaid(uint256 amount);
    event PromotionStarted(uint256 indexed listingId, uint256 cost, uint256 price, uint256 endBlock);
    event StepFailed(bytes32 indexed step);
    event RetireStarted();
    event Retired(uint256 returned);
    event ModuleSet(bytes32 indexed kind, address module);
    event CapitalSet(Capital c);

    error PoolExists();
    error NoPool();
    error NotVault();
    error NotKeeperFund();
    error NotSelf();
    error Retiring();
    error NotRetiring();
    error NotReady();
    error NoWork();

    /// @notice Constructor arguments.
    struct Config {
        address governance;
        address factory;
        address poolOwner;
        address vault;
        address farm;
        address buyback;
        address keeperFund;
        address board;
        address pricing;
        address buyer;
        Capital capital;
        uint256 marketLead;
    }

    constructor(Config memory c) Governed(c.governance, false) {
        if (
            c.factory == address(0) || c.poolOwner == address(0) || c.vault == address(0) || c.farm == address(0)
                || c.buyback == address(0) || c.keeperFund == address(0)
        ) revert ZeroAddress();
        if (c.marketLead > MAX_MARKET_LEAD) revert OutOfBounds();
        factory = IFWAFactory(c.factory);
        poolOwner = IPoolOwner(c.poolOwner);
        vault = IPrizeVault(c.vault);
        farm = IGenesisFarm(c.farm);
        buyback = c.buyback;
        keeperFund = IKeeperFund(c.keeperFund);
        marketLead = c.marketLead;
        EPOCH_BLOCKS = IGenesisFarm(c.farm).EPOCH_BLOCKS();
        _setModule("board", c.board);
        _setModule("pricing", c.pricing);
        _setModule("buyer", c.buyer);
        _setCapital(c.capital);
        lastSyncAt = block.timestamp;
    }

    receive() external payable {}

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    // ------------------------------------------------------------------ setup and inflows

    /// @notice The PoolOwner reports the FWA pool it created; the game sets the purchase gate.
    function poolCreated(address pool_) external {
        if (msg.sender != address(poolOwner) || address(pool) != address(0)) revert PoolExists();
        pool = IFWAPool(pool_);
        _pushGate();
    }

    /// @notice Capital from the vault. Capital is never profit.
    function receiveFunding() external payable {
        if (msg.sender != address(vault)) revert NotVault();
        capitalIn += msg.value;
        emit Funded(msg.value);
    }

    /// @notice Adds to the promotion budget. Not while retiring.
    function fundPromotion() external payable {
        if (retiring) revert Retiring();
        promoBudget += msg.value;
        promoFunded += msg.value;
        emit PromotionFunded(msg.sender, msg.value);
    }

    /// @notice KeeperFund returns operating allocation above its target; it reduces the net operating expense.
    function returnOps() external payable {
        if (msg.sender != address(keeperFund)) revert NotKeeperFund();
        opsReturned += msg.value;
    }

    /// @notice Opens the game: at least `marketLead` after the ENGINE market opened, with every board row listed and
    ///         the reserve target in cash. Starts the farm clock and admits purchases.
    function openGame() external onlyGovernance {
        if (address(pool) == address(0)) revert NoPool();
        if (retiring) revert Retiring();
        uint256 t0 = ILaunched(buyer.hook()).launchedAt();
        if (t0 == 0 || block.timestamp < t0 + marketLead || _popcount(liveRows) < _rows() || cash() < reserveTarget) {
            revert NotReady();
        }
        opened = true;
        if (farm.openBlock() == 0) farm.start();
        _admit();
        emit GameOpened(farm.openBlock());
    }

    /// @notice Pauses or resumes new purchases. Settlement, delivery and refunds continue either way.
    function setPaused(bool paused_) external onlyGovernance {
        if (retiring) revert Retiring();
        paused = paused_;
        _admit();
    }

    // ------------------------------------------------------------------ keeper work

    /// @notice Sees and resolves up to `maxCount` requests, collects owner proceeds, pays the operating allocation and
    ///         distributable profit, at a maintenance window lists replacements and ends an expired promotion, applies
    ///         the admission rules and the purchase gate, and refills KeeperFund from the vault if it is low. Each step
    ///         runs on its own: a failing one emits `StepFailed`. Anyone may call; tipped. Reverts `NoWork` when there
    ///         is nothing to do.
    function sync(uint256 maxCount) external nonReentrant returns (uint256 work) {
        uint256 gasStart = gasleft();
        if (address(pool) == address(0)) revert NoPool();
        if (retiring) revert Retiring();
        work = _advance(maxCount);
        if (!factory.globalWithdrawOnly()) {
            try this.maintainStep() returns (uint256 changes) {
                work += changes;
            } catch {
                emit StepFailed("maintenance");
            }
        }
        try this.admitStep() returns (bool changed) {
            if (changed) ++work;
        } catch {
            emit StepFailed("admission");
        }
        try vault.topUpKeeper() {} catch {}
        _tip(gasStart, work, false);
    }

    /// @notice Retirement, step by step: settle and book, then withdraw and burn every prize FWA still holds for us,
    ///         then return everything to the vault. Uses no module. A prize stuck in FWA's delivery quarantine does not
    ///         block it: later calls sweep whatever it yields to the vault. Anyone may call; tipped (retirement may spend
    ///         the keeper floor). Works while the factory is withdraw-only.
    function retireStep(uint256 maxCount) external nonReentrant returns (uint256 work) {
        uint256 gasStart = gasleft();
        if (!retiring) revert NotRetiring();
        bool caughtUp = true;
        if (address(pool) != address(0)) {
            work = _advance(maxCount);
            caughtUp = pool.unsettledAcquisitionCount() == 0 && seenSeq > pool.lastIssuedSequence();
        }
        uint256 left;
        if (caughtUp && !retired) (work, left) = (work + _withdrawSome(), _withdrawable());
        uint256 amount = address(this).balance;
        if (caughtUp && left == 0 && (!retired || amount != 0)) {
            promoBudget = 0;
            replacementsOwed = 0;
            if (!retired) {
                retired = true;
                vault.repay{value: amount}(true);
                emit Retired(amount);
            } else {
                SafeTransferLib.forceSafeTransferETH(address(vault), amount); // a late settlement after retirement
            }
            ++work;
        }
        _tip(gasStart, work, true);
    }

    /// @notice Starts retirement. Called by the vault (`PrizeVault.retireGame`, timelock).
    function retire() external {
        if (msg.sender != address(vault)) revert NotVault();
        if (retiring) revert Retiring();
        retiring = true;
        if (address(pool) != address(0) && !pool.retired()) {
            try poolOwner.retirePool() {}
            catch {
                emit StepFailed("retirePool");
            }
        }
        emit RetireStarted();
    }

    function _tip(uint256 gasStart, uint256 work, bool retirement) internal {
        if (work == 0) revert NoWork();
        lastSyncAt = block.timestamp;
        try keeperFund.tip(msg.sender, gasStart - gasleft(), work, retirement) {} catch {}
    }

    /// @dev Cranks FWA settlement, books, collects owner proceeds, trues up, then pays: each on its own.
    function _advance(uint256 maxCount) internal returns (uint256 work) {
        try pool.processAcquisitions(maxCount) {} catch {}
        try this.bookStep(maxCount) returns (uint256 w) {
            work = w;
        } catch {
            emit StepFailed("booking");
        }
        try poolOwner.collectProceeds() returns (uint256 got) {
            proceedsCollected += got;
        } catch {
            emit StepFailed("proceeds");
        }
        _trueUp();
        try this.payStep() {}
        catch {
            emit StepFailed("distribution");
        }
    }

    function bookStep(uint256 maxCount) external onlySelf returns (uint256 work) {
        work = _resolveOpen(maxCount);
        work += _see(maxCount);
    }

    function payStep() external onlySelf {
        _pay();
    }

    function maintainStep() external onlySelf returns (uint256 changes) {
        if (pool.retired() || !_maintenanceDue()) return 0;
        changes = _restock() + _promoStep();
        if (changes != 0) lastMaintenanceAt = block.timestamp;
    }

    function admitStep() external onlySelf returns (bool) {
        if (_minListed() != _gateMinListed) _pushGate();
        return _admit();
    }

    /// @dev Books what FWA actually paid above the proceeds booked at the booking edge, once every issued request is
    ///      booked and FWA holds no owner proceeds for us: the books then match FWA exactly.
    function _trueUp() internal {
        if (proceedsCollected <= proceedsBooked || _open.length != 0) return;
        if (seenSeq <= pool.lastIssuedSequence() || pool.unsettledAcquisitionCount() != 0 || pool.ownerProceeds() != 0)
        {
            return;
        }
        uint256 extra = proceedsCollected - proceedsBooked;
        proceedsBooked = proceedsCollected;
        revenue += extra;
        emit TrueUp(extra);
    }

    // ------------------------------------------------------------------ accounting views

    /// @notice Cash the game may spend on prizes: its balance less the promotion budget.
    function cash() public view returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > promoBudget ? bal - promoBudget : 0;
    }

    /// @notice Operating allocation accrued and not yet paid to KeeperFund.
    function opsOwed() public view returns (uint256) {
        return opsAccrued - opsPaid;
    }

    /// @notice Realised profit of the ordinary game since launch, signed: revenue less prize expense and net operating
    ///         allocation. Capital and promotions never enter it.
    function profit() public view returns (int256) {
        return int256(revenue + opsReturned) - int256(prizeExpense + opsAccrued);
    }

    /// @notice Worst-case replacement cost of requests FWA has issued and not settled, bounded by the inventory (they
    ///         cannot win more than every prize held).
    function exposure() public view returns (uint256 e) {
        if (address(pool) == address(0)) return 0;
        e = pool.unsettledAcquisitionCount() * maxItemCost;
        if (e > inventoryCost) e = inventoryCost;
    }

    /// @notice Cash the game protects before any distribution: replacements owed, operating allocation owed, the
    ///         reserve target and the settlement exposure.
    function protectedCash() public view returns (uint256) {
        return replacementsOwed + opsOwed() + reserveTarget + exposure();
    }

    /// @notice What may go to the buyback now: the lesser of undistributed profit and cash above protection.
    function distributable() public view returns (uint256) {
        int256 p = profit() - int256(distributed);
        uint256 c = cash();
        uint256 keep = protectedCash();
        if (retiring || p <= 0 || c <= keep) return 0;
        c -= keep;
        return uint256(p) < c ? uint256(p) : c;
    }

    /// @notice True when FWA's settings are in the supported range and the board is filled enough for new purchases.
    ///         (The in-flight bound is the purchase gate's, checked at every purchase.)
    function admissible() public view returns (bool) {
        return factory.edgeBps() <= maxEdgeBps && factory.inventoryChangeCooldown() <= maxCooldown
            && _popcount(liveRows) * BPS >= minLiveBps * _rows();
    }

    /// @dev Pays the operating allocation once replacements are covered (during retirement, from any cash), then
    ///      distributable profit.
    function _pay() internal {
        uint256 owe = opsOwed();
        if (owe != 0 && cash() >= owe + (retiring ? 0 : replacementsOwed)) {
            opsPaid += owe;
            keeperFund.fundKeeper{value: owe}();
            emit OpsPaid(owe);
        }
        uint256 d = distributable();
        if (d == 0) return;
        distributed += d;
        SafeTransferLib.forceSafeTransferETH(buyback, d);
        emit Distributed(d);
    }

    /// @dev Opens or closes FWA purchases to match the rules. True when it changed.
    function _admit() internal returns (bool) {
        bool ok = opened && !paused && !retiring && admissible();
        if (ok == pool.localPurchasesEnabled()) return false;
        poolOwner.setAcquisitions(ok);
        emit Admission(ok);
        return true;
    }

    /// @dev The purchase gate's floor: the admission fill of the board, rounded up.
    function _minListed() internal view returns (uint256) {
        return (minLiveBps * _rows() + BPS - 1) / BPS;
    }

    function _pushGate() internal {
        if (address(pool) == address(0)) return;
        uint256 ml = _minListed();
        _gateMinListed = ml;
        poolOwner.setGate(maxInFlight, maxEdgeBps, maxCooldown, ml);
    }

    // ------------------------------------------------------------------ the walk

    /// @dev First cursor: every issued request is seen once, counted accepted in its epoch, and resolved at once if it is
    ///      already terminal; otherwise it joins the open set.
    function _see(uint256 maxCount) internal returns (uint256 n) {
        uint64 seq = seenSeq;
        uint64 last = pool.lastIssuedSequence();
        uint256 open = farm.openBlock();
        while (n < maxCount && seq <= last) {
            uint256 requestId = pool.requestIdAtSequence(seq);
            uint256 requestBlock = _request(requestId).requestBlock;
            uint256 epoch = open == 0 || requestBlock < open ? 0 : (requestBlock - open) / EPOCH_BLOCKS;
            ++epochAccepted[epoch];
            Open memory o = Open(seq, uint32(epoch), false, promoListing != 0);
            if (!_tryResolve(o, requestId)) _open.push(o);
            ++seq;
            ++n;
        }
        seenSeq = seq;
    }

    /// @dev Second cursor: resolves open requests that have become terminal, in any order.
    function _resolveOpen(uint256 maxCount) internal returns (uint256 n) {
        uint256 i;
        while (i < _open.length && n < maxCount) {
            Open memory o = _open[i];
            bool wasResolved = o.rewardResolved;
            if (_tryResolve(o, pool.requestIdAtSequence(o.seq))) {
                _open[i] = _open[_open.length - 1];
                _open.pop();
                ++n;
            } else {
                if (!wasResolved && o.rewardResolved) {
                    _open[i].rewardResolved = true; // resolved for rewards, economics still open
                    ++n;
                }
                ++i;
            }
        }
    }

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

    /// @dev Resolves `o` if its request is terminal. A pending delivery vacates the prize's row at once (FWA has taken it
    ///      out of the draw) and, after the grace period, counts resolved without weight; it stays open until its
    ///      economics settle. A delivered pull adds its ticket ETH to the purchaser's weight. A refunded delivery counts
    ///      resolved for the farm first; its prize is then recovered and burned, and if that fails it stays open and is
    ///      retried.
    function _tryResolve(Open memory o, uint256 requestId) internal returns (bool done) {
        Req memory r = _request(requestId);
        IFWAPool.AcquisitionStatus st = r.status;
        if (
            st == IFWAPool.AcquisitionStatus.Pending || st == IFWAPool.AcquisitionStatus.Ready
                || st == IFWAPool.AcquisitionStatus.None
        ) return false;
        if (st == IFWAPool.AcquisitionStatus.DeliveryPending) {
            _vacate(r.listingId);
            if (!o.rewardResolved && block.number > r.requestBlock + DELIVERY_GRACE_BLOCKS) _resolveForFarm(o, st);
            return false;
        }
        uint256 weight;
        if (st == IFWAPool.AcquisitionStatus.Fulfilled) {
            if (!o.rewardResolved) {
                weight = r.paid;
                epochWeight[o.epoch] += weight;
                userWeight[o.epoch][r.purchaser] += weight;
                ++epochResolved[o.epoch];
            }
            ++pullsBooked;
            turnover += r.paid;
            if (o.promo) promoTurnover += r.paid;
            _bookCapture(r.listingId, r.paid);
        } else if (st == IFWAPool.AcquisitionStatus.DeliveryRefunded) {
            if (!o.rewardResolved) _resolveForFarm(o, st);
            try poolOwner.recoverAndBurn(r.listingId) {
                _vacate(r.listingId);
                _writeOff(r.listingId);
            } catch {
                emit StepFailed("recover");
                return false;
            }
        } else if (!o.rewardResolved) {
            ++epochResolved[o.epoch];
        }
        emit Resolved(o.seq, o.epoch, uint8(st), weight);
        return true;
    }

    function _resolveForFarm(Open memory o, IFWAPool.AcquisitionStatus st) internal {
        ++epochResolved[o.epoch];
        o.rewardResolved = true;
        emit Resolved(o.seq, o.epoch, uint8(st), 0);
    }

    /// @dev Books a delivered prize. Board prize: proceeds (at the booking edge) are revenue, its carried cost the
    ///      expense, and the operating allocation the listing's frozen `opsBps` of the quote's expected replacement cost,
    ///      taken on the ticket before FWA's edge so it is never understated. Promotion prize: proceeds and cost stay in
    ///      the promotion budget.
    function _bookCapture(uint256 listingId, uint256 paid) internal {
        _vacate(listingId);
        Item memory it = items[listingId];
        inventoryBacking -= it.backing;
        uint256 base = paid * BPS / (BPS + bookingEdgeBps);
        uint256 proceeds = paid - (paid - base) / 2;
        proceedsBooked += proceeds;
        uint256 ops;
        if (it.row == PROMO_ROW) {
            promoBudget += proceeds;
            promoProceeds += proceeds;
            promoSpent += it.cost;
        } else {
            inventoryCost -= it.cost;
            revenue += proceeds;
            prizeExpense += it.cost;
            ops = base * BPS / (BPS + it.markupBps) * it.opsBps / BPS;
            opsAccrued += ops;
        }
        emit Captured(listingId, proceeds, it.cost, ops);
    }

    /// @dev Takes a listing off the board: its row needs a replacement (or the promotion ends). Once per listing.
    function _vacate(uint256 listingId) internal {
        uint256 idx = _liveIndex[listingId];
        if (idx == 0) return;
        uint256 lastId = _live[_live.length - 1];
        _live[idx - 1] = lastId;
        _liveIndex[lastId] = idx;
        _live.pop();
        delete _liveIndex[listingId];
        Item storage it = items[listingId];
        it.live = false;
        if (it.row == PROMO_ROW) {
            promoListing = 0;
        } else {
            liveRows &= ~(uint256(1) << it.row);
            replacementsOwed += it.cost;
        }
    }

    /// @dev Books a prize the PoolOwner turned back into ETH (its backing arrived): the mint fees are written off
    ///      (against the promotion budget for a promotion prize).
    function _writeOff(uint256 listingId) internal {
        Item memory it = items[listingId];
        inventoryBacking -= it.backing;
        if (it.row == PROMO_ROW) {
            promoBudget += it.backing;
            promoSpent += it.cost - it.backing;
        } else {
            inventoryCost -= it.cost;
            prizeExpense += it.cost - it.backing;
        }
        delete items[listingId];
    }

    // ------------------------------------------------------------------ inventory

    /// @dev Replacements list when nothing is in flight (FWA would stage them until a later request settles), unless the
    ///      board is near the purchase gate's line; and then when `listBatch` rows wait or `maintenanceInterval` (at least six
    ///      FWA cooldowns) has passed since the last inventory change, or a promotion has ended (D49).
    function _maintenanceDue() internal view returns (bool) {
        uint256 rows = _rows();
        uint256 live = _popcount(liveRows);
        // short: near the purchase gate's line (the floor, a full batch and every request the gate allows in flight),
        // so replacements list under steady play before the gate would close
        bool short_ = live < _minListed() + maxInFlight + 5;
        if (!short_ && pool.unsettledAcquisitionCount() != 0) return false;
        if (promoListing != 0 && block.number >= promoEndBlock) return true;
        if (live == rows) return false;
        uint256 wait = maintenanceInterval;
        uint256 cd = factory.inventoryChangeCooldown() * 6;
        if (cd > wait) wait = cd;
        return short_ || rows - live >= board.listBatch() || block.timestamp >= lastMaintenanceAt + wait;
    }

    function _rows() internal view returns (uint256 rows) {
        rows = board.rowCount();
        if (rows > MAX_BOARD) rows = MAX_BOARD;
    }

    function _popcount(uint256 x) internal pure returns (uint256 c) {
        while (x != 0) {
            x &= x - 1;
            ++c;
        }
    }

    /// @dev Pays the PoolOwner to mint and list prizes for board rows without a live listing (up to 20 per call), while
    ///      cash covers them. Price, markup and operating allocation are fixed per listing here.
    function _restock() internal returns (uint256 count) {
        uint256 rows = _rows();
        IPoolOwner.Mint[] memory mints = new IPoolOwner.Mint[](MAX_LIST_PER_CALL);
        Item[] memory made = new Item[](MAX_LIST_PER_CALL);
        uint256 bits = liveRows;
        uint256 total;
        uint256 c = cash();
        uint256 opsBps = pricing.opsBps();
        if (opsBps > MAX_OPS_BPS) opsBps = MAX_OPS_BPS;
        for (uint256 r; r < rows && count < MAX_LIST_PER_CALL; ++r) {
            if (bits & (uint256(1) << r) != 0) continue;
            (uint8 kind, uint96 backing) = board.rowAt(r);
            uint256 cost = poolOwner.costOf(kind, backing);
            if (cost == 0) continue;
            if (c < total + cost) break;
            total += cost;
            Item memory it;
            it.cost = uint72(cost);
            it.backing = uint72(backing);
            it.row = uint16(r);
            it.kind = kind;
            it.opsBps = uint16(opsBps);
            mints[count] = IPoolOwner.Mint(kind, backing, cost, _price(it));
            made[count] = it;
            bits |= uint256(1) << r;
            ++count;
        }
        if (count == 0) return 0;
        assembly ("memory-safe") {
            mstore(mints, count)
        }
        _list(mints, made, total);
        liveRows = bits;
    }

    /// @dev Prices an item within bounds (at least its cost, at most cost × 1.05) and records the markup on it.
    function _price(Item memory it) internal view returns (uint256 price) {
        price = pricing.listPrice(it.kind, it.backing, it.cost);
        uint256 cap = uint256(it.cost) * (BPS + MAX_MARKUP_BPS) / BPS;
        if (price < it.cost) price = it.cost;
        if (price > cap) price = cap;
        it.markupBps = uint16((price - it.cost) * BPS / it.cost);
    }

    function _list(IPoolOwner.Mint[] memory mints, Item[] memory made, uint256 total) internal {
        (uint256[] memory ids, uint256[] memory tokenIds) = poolOwner.mintAndList{value: total}(mints);
        for (uint256 i; i < ids.length; ++i) {
            Item memory it = made[i];
            it.tokenId = uint48(tokenIds[i]);
            it.live = true;
            items[ids[i]] = it;
            _liveIndex[ids[i]] = _live.length + 1;
            _live.push(ids[i]);
            inventoryBacking += it.backing;
            if (it.row != PROMO_ROW) {
                inventoryCost += it.cost;
                replacementsOwed = replacementsOwed > it.cost ? replacementsOwed - it.cost : 0;
                if (it.cost > maxItemCost) maxItemCost = it.cost;
            }
            emit Listed(ids[i], it.row, mints[i].price);
        }
    }

    /// @dev Withdraws up to 20 listings FWA still holds as Active or Staged; the PoolOwner burns them for their backing.
    function _withdrawSome() internal returns (uint256 n) {
        uint256[] memory ids = new uint256[](MAX_LIST_PER_CALL);
        for (uint256 i = _live.length; i != 0 && n < MAX_LIST_PER_CALL; --i) {
            if (_withdrawableListing(_live[i - 1])) ids[n++] = _live[i - 1];
        }
        if (n == 0) return 0;
        assembly ("memory-safe") {
            mstore(ids, n)
        }
        poolOwner.withdrawAndBurn(ids);
        for (uint256 i; i < n; ++i) {
            _vacate(ids[i]);
            _writeOff(ids[i]);
        }
    }

    /// @dev Live listings FWA still holds as Active or Staged.
    function _withdrawable() internal view returns (uint256 n) {
        for (uint256 i; i < _live.length; ++i) {
            if (_withdrawableListing(_live[i])) ++n;
        }
    }

    function _withdrawableListing(uint256 id) internal view returns (bool) {
        (,,,,,,, IFWAPool.ListingStatus st) = pool.listings(id);
        return st == IFWAPool.ListingStatus.Active || st == IFWAPool.ListingStatus.Staged;
    }

    // ------------------------------------------------------------------ promotions

    /// @notice Starts a promotion: one Shape of `backing`, paid in full from the promotion budget (its cost is the
    ///         promotion's maximum obligation), listed at `priceBps` of its cost and never repriced, until it is won or
    ///         `endBlock`. Price bounds: at least MIN_PROMO_PRICE_BPS of backing, and a win probability of at most
    ///         MAX_PROMO_PROB_BPS. One promotion at a time.
    function startPromotion(uint256 backing, uint256 priceBps, uint256 endBlock) external onlyGovernance {
        uint256 cost = poolOwner.costOf(0, backing);
        if (
            retiring || promoListing != 0 || cost > promoBudget || endBlock <= block.number
                || endBlock > block.number + MAX_PROMO_BLOCKS || address(pool) == address(0)
        ) revert NotReady();
        uint256 price = cost * priceBps / BPS;
        uint256 floor = backing * MIN_PROMO_PRICE_BPS / BPS;
        if (price < floor) price = floor;
        // weight / (others + weight) <= MAX  <=>  weight <= MAX × others / (BPS − MAX)
        uint256 maxWeight = MAX_PROMO_PROB_BPS * pool.totalWeight() / (BPS - MAX_PROMO_PROB_BPS);
        uint256 probFloor = maxWeight == 0 ? type(uint128).max : WEIGHT_NUMERATOR / maxWeight + 1;
        if (price < probFloor) price = probFloor;
        promoBudget -= cost;
        Item memory it;
        it.cost = uint72(cost);
        it.backing = uint72(backing);
        it.row = PROMO_ROW;
        IPoolOwner.Mint[] memory mints = new IPoolOwner.Mint[](1);
        mints[0] = IPoolOwner.Mint(0, backing, cost, price);
        Item[] memory made = new Item[](1);
        made[0] = it;
        _list(mints, made, cost);
        promoListing = _live[_live.length - 1];
        promoEndBlock = endBlock;
        emit PromotionStarted(promoListing, cost, price, endBlock);
    }

    /// @dev After its end block, withdraws an unwon promotion prize and burns it; the backing returns to the budget.
    function _promoStep() internal returns (uint256) {
        uint256 id = promoListing;
        if (id == 0 || block.number < promoEndBlock || pool.unsettledAcquisitionCount() != 0) return 0;
        if (!_withdrawableListing(id)) return 0;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        poolOwner.withdrawAndBurn(ids);
        _vacate(id);
        _writeOff(id);
        return 1;
    }

    /// @notice Returns unspent promotion budget to the vault, as capital. Not while a promotion is live.
    function releasePromotion(uint256 amount) external onlyGovernance {
        if (promoListing != 0 || amount > promoBudget) revert NotReady();
        promoBudget -= amount;
        promoReleased += amount;
        vault.repay{value: amount}(false);
    }

    // ------------------------------------------------------------------ ledger

    /// @notice `(accepted, resolved, weight)` of `epoch`.
    function epochTotals(uint256 epoch) external view returns (uint256, uint256, uint256) {
        return (epochAccepted[epoch], epochResolved[epoch], epochWeight[epoch]);
    }

    /// @notice True once `epoch` has ended, every request FWA issued in it has been seen (accepted), and every accepted
    ///         request is resolved.
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

    function openCount() external view returns (uint256) {
        return _open.length;
    }

    // ------------------------------------------------------------------ governance

    function setModule(bytes32 kind, address module) external onlyGovernance {
        _setModule(kind, module);
    }

    /// @notice Sets the capital and admission settings. The reserve target is at least twice the cost of the board's
    ///         most expensive prize.
    function setCapital(Capital calldata c) external onlyGovernance {
        _setCapital(c);
        _pushGate();
        if (opened && !retiring) _admit();
    }

    function _setCapital(Capital memory c) internal {
        if (
            c.reserveTarget > MAX_RESERVE_TARGET || c.maintenanceInterval > MAX_MAINTENANCE_INTERVAL
                || c.minLiveBps < 5_000 || c.minLiveBps > BPS || c.maxInFlight == 0 || c.maxInFlight > 20
                || c.maxEdgeBps > 1_000 || c.maxCooldown > MAX_COOLDOWN
        ) revert OutOfBounds();
        uint256 rows = _rows();
        uint256 maxBacking;
        for (uint256 r; r < rows; ++r) {
            (, uint96 b) = board.rowAt(r);
            if (b > maxBacking) maxBacking = b;
        }
        if (c.reserveTarget < 2 * maxBacking) revert OutOfBounds();
        reserveTarget = c.reserveTarget;
        maintenanceInterval = c.maintenanceInterval;
        minLiveBps = c.minLiveBps;
        maxInFlight = c.maxInFlight;
        maxEdgeBps = c.maxEdgeBps;
        maxCooldown = c.maxCooldown;
        if (c.maxEdgeBps > bookingEdgeBps) bookingEdgeBps = c.maxEdgeBps;
        emit CapitalSet(c);
    }

    function _setModule(bytes32 kind, address module) internal {
        if (module.code.length == 0) revert ZeroAddress();
        if (kind == "board") board = IBoardPolicy(module);
        else if (kind == "pricing") pricing = IPricingPolicy(module);
        else if (kind == "buyer") buyer = IEngineBuyer(module);
        else revert OutOfBounds();
        emit ModuleSet(kind, module);
    }
}
