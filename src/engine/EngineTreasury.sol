// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPool, IPoolTypes} from "../interfaces/IPool.sol";
import {IFWAClone} from "../interfaces/IFWAClone.sol";
import {IForeignController} from "../interfaces/IForeignController.sol";
import {
    IArtCoinsFactoryV2,
    IArtCoinsHookV2,
    IArtCoinsLpLockerV2,
    IArtCoinsFeeEscrowV2,
    IArtCoinsTokenV2
} from "../interfaces/IArtcoins.sol";
import {FoundingRound} from "./FoundingRound.sol";
import {PrizeSponsorship} from "./PrizeSponsorship.sol";

/// @dev `redeem(uint256)` of Shapes and Draw Packs: burns the token and pays its backing to the caller.
interface IRedeemable {
    function redeem(uint256 tokenId) external;
}

/// @title EngineTreasury
/// @notice Protocol treasury of the Draw Shapes game. It is the only shareholder and the admin of
///         the `Pool`, the bounty recipient of the ENGINE coin's Artcoins v2 market, and the payer of
///         founder distributions, sponsor compensation, GRAIL boosts and coin buybacks.
/// @dev Every wei the treasury holds belongs to one bucket or is unbooked:
///      - `reserve`: liquid coverage. Refills the pool's maintenance bucket and its ordinary NAV.
///      - `prizeBudget`: trading receipts kept for the player offer. A standing collectible bid
///        holds up to its price; the rest goes to the pool's GRAIL fund through `boostGrail`.
///      - `buybackFund`: game earnings kept for coin buybacks.
///      Unbooked ETH (`address(this).balance - booked()`) is new trading receipts: Artcoins pushes
///      the bounty leg of every swap here with a 2,300 gas stipend, so `receive` stays empty and the
///      receipts are booked by the next `collectFees`. Every other inflow (escrow release, pool
///      withdrawals, redemptions, the treasury's own buyback rebate) is booked by the function that
///      caused it, inside the same call.
///
///      Founder payments and sponsor payments leave the treasury the moment they are allocated, to
///      `FoundingRound` and `PrizeSponsorship`, so nothing credited to them can be spent by the game.
///
///      Game earnings are ordinary NAV of the pool above `basis`, the principal the treasury put in.
///      The pool's books already net FWA's share, the creator's Shapes mint fees (the mint line),
///      keeper refunds (maintenance share) and GRAIL funding (feed share) out of that NAV, so
///      `nav - basis` is what the game earned for its owner. Maintenance top-ups the reserve paid
///      (`coverageOwed`) are repaid from earnings before they are distributed. Principal is never
///      distributed while the game runs: the only path that pays founders from the bankroll is the
///      wind-down.
contract EngineTreasury is ReentrancyGuard, IUnlockCallback, IForeignController {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ types

    struct Config {
        address owner;
        IPool pool;
        IPoolManager poolManager;
        address artcoinsFactory;
        address artcoinsHook;
        address artcoinsLocker;
        uint24 coinSkimBps;
        uint16 coinBountyBps;
        uint24 coinLpFeePips;
        uint16 founderTradingBps;
        uint16 founderEarningsBps;
        uint16 maxSponsorShareBps;
        uint256 poolTarget;
        uint16 poolFloorBps;
        uint256 grailSeed;
        uint256 maintenanceTarget;
        uint256 maintenanceFloor;
        uint256 reserveTarget;
        uint16 premiumFloorBps;
        uint256 maxBuybackPerCall;
        uint16 maxImpactBps;
        address prizeCollection;
        uint256 maxBidWei;
        uint256 dormancy;
    }

    struct Bid {
        uint256 tokenId;
        uint256 priceWei;
        uint256 listPriceWei;
        bool open;
    }

    /// @dev Totals for the frontend and the accounting tests. Every value is cumulative wei, except
    ///      `coinBought` and `coinBurned`, which are coin base units.
    struct Totals {
        uint256 tradingReceived;
        uint256 earningsReceived;
        uint256 coverageFromInflows;
        uint256 foundersFromTrading;
        uint256 foundersFromEarnings;
        uint256 foundersFromWindDown;
        uint256 sponsorPaid;
        uint256 grailBoosted;
        uint256 collectiblesBought;
        uint256 maintenanceFunded;
        uint256 poolRepaired;
        uint256 principalReturned;
        uint256 buybackEthSpent;
        uint256 coinBought;
        uint256 coinBurned;
    }

    // ------------------------------------------------------------------ errors and events

    error NotOwner();
    error NotPool();
    error NotPoolManager();
    error BadConfig();
    error AlreadySet();
    error NotReady(uint8 check);
    error NotActive();
    error WindingDown();
    error NotWindingDown();
    error NothingToDo();
    error SelectorDenied(bytes4 selector);
    error ArgumentDenied(bytes4 selector);
    error BuybackTooSoon();
    error SlippageExceeded(uint256 out, uint256 minOut);
    error BurnMismatch();
    error ClaimsQueued();
    error NavBelowBasis();
    error BidInvalid();
    error SponsorshipActive();

    event FoundingRoundSet(address round);
    event CoinSet(address coin, bytes32 poolId);
    event Activated(uint256 released, uint256 poolDeposit, uint256 grailSeed, uint256 maintenance, uint256 reserve);
    event TradingReceipts(uint256 amount, uint256 toReserve, uint256 toFounders, uint256 toSponsor, uint256 toPrizes);
    event Earnings(uint256 amount, uint256 toCoverage, uint256 toFounders, uint256 toBuyback);
    event PrincipalReturned(uint256 amount);
    event CoverageFunded(uint256 maintenance, uint256 poolDeposit);
    event GrailBoosted(uint256 amount);
    event Buyback(uint256 ethSpent, uint256 rebate, uint256 coinBurned);
    event FeeCoinBurned(uint256 amount);
    event BidSet(uint256 tokenId, uint256 priceWei, uint256 listPriceWei);
    event BidCancelled();
    event CollectibleBought(uint256 tokenId, address seller, uint256 priceWei);
    event CollectibleCaptured(uint256 listingId, uint256 proceeds);
    event SponsorshipSet(address sponsorship, uint16 shareBps);
    event WindDownStarted(bool dormant);
    event WindDownSettled(uint256 total, uint256 toFounders, uint256 toBuyback);
    event OwnerSet(address owner);

    // ------------------------------------------------------------------ constants and immutables

    uint256 internal constant BPS = 10_000;
    /// @dev Longest anti sniper window of the Artcoins v2 hook (`Constants.MAX_MEV_WINDOW`). No
    ///      buyback runs before the pool is this old, so a buyback never pays the elevated skim.
    uint256 internal constant SNIPER_WINDOW = 180 minutes;
    uint256 internal constant MIN_HARVEST = 0.001 ether;
    uint256 internal constant MIN_BOOST = 0.01 ether;
    uint256 internal constant MAX_EXPORT_ITEMS = 25;
    /// @dev Unrecovered maintenance subsidy is capped at this many `maintenanceTarget`s. Past it the
    ///      reserve stops paying keeper gas, so an uneconomic gas regime cannot drain the reserve and,
    ///      through the coverage-first refill, the founders' share of receipts. The owner's remedy is a
    ///      higher `maintenanceBps`.
    uint256 internal constant MAX_SUBSIDY_TARGETS = 4;

    IPool public immutable pool;
    IPoolManager public immutable poolManager;
    address public immutable artcoinsFactory;
    address public immutable artcoinsHook;
    address public immutable artcoinsLocker;
    uint24 public immutable coinSkimBps;
    uint16 public immutable coinBountyBps;
    uint24 public immutable coinLpFeePips;
    /// @notice Founders' share of net trading receipts while they are owed, in bps.
    uint16 public immutable founderTradingBps;
    /// @notice Founders' share of game earnings while they are owed, in bps.
    uint16 public immutable founderEarningsBps;
    /// @notice Ceiling on a sponsorship's share of the trading receipts left after founders.
    uint16 public immutable maxSponsorShareBps;
    /// @notice Ordinary NAV the treasury puts in the pool at activation and restores after losses.
    uint256 public immutable poolTarget;
    /// @notice Ordinary NAV below which `maintainCoverage` refills the pool, in bps of `poolTarget`.
    uint16 public immutable poolFloorBps;
    uint256 public immutable grailSeed;
    uint256 public immutable maintenanceTarget;
    uint256 public immutable maintenanceFloor;
    uint256 public immutable reserveTarget;
    /// @notice Lowest pool `premiumBps` the owner may set. Keeps game earnings from being set to zero.
    uint16 public immutable premiumFloorBps;
    uint256 public immutable maxBuybackPerCall;
    /// @notice Largest move of the pool price one buyback may cause, in bps of the price.
    uint16 public immutable maxImpactBps;
    /// @notice The only collection the treasury may buy (Wrapped Cryptopunks on mainnet).
    address public immutable prizeCollection;
    uint256 public immutable maxBidWei;
    /// @notice Seconds without a new paid draw after which anyone may start the wind-down.
    uint256 public immutable dormancy;

    // ------------------------------------------------------------------ storage

    address public owner;
    FoundingRound public round;
    IArtCoinsTokenV2 public coin;
    PoolKey internal _poolKey;
    bool public activated;
    bool public windingDown;
    bool public settled;

    uint256 public reserve;
    uint256 public prizeBudget;
    uint256 public buybackFund;
    /// @notice Ordinary pool NAV the treasury put in and has not taken back.
    uint256 public basis;
    /// @notice Maintenance top-ups paid by the reserve and not yet repaid from earnings.
    uint256 public coverageOwed;

    PrizeSponsorship public sponsorship;
    uint16 public sponsorShareBps;
    Bid public bid;

    /// @notice Post wind-down sale price of a collectible the treasury holds, zero when not offered.
    mapping(uint256 tokenId => uint256) public askOf;

    uint256 public lastBuybackBlock;
    uint64 public lastPulls;
    uint256 public lastActivityAt;

    Totals internal _totals;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier live() {
        if (!activated) revert NotActive();
        if (windingDown) revert WindingDown();
        _;
    }

    constructor(Config memory c) {
        if (
            c.owner == address(0) || address(c.pool) == address(0) || address(c.poolManager) == address(0)
                || c.artcoinsFactory == address(0) || c.artcoinsHook == address(0) || c.artcoinsLocker == address(0)
                || c.founderTradingBps > BPS || c.founderEarningsBps > BPS || c.maxSponsorShareBps > BPS
                || c.poolFloorBps > BPS || c.maintenanceFloor > c.maintenanceTarget || c.poolTarget == 0
                || c.maxImpactBps == 0 || c.maxImpactBps >= BPS || c.maxBuybackPerCall == 0 || c.dormancy < 30 days
        ) revert BadConfig();
        owner = c.owner;
        pool = c.pool;
        poolManager = c.poolManager;
        artcoinsFactory = c.artcoinsFactory;
        artcoinsHook = c.artcoinsHook;
        artcoinsLocker = c.artcoinsLocker;
        coinSkimBps = c.coinSkimBps;
        coinBountyBps = c.coinBountyBps;
        coinLpFeePips = c.coinLpFeePips;
        founderTradingBps = c.founderTradingBps;
        founderEarningsBps = c.founderEarningsBps;
        maxSponsorShareBps = c.maxSponsorShareBps;
        poolTarget = c.poolTarget;
        poolFloorBps = c.poolFloorBps;
        grailSeed = c.grailSeed;
        maintenanceTarget = c.maintenanceTarget;
        maintenanceFloor = c.maintenanceFloor;
        reserveTarget = c.reserveTarget;
        premiumFloorBps = c.premiumFloorBps;
        maxBuybackPerCall = c.maxBuybackPerCall;
        maxImpactBps = c.maxImpactBps;
        prizeCollection = c.prizeCollection;
        maxBidWei = c.maxBidWei;
        dormancy = c.dormancy;
    }

    /// @notice Accepts ETH without running code, so the Artcoins hook's 2,300 gas bounty push lands.
    receive() external payable {}

    // ------------------------------------------------------------------ setup

    function setOwner(address owner_) external onlyOwner {
        if (owner_ == address(0)) revert BadConfig();
        owner = owner_;
        emit OwnerSet(owner_);
    }

    /// @notice Names the founding round. Once, or again after the named round fell into `Refunding`,
    ///         before activation. The round must name this treasury and its target must cover the
    ///         opening deployment.
    function setFoundingRound(FoundingRound round_) external onlyOwner {
        if (activated) revert AlreadySet();
        if (address(round) != address(0) && round.state() != FoundingRound.State.Refunding) revert AlreadySet();
        if (round_.treasury() != address(this) || round_.target() < poolTarget + grailSeed + maintenanceTarget) {
            revert BadConfig();
        }
        round = round_;
        emit FoundingRoundSet(address(round_));
    }

    /// @notice Binds the ENGINE coin. Once, before activation. The coin must be an Artcoins v2 coin
    ///         on the configured hook and locker, paired with native ETH, with this treasury as its
    ///         bounty recipient, the configured fee terms, and its recipients locked so the coin admin
    ///         can no longer move the fee stream.
    function setCoin(address coin_) external onlyOwner {
        if (address(coin) != address(0) || activated) revert AlreadySet();
        if (!IArtCoinsFactoryV2(artcoinsFactory).isCoin(coin_)) revert BadConfig();
        PoolKey memory key = IArtCoinsLpLockerV2(artcoinsLocker).tokenRewards(coin_).poolKey;
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != coin_
                || address(key.hooks) != artcoinsHook
        ) revert BadConfig();
        IArtCoinsHookV2.SkimConfig memory s = IArtCoinsHookV2(artcoinsHook).skimConfig(key.toId());
        if (
            s.bountyRecipient != address(this) || s.baselineSkimBps != coinSkimBps || s.bountyBps != coinBountyBps
                || s.lpFeePips != coinLpFeePips || s.maxReferralBpsOfVolume != 0
        ) revert BadConfig();
        if (!IArtCoinsTokenV2(coin_).recipientsLocked()) revert BadConfig();
        coin = IArtCoinsTokenV2(coin_);
        _poolKey = key;
        emit CoinSet(coin_, PoolId.unwrap(key.toId()));
    }

    /// @notice Why `activate` would revert now, or 0 when it would not: 1 round not funded, 2 coin
    ///         not bound, 3 pool admin is not this treasury, 4 FWA pool missing or pool not Opening,
    ///         5 pool already has shares, 6 pool admission terms would tax or block the treasury.
    function activationCheck() public view returns (uint8) {
        if (address(round) == address(0) || round.state() != FoundingRound.State.Funded) return 1;
        if (address(coin) == address(0)) return 2;
        if (pool.admin() != address(this)) return 3;
        if (address(pool.fwaPool()) == address(0) || pool.lifecycle() != IPoolTypes.Lifecycle.Opening) return 4;
        if (pool.totalShares() != 0) return 5;
        (uint32 floorBps, uint32 capBps,) = pool.entryFee();
        if (floorBps != 0 || capBps != 0 || pool.founderWindowSeconds() != 0 || pool.navCapFloor() != 0) return 6;
        return 0;
    }

    /// @notice Takes the funded escrow and deploys it: `poolTarget` into the pool as ordinary NAV,
    ///         `grailSeed` into the GRAIL fund, `maintenanceTarget` into maintenance, up to
    ///         `reserveTarget` into the reserve and the rest into the prize budget. Owner only, once,
    ///         when `activationCheck()` is 0. Pool deposits stay paused for everyone else.
    function activate() external onlyOwner nonReentrant {
        if (activated) revert AlreadySet();
        uint8 check = activationCheck();
        if (check != 0) revert NotReady(check);
        activated = true;
        uint256 released = round.release();
        pool.setPaused(pool.pullsPaused(), true);
        pool.setBoardNavCap(poolTarget);
        _deposit(poolTarget);
        basis = poolTarget;
        pool.fundGrail{value: grailSeed}();
        pool.fundMaintenance{value: maintenanceTarget}();
        uint256 rest = released - poolTarget - grailSeed - maintenanceTarget;
        uint256 toReserve = rest < reserveTarget ? rest : reserveTarget;
        reserve = toReserve;
        prizeBudget = rest - toReserve;
        lastPulls = pool.grail().pulls;
        lastActivityAt = block.timestamp;
        emit Activated(released, poolTarget, grailSeed, maintenanceTarget, toReserve);
    }

    // ------------------------------------------------------------------ inflows

    /// @notice Books new trading receipts: claims any escrowed bounty, collects locker rewards when
    ///         the market has an LP fee (and burns the coin half of them), then allocates every unbooked
    ///         wei. After the wind-down settled, unbooked wei go founders first, then buybacks. Anyone.
    function collectFees() external nonReentrant {
        if (!activated) revert NotActive();
        _noteActivity();
        if (_collect() == 0) revert NothingToDo();
    }

    /// @notice Takes game earnings or returned principal out of the pool. Earnings are ordinary NAV
    ///         above `basis`; principal is NAV above `poolTarget` while `basis` is above it, after a
    ///         refill. Withdraws at most the pool's free cash (cash above claims and the pool's own
    ///         reserve), so no claim is ever queued and no listing is liquidated. Anyone.
    function harvest() external live nonReentrant {
        _noteActivity();
        uint256 nav = pool.nav();
        uint256 cash = pool.cash();
        uint256 locked = pool.claims() + nav * pool.reserveBps() / BPS;
        uint256 free = cash > locked ? cash - locked : 0;
        bool earnings;
        uint256 amount;
        if (nav > basis) {
            earnings = true;
            amount = nav - basis;
        } else if (basis > poolTarget && nav > poolTarget) {
            amount = nav - poolTarget;
        }
        if (amount > free) amount = free;
        if (amount < MIN_HARVEST) revert NothingToDo();
        uint256 received = _withdraw(amount * pool.totalShares() / nav);
        if (earnings) {
            if (pool.nav() < basis) revert NavBelowBasis();
            _allocateEarnings(received);
        } else {
            basis -= received < basis ? received : basis;
            reserve += received;
            _totals.principalReturned += received;
            emit PrincipalReturned(received);
        }
    }

    // ------------------------------------------------------------------ coverage and prizes

    /// @notice Refills the pool from the reserve: maintenance up to `maintenanceTarget` once it is
    ///         below `maintenanceFloor`, while the unrecovered subsidy stays within
    ///         `MAX_SUBSIDY_TARGETS * maintenanceTarget`, and ordinary NAV up to `poolTarget` once it
    ///         is below `poolFloorBps` of it. Anyone. Reverts `NothingToDo` when neither is due or the
    ///         reserve is empty.
    function maintainCoverage() external live nonReentrant {
        uint256 m = pool.maintenance();
        uint256 toMaintenance;
        uint256 room = MAX_SUBSIDY_TARGETS * maintenanceTarget;
        room = room > coverageOwed ? room - coverageOwed : 0;
        if (m < maintenanceFloor) {
            uint256 want = maintenanceTarget - m;
            toMaintenance = _fromReserve(want < room ? want : room);
            if (toMaintenance != 0) {
                coverageOwed += toMaintenance;
                _totals.maintenanceFunded += toMaintenance;
                pool.fundMaintenance{value: toMaintenance}();
            }
        }
        uint256 toPool;
        uint256 nav = pool.nav();
        if (nav < poolTarget * poolFloorBps / BPS && pool.lifecycle() == IPoolTypes.Lifecycle.Live) {
            toPool = _fromReserve(poolTarget - nav);
            if (toPool != 0) {
                _deposit(toPool);
                basis += toPool;
                _totals.poolRepaired += toPool;
            }
        }
        if (toMaintenance == 0 && toPool == 0) revert NothingToDo();
        emit CoverageFunded(toMaintenance, toPool);
    }

    /// @notice Sends the prize budget above the open bid's price to the pool's GRAIL fund. Anyone.
    function boostGrail() external live nonReentrant {
        uint256 held = bid.open ? bid.priceWei : 0;
        uint256 amount = prizeBudget > held ? prizeBudget - held : 0;
        if (amount < MIN_BOOST) revert NothingToDo();
        prizeBudget -= amount;
        _totals.grailBoosted += amount;
        emit GrailBoosted(amount);
        pool.fundGrail{value: amount}();
    }

    // ------------------------------------------------------------------ buyback and burn

    /// @notice Buys the coin with up to `maxEthIn` of the buyback fund (at most `maxBuybackPerCall`)
    ///         on its Artcoins v4 pool and burns every coin bought. Anyone, once per block, from three
    ///         hours after the market opened. The swap stops at `maxImpactBps` of price movement and
    ///         reverts below `minCoinOut`. The bounty leg of the treasury's own swap comes back to the
    ///         treasury and is returned to the buyback fund, not booked as trading receipts.
    function buyback(uint256 maxEthIn, uint256 minCoinOut) external nonReentrant returns (uint256 burned) {
        if (!activated) revert NotActive();
        if (block.number <= lastBuybackBlock) revert BuybackTooSoon();
        PoolKey memory key = _poolKey;
        PoolId id = key.toId();
        if (block.timestamp < IArtCoinsHookV2(artcoinsHook).poolInfo(id).createdAt + SNIPER_WINDOW) {
            revert BuybackTooSoon();
        }
        lastBuybackBlock = block.number;
        _collect();
        uint256 ethIn = buybackFund < maxBuybackPerCall ? buybackFund : maxBuybackPerCall;
        if (maxEthIn < ethIn) ethIn = maxEthIn;
        if (ethIn == 0) revert NothingToDo();

        (uint160 sqrtPrice,,,) = poolManager.getSlot0(id);
        uint160 limit = uint160(FixedPointMathLib.mulDiv(sqrtPrice, FixedPointMathLib.sqrt((BPS - maxImpactBps) * 1e18), 1e11));
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;

        uint256 before = address(this).balance;
        (uint256 spent, uint256 out) = abi.decode(poolManager.unlock(abi.encode(ethIn, limit)), (uint256, uint256));
        _claimEscrow();
        uint256 rebate = address(this).balance + spent - before;
        if (out < minCoinOut) revert SlippageExceeded(out, minCoinOut);

        buybackFund = buybackFund + rebate - spent;
        uint256 supply = coin.totalSupply();
        coin.burn(out);
        if (coin.totalSupply() != supply - out) revert BurnMismatch();
        _totals.buybackEthSpent += spent - rebate;
        _totals.coinBought += out;
        _totals.coinBurned += out;
        emit Buyback(spent - rebate, rebate, out);
        return out;
    }

    /// @notice PoolManager callback of `buyback`: swaps exact ETH in for the coin down to `limit`,
    ///         pays the ETH actually taken and takes the coin.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 ethIn, uint160 limit) = abi.decode(data, (uint256, uint160));
        PoolKey memory key = _poolKey;
        BalanceDelta delta = poolManager.swap(
            key, IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: limit}), ""
        );
        uint256 spent = uint256(uint128(-delta.amount0()));
        uint256 out = uint256(uint128(delta.amount1()));
        poolManager.settle{value: spent}();
        poolManager.take(key.currency1, address(this), out);
        return abi.encode(spent, out);
    }

    // ------------------------------------------------------------------ collectibles

    /// @notice Offers `priceWei` from the prize budget for token `tokenId` of `prizeCollection`, to be
    ///         listed on the board at `listPriceWei` once bought. Owner only, while live. Replaces
    ///         any open bid. While open, the bid holds up to its price in the prize budget.
    function setBid(uint256 tokenId, uint256 priceWei, uint256 listPriceWei) external onlyOwner live {
        if (prizeCollection == address(0) || priceWei == 0 || priceWei > maxBidWei || listPriceWei == 0) {
            revert BidInvalid();
        }
        bid = Bid(tokenId, priceWei, listPriceWei, true);
        emit BidSet(tokenId, priceWei, listPriceWei);
    }

    function cancelBid() external onlyOwner {
        delete bid;
        emit BidCancelled();
    }

    /// @notice Sells the bid's token to the treasury at the bid price and lists it on the board as a
    ///         treasury-owned foreign listing. The caller holds the token and has approved this
    ///         contract. Reverts while the prize budget is below the price.
    function fillBid(uint256 tokenId) external live nonReentrant {
        Bid memory b = bid;
        if (!b.open || b.tokenId != tokenId || prizeBudget < b.priceWei) revert BidInvalid();
        delete bid;
        prizeBudget -= b.priceWei;
        _totals.collectiblesBought += b.priceWei;
        IERC721(prizeCollection).transferFrom(msg.sender, address(this), tokenId);
        IERC721(prizeCollection).approve(address(pool), tokenId);
        pool.registerForeign(prizeCollection, tokenId, address(this), b.listPriceWei);
        emit CollectibleBought(tokenId, msg.sender, b.priceWei);
        SafeTransferLib.safeTransferETH(msg.sender, b.priceWei);
    }

    /// @notice Reprices a treasury-owned foreign listing. Owner only. The pool enforces its step,
    ///         spacing and probability cap rules.
    function repriceCollectible(uint256 listingId, uint256 priceWei) external onlyOwner {
        pool.repriceForeign(listingId, priceWei);
    }

    /// @notice Pool callback when a treasury-owned collectible is won. The ticket proceeds join the
    ///         prize budget. The pool forwards at most 200,000 gas.
    function onForeignCapture(uint256 listingId, uint256, uint256) external payable {
        if (msg.sender != address(pool)) revert NotPool();
        prizeBudget += msg.value;
        emit CollectibleCaptured(listingId, msg.value);
    }

    // ------------------------------------------------------------------ sponsorship

    /// @notice Attaches `s` as the sponsorship paid `shareBps` of the trading receipts left after
    ///         founders, and makes it the pool's registrar so its sponsor can stake. Owner only, at
    ///         most `maxSponsorShareBps`. Replacing or clearing (`s` zero) needs the current one to be
    ///         inactive, so a sponsor's live terms cannot be cut.
    function setSponsorship(PrizeSponsorship s, uint16 shareBps) external onlyOwner live {
        if (address(sponsorship) != address(0) && sponsorship.active()) revert SponsorshipActive();
        if (shareBps > maxSponsorShareBps) revert BadConfig();
        if (address(s) != address(0) && (address(s.pool()) != address(pool) || s.treasury() != address(this))) {
            revert BadConfig();
        }
        sponsorship = s;
        sponsorShareBps = address(s) == address(0) ? 0 : shareBps;
        pool.setRegistrar(address(s));
        emit SponsorshipSet(address(s), sponsorShareBps);
    }

    // ------------------------------------------------------------------ pool administration

    /// @notice Forwards an admin call to the pool. Owner only. Tuning setters pass. `setFeeSplit`
    ///         keeps `premiumBps` at or above `premiumFloorBps`; `setPaused` keeps deposits paused;
    ///         `adminCall` reaches only FWA `recoverRefundedNFT`; `sweep` sends only to this treasury.
    ///         Every other selector, including `setAdmin`, `startExit`, `transferGrailEstate`,
    ///         `setRegistrar`, `registerForeign`, the admission setters, `deposit` and `withdraw`, is
    ///         refused, so the owner cannot move principal, change who holds the pool or redirect a
    ///         prize.
    function poolCall(bytes calldata data) external onlyOwner returns (bytes memory ret) {
        bytes4 sel = bytes4(data[:4]);
        if (sel == IPool.setFeeSplit.selector) {
            (uint16 premiumBps,,) = abi.decode(data[4:], (uint16, uint16, uint16));
            if (premiumBps < premiumFloorBps) revert ArgumentDenied(sel);
        } else if (sel == IPool.setPaused.selector) {
            (, bool deposits) = abi.decode(data[4:], (bool, bool));
            if (!deposits) revert ArgumentDenied(sel);
        } else if (sel == IPool.adminCall.selector) {
            (address target, bytes memory inner, uint256 value) = abi.decode(data[4:], (address, bytes, uint256));
            if (target != address(pool.fwaPool()) || value != 0 || bytes4(inner) != IFWAClone.recoverRefundedNFT.selector)
            {
                revert ArgumentDenied(sel);
            }
        } else if (sel == IPool.sweep.selector) {
            (,, address to) = abi.decode(data[4:], (address, uint256, address));
            if (to != address(this)) revert ArgumentDenied(sel);
        } else if (
            sel != IPool.createFwaPool.selector && sel != IPool.setMix.selector && sel != IPool.setGrail.selector
                && sel != IPool.setGrailStep.selector && sel != IPool.setGrailTarget.selector
                && sel != IPool.setMaxBatch.selector && sel != IPool.setConcurrency.selector
                && sel != IPool.setRotateInterval.selector && sel != IPool.setMinItems.selector
                && sel != IPool.setGrailProbCap.selector && sel != IPool.setBatch.selector
                && sel != IPool.setReplacement.selector && sel != IPool.setReserve.selector
                && sel != IPool.setTip.selector && sel != IPool.setListWhilePaused.selector
                && sel != IPool.setTurnover.selector
        ) {
            revert SelectorDenied(sel);
        }
        bool ok;
        (ok, ret) = address(pool).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice Redeems a Shape or Draw Pack the treasury holds (a swept token) into the reserve.
    ///         Owner only, while live. Wind-down redeems the GRAIL estate itself.
    function redeemHeld(address collection, uint256 tokenId) external onlyOwner live nonReentrant {
        if (collection != pool.shapes() && collection != pool.drawPacks()) revert BadConfig();
        reserve += _redeem(collection, tokenId);
    }

    // ------------------------------------------------------------------ wind-down

    /// @notice True when no paid draw has been booked for `dormancy` seconds.
    function dormant() public view returns (bool) {
        return activated && pool.grail().pulls == lastPulls && block.timestamp > lastActivityAt + dormancy;
    }

    /// @notice Starts retiring the game: the pool stops taking draws and exports itself. Owner, or
    ///         anyone once the game is `dormant()`. Pending draws settle at FWA before the export can
    ///         complete.
    function windDown() external nonReentrant {
        if (!activated) revert NotActive();
        if (windingDown) revert WindingDown();
        bool isDormant = dormant();
        if (msg.sender != owner && !isDormant) revert NotOwner();
        windingDown = true;
        delete bid;
        emit WindDownStarted(isDormant);
        pool.startExit(address(pool));
    }

    /// @notice Advances the wind-down. While the pool is Exiting it runs `exportStep`. Once Exported it
    ///         takes the GRAIL estate and redeems it, withdraws every share, and pays every wei the
    ///         treasury holds to the founders up to their remaining entitlement, the rest to the
    ///         buyback fund. Anyone. Returns true when settled.
    function windDownStep() external nonReentrant returns (bool) {
        if (!windingDown) revert NotWindingDown();
        if (settled) return true;
        if (pool.lifecycle() == IPoolTypes.Lifecycle.Exiting) {
            pool.exportStep(MAX_EXPORT_ITEMS);
            if (pool.lifecycle() == IPoolTypes.Lifecycle.Exiting) return false;
        }
        IPoolTypes.GrailItem[] memory items = pool.grailItems();
        if (items.length != 0 || pool.grail().fund != 0) {
            pool.transferGrailEstate(address(this));
            for (uint256 i; i < items.length; ++i) {
                _redeem(items[i].collection, items[i].tokenId);
            }
        }
        uint256 shares = pool.totalShares();
        if (shares != 0) {
            uint256 nav = pool.nav();
            uint256 cash = pool.cash();
            uint256 take = nav <= cash ? shares : shares * cash / nav;
            if (take != 0) _withdraw(take);
            if (pool.totalShares() != 0) return false;
        }
        _claimEscrow();
        settled = true;
        uint256 total = address(this).balance;
        reserve = 0;
        prizeBudget = 0;
        buybackFund = 0;
        basis = 0;
        coverageOwed = 0;
        (uint256 founders, uint256 toBuyback) = _allocateWindDown(total);
        emit WindDownSettled(total, founders, toBuyback);
        return true;
    }

    /// @notice Offers the collectible `tokenId` the treasury got back from the pool at `priceWei`
    ///         after settlement. Owner only. The price is the owner's; the contract cannot verify a
    ///         market price. Zero withdraws the offer.
    function setAsk(uint256 tokenId, uint256 priceWei) external onlyOwner {
        if (!settled) revert NotWindingDown();
        askOf[tokenId] = priceWei;
    }

    /// @notice Buys an offered collectible at its ask. The ETH is allocated like the rest of the
    ///         wind-down: founders first, then the buyback fund.
    function buyCollectible(uint256 tokenId) external payable nonReentrant {
        uint256 price = askOf[tokenId];
        if (!settled || price == 0 || msg.value != price) revert BidInvalid();
        delete askOf[tokenId];
        IERC721(prizeCollection).transferFrom(address(this), msg.sender, tokenId);
        _allocateWindDown(price);
    }

    // ------------------------------------------------------------------ views

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function totals() external view returns (Totals memory) {
        return _totals;
    }

    /// @notice Sum of the three buckets. `address(this).balance - booked()` is unbooked receipts.
    function booked() public view returns (uint256) {
        return reserve + prizeBudget + buybackFund;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ internal

    /// @dev Claims escrowed ETH, collects locker rewards when the market has an LP fee and burns the
    ///      coin it receives, then allocates the unbooked balance as trading receipts (or to the
    ///      wind-down after settlement). Returns the amount allocated.
    function _collect() internal returns (uint256 amount) {
        if (address(coin) == address(0)) return 0;
        _claimEscrow();
        if (coinLpFeePips != 0) {
            IArtCoinsLpLockerV2(artcoinsLocker).collectRewards(address(coin));
            uint256 held = coin.balanceOf(address(this));
            if (held != 0) {
                coin.burn(held);
                _totals.coinBurned += held;
                emit FeeCoinBurned(held);
            }
        }
        uint256 bal = address(this).balance;
        uint256 b = booked();
        if (bal <= b) return 0;
        amount = bal - b;
        if (settled) _allocateWindDown(amount);
        else _allocateTrading(amount);
    }

    function _claimEscrow() internal {
        if (address(coin) == address(0)) return;
        IArtCoinsFeeEscrowV2 escrow = IArtCoinsFeeEscrowV2(IArtCoinsHookV2(artcoinsHook).globals().feeEscrow);
        if (escrow.balances(address(this), address(0)) != 0) escrow.claim(address(this), address(0));
    }

    /// @dev Trading receipts: the reserve is refilled to `reserveTarget` first, founders take
    ///      `founderTradingBps` of the rest up to their remaining entitlement, the active sponsorship
    ///      takes `sponsorShareBps` of what is left up to what it is owed, and the remainder joins
    ///      the prize budget. During the wind-down (before settlement) receipts join the reserve,
    ///      which the settlement distributes.
    function _allocateTrading(uint256 amount) internal {
        _totals.tradingReceived += amount;
        if (windingDown) {
            reserve += amount;
            emit TradingReceipts(amount, amount, 0, 0, 0);
            return;
        }
        uint256 toReserve = _toCoverage(amount);
        uint256 rest = amount - toReserve;
        uint256 toFounders = _payFounders(rest * founderTradingBps / BPS);
        _totals.foundersFromTrading += toFounders;
        rest -= toFounders;
        uint256 toSponsor;
        PrizeSponsorship s = sponsorship;
        if (address(s) != address(0) && rest != 0) {
            toSponsor = rest * sponsorShareBps / BPS;
            uint256 owed = s.owed();
            if (toSponsor > owed) toSponsor = owed;
            if (toSponsor != 0) {
                _totals.sponsorPaid += toSponsor;
                s.pay{value: toSponsor}();
            }
        }
        prizeBudget += rest - toSponsor;
        emit TradingReceipts(amount, toReserve, toFounders, toSponsor, rest - toSponsor);
    }

    /// @dev Game earnings: maintenance top-ups the reserve paid are repaid first, then the reserve is
    ///      refilled to `reserveTarget`, founders take `founderEarningsBps` of the rest up to their
    ///      remaining entitlement, and the remainder joins the buyback fund.
    function _allocateEarnings(uint256 amount) internal {
        _totals.earningsReceived += amount;
        uint256 repay = amount < coverageOwed ? amount : coverageOwed;
        coverageOwed -= repay;
        reserve += repay;
        uint256 toCoverage = repay + _toCoverage(amount - repay);
        uint256 rest = amount - toCoverage;
        uint256 toFounders = _payFounders(rest * founderEarningsBps / BPS);
        _totals.foundersFromEarnings += toFounders;
        buybackFund += rest - toFounders;
        emit Earnings(amount, toCoverage, toFounders, rest - toFounders);
    }

    /// @dev Wind-down: founders up to their remaining entitlement, then the buyback fund.
    function _allocateWindDown(uint256 amount) internal returns (uint256 toFounders, uint256 toBuyback) {
        toFounders = _payFounders(amount);
        _totals.foundersFromWindDown += toFounders;
        toBuyback = amount - toFounders;
        buybackFund += toBuyback;
    }

    /// @dev Adds up to `amount` to the reserve, stopping at `reserveTarget`. Returns what it added.
    function _toCoverage(uint256 amount) internal returns (uint256 added) {
        if (reserve < reserveTarget) {
            added = reserveTarget - reserve;
            if (added > amount) added = amount;
            reserve += added;
            _totals.coverageFromInflows += added;
        }
    }

    /// @dev Pays `amount`, capped at the round's remaining entitlement, to the founding round.
    function _payFounders(uint256 amount) internal returns (uint256 paid) {
        uint256 room = round.remaining();
        paid = amount < room ? amount : room;
        if (paid != 0) round.distribute{value: paid}();
    }

    function _fromReserve(uint256 want) internal returns (uint256 taken) {
        taken = want < reserve ? want : reserve;
        reserve -= taken;
    }

    /// @dev Deposits `amount` into the pool. Deposits are paused and the admission floor is zero for
    ///      everyone, so the treasury lifts both for its own deposit and restores them in the same call.
    function _deposit(uint256 amount) internal {
        bool pulls = pool.pullsPaused();
        pool.setPaused(pulls, false);
        pool.setNavCapFloor(type(uint256).max);
        pool.deposit{value: amount}();
        pool.setNavCapFloor(0);
        pool.setPaused(pulls, true);
    }

    /// @dev Burns `shares` of the pool and returns the ETH received. Reverts when part of the claim
    ///      was queued, which would liquidate listings.
    function _withdraw(uint256 shares) internal returns (uint256 received) {
        uint256 before = address(this).balance;
        pool.withdraw(shares);
        if (pool.claims() != 0) revert ClaimsQueued();
        received = address(this).balance - before;
    }

    /// @dev Redeems a Shape or Draw Pack and returns the ETH received.
    function _redeem(address collection, uint256 tokenId) internal returns (uint256 received) {
        uint256 before = address(this).balance;
        IRedeemable(collection).redeem(tokenId);
        received = address(this).balance - before;
    }

    /// @dev Moves `lastActivityAt` when the pool booked a draw since the last look.
    function _noteActivity() internal {
        uint64 pulls = pool.grail().pulls;
        if (pulls != lastPulls) {
            lastPulls = pulls;
            lastActivityAt = block.timestamp;
        }
    }
}
