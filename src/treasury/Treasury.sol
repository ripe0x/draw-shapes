// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Governed} from "../Governed.sol";
import {IKeeperFund} from "../interfaces/IDrawShapes.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Treasury
/// @notice Holds the game's revenue: the hook's ETH fee on every ENGINE swap, the house margin of every
///         booked pull and KeeperFund overflow. `distribute()` allocates the unallocated balance to the
///         registered sinks by the governance table; each sink draws its allocation when it runs.
/// @dev The only outflow is `draw`, to a registered sink, up to its allocation. A new table returns every
///      allocation to the unallocated balance (docs/IMPLEMENTOR_DECISIONS.md D15).
contract Treasury is Governed, ReentrancyGuard {
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_SINKS = 8;

    struct Sink {
        address sink;
        uint16 bps;
    }

    Sink[] internal _sinks;
    mapping(address sink => uint256) public owed;
    uint256 public allocatedTotal;

    IKeeperFund public keeperFund;
    uint256 public lastDistributeAt;
    uint256 public totalReceived;

    event SinksSet(address[] sinks, uint16[] bps);
    event Distributed(uint256 amount);
    event Drawn(address indexed sink, uint256 amount);
    event KeeperFundSet(address keeperFund);

    error InvalidTable();
    error NotSink();
    error ExceedsOwed();
    error NoWork();

    constructor(address governance_) Governed(governance_, true) {
        lastDistributeAt = block.timestamp;
    }

    /// @notice One-shot wiring by the deployer: the keeper fund and the launch table.
    function wire(address keeperFund_, address[] calldata sinks_, uint16[] calldata bps_) external onlyWiring {
        _setKeeperFund(keeperFund_);
        _setSinks(sinks_, bps_);
    }

    /// @dev Kept cheap: the hook pays its fee here in the middle of every swap.
    receive() external payable {}

    function sinkCount() external view returns (uint256) {
        return _sinks.length;
    }

    function sinkAt(uint256 i) external view returns (address sink, uint16 bps) {
        Sink memory s = _sinks[i];
        return (s.sink, s.bps);
    }

    function unallocated() public view returns (uint256) {
        return address(this).balance - allocatedTotal;
    }

    /// @notice Allocates the unallocated balance to the sinks by the table, then tips the caller.
    function distribute() external nonReentrant returns (uint256 amount) {
        uint256 gasStart = gasleft();
        amount = unallocated();
        uint256 n = _sinks.length;
        if (amount == 0 || n == 0) revert NoWork();
        uint256 left = amount;
        for (uint256 i; i < n; ++i) {
            Sink memory s = _sinks[i];
            uint256 share = i == n - 1 ? left : amount * s.bps / BPS;
            owed[s.sink] += share;
            left -= share;
        }
        allocatedTotal += amount;
        totalReceived += amount;
        uint256 age = block.timestamp - lastDistributeAt;
        lastDistributeAt = block.timestamp;
        emit Distributed(amount);
        if (address(keeperFund) != address(0)) keeperFund.tip(msg.sender, gasStart - gasleft(), age, n, false);
    }

    /// @notice A registered sink draws up to its allocation.
    function draw(uint256 amount) external nonReentrant {
        uint256 o = owed[msg.sender];
        if (amount > o) revert ExceedsOwed();
        owed[msg.sender] = o - amount;
        allocatedTotal -= amount;
        SafeTransferLib.forceSafeTransferETH(msg.sender, amount);
        emit Drawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------ governance

    /// @notice Replaces the table. Each sink must have code; bps sum to 10,000. Every allocation returns to
    ///         the unallocated balance.
    function setSinks(address[] calldata sinks_, uint16[] calldata bps_) external onlyGovernance {
        _setSinks(sinks_, bps_);
    }

    function setKeeperFund(address keeperFund_) external onlyGovernance {
        _setKeeperFund(keeperFund_);
    }

    function _setSinks(address[] memory sinks_, uint16[] memory bps_) internal {
        uint256 n = sinks_.length;
        if (n == 0 || n > MAX_SINKS || n != bps_.length) revert InvalidTable();
        uint256 old = _sinks.length;
        for (uint256 i; i < old; ++i) {
            delete owed[_sinks[i].sink];
        }
        delete _sinks;
        allocatedTotal = 0;
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address s = sinks_[i];
            if (s.code.length == 0) revert InvalidTable();
            for (uint256 j; j < i; ++j) {
                if (sinks_[j] == s) revert InvalidTable();
            }
            sum += bps_[i];
            _sinks.push(Sink(s, bps_[i]));
        }
        if (sum != BPS) revert InvalidTable();
        emit SinksSet(sinks_, bps_);
    }

    function _setKeeperFund(address keeperFund_) internal {
        if (keeperFund_ == address(0)) revert ZeroAddress();
        keeperFund = IKeeperFund(keeperFund_);
        emit KeeperFundSet(keeperFund_);
    }
}
