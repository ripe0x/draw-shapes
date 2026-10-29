// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Governed} from "../Governed.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IFwaGame} from "../interfaces/IDrawShapes.sol";

/// @title KeeperFund
/// @notice Holds the keeper allowance and pays callers of keeper jobs. FwaGame funds it with the operating allocation
///         of every booked pull; the PrizeVault tops it up from trading fees while it is low, within a lifetime limit
///         (D48). Above `keeperTargetWei` it returns the excess: first the vault's top-ups (capital goes back as
///         capital), then the rest to the game (`returnOps`), where it reduces the net operating expense.
/// @dev Tip (D48):
///        tip = min(tipCap, (gasUsed + gasOverhead) × min(tx.gasprice, maxGasPrice)) + flatFee
///      where the flat fee is paid at most once per `feeInterval` per payer, so splitting work earns no more and a call
///      that does nothing earns nothing (`work` 0). Gas is refunded at what the keeper paid (base fee and priority),
///      capped. A registered payer (a holder or sink running a keeper job) calls `tip`. The fund pays what it can and
///      never reverts for lack of balance; it keeps `maintenanceFloor` that only retirement steps may spend. Tips are
///      pushed with a gas stipend; a failed push is credited and withdrawn by the keeper (`withdrawTips`). Outflows:
///      keepers, the vault (its top-ups back) and the game.
contract KeeperFund is Governed, ReentrancyGuard {
    uint256 internal constant PUSH_GAS = 50_000;

    uint256 public constant MAX_TIP_CAP = 0.05 ether;
    uint256 public constant MAX_GAS_PRICE = 100 gwei;
    uint256 public constant MAX_GAS_OVERHEAD = 200_000;
    uint256 public constant MAX_FLAT_FEE = 0.005 ether;
    uint256 public constant MAX_FEE_INTERVAL = 1 days;
    uint256 public constant MAX_TARGET = 100 ether;
    uint256 public constant MAX_FLOOR = 10 ether;

    uint256 public tipCap;
    uint256 public maxGasPrice;
    uint256 public gasOverhead;
    uint256 public flatFee;
    uint256 public feeInterval;
    uint256 public keeperTargetWei;
    uint256 public maintenanceFloor;

    address public overflow; // the game
    address public vault;
    mapping(address payer => bool) public isPayer;
    mapping(address payer => uint256) public lastFeeAt;
    mapping(address keeper => uint256) public tipCredit;
    uint256 public tipCreditTotal;
    uint256 public totalTipsPaid;
    /// @notice Vault top-ups not yet returned to the vault.
    uint256 public capitalHeld;

    event TipPaid(address indexed payer, address indexed keeper, uint256 amount, bool credited);
    event TipWithdrawn(address indexed keeper, uint256 amount);
    event ToppedUp(uint256 amount);
    event Overflow(uint256 toVault, uint256 toGame);
    event ParamsSet(Params p);
    event PayerSet(address indexed payer, bool allowed);
    event OverflowSet(address overflow);

    error NotPayer();
    error NotVault();
    error NothingToWithdraw();

    struct Params {
        uint256 tipCap;
        uint256 maxGasPrice;
        uint256 gasOverhead;
        uint256 flatFee;
        uint256 feeInterval;
        uint256 keeperTargetWei;
        uint256 maintenanceFloor;
    }

    /// @dev Payable so the deploy script can seed the fund (`KEEPER_SEED`).
    constructor(address governance_, Params memory p) payable Governed(governance_, true) {
        _setParams(p);
    }

    /// @notice One-shot wiring by the deployer: the payers that may call `tip`, the overflow recipient (the game) and
    ///         the vault that tops the fund up.
    function wire(address[] calldata payers, address overflow_, address vault_) external onlyWiring {
        for (uint256 i; i < payers.length; ++i) {
            _setPayer(payers[i], true);
        }
        _setOverflow(overflow_);
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
    }

    receive() external payable {}

    /// @notice A top-up from the vault (trading fees). Counted as capital held until returned.
    function topUp() external payable {
        if (msg.sender != vault) revert NotVault();
        capitalHeld += msg.value;
        emit ToppedUp(msg.value);
    }

    /// @notice Funding from FwaGame's operating allocation. Anything above `keeperTargetWei` (net of credited tips) goes
    ///         back: the vault's top-ups first, then the rest to the game.
    function fundKeeper() external payable nonReentrant {
        uint256 avail = address(this).balance - tipCreditTotal;
        if (avail <= keeperTargetWei) return;
        uint256 excess = avail - keeperTargetWei;
        uint256 toVault = excess < capitalHeld ? excess : capitalHeld;
        if (toVault != 0) {
            capitalHeld -= toVault;
            SafeTransferLib.safeTransferETH(vault, toVault);
        }
        uint256 toGame = excess - toVault;
        if (toGame != 0 && overflow != address(0)) IFwaGame(overflow).returnOps{value: toGame}();
        emit Overflow(toVault, toGame);
    }

    /// @notice The tip for a job that used `gasUsed` gas and did `work` units of progress, before the balance limit and
    ///         without the flat fee's interval.
    function quoteTip(uint256 gasUsed, uint256 work) public view returns (uint256 amount) {
        if (work == 0) return 0;
        uint256 price = tx.gasprice < maxGasPrice ? tx.gasprice : maxGasPrice;
        amount = (gasUsed + gasOverhead) * price;
        if (amount > tipCap) amount = tipCap;
        amount += flatFee;
    }

    /// @notice Balance available for tips (excludes credited, unwithdrawn tips). Ordinary jobs may not spend the
    ///         maintenance floor; retirement steps may.
    function available(bool retirement) public view returns (uint256) {
        uint256 bal = address(this).balance - tipCreditTotal;
        uint256 floor = retirement ? 0 : maintenanceFloor;
        return bal > floor ? bal - floor : 0;
    }

    /// @notice Pays `keeper` for a job. Registered payers only. Pays at most the available balance.
    function tip(address keeper, uint256 gasUsed, uint256 work, bool retirement)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (!isPayer[msg.sender]) revert NotPayer();
        if (work == 0 || keeper == address(0)) return 0;
        uint256 price = tx.gasprice < maxGasPrice ? tx.gasprice : maxGasPrice;
        paid = (gasUsed + gasOverhead) * price;
        if (paid > tipCap) paid = tipCap;
        if (block.timestamp >= lastFeeAt[msg.sender] + feeInterval) {
            lastFeeAt[msg.sender] = block.timestamp;
            paid += flatFee;
        }
        uint256 avail = available(retirement);
        if (paid > avail) paid = avail;
        if (paid == 0) return 0;
        totalTipsPaid += paid;
        bool ok;
        assembly ("memory-safe") {
            ok := call(PUSH_GAS, keeper, paid, 0, 0, 0, 0)
        }
        if (!ok) {
            tipCredit[keeper] += paid;
            tipCreditTotal += paid;
        }
        emit TipPaid(msg.sender, keeper, paid, !ok);
    }

    /// @notice Withdraws tips that could not be pushed.
    function withdrawTips() external nonReentrant {
        uint256 amount = tipCredit[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        tipCredit[msg.sender] = 0;
        tipCreditTotal -= amount;
        SafeTransferLib.forceSafeTransferETH(msg.sender, amount);
        emit TipWithdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------ governance

    function setParams(Params calldata p) external onlyGovernance {
        _setParams(p);
    }

    function setPayer(address payer, bool allowed) external onlyGovernance {
        _setPayer(payer, allowed);
    }

    /// @notice The game that receives overflow (a new game after a retirement).
    function setOverflow(address overflow_) external onlyGovernance {
        _setOverflow(overflow_);
    }

    function _setOverflow(address overflow_) internal {
        if (overflow_.code.length == 0) revert ZeroAddress();
        overflow = overflow_;
        emit OverflowSet(overflow_);
    }

    function _setParams(Params memory p) internal {
        if (
            p.tipCap > MAX_TIP_CAP || p.maxGasPrice > MAX_GAS_PRICE || p.gasOverhead > MAX_GAS_OVERHEAD
                || p.flatFee > MAX_FLAT_FEE || p.feeInterval > MAX_FEE_INTERVAL || p.keeperTargetWei > MAX_TARGET
                || p.maintenanceFloor > MAX_FLOOR || p.maintenanceFloor > p.keeperTargetWei
        ) revert OutOfBounds();
        tipCap = p.tipCap;
        maxGasPrice = p.maxGasPrice;
        gasOverhead = p.gasOverhead;
        flatFee = p.flatFee;
        feeInterval = p.feeInterval;
        keeperTargetWei = p.keeperTargetWei;
        maintenanceFloor = p.maintenanceFloor;
        emit ParamsSet(p);
    }

    function _setPayer(address payer, bool allowed) internal {
        if (payer == address(0)) revert ZeroAddress();
        isPayer[payer] = allowed;
        emit PayerSet(payer, allowed);
    }
}
