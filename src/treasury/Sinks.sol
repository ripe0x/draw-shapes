// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Governed} from "../Governed.sol";
import {ITreasury, IKeeperFund, IEngineBuyer, IGenesisFarm, IFwaGame, IBurnable} from "../interfaces/IDrawShapes.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Base of a Treasury sink: draws its allocation from the Treasury and spends it in the same call.
///         Its allocation waits in the Treasury between calls; anything unspent goes back to the Treasury.
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

    /// @dev Returns any ETH left in the sink to the Treasury and tips the caller for one unit of work.
    function _finish(uint256 gasStart) internal {
        uint256 left = address(this).balance;
        if (left != 0) SafeTransferLib.forceSafeTransferETH(address(treasury), left);
        uint256 age = block.timestamp - lastRunAt;
        lastRunAt = block.timestamp;
        keeperFund.tip(msg.sender, gasStart - gasleft(), age, 1, false);
    }
}

/// @title Buyback
/// @notice Treasury sink: buys ENGINE with its allocation in slices through EngineBuyer (one purchase per call, at
///         most one call per `minSpacing`, price impact capped at `maxImpactBps`), then burns `burnShareBps` of
///         what it bought and deposits the rest into the farm's current epoch, paid to that epoch's players.
/// @dev The slice is `min(sliceWei, max(owed / 4, MIN_SLICE))`, so a small allocation is spent over a few calls
///      rather than in one. Rewards are an incentive to play now, not compensation for past revenue.
contract Buyback is TreasurySink {
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_SLICE = 10 ether;
    uint256 public constant MIN_SLICE = 0.005 ether;
    uint256 public constant MAX_SPACING = 1 days;
    uint256 public constant MAX_IMPACT_BPS = 2_000;

    address public immutable engine;
    IGenesisFarm public immutable farm;
    IEngineBuyer public buyer;
    uint256 public sliceWei;
    uint256 public minSpacing;
    uint256 public maxImpactBps;
    uint256 public burnShareBps;
    uint256 public totalSpent;
    uint256 public totalBurned;
    uint256 public totalDeposited;

    event Bought(uint256 ethSpent, uint256 engineOut, uint256 burned, uint256 deposited);
    event ParamsSet(uint256 sliceWei, uint256 minSpacing, uint256 maxImpactBps, uint256 burnShareBps);
    event BuyerSet(address buyer);

    error TooSoon();
    error InsufficientOutput();

    constructor(
        address governance_,
        address treasury_,
        address keeperFund_,
        address engine_,
        address buyer_,
        address farm_,
        uint256 sliceWei_,
        uint256 minSpacing_,
        uint256 maxImpactBps_,
        uint256 burnShareBps_
    ) TreasurySink(governance_, treasury_, keeperFund_) {
        if (engine_ == address(0) || farm_ == address(0)) revert ZeroAddress();
        engine = engine_;
        farm = IGenesisFarm(farm_);
        _setBuyer(buyer_);
        _setParams(sliceWei_, minSpacing_, maxImpactBps_, burnShareBps_);
        lastRunAt = 0;
    }

    /// @notice The slice the next `process` would spend.
    function nextSlice() public view returns (uint256 amount) {
        uint256 owed = treasury.owed(address(this));
        amount = owed / 4;
        if (amount < MIN_SLICE) amount = owed < MIN_SLICE ? owed : MIN_SLICE;
        if (amount > sliceWei) amount = sliceWei;
    }

    /// @notice Buys one slice of ENGINE, burns the burn share and deposits the rest. Anyone may call; tipped.
    function process(uint256 minOut) external nonReentrant returns (uint256 out) {
        uint256 gasStart = gasleft();
        if (block.timestamp < lastRunAt + minSpacing) revert TooSoon();
        uint256 amount = nextSlice();
        if (amount == 0) revert NoWork();
        treasury.draw(amount);
        uint256 spent;
        (out, spent) = buyer.buy{value: amount}(minOut, address(this), maxImpactBps);
        if (out < minOut || out == 0) revert InsufficientOutput();
        uint256 burned = out * burnShareBps / BPS;
        uint256 deposited = out - burned;
        totalSpent += spent;
        totalBurned += burned;
        totalDeposited += deposited;
        if (burned != 0) IBurnable(engine).burn(burned);
        if (deposited != 0) {
            SafeTransferLib.safeApprove(engine, address(farm), deposited);
            farm.deposit(deposited);
        }
        emit Bought(spent, out, burned, deposited);
        _finish(gasStart);
    }

    function setParams(uint256 sliceWei_, uint256 minSpacing_, uint256 maxImpactBps_, uint256 burnShareBps_)
        external
        onlyGovernance
    {
        _setParams(sliceWei_, minSpacing_, maxImpactBps_, burnShareBps_);
    }

    function setBuyer(address buyer_) external onlyGovernance {
        _setBuyer(buyer_);
    }

    function _setParams(uint256 sliceWei_, uint256 minSpacing_, uint256 maxImpactBps_, uint256 burnShareBps_)
        internal
    {
        if (
            sliceWei_ < MIN_SLICE || sliceWei_ > MAX_SLICE || minSpacing_ > MAX_SPACING || maxImpactBps_ == 0
                || maxImpactBps_ > MAX_IMPACT_BPS || burnShareBps_ > BPS
        ) revert OutOfBounds();
        sliceWei = sliceWei_;
        minSpacing = minSpacing_;
        maxImpactBps = maxImpactBps_;
        burnShareBps = burnShareBps_;
        emit ParamsSet(sliceWei_, minSpacing_, maxImpactBps_, burnShareBps_);
    }

    function _setBuyer(address buyer_) internal {
        if (buyer_ == address(0)) revert ZeroAddress();
        buyer = IEngineBuyer(buyer_);
        emit BuyerSet(buyer_);
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
