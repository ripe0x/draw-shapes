// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Governed} from "../Governed.sol";
import {IKeeperFund, IEngineBuyer, IBurnable} from "../interfaces/IDrawShapes.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";

interface IPriceRef {
    function blockOpenPrice() external view returns (uint160 open, uint160 current);
}

/// @title Buyback
/// @notice Spends the game's distributed profit buying ENGINE and burns every token it buys. It receives ETH only as
///         profit from a registered source (the game) and returns of unspent ETH from EngineBuyer. One purchase per
///         call, at most one call per `minSpacing`, of at most `sliceWei`. Two price limits hold whatever `minOut`
///         the caller passes: the purchase may move the price at most `maxImpactBps`, and it does not start when
///         the price has already moved more than `maxDeviationBps` against the buyer since the block opened (the
///         hook records the opening price), which defeats a same-block sandwich.
/// @dev No sink table and no other outflow: ENGINE is burned in the same call, unspent ETH stays for the next call.
contract Buyback is Governed, ReentrancyGuard {
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_SLICE = 10 ether;
    uint256 public constant MAX_SPACING = 1 days;
    uint256 public constant MAX_IMPACT_BPS = 2_000;
    uint256 public constant MAX_DEVIATION_BPS = 2_000;

    address public immutable engine;
    IKeeperFund public immutable keeperFund;
    IEngineBuyer public buyer;
    mapping(address => bool) public isSource;
    uint256 public sliceWei;
    uint256 public minSpacing;
    uint256 public maxImpactBps;
    uint256 public maxDeviationBps;
    uint256 public lastRunAt;
    uint256 public profitReceived;
    uint256 public totalSpent;
    uint256 public totalBurned;
    uint256 public purchases;

    event ProfitReceived(address indexed source, uint256 amount);
    event Bought(uint256 ethSpent, uint256 engineBurned);
    event ParamsSet(uint256 sliceWei, uint256 minSpacing, uint256 maxImpactBps, uint256 maxDeviationBps);
    event BuyerSet(address buyer);
    event SourceSet(address indexed source, bool allowed);

    error NoWork();
    error TooSoon();
    error PriceMoved();
    error InsufficientOutput();
    error NotAccepted();

    constructor(
        address governance_,
        address keeperFund_,
        address engine_,
        address buyer_,
        uint256 sliceWei_,
        uint256 minSpacing_,
        uint256 maxImpactBps_,
        uint256 maxDeviationBps_
    ) Governed(governance_, true) {
        if (engine_ == address(0) || keeperFund_ == address(0)) revert ZeroAddress();
        engine = engine_;
        keeperFund = IKeeperFund(keeperFund_);
        _setBuyer(buyer_);
        _setParams(sliceWei_, minSpacing_, maxImpactBps_, maxDeviationBps_);
    }

    /// @notice One-shot wiring by the deployer: the profit source (the game).
    function wire(address source) external onlyWiring {
        _setSource(source, true);
    }

    /// @notice Profit from a registered source, or unspent ETH returned by the buyer. Nothing else.
    receive() external payable {
        if (isSource[msg.sender]) {
            profitReceived += msg.value;
            emit ProfitReceived(msg.sender, msg.value);
        } else if (msg.sender != address(buyer)) {
            revert NotAccepted();
        }
    }

    /// @notice The slice the next `process` would spend: everything held, up to `sliceWei`.
    function nextSlice() public view returns (uint256) {
        uint256 bal = address(this).balance;
        return bal < sliceWei ? bal : sliceWei;
    }

    /// @notice False when the price has moved more than `maxDeviationBps` against the buyer since the block opened.
    function priceOk() public view returns (bool) {
        (uint160 open, uint160 current) = IPriceRef(buyer.hook()).blockOpenPrice();
        // ENGINE per ETH falls when someone buys ENGINE ahead of us.
        uint256 floor = uint256(open) * FPM.sqrt((BPS - maxDeviationBps) * 1e18 / BPS) / 1e9;
        return current >= floor;
    }

    /// @notice Buys one slice of ENGINE and burns all of it. Anyone may call; tipped. `minOut` can only tighten the
    ///         contract's own limits.
    function process(uint256 minOut) external nonReentrant returns (uint256 out) {
        uint256 gasStart = gasleft();
        if (block.timestamp < lastRunAt + minSpacing) revert TooSoon();
        uint256 amount = nextSlice();
        if (amount == 0) revert NoWork();
        if (!priceOk()) revert PriceMoved();
        uint256 spent;
        (out, spent) = buyer.buy{value: amount}(minOut, address(this), maxImpactBps);
        if (out == 0) revert InsufficientOutput();
        totalSpent += spent;
        totalBurned += out;
        ++purchases;
        IBurnable(engine).burn(out);
        emit Bought(spent, out);
        lastRunAt = block.timestamp;
        keeperFund.tip(msg.sender, gasStart - gasleft(), 1, false);
    }

    function setParams(uint256 sliceWei_, uint256 minSpacing_, uint256 maxImpactBps_, uint256 maxDeviationBps_)
        external
        onlyGovernance
    {
        _setParams(sliceWei_, minSpacing_, maxImpactBps_, maxDeviationBps_);
    }

    function setBuyer(address buyer_) external onlyGovernance {
        _setBuyer(buyer_);
    }

    /// @notice Registers a profit source (a new game after a retirement).
    function setSource(address source, bool allowed) external onlyGovernance {
        _setSource(source, allowed);
    }

    function _setParams(uint256 sliceWei_, uint256 minSpacing_, uint256 maxImpactBps_, uint256 maxDeviationBps_)
        internal
    {
        if (
            sliceWei_ == 0 || sliceWei_ > MAX_SLICE || minSpacing_ > MAX_SPACING || maxImpactBps_ == 0
                || maxImpactBps_ > MAX_IMPACT_BPS || maxDeviationBps_ == 0 || maxDeviationBps_ > MAX_DEVIATION_BPS
        ) revert OutOfBounds();
        sliceWei = sliceWei_;
        minSpacing = minSpacing_;
        maxImpactBps = maxImpactBps_;
        maxDeviationBps = maxDeviationBps_;
        emit ParamsSet(sliceWei_, minSpacing_, maxImpactBps_, maxDeviationBps_);
    }

    function _setBuyer(address buyer_) internal {
        if (buyer_ == address(0)) revert ZeroAddress();
        buyer = IEngineBuyer(buyer_);
        emit BuyerSet(buyer_);
    }

    function _setSource(address source, bool allowed) internal {
        if (source == address(0)) revert ZeroAddress();
        isSource[source] = allowed;
        emit SourceSet(source, allowed);
    }
}
