// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Governed} from "../Governed.sol";
import {ISwapPolicy, IGenesisFarm} from "../interfaces/IDrawShapes.sol";

interface ILaunched {
    function launchedAt() external view returns (uint64);
}

/// @title SwapPolicy
/// @notice Launch policy of the ENGINE hook. Fee `feeBps` on every swap; exempt senders (EngineBuyer, which serves
///         the Converter and the Buyback, and ProtocolLiquidity) pay nothing and pass the gate. From game open to
///         genesis end a buy from anyone else is refused (the gate reads the farm's clock). For `snipeWindow` seconds
///         after the pool opens, buys pay an extra fee that decays linearly from `snipeStartBps` to zero.
/// @dev A module: views only. The hook enforces its own caps and never lets a policy block a sell. The hook sees as
///      `sender` whoever called `PoolManager.swap`: for a public router (the Universal Router, any aggregator) that
///      is the router, shared by everyone. Exempting one would open the gate to all its users, so the exempt set is
///      fixed at wiring (EngineBuyer, which serves only registered callers, and ProtocolLiquidity) and has no setter;
///      a different set needs a new policy (`EngineHook.setPolicy`, timelock).
contract SwapPolicy is ISwapPolicy, Governed {
    uint256 public constant MAX_FEE_BPS = 500;
    uint256 public constant MAX_SNIPE_BPS = 9_000;
    uint256 public constant MAX_SNIPE_WINDOW = 3 hours;

    IGenesisFarm public immutable farm;
    address public hook;
    uint256 public feeBps;
    uint256 public snipeStartBps;
    uint256 public snipeWindow;
    mapping(address => bool) public exempt;

    event FeeSet(uint256 feeBps);
    event SnipeSet(uint256 startBps, uint256 window);
    event ExemptSet(address indexed account, bool exempt);
    event HookSet(address hook);

    constructor(address governance_, address farm_, uint256 feeBps_, uint256 snipeStartBps_, uint256 snipeWindow_)
        Governed(governance_, true)
    {
        if (farm_ == address(0)) revert ZeroAddress();
        farm = IGenesisFarm(farm_);
        _setFee(feeBps_);
        _setSnipe(snipeStartBps_, snipeWindow_);
    }

    /// @notice One-shot wiring by the deployer: the hook (for its launch time) and the exempt senders.
    function wire(address hook_, address[] calldata exempt_) external onlyWiring {
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookSet(hook_);
        for (uint256 i; i < exempt_.length; ++i) {
            _setExempt(exempt_[i], true);
        }
    }

    /// @notice True while public buys are closed: from game open until genesis end.
    function gated() public view returns (bool) {
        uint256 open = farm.openBlock();
        return open != 0 && block.number < farm.genesisEndBlock();
    }

    /// @notice Extra buy fee now, in bps.
    function snipeFeeBps() public view returns (uint256) {
        if (hook == address(0) || snipeWindow == 0) return 0;
        uint256 t0 = ILaunched(hook).launchedAt();
        if (t0 == 0 || block.timestamp >= t0 + snipeWindow) return 0;
        return snipeStartBps * (t0 + snipeWindow - block.timestamp) / snipeWindow;
    }

    /// @inheritdoc ISwapPolicy
    function check(address sender, bool isBuy) external view returns (bool allowed, uint256 fee) {
        if (exempt[sender]) return (true, 0);
        if (!isBuy) return (true, feeBps);
        if (gated()) return (false, 0);
        return (true, feeBps + snipeFeeBps());
    }

    function setFee(uint256 feeBps_) external onlyGovernance {
        _setFee(feeBps_);
    }

    function setSnipe(uint256 startBps, uint256 window) external onlyGovernance {
        _setSnipe(startBps, window);
    }

    function _setFee(uint256 feeBps_) internal {
        if (feeBps_ > MAX_FEE_BPS) revert OutOfBounds();
        feeBps = feeBps_;
        emit FeeSet(feeBps_);
    }

    function _setSnipe(uint256 startBps, uint256 window) internal {
        if (startBps > MAX_SNIPE_BPS || window > MAX_SNIPE_WINDOW) revert OutOfBounds();
        snipeStartBps = startBps;
        snipeWindow = window;
        emit SnipeSet(startBps, window);
    }

    function _setExempt(address account, bool isExempt) internal {
        if (account == address(0)) revert ZeroAddress();
        exempt[account] = isExempt;
        emit ExemptSet(account, isExempt);
    }
}
