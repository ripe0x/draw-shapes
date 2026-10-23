// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title FoundingRound
/// @notice Conditional ETH escrow for the opening bankroll, then the ledger of the founders' capped
///         payment entitlement.
/// @dev Escrow: contributions are accepted until `deadline` and up to `target`, which is also the
///      hard cap. Nothing leaves the escrow except through `refund` or `release`. `release` is the
///      treasury's alone, only while the round is `Funded` (target reached, not cancelled, not past
///      `launchDeadline`), and sends the whole escrow to the treasury in one transfer. The round is
///      `Refunding` when the deadline passes below target, when the owner cancels before release,
///      or when `launchDeadline` passes without a release; each contributor then pulls their whole
///      contribution back with `refund`.
///
///      Ledger: after release the treasury pays founder distributions in with `distribute`. They are
///      held here, outside the treasury, so game spending cannot reach them. Every contributor is
///      credited pro rata to their contribution: `credited(a) = contributionOf[a] * totalDistributed /
///      totalContributed`. `totalDistributed` can never pass `entitlement() = totalContributed *
///      capBps / 10_000` (`distribute` reverts `AboveCap`), so no contributor is ever credited more
///      than `capBps` of their contribution, and the round stops accepting payments at the cap. The
///      entitlement is a ceiling on payments, not a promise of them.
contract FoundingRound is ReentrancyGuard {
    enum State {
        Open,
        Funded,
        Released,
        Refunding
    }

    error NotOwner();
    error NotTreasury();
    error WrongState(State state);
    error ZeroAmount();
    error BelowMinimum(uint256 minimum);
    error AboveCap(uint256 remaining);
    error BadTerms();
    error NothingToClaim();

    event Contributed(address indexed from, uint256 accepted, uint256 returned);
    event Refunded(address indexed to, uint256 amount);
    event Released(address indexed treasury, uint256 amount);
    event Cancelled();
    event Distributed(uint256 amount, uint256 totalDistributed);
    event Claimed(address indexed to, uint256 amount);

    uint256 internal constant BPS = 10_000;

    /// @notice May cancel the round before release. Has no other power.
    address public immutable owner;
    /// @notice The only address that may `release` the escrow and `distribute` payments.
    address public immutable treasury;
    /// @notice Funding goal and hard cap, in wei.
    uint256 public immutable target;
    /// @notice Contributions close at this timestamp.
    uint256 public immutable deadline;
    /// @notice A funded round that is not released by this timestamp refunds.
    uint256 public immutable launchDeadline;
    /// @notice Ceiling on cumulative payments per contributed wei, in bps (12,000 is 1.2x).
    uint256 public immutable capBps;
    /// @notice Smallest accepted contribution, except the last one that fills the round.
    uint256 public immutable minContribution;

    uint256 public totalContributed;
    mapping(address => uint256) public contributionOf;
    bool public released;
    bool public cancelled;

    /// @notice Sum of every `distribute` payment.
    uint256 public totalDistributed;
    mapping(address => uint256) public claimedOf;

    constructor(
        address owner_,
        address treasury_,
        uint256 target_,
        uint256 duration,
        uint256 launchWindow,
        uint256 capBps_,
        uint256 minContribution_
    ) {
        if (
            owner_ == address(0) || treasury_ == address(0) || target_ == 0 || duration == 0 || capBps_ < BPS
                || capBps_ > 2 * BPS || minContribution_ > target_
        ) revert BadTerms();
        owner = owner_;
        treasury = treasury_;
        target = target_;
        deadline = block.timestamp + duration;
        launchDeadline = block.timestamp + duration + launchWindow;
        capBps = capBps_;
        minContribution = minContribution_;
    }

    /// @notice Current state. `Funded` is reached the moment the target is met, even before `deadline`.
    function state() public view returns (State) {
        if (released) return State.Released;
        if (cancelled) return State.Refunding;
        if (totalContributed == target) {
            return block.timestamp <= launchDeadline ? State.Funded : State.Refunding;
        }
        return block.timestamp < deadline ? State.Open : State.Refunding;
    }

    // ------------------------------------------------------------------ escrow

    /// @notice Contributes `msg.value`. Accepts at most the room left below `target` and returns the
    ///         rest in the same call.
    function contribute() external payable nonReentrant {
        State s = state();
        if (s != State.Open) revert WrongState(s);
        uint256 room = target - totalContributed;
        uint256 accepted = msg.value < room ? msg.value : room;
        if (accepted == 0) revert ZeroAmount();
        if (accepted < minContribution && accepted != room) revert BelowMinimum(minContribution);
        totalContributed += accepted;
        contributionOf[msg.sender] += accepted;
        uint256 returned = msg.value - accepted;
        emit Contributed(msg.sender, accepted, returned);
        if (returned != 0) SafeTransferLib.safeTransferETH(msg.sender, returned);
    }

    /// @notice Returns the caller's whole contribution while the round is `Refunding`.
    function refund() external nonReentrant {
        State s = state();
        if (s != State.Refunding) revert WrongState(s);
        uint256 amount = contributionOf[msg.sender];
        if (amount == 0) revert NothingToClaim();
        contributionOf[msg.sender] = 0;
        emit Refunded(msg.sender, amount);
        SafeTransferLib.safeTransferETH(msg.sender, amount);
    }

    /// @notice Ends the round before release. Every contributor can then `refund`.
    function cancel() external {
        if (msg.sender != owner) revert NotOwner();
        State s = state();
        if (s == State.Released || s == State.Refunding) revert WrongState(s);
        cancelled = true;
        emit Cancelled();
    }

    /// @notice Sends the full escrow to the treasury. Treasury only, while `Funded`. The treasury
    ///         calls this from its activation, after it has checked the launch conditions.
    function release() external nonReentrant returns (uint256 amount) {
        if (msg.sender != treasury) revert NotTreasury();
        State s = state();
        if (s != State.Funded) revert WrongState(s);
        released = true;
        amount = totalContributed;
        emit Released(treasury, amount);
        SafeTransferLib.safeTransferETH(treasury, amount);
    }

    // ------------------------------------------------------------------ ledger

    /// @notice Cumulative payment ceiling: `totalContributed * capBps / 10_000`.
    function entitlement() public view returns (uint256) {
        return totalContributed * capBps / BPS;
    }

    /// @notice Payments still possible before the cap: zero before release and once the cap is reached.
    function remaining() public view returns (uint256) {
        if (!released) return 0;
        return entitlement() - totalDistributed;
    }

    /// @notice Credits `msg.value` to every contributor pro rata. Treasury only, after release, at
    ///         most `remaining()`.
    function distribute() external payable {
        if (msg.sender != treasury) revert NotTreasury();
        if (!released) revert WrongState(state());
        if (msg.value == 0) revert ZeroAmount();
        uint256 room = remaining();
        if (msg.value > room) revert AboveCap(room);
        totalDistributed += msg.value;
        emit Distributed(msg.value, totalDistributed);
    }

    /// @notice Total credited to `account` so far, claimed or not.
    function creditedOf(address account) public view returns (uint256) {
        if (totalContributed == 0) return 0;
        return contributionOf[account] * totalDistributed / totalContributed;
    }

    /// @notice Credited and not yet claimed.
    function claimable(address account) public view returns (uint256) {
        if (!released) return 0;
        return creditedOf(account) - claimedOf[account];
    }

    /// @notice Pays the caller everything credited and not yet claimed.
    function claim() external nonReentrant returns (uint256 amount) {
        amount = claimable(msg.sender);
        if (amount == 0) revert NothingToClaim();
        claimedOf[msg.sender] += amount;
        emit Claimed(msg.sender, amount);
        SafeTransferLib.safeTransferETH(msg.sender, amount);
    }
}
