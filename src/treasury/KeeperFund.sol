// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Governed} from "../Governed.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IFwaGame} from "../interfaces/IDrawShapes.sol";

/// @title KeeperFund
/// @notice Holds the keeper allowance and pays callers of keeper jobs. FwaGame funds it with the operating
///         allocation of every booked pull; anything above `keeperTargetWei` goes back to the game (`overflow`,
///         `returnOps`), where it reduces the net operating expense.
/// @dev Tip formula (BUILD_PROMPT 4.6):
///        tip = min(tipCap, (gasUsed + gasOverhead) × min(basefee, basefeeCap) × (10,000 + premiumBps) / 10,000)
///            + maxBounty × min(age, rampSeconds) / rampSeconds × min(items, BOUNTY_ITEMS) / BOUNTY_ITEMS
///      The bounty is paid per unit of progress (`items`: requests seen or resolved, listings made, slices
///      bought), so splitting work across calls earns no more than one call; a call with no progress earns
///      nothing. A registered payer (a holder or sink running a keeper job) calls `tip`. The fund pays what it
///      can and never reverts for lack of balance; it keeps `maintenanceFloor` that only retirement steps may
///      spend. Tips are pushed with a gas stipend; a failed push is credited and withdrawn by the keeper
///      (`withdrawTips`). Outflows: keepers and the game.
contract KeeperFund is Governed, ReentrancyGuard {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PUSH_GAS = 50_000;

    uint256 public constant MAX_PREMIUM_BPS = 10_000;
    uint256 public constant MAX_BASEFEE_CAP = 500 gwei;
    uint256 public constant MAX_TIP_CAP = 0.05 ether;
    uint256 public constant MAX_BOUNTY = 0.01 ether;
    uint256 public constant MAX_RAMP = 7 days;
    uint256 public constant MAX_GAS_OVERHEAD = 200_000;
    uint256 public constant MAX_TARGET = 100 ether;
    uint256 public constant MAX_FLOOR = 10 ether;
    uint256 public constant BOUNTY_ITEMS = 20;

    address public overflow;

    uint256 public premiumBps;
    uint256 public basefeeCap;
    uint256 public tipCap;
    uint256 public maxBounty;
    uint256 public rampSeconds;
    uint256 public gasOverhead;
    uint256 public keeperTargetWei;
    uint256 public maintenanceFloor;

    mapping(address payer => bool) public isPayer;
    mapping(address keeper => uint256) public tipCredit;
    uint256 public tipCreditTotal;
    uint256 public totalTipsPaid;

    event TipPaid(address indexed payer, address indexed keeper, uint256 amount, bool credited);
    event TipWithdrawn(address indexed keeper, uint256 amount);
    event Overflow(uint256 amount);
    event ParamsSet(
        uint256 premiumBps,
        uint256 basefeeCap,
        uint256 tipCap,
        uint256 maxBounty,
        uint256 rampSeconds,
        uint256 gasOverhead,
        uint256 keeperTargetWei,
        uint256 maintenanceFloor
    );
    event PayerSet(address indexed payer, bool allowed);
    event OverflowSet(address overflow);

    error NotPayer();
    error NothingToWithdraw();

    struct Params {
        uint256 premiumBps;
        uint256 basefeeCap;
        uint256 tipCap;
        uint256 maxBounty;
        uint256 rampSeconds;
        uint256 gasOverhead;
        uint256 keeperTargetWei;
        uint256 maintenanceFloor;
    }

    /// @dev Payable so the deploy script can seed the fund (`KEEPER_SEED`).
    constructor(address governance_, Params memory p) payable Governed(governance_, true) {
        _setParams(p);
    }

    /// @notice One-shot wiring by the deployer: the payers that may call `tip` and the overflow recipient (the game).
    function wire(address[] calldata payers, address overflow_) external onlyWiring {
        for (uint256 i; i < payers.length; ++i) {
            _setPayer(payers[i], true);
        }
        _setOverflow(overflow_);
    }

    receive() external payable {}

    /// @notice Funding from FwaGame's operating allocation. Anything above `keeperTargetWei` (net of credited
    ///         tips) goes back to the overflow recipient.
    function fundKeeper() external payable nonReentrant {
        uint256 avail = address(this).balance - tipCreditTotal;
        if (avail > keeperTargetWei && overflow != address(0)) {
            uint256 excess = avail - keeperTargetWei;
            IFwaGame(overflow).returnOps{value: excess}();
            emit Overflow(excess);
        }
    }

    /// @notice The tip for a job that used `gasUsed` gas and made `items` units of progress after waiting `age`
    ///         seconds, before the balance limit.
    function quoteTip(uint256 gasUsed, uint256 age, uint256 items) public view returns (uint256 amount) {
        if (items == 0) return 0;
        uint256 fee = block.basefee < basefeeCap ? block.basefee : basefeeCap;
        amount = (gasUsed + gasOverhead) * fee * (BPS + premiumBps) / BPS;
        if (amount > tipCap) amount = tipCap;
        uint256 ramp = rampSeconds;
        amount += maxBounty * (age < ramp ? age : ramp) / ramp * (items < BOUNTY_ITEMS ? items : BOUNTY_ITEMS) / BOUNTY_ITEMS;
    }

    /// @notice Balance available for tips (excludes credited, unwithdrawn tips). Ordinary jobs may not spend the
    ///         maintenance floor; retirement steps may.
    function available(bool retirement) public view returns (uint256) {
        uint256 bal = address(this).balance - tipCreditTotal;
        uint256 floor = retirement ? 0 : maintenanceFloor;
        return bal > floor ? bal - floor : 0;
    }

    /// @notice Pays `keeper` for a job. Registered payers only. Pays at most the available balance.
    function tip(address keeper, uint256 gasUsed, uint256 age, uint256 items, bool retirement)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (!isPayer[msg.sender]) revert NotPayer();
        paid = quoteTip(gasUsed, age, items);
        uint256 avail = available(retirement);
        if (paid > avail) paid = avail;
        if (paid == 0 || keeper == address(0)) return 0;
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
            p.premiumBps > MAX_PREMIUM_BPS || p.basefeeCap > MAX_BASEFEE_CAP || p.tipCap > MAX_TIP_CAP
                || p.maxBounty > MAX_BOUNTY || p.rampSeconds == 0 || p.rampSeconds > MAX_RAMP
                || p.gasOverhead > MAX_GAS_OVERHEAD || p.keeperTargetWei > MAX_TARGET || p.maintenanceFloor > MAX_FLOOR
                || p.maintenanceFloor > p.keeperTargetWei
        ) revert OutOfBounds();
        premiumBps = p.premiumBps;
        basefeeCap = p.basefeeCap;
        tipCap = p.tipCap;
        maxBounty = p.maxBounty;
        rampSeconds = p.rampSeconds;
        gasOverhead = p.gasOverhead;
        keeperTargetWei = p.keeperTargetWei;
        maintenanceFloor = p.maintenanceFloor;
        emit ParamsSet(
            p.premiumBps,
            p.basefeeCap,
            p.tipCap,
            p.maxBounty,
            p.rampSeconds,
            p.gasOverhead,
            p.keeperTargetWei,
            p.maintenanceFloor
        );
    }

    function _setPayer(address payer, bool allowed) internal {
        if (payer == address(0)) revert ZeroAddress();
        isPayer[payer] = allowed;
        emit PayerSet(payer, allowed);
    }
}
