// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Governed} from "../Governed.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title KeeperFund
/// @notice Holds the keeper allowance and pays callers of keeper jobs. FwaGame funds it from the markup
///         line of every booked pull up to `keeperTargetWei`; anything above the target goes to the Treasury.
/// @dev Tip formula (BUILD_PROMPT 4.6):
///        tip = min(tipCap, (gasUsed + gasOverhead) × min(basefee, basefeeCap) × (10,000 + premiumBps) / 10,000)
///            + maxBounty × min(age, rampSeconds) / rampSeconds
///      A registered payer (a holder or sink running a keeper job) calls `tip`. The fund pays what it can
///      and never reverts for lack of balance. Tips are pushed with a gas stipend; a failed push is
///      credited and withdrawn by the keeper (`withdrawTips`). Outflows: keepers and the Treasury.
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

    address public immutable treasury;

    uint256 public premiumBps;
    uint256 public basefeeCap;
    uint256 public tipCap;
    uint256 public maxBounty;
    uint256 public rampSeconds;
    uint256 public gasOverhead;
    uint256 public keeperTargetWei;

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
        uint256 keeperTargetWei
    );
    event PayerSet(address indexed payer, bool allowed);

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
    }

    constructor(address governance_, address treasury_, Params memory p) Governed(governance_, true) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        _setParams(p);
    }

    /// @notice One-shot wiring by the deployer: the payers that may call `tip`.
    function wire(address[] calldata payers) external onlyWiring {
        for (uint256 i; i < payers.length; ++i) {
            _setPayer(payers[i], true);
        }
    }

    receive() external payable {}

    /// @notice Funding from FwaGame's markup line. Anything above `keeperTargetWei` (net of credited
    ///         tips) is forwarded to the Treasury.
    function fundKeeper() external payable nonReentrant {
        uint256 avail = address(this).balance - tipCreditTotal;
        if (avail > keeperTargetWei) {
            uint256 excess = avail - keeperTargetWei;
            SafeTransferLib.forceSafeTransferETH(treasury, excess);
            emit Overflow(excess);
        }
    }

    /// @notice The tip for a job that used `gasUsed` gas after waiting `age` seconds, before the
    ///         balance limit.
    function quoteTip(uint256 gasUsed, uint256 age) public view returns (uint256 amount) {
        uint256 fee = block.basefee < basefeeCap ? block.basefee : basefeeCap;
        amount = (gasUsed + gasOverhead) * fee * (BPS + premiumBps) / BPS;
        if (amount > tipCap) amount = tipCap;
        uint256 ramp = rampSeconds;
        amount += maxBounty * (age < ramp ? age : ramp) / ramp;
    }

    /// @notice Balance available for tips (excludes credited, unwithdrawn tips).
    function available() public view returns (uint256) {
        return address(this).balance - tipCreditTotal;
    }

    /// @notice Pays `keeper` for a job. Registered payers only. Pays at most the available balance.
    function tip(address keeper, uint256 gasUsed, uint256 age) external nonReentrant returns (uint256 paid) {
        if (!isPayer[msg.sender]) revert NotPayer();
        paid = quoteTip(gasUsed, age);
        uint256 avail = available();
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

    function _setParams(Params memory p) internal {
        if (
            p.premiumBps > MAX_PREMIUM_BPS || p.basefeeCap > MAX_BASEFEE_CAP || p.tipCap > MAX_TIP_CAP
                || p.maxBounty > MAX_BOUNTY || p.rampSeconds == 0 || p.rampSeconds > MAX_RAMP
                || p.gasOverhead > MAX_GAS_OVERHEAD || p.keeperTargetWei > MAX_TARGET
        ) revert OutOfBounds();
        premiumBps = p.premiumBps;
        basefeeCap = p.basefeeCap;
        tipCap = p.tipCap;
        maxBounty = p.maxBounty;
        rampSeconds = p.rampSeconds;
        gasOverhead = p.gasOverhead;
        keeperTargetWei = p.keeperTargetWei;
        emit ParamsSet(
            p.premiumBps, p.basefeeCap, p.tipCap, p.maxBounty, p.rampSeconds, p.gasOverhead, p.keeperTargetWei
        );
    }

    function _setPayer(address payer, bool allowed) internal {
        if (payer == address(0)) revert ZeroAddress();
        isPayer[payer] = allowed;
        emit PayerSet(payer, allowed);
    }

}
