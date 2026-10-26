// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {Governed} from "../Governed.sol";
import {ILedger, IEmissionSchedule, IKeeperFund, IBurnable} from "../interfaces/IDrawShapes.sol";

/// @title GenesisFarm
/// @notice Holds the farm's ENGINE: the genesis allocation, the prize-conversion bonus pool and the seasons
///         reserve. Pays each epoch's pot to that epoch's delivered pulls, pro rata by units (one per pull),
///         once the epoch is final. Owns the epoch clock: epochs of `EPOCH_BLOCKS` blocks from `openBlock`.
/// @dev Pot of epoch `e` = genesis allocation (`e < genesisEpochs`, from the EmissionSchedule module) +
///      season allocation + buyback deposits + amounts rolled in from empty epochs. The pot is snapshotted at
///      the epoch's first claim. Units come from up to `MAX_LEDGERS` registered games, summed; an epoch is
///      final when its last block has passed and every ledger reports it final. Claims never expire.
///      ENGINE leaves only by claims, conversion bonuses (to a ledger's caller), and burns.
contract GenesisFarm is ReentrancyGuard, Governed {
    uint256 public constant EPOCH_BLOCKS = 7_200;
    uint256 public constant MAX_GENESIS_EPOCHS = 21;
    uint256 public constant MIN_GENESIS_EPOCHS = 7;
    uint256 public constant NOTICE_EPOCHS = 2;
    uint256 public constant MAX_LEDGERS = 4;
    uint256 public constant MAX_SEASONS = 8;
    uint256 public constant MAX_SEASON_EPOCHS = 365;

    address public immutable engine;
    uint256 public immutable genesisBudget;

    IEmissionSchedule public schedule;
    IKeeperFund public keeperFund;
    uint256 public genesisEpochs = MAX_GENESIS_EPOCHS;
    uint256 public openBlock;
    uint256 public bonusPool;
    uint256 public reserve;

    address[] internal _ledgers;
    mapping(address => bool) public isLedger;
    mapping(address => bool) public isDepositor;

    struct Season {
        uint64 startEpoch;
        uint64 epochs;
        uint128 perEpoch;
    }

    Season[] internal _seasons;

    mapping(uint256 epoch => uint256) public deposits;
    mapping(uint256 epoch => uint256) public rolledIn;
    mapping(uint256 epoch => bool) public rolledOut;
    mapping(uint256 epoch => uint256) internal _potSnapshot; // pot + 1 once snapshotted
    mapping(uint256 epoch => mapping(address => bool)) public claimed;

    /// @notice Genesis allocation committed so far: snapshotted pots' genesis parts plus genesis burns.
    uint256 public genesisCommitted;
    uint256 public totalClaimed;
    uint256 public totalDeposited;
    uint256 public totalBonusPaid;
    uint256 public totalBurned;
    bool public unearnedRetired;

    event Started(uint256 openBlock);
    event Claimed(address indexed purchaser, uint256 indexed epoch, uint256 amount);
    event Deposited(address indexed depositor, uint256 indexed epoch, uint256 amount);
    event RolledOver(uint256 indexed fromEpoch, uint256 indexed toEpoch, uint256 amount);
    event BonusPaid(address indexed to, uint256 amount);
    event Shortened(uint256 genesisEpochs, uint256 burned);
    event SeasonScheduled(uint256 startEpoch, uint256 epochs, uint256 perEpoch);
    event ReserveBurned(uint256 amount);
    event UnearnedRetired(uint256 amount, uint256 emptyEpochs, uint256 bonusBurned);
    event LedgerAdded(address ledger);
    event DepositorSet(address indexed depositor, bool allowed);
    event ScheduleSet(address schedule);
    event KeeperFundSet(address keeperFund);

    error NotLedger();
    error NotDepositor();
    error AlreadyStarted();
    error NotStarted();
    error NotFinal(uint256 epoch);
    error AlreadyClaimed(uint256 epoch);
    error NoUnits(uint256 epoch);
    error NothingToClaim();
    error CannotRollover(uint256 epoch);
    error GenesisNotOver();
    error AlreadyRetired();
    error InvalidShorten();
    error InvalidSeason();
    error ExceedsReserve();
    error Underfunded();

    constructor(
        address governance_,
        address engine_,
        uint256 genesisBudget_,
        uint256 bonusPool_,
        uint256 reserve_,
        address schedule_
    ) Governed(governance_, true) {
        if (engine_ == address(0) || schedule_ == address(0)) revert ZeroAddress();
        engine = engine_;
        genesisBudget = genesisBudget_;
        bonusPool = bonusPool_;
        reserve = reserve_;
        schedule = IEmissionSchedule(schedule_);
    }

    /// @notice One-shot wiring by the deployer: the first game, the buyback depositor, the keeper fund.
    ///         Requires the farm to hold its three allocations.
    function wire(address ledger, address depositor, address keeperFund_) external onlyWiring {
        if (SafeTransferLib.balanceOf(engine, address(this)) < genesisBudget + bonusPool + reserve) revert Underfunded();
        _addLedger(ledger);
        _setDepositor(depositor, true);
        _setKeeperFund(keeperFund_);
    }

    // ------------------------------------------------------------------ clock

    /// @notice Starts the clock. Called once by a registered game when it opens.
    function start() external {
        if (!isLedger[msg.sender]) revert NotLedger();
        if (openBlock != 0) revert AlreadyStarted();
        openBlock = block.number;
        emit Started(block.number);
    }

    /// @notice Epoch of the current block (0 before the clock starts).
    function currentEpoch() public view returns (uint256) {
        return openBlock == 0 ? 0 : (block.number - openBlock) / EPOCH_BLOCKS;
    }

    /// @notice First block after genesis (max uint before the clock starts).
    function genesisEndBlock() public view returns (uint256) {
        return openBlock == 0 ? type(uint256).max : openBlock + genesisEpochs * EPOCH_BLOCKS;
    }

    function ledgers() external view returns (address[] memory) {
        return _ledgers;
    }

    function seasonCount() external view returns (uint256) {
        return _seasons.length;
    }

    function seasonAt(uint256 i) external view returns (uint256 startEpoch, uint256 epochs, uint256 perEpoch) {
        Season memory s = _seasons[i];
        return (s.startEpoch, s.epochs, s.perEpoch);
    }

    // ------------------------------------------------------------------ ledger reads

    function epochUnits(uint256 epoch) public view returns (uint256 units) {
        uint256 n = _ledgers.length;
        for (uint256 i; i < n; ++i) {
            units += ILedger(_ledgers[i]).epochUnits(epoch);
        }
    }

    function userUnits(uint256 epoch, address purchaser) public view returns (uint256 units) {
        uint256 n = _ledgers.length;
        for (uint256 i; i < n; ++i) {
            units += ILedger(_ledgers[i]).userUnits(epoch, purchaser);
        }
    }

    /// @notice True once `epoch` has ended and every pull accepted in it is terminal and booked.
    function isFinal(uint256 epoch) public view returns (bool) {
        if (openBlock == 0 || block.number < openBlock + (epoch + 1) * EPOCH_BLOCKS) return false;
        uint256 n = _ledgers.length;
        for (uint256 i; i < n; ++i) {
            if (!ILedger(_ledgers[i]).isEpochFinal(epoch)) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------ pots

    /// @notice Genesis allocation of `epoch` (zero once the epoch is past genesis).
    function genesisAllocationOf(uint256 epoch) public view returns (uint256) {
        if (epoch >= genesisEpochs) return 0;
        return schedule.allocationOf(epoch, genesisBudget);
    }

    function seasonAllocationOf(uint256 epoch) public view returns (uint256 amount) {
        uint256 n = _seasons.length;
        for (uint256 i; i < n; ++i) {
            Season memory s = _seasons[i];
            if (epoch >= s.startEpoch && epoch < uint256(s.startEpoch) + s.epochs) amount += s.perEpoch;
        }
    }

    /// @notice Pot of `epoch`: the snapshot if taken, else what it would be now.
    function potOf(uint256 epoch) public view returns (uint256) {
        uint256 snap = _potSnapshot[epoch];
        if (snap != 0) return snap - 1;
        if (rolledOut[epoch]) return 0;
        return _genesisPart(epoch) + seasonAllocationOf(epoch) + deposits[epoch] + rolledIn[epoch];
    }

    /// @dev Genesis allocation of `epoch`, limited by what is left of the genesis budget.
    function _genesisPart(uint256 epoch) internal view returns (uint256 g) {
        g = genesisAllocationOf(epoch);
        uint256 headroom = genesisBudget - genesisCommitted;
        if (g > headroom) g = headroom;
    }

    /// @notice Reward of `purchaser` in `epoch` as the ledgers stand (final once `isFinal`).
    function rewardOf(uint256 epoch, address purchaser) public view returns (uint256) {
        uint256 units = epochUnits(epoch);
        if (units == 0) return 0;
        return FPM.fullMulDiv(potOf(epoch), userUnits(epoch, purchaser), units);
    }

    /// @notice Unclaimed rewards of `purchaser` across final epochs `[from, to)`.
    function claimable(address purchaser, uint256 from, uint256 to) external view returns (uint256 total) {
        for (uint256 e = from; e < to; ++e) {
            if (!claimed[e][purchaser] && isFinal(e)) total += rewardOf(e, purchaser);
        }
    }

    // ------------------------------------------------------------------ claims

    /// @notice Claims the caller's rewards for `epochs`, each final and unclaimed.
    function claim(uint256[] calldata epochs) external nonReentrant returns (uint256 total) {
        for (uint256 i; i < epochs.length; ++i) {
            uint256 e = epochs[i];
            if (!isFinal(e)) revert NotFinal(e);
            if (claimed[e][msg.sender]) revert AlreadyClaimed(e);
            uint256 units = epochUnits(e);
            if (units == 0) revert NoUnits(e);
            claimed[e][msg.sender] = true;
            uint256 pot = _snapshot(e);
            uint256 amount = FPM.fullMulDiv(pot, userUnits(e, msg.sender), units);
            total += amount;
            emit Claimed(msg.sender, e, amount);
        }
        if (total == 0) revert NothingToClaim();
        totalClaimed += total;
        SafeTransferLib.safeTransfer(engine, msg.sender, total);
    }

    function _snapshot(uint256 e) internal returns (uint256 pot) {
        uint256 snap = _potSnapshot[e];
        if (snap != 0) return snap - 1;
        uint256 g = _genesisPart(e);
        genesisCommitted += g;
        pot = g + seasonAllocationOf(e) + deposits[e] + rolledIn[e];
        _potSnapshot[e] = pot + 1;
    }

    /// @notice Moves the non-genesis part of a final epoch with no units (deposits, season allocation,
    ///         amounts rolled into it) to the current epoch. Anyone may call it.
    function rollover(uint256 epoch) external nonReentrant returns (uint256 amount) {
        uint256 cur = currentEpoch();
        if (epoch >= cur || !isFinal(epoch) || epochUnits(epoch) != 0 || rolledOut[epoch]) {
            revert CannotRollover(epoch);
        }
        rolledOut[epoch] = true;
        amount = seasonAllocationOf(epoch) + deposits[epoch] + rolledIn[epoch];
        rolledIn[cur] += amount;
        emit RolledOver(epoch, cur, amount);
    }

    // ------------------------------------------------------------------ inflows and bonus

    /// @notice A registered depositor (the BuybackReward sink) adds ENGINE to the current epoch's pot.
    function deposit(uint256 amount) external nonReentrant {
        if (!isDepositor[msg.sender]) revert NotDepositor();
        SafeTransferLib.safeTransferFrom(engine, msg.sender, address(this), amount);
        uint256 e = currentEpoch();
        deposits[e] += amount;
        totalDeposited += amount;
        emit Deposited(msg.sender, e, amount);
    }

    /// @notice Pays a prize-conversion bonus from the bonus pool. Registered games only. Pays what the pool
    ///         holds, up to `amount`; nothing once the unused pool has been burned.
    function payBonus(address to, uint256 amount) external nonReentrant returns (uint256 paid) {
        if (!isLedger[msg.sender]) revert NotLedger();
        paid = amount < bonusPool ? amount : bonusPool;
        if (paid == 0) return 0;
        bonusPool -= paid;
        totalBonusPaid += paid;
        SafeTransferLib.safeTransfer(engine, to, paid);
        emit BonusPaid(to, paid);
    }

    // ------------------------------------------------------------------ genesis end

    /// @notice Burns the genesis allocation of every genesis epoch with no units and the unused bonus pool,
    ///         once genesis has ended and every genesis epoch is final. Anyone may call; tipped.
    function retireUnearned() external nonReentrant returns (uint256 amount) {
        uint256 gasStart = gasleft();
        if (unearnedRetired) revert AlreadyRetired();
        if (openBlock == 0 || block.number < genesisEndBlock()) revert GenesisNotOver();
        uint256 n = genesisEpochs;
        uint256 empty;
        for (uint256 e; e < n; ++e) {
            if (!isFinal(e)) revert GenesisNotOver();
            if (epochUnits(e) == 0 && _potSnapshot[e] == 0) {
                uint256 g = _genesisPart(e);
                genesisCommitted += g;
                amount += g;
                ++empty;
            }
        }
        unearnedRetired = true;
        uint256 bonus = bonusPool;
        bonusPool = 0;
        _burn(amount + bonus);
        emit UnearnedRetired(amount, empty, bonus);
        if (address(keeperFund) != address(0)) {
            keeperFund.tip(msg.sender, gasStart - gasleft(), block.timestamp - _genesisEndTime());
        }
    }

    /// @dev Approximate time genesis ended, for the keeper bounty (12 s blocks).
    function _genesisEndTime() internal view returns (uint256) {
        uint256 blocksAgo = block.number - genesisEndBlock();
        uint256 secs = blocksAgo * 12;
        return secs > block.timestamp ? 0 : block.timestamp - secs;
    }

    function _burn(uint256 amount) internal {
        if (amount == 0) return;
        totalBurned += amount;
        IBurnable(engine).burn(amount);
    }

    // ------------------------------------------------------------------ governance

    /// @notice Shortens genesis to `newEpochs` (one way, at least `MIN_GENESIS_EPOCHS`, with at least
    ///         `NOTICE_EPOCHS` full epochs after the current one). Cut epochs' allocations are burned.
    function shorten(uint256 newEpochs) external onlyGovernance {
        uint256 old = genesisEpochs;
        if (newEpochs >= old || newEpochs < MIN_GENESIS_EPOCHS) revert InvalidShorten();
        if (openBlock != 0 && newEpochs < currentEpoch() + 1 + NOTICE_EPOCHS) revert InvalidShorten();
        uint256 cut;
        for (uint256 e = newEpochs; e < old; ++e) {
            uint256 g = _genesisPart(e);
            genesisCommitted += g;
            cut += g;
        }
        genesisEpochs = newEpochs;
        _burn(cut);
        emit Shortened(newEpochs, cut);
    }

    /// @notice Schedules a farming season from the reserve: `amount` spread over `epochs` epochs from
    ///         `startEpoch` (after genesis, at least `NOTICE_EPOCHS` epochs out). Rounding stays in the reserve.
    function scheduleSeason(uint256 startEpoch, uint256 epochs, uint256 amount) external onlyGovernance {
        if (
            epochs == 0 || epochs > MAX_SEASON_EPOCHS || startEpoch < genesisEpochs
                || startEpoch < currentEpoch() + NOTICE_EPOCHS || _seasons.length >= MAX_SEASONS
                || startEpoch > type(uint64).max
        ) revert InvalidSeason();
        if (amount > reserve) revert ExceedsReserve();
        uint256 perEpoch = amount / epochs;
        if (perEpoch == 0) revert InvalidSeason();
        reserve -= perEpoch * epochs;
        _seasons.push(Season(uint64(startEpoch), uint64(epochs), uint128(perEpoch)));
        emit SeasonScheduled(startEpoch, epochs, perEpoch);
    }

    /// @notice Burns `amount` of the seasons reserve. The reserve has no other outflow.
    function burnReserve(uint256 amount) external onlyGovernance {
        if (amount > reserve) revert ExceedsReserve();
        reserve -= amount;
        _burn(amount);
        emit ReserveBurned(amount);
    }

    function addLedger(address ledger) external onlyGovernance {
        _addLedger(ledger);
    }

    function setDepositor(address depositor, bool allowed) external onlyGovernance {
        _setDepositor(depositor, allowed);
    }

    function setSchedule(address schedule_) external onlyGovernance {
        if (schedule_ == address(0)) revert ZeroAddress();
        schedule = IEmissionSchedule(schedule_);
        emit ScheduleSet(schedule_);
    }

    function setKeeperFund(address keeperFund_) external onlyGovernance {
        _setKeeperFund(keeperFund_);
    }

    function _addLedger(address ledger) internal {
        if (ledger == address(0)) revert ZeroAddress();
        if (isLedger[ledger] || _ledgers.length >= MAX_LEDGERS) revert OutOfBounds();
        isLedger[ledger] = true;
        _ledgers.push(ledger);
        emit LedgerAdded(ledger);
    }

    function _setDepositor(address depositor, bool allowed) internal {
        if (depositor == address(0)) revert ZeroAddress();
        isDepositor[depositor] = allowed;
        emit DepositorSet(depositor, allowed);
    }

    function _setKeeperFund(address keeperFund_) internal {
        if (keeperFund_ == address(0)) revert ZeroAddress();
        keeperFund = IKeeperFund(keeperFund_);
        emit KeeperFundSet(keeperFund_);
    }
}
