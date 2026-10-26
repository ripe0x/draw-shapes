// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Governed} from "../Governed.sol";
import {ITreasury, IKeeperFund, IEngineBuyer, IGenesisFarm, IFwaGame, IBurnable} from "../interfaces/IDrawShapes.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Base of a Treasury sink: draws its allocation from the Treasury and spends it in the same call.
///         A sink holds no ETH between calls; anything unspent goes back to the Treasury.
abstract contract TreasurySink is Governed, ReentrancyGuard {
    ITreasury public immutable treasury;
    IKeeperFund public immutable keeperFund;
    uint256 public lastRunAt;

    error NoWork();

    constructor(address governance_, address treasury_, address keeperFund_) Governed(governance_, false) {
        if (treasury_ == address(0) || keeperFund_ == address(0)) revert ZeroAddress();
        treasury = ITreasury(treasury_);
        keeperFund = IKeeperFund(keeperFund_);
        lastRunAt = block.timestamp;
    }

    receive() external payable {}

    /// @dev Returns any ETH left in the sink to the Treasury and tips the caller.
    function _finish(uint256 gasStart) internal {
        uint256 left = address(this).balance;
        if (left != 0) SafeTransferLib.forceSafeTransferETH(address(treasury), left);
        uint256 age = block.timestamp - lastRunAt;
        lastRunAt = block.timestamp;
        keeperFund.tip(msg.sender, gasStart - gasleft(), age);
    }
}

/// @notice Buys ENGINE with Treasury ETH in slices through EngineBuyer. `sliceWei` per call, at most one
///         call per `minSpacing`, price impact capped at `maxImpactBps`.
abstract contract BuybackSink is TreasurySink {
    uint256 public constant MAX_SLICE = 10 ether;
    uint256 public constant MAX_SPACING = 1 days;
    uint256 public constant MAX_IMPACT_BPS = 2_000;

    address public immutable engine;
    IEngineBuyer public buyer;
    uint256 public sliceWei;
    uint256 public minSpacing;
    uint256 public maxImpactBps;
    uint256 public totalSpent;
    uint256 public totalBought;

    event Bought(uint256 ethSpent, uint256 engineOut);
    event ParamsSet(uint256 sliceWei, uint256 minSpacing, uint256 maxImpactBps);
    event BuyerSet(address buyer);

    error TooSoon();
    error InsufficientOutput();

    constructor(
        address governance_,
        address treasury_,
        address keeperFund_,
        address engine_,
        address buyer_,
        uint256 sliceWei_,
        uint256 minSpacing_,
        uint256 maxImpactBps_
    ) TreasurySink(governance_, treasury_, keeperFund_) {
        if (engine_ == address(0)) revert ZeroAddress();
        engine = engine_;
        _setBuyer(buyer_);
        _setParams(sliceWei_, minSpacing_, maxImpactBps_);
        lastRunAt = 0;
    }

    /// @notice Buys one slice of ENGINE and uses it (burn or farm deposit). Anyone may call; tipped.
    function process(uint256 minOut) external nonReentrant returns (uint256 out) {
        uint256 gasStart = gasleft();
        if (block.timestamp < lastRunAt + minSpacing) revert TooSoon();
        uint256 amount = treasury.owed(address(this));
        if (amount > sliceWei) amount = sliceWei;
        if (amount == 0) revert NoWork();
        treasury.draw(amount);
        uint256 spent;
        (out, spent) = buyer.buy{value: amount}(minOut, address(this), maxImpactBps);
        if (out < minOut || out == 0) revert InsufficientOutput();
        totalSpent += spent;
        totalBought += out;
        emit Bought(spent, out);
        _use(out);
        _finish(gasStart);
    }

    function _use(uint256 amount) internal virtual;

    function setParams(uint256 sliceWei_, uint256 minSpacing_, uint256 maxImpactBps_) external onlyGovernance {
        _setParams(sliceWei_, minSpacing_, maxImpactBps_);
    }

    function setBuyer(address buyer_) external onlyGovernance {
        _setBuyer(buyer_);
    }

    function _setParams(uint256 sliceWei_, uint256 minSpacing_, uint256 maxImpactBps_) internal {
        if (sliceWei_ == 0 || sliceWei_ > MAX_SLICE || minSpacing_ > MAX_SPACING || maxImpactBps_ == 0
            || maxImpactBps_ > MAX_IMPACT_BPS) revert OutOfBounds();
        sliceWei = sliceWei_;
        minSpacing = minSpacing_;
        maxImpactBps = maxImpactBps_;
        emit ParamsSet(sliceWei_, minSpacing_, maxImpactBps_);
    }

    function _setBuyer(address buyer_) internal {
        if (buyer_ == address(0)) revert ZeroAddress();
        buyer = IEngineBuyer(buyer_);
        emit BuyerSet(buyer_);
    }
}

/// @title BuybackBurn
/// @notice Treasury sink: buys ENGINE and burns it.
contract BuybackBurn is BuybackSink {
    constructor(
        address governance_,
        address treasury_,
        address keeperFund_,
        address engine_,
        address buyer_,
        uint256 sliceWei_,
        uint256 minSpacing_,
        uint256 maxImpactBps_
    ) BuybackSink(governance_, treasury_, keeperFund_, engine_, buyer_, sliceWei_, minSpacing_, maxImpactBps_) {}

    function _use(uint256 amount) internal override {
        IBurnable(engine).burn(amount);
    }
}

/// @title BuybackReward
/// @notice Treasury sink: buys ENGINE and deposits it into the farm's current epoch, paid to that epoch's
///         players pro rata to their pulls.
contract BuybackReward is BuybackSink {
    IGenesisFarm public immutable farm;

    constructor(
        address governance_,
        address treasury_,
        address keeperFund_,
        address engine_,
        address buyer_,
        address farm_,
        uint256 sliceWei_,
        uint256 minSpacing_,
        uint256 maxImpactBps_
    ) BuybackSink(governance_, treasury_, keeperFund_, engine_, buyer_, sliceWei_, minSpacing_, maxImpactBps_) {
        if (farm_ == address(0)) revert ZeroAddress();
        farm = IGenesisFarm(farm_);
    }

    function _use(uint256 amount) internal override {
        SafeTransferLib.safeApprove(engine, address(farm), amount);
        farm.deposit(amount);
    }
}

/// @title GrailFund
/// @notice Treasury sink: forwards its allocation to the active game's GRAIL reserve.
contract GrailFund is TreasurySink {
    IFwaGame public game;

    event Forwarded(address indexed game, uint256 amount);
    event GameSet(address game);

    constructor(address governance_, address treasury_, address keeperFund_, address game_)
        TreasurySink(governance_, treasury_, keeperFund_)
    {
        _setGame(game_);
    }

    function process() external nonReentrant returns (uint256 amount) {
        uint256 gasStart = gasleft();
        amount = treasury.owed(address(this));
        if (amount == 0) revert NoWork();
        treasury.draw(amount);
        game.fundGrail{value: amount}();
        emit Forwarded(address(game), amount);
        _finish(gasStart);
    }

    function setGame(address game_) external onlyGovernance {
        _setGame(game_);
    }

    function _setGame(address game_) internal {
        if (game_ == address(0)) revert ZeroAddress();
        game = IFwaGame(game_);
        emit GameSet(game_);
    }
}
