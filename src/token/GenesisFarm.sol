// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {Governed} from "../Governed.sol";
import {ILedger, IKeeperFund, IBurnable} from "../interfaces/IDrawShapes.sol";

/// @title GenesisFarm
/// @notice Holds the genesis allocation and the prize-conversion bonus pool. Over 21 epochs of `EPOCH_BLOCKS` blocks
///         from `openBlock` it pays each epoch's pot to that epoch's delivered pulls, pro rata by eligible ticket
///         ETH, once the epoch is final. Owns the epoch clock; genesis ends at `openBlock + 21 × EPOCH_BLOCKS`, a
///         fixed block nobody can move.
/// @dev Schedule (frozen in code): epoch weight `w(e)` is 8 for the 14 steady epochs, then 7, 6, ..., 1 (87.5% down to
///      12.5%); the weights sum to 140. Epoch `e` has an allocation cap `genesisBudget × w(e) / 140` (F / 17.5 in a
///      steady epoch) and a rate cap `rateCap × w(e) / 8` ENGINE per ETH of eligible ticket ETH. Its pot is
///      `min(allocation cap, eligible ticket ETH × rate cap)`, so a small purchase earns at most its rate and never a
///      whole pot. Weight is FWA fee paid on delivered pulls (refunded, expired and undelivered draws count nothing;
///      neither do VRF fees, gas, conversions or transfers), summed over up to `MAX_LEDGERS` games. An epoch is final
///      when its last block has passed and every ledger reports it final; `finalize` then fixes its pot and burns the
///      rest of its cap, which no one can earn any more. Claims never expire. ENGINE leaves only by claims, conversion
///      bonuses (to the registered Converter's caller), and burns of what is conclusively unearned.
contract GenesisFarm is ReentrancyGuard, Governed {
    uint256 public constant EPOCH_BLOCKS = 7_200;
    uint256 public constant GENESIS_EPOCHS = 21;
    uint256 public constant STEADY_EPOCHS = 14;
    uint256 public constant STEADY_WEIGHT = 8;
    uint256 public constant TOTAL_WEIGHT = 140;
    uint256 public constant MAX_LEDGERS = 4;

    address public immutable engine;
    uint256 public immutable genesisBudget;
    /// @notice Steady-epoch rate cap: ENGINE (wei) per 1 ETH of eligible ticket ETH.
    uint256 public immutable rateCap;

    IKeeperFund public keeperFund;
    uint256 public openBlock;
    uint256 public bonusPool;

    address[] internal _ledgers;
    /// @notice The first epoch a ledger counts in: the epoch it was added in (0 for one added before the clock starts).
    ///         Ended epochs never change when governance adds a ledger, so finalized pots and their shares are fixed.
    mapping(address ledger => uint256) public ledgerFrom;
    mapping(address => bool) public isLedger;
    mapping(address => bool) public isBonusPayer;

    mapping(uint256 epoch => uint256) internal _potSnapshot; // pot + 1 once finalized
    mapping(uint256 epoch => mapping(address => bool)) public claimed;

    uint256 public totalPots; // pots fixed by finalization
    uint256 public totalClaimed;
    uint256 public totalBonusPaid;
    uint256 public totalBurned;
    bool public bonusRetired;

    event Started(uint256 openBlock);
    event Finalized(uint256 indexed epoch, uint256 pot, uint256 burned);
    event Claimed(address indexed purchaser, uint256 indexed epoch, uint256 amount);
    event BonusPaid(address indexed to, uint256 amount);
    event BonusRetired(uint256 burned);
    event LedgerAdded(address ledger);
    event BonusPayerSet(address indexed payer, bool allowed);
    event KeeperFundSet(address keeperFund);

    error NotLedger();
    error NotBonusPayer();
    error AlreadyStarted();
    error NotFinal(uint256 epoch);
    error AlreadyClaimed(uint256 epoch);
    error NothingToClaim();
    error GenesisNotOver();
    error NoWork();
    error Underfunded();

    constructor(address governance_, address engine_, uint256 genesisBudget_, uint256 bonusPool_, uint256 rateCap_)
        Governed(governance_, true)
    {
        if (engine_ == address(0)) revert ZeroAddress();
        engine = engine_;
        genesisBudget = genesisBudget_;
        bonusPool = bonusPool_;
        rateCap = rateCap_;
    }

    /// @notice One-shot wiring by the deployer: the first game, the converter, the keeper fund. Requires the farm to
    ///         hold its two allocations.
    function wire(address ledger, address converter, address keeperFund_) external onlyWiring {
        if (SafeTransferLib.balanceOf(engine, address(this)) < genesisBudget + bonusPool) revert Underfunded();
        _addLedger(ledger);
        _setBonusPayer(converter, true);
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

    /// @notice First block after genesis (max uint before the clock starts). Public buys reopen here.
    function genesisEndBlock() public view returns (uint256) {
        return openBlock == 0 ? type(uint256).max : openBlock + GENESIS_EPOCHS * EPOCH_BLOCKS;
    }

    function ledgers() external view returns (address[] memory) {
        return _ledgers;
    }

    // ------------------------------------------------------------------ schedule

    /// @notice Weight of `epoch` in the schedule, in eighths of a steady epoch (zero after genesis).
    function stepWeight(uint256 epoch) public pure returns (uint256) {
        if (epoch < STEADY_EPOCHS) return STEADY_WEIGHT;
        if (epoch < GENESIS_EPOCHS) return GENESIS_EPOCHS - epoch;
        return 0;
    }

    /// @notice Most ENGINE `epoch` can pay. The last epoch takes the rounding so the caps sum to the budget.
    function allocationCap(uint256 epoch) public view returns (uint256 cap) {
        if (epoch >= GENESIS_EPOCHS) return 0;
        if (epoch < GENESIS_EPOCHS - 1) return genesisBudget * stepWeight(epoch) / TOTAL_WEIGHT;
        cap = genesisBudget;
        for (uint256 e; e < GENESIS_EPOCHS - 1; ++e) {
            cap -= genesisBudget * stepWeight(e) / TOTAL_WEIGHT;
        }
    }

    /// @notice ENGINE (wei) per 1 ETH of eligible ticket ETH in `epoch`.
    function rateCapOf(uint256 epoch) public view returns (uint256) {
        return rateCap * stepWeight(epoch) / STEADY_WEIGHT;
    }

    // ------------------------------------------------------------------ ledger reads

    function epochWeight(uint256 epoch) public view returns (uint256 w) {
        uint256 n = _ledgers.length;
        for (uint256 i; i < n; ++i) {
            if (epoch >= ledgerFrom[_ledgers[i]]) w += ILedger(_ledgers[i]).epochWeight(epoch);
        }
    }

    function userWeight(uint256 epoch, address purchaser) public view returns (uint256 w) {
        uint256 n = _ledgers.length;
        for (uint256 i; i < n; ++i) {
            if (epoch >= ledgerFrom[_ledgers[i]]) w += ILedger(_ledgers[i]).userWeight(epoch, purchaser);
        }
    }

    /// @notice True once `epoch` has ended and every pull accepted in it is terminal and booked.
    function isFinal(uint256 epoch) public view returns (bool) {
        if (openBlock == 0 || block.number < openBlock + (epoch + 1) * EPOCH_BLOCKS) return false;
        uint256 n = _ledgers.length;
        for (uint256 i; i < n; ++i) {
            if (epoch >= ledgerFrom[_ledgers[i]] && !ILedger(_ledgers[i]).isEpochFinal(epoch)) return false;
        }
        return true;
    }

    function isFinalized(uint256 epoch) public view returns (bool) {
        return _potSnapshot[epoch] != 0;
    }

    // ------------------------------------------------------------------ pots

    /// @notice Pot of `epoch`: fixed once finalized, else what it would be on the ledgers as they stand.
    function potOf(uint256 epoch) public view returns (uint256) {
        uint256 snap = _potSnapshot[epoch];
        if (snap != 0) return snap - 1;
        uint256 cap = allocationCap(epoch);
        uint256 byRate = FPM.fullMulDiv(epochWeight(epoch), rateCapOf(epoch), 1 ether);
        return byRate < cap ? byRate : cap;
    }

    /// @notice Reward of `purchaser` in `epoch` (final once the epoch is final).
    function rewardOf(uint256 epoch, address purchaser) public view returns (uint256) {
        uint256 w = epochWeight(epoch);
        if (w == 0) return 0;
        return FPM.fullMulDiv(potOf(epoch), userWeight(epoch, purchaser), w);
    }

    /// @notice Unclaimed rewards of `purchaser` across final epochs `[from, to)`.
    function claimable(address purchaser, uint256 from, uint256 to) external view returns (uint256 total) {
        for (uint256 e = from; e < to; ++e) {
            if (!claimed[e][purchaser] && isFinal(e)) total += rewardOf(e, purchaser);
        }
    }

    /// @notice Allocation still reserved for genesis epochs: unfinalized caps plus unclaimed finalized pots.
    function reserved() public view returns (uint256 r) {
        r = totalPots - totalClaimed;
        for (uint256 e; e < GENESIS_EPOCHS; ++e) {
            if (_potSnapshot[e] == 0) r += allocationCap(e);
        }
    }

    // ------------------------------------------------------------------ finalization and claims

    /// @notice Fixes the pot of each final epoch in `epochs` and burns the rest of its cap. Anyone may call; tipped per
    ///         epoch finalized. Epochs already finalized are skipped; a non-final epoch reverts.
    function finalize(uint256[] calldata epochs) external nonReentrant returns (uint256 done) {
        uint256 gasStart = gasleft();
        for (uint256 i; i < epochs.length; ++i) {
            if (_potSnapshot[epochs[i]] != 0) continue;
            _finalize(epochs[i]);
            ++done;
        }
        if (done == 0) revert NoWork();
        if (address(keeperFund) != address(0)) keeperFund.tip(msg.sender, gasStart - gasleft(), done, false);
    }

    /// @notice Claims the caller's rewards for `epochs`, each final and unclaimed (finalizing it if needed).
    function claim(uint256[] calldata epochs) external nonReentrant returns (uint256 total) {
        for (uint256 i; i < epochs.length; ++i) {
            uint256 e = epochs[i];
            if (claimed[e][msg.sender]) revert AlreadyClaimed(e);
            uint256 pot = _potSnapshot[e] != 0 ? _potSnapshot[e] - 1 : _finalize(e);
            claimed[e][msg.sender] = true;
            uint256 w = epochWeight(e);
            uint256 amount = w == 0 ? 0 : FPM.fullMulDiv(pot, userWeight(e, msg.sender), w);
            total += amount;
            emit Claimed(msg.sender, e, amount);
        }
        if (total == 0) revert NothingToClaim();
        totalClaimed += total;
        SafeTransferLib.safeTransfer(engine, msg.sender, total);
    }

    function _finalize(uint256 e) internal returns (uint256 pot) {
        if (!isFinal(e)) revert NotFinal(e);
        pot = potOf(e);
        _potSnapshot[e] = pot + 1;
        totalPots += pot;
        uint256 burned = allocationCap(e) - pot;
        _burn(burned);
        emit Finalized(e, pot, burned);
    }

    // ------------------------------------------------------------------ bonus

    /// @notice Pays a prize-conversion bonus from the bonus pool. The registered Converter only. Pays what the pool
    ///         holds, up to `amount`; nothing once the pool is spent or retired.
    function payBonus(address to, uint256 amount) external nonReentrant returns (uint256 paid) {
        if (!isBonusPayer[msg.sender]) revert NotBonusPayer();
        paid = amount < bonusPool ? amount : bonusPool;
        if (paid == 0) return 0;
        bonusPool -= paid;
        totalBonusPaid += paid;
        SafeTransferLib.safeTransfer(engine, to, paid);
        emit BonusPaid(to, paid);
    }

    /// @notice Burns what is left of the bonus pool once genesis has ended. Conversion continues without a bonus.
    ///         Anyone may call.
    function retireBonus() external nonReentrant returns (uint256 amount) {
        if (openBlock == 0 || block.number < genesisEndBlock()) revert GenesisNotOver();
        if (bonusRetired) revert NoWork();
        bonusRetired = true;
        amount = bonusPool;
        bonusPool = 0;
        _burn(amount);
        emit BonusRetired(amount);
    }

    function _burn(uint256 amount) internal {
        if (amount == 0) return;
        totalBurned += amount;
        IBurnable(engine).burn(amount);
    }

    // ------------------------------------------------------------------ governance

    /// @notice Registers another game's ledger (a replacement game after a retirement).
    function addLedger(address ledger) external onlyGovernance {
        _addLedger(ledger);
    }

    function setBonusPayer(address payer, bool allowed) external onlyGovernance {
        _setBonusPayer(payer, allowed);
    }

    function setKeeperFund(address keeperFund_) external onlyGovernance {
        _setKeeperFund(keeperFund_);
    }

    function _addLedger(address ledger) internal {
        if (ledger == address(0)) revert ZeroAddress();
        if (isLedger[ledger] || _ledgers.length >= MAX_LEDGERS) revert OutOfBounds();
        isLedger[ledger] = true;
        ledgerFrom[ledger] = currentEpoch();
        _ledgers.push(ledger);
        emit LedgerAdded(ledger);
    }

    function _setBonusPayer(address payer, bool allowed) internal {
        if (payer == address(0)) revert ZeroAddress();
        isBonusPayer[payer] = allowed;
        emit BonusPayerSet(payer, allowed);
    }

    function _setKeeperFund(address keeperFund_) internal {
        if (keeperFund_ == address(0)) revert ZeroAddress();
        keeperFund = IKeeperFund(keeperFund_);
        emit KeeperFundSet(keeperFund_);
    }
}
