// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Governed} from "../Governed.sol";
import {IFwaGame, IProtocolLiquidity} from "../interfaces/IDrawShapes.sol";

/// @title PrizeVault
/// @notice Holds the game's capital: the opening capital, every ENGINE trading fee (the hook pays it here, through the
///         PoolManager), contributions, and what a game returns. It sends ETH only to the active game, as capital
///         (`fund`, anyone) or as a promotion budget (`fundPromotion`, timelock), and, once no game is active and the
///         last one has returned everything, to the ENGINE liquidity position (`shutdown`, anyone, after
///         `shutdownDelay`). There is no withdraw. Each source is counted separately; none of it is profit.
contract PrizeVault is ReentrancyGuard, Governed {
    uint256 public constant MIN_SHUTDOWN_DELAY = 1 days;
    uint256 public constant MAX_SHUTDOWN_DELAY = 365 days;

    IProtocolLiquidity public immutable liquidity;
    address public immutable poolManager;
    address public activeGame;
    bool public retiring;
    uint256 public returnedAt;
    uint256 public shutdownDelay;
    uint256 public totalFunded;
    uint256 public totalRepaid;
    uint256 public tradingFees;
    uint256 public contributions;
    uint256 public promotionsFunded;
    /// @notice Most ETH the vault may ever send KeeperFund (D48): enough to pay for listing the opening board at high
    ///         gas; after it, keepers live on the operating allocation.
    uint256 public constant KEEPER_TOP_UP_LIMIT = 1 ether;
    uint256 public constant MAX_KEEPER_TOP_UP_TARGET = 0.5 ether;
    address public keeperFund;
    uint256 public keeperTopUpTarget; // KeeperFund is refilled to its floor plus this
    uint256 public keeperTopUps; // total sent to KeeperFund
    uint256 public keeperReturned; // total KeeperFund sent back

    event GameActivated(address indexed game);
    event Funded(address indexed game, uint256 amount);
    event RetireStarted(address indexed game);
    event Repaid(address indexed game, uint256 amount, bool final_);
    event Shutdown(uint256 amount);
    event ShutdownDelaySet(uint256 delay);
    event PromotionFunded(address indexed game, uint256 amount);

    error GameActive();
    error NoActiveGame();
    error NotGame();
    error NotReady();
    error NothingToSend();

    constructor(address governance_, address liquidity_, address poolManager_, uint256 shutdownDelay_)
        Governed(governance_, true)
    {
        if (liquidity_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        liquidity = IProtocolLiquidity(liquidity_);
        poolManager = poolManager_;
        _setShutdownDelay(shutdownDelay_);
    }

    /// @dev Trading fees arrive from the PoolManager in the middle of every swap; kept cheap.
    receive() external payable {
        if (msg.sender == poolManager) tradingFees += msg.value;
        else if (msg.sender == keeperFund) keeperReturned += msg.value;
        else contributions += msg.value;
    }

    /// @notice One-shot wiring by the deployer: the first game.
    function wire(address game, address keeperFund_, uint256 keeperTopUpTarget_) external onlyWiring {
        if (keeperFund_ == address(0)) revert ZeroAddress();
        keeperFund = keeperFund_;
        _setKeeperTopUpTarget(keeperTopUpTarget_);
        _activate(game);
    }

    /// @notice Registers the game the vault funds. Only when no game is active.
    function setActiveGame(address game) external onlyGovernance {
        _activate(game);
    }

    function _activate(address game) internal {
        if (activeGame != address(0)) revert GameActive();
        if (game.code.length == 0) revert ZeroAddress();
        activeGame = game;
        retiring = false;
        returnedAt = 0;
        emit GameActivated(game);
    }

    /// @notice Sends the whole balance to the active game. Anyone may call.
    function fund() external nonReentrant {
        address game = activeGame;
        if (game == address(0) || retiring) revert NoActiveGame();
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToSend();
        totalFunded += amount;
        IFwaGame(game).receiveFunding{value: amount}();
        emit Funded(game, amount);
    }

    /// @notice Refills KeeperFund to its maintenance floor plus `keeperTopUpTarget` from the vault's balance (trading
    ///         fees, contributions), within `KEEPER_TOP_UP_LIMIT` over the vault's life. Anyone may call; the game calls
    ///         it in every sync. KeeperFund returns top-ups to the vault before any overflow reaches the game, so this
    ///         capital never becomes game profit.
    function topUpKeeper() external nonReentrant returns (uint256 amount) {
        IKeeperFundView kf = IKeeperFundView(keeperFund);
        uint256 have = keeperFund.balance - kf.tipCreditTotal();
        uint256 target = kf.maintenanceFloor() + keeperTopUpTarget;
        if (have >= target) return 0;
        amount = target - have;
        uint256 left = KEEPER_TOP_UP_LIMIT - keeperTopUps;
        if (amount > left) amount = left;
        if (amount > address(this).balance) amount = address(this).balance;
        if (amount == 0) return 0;
        keeperTopUps += amount;
        kf.topUp{value: amount}();
    }

    function setKeeperTopUpTarget(uint256 target) external onlyGovernance {
        _setKeeperTopUpTarget(target);
    }

    function _setKeeperTopUpTarget(uint256 target) internal {
        if (target > MAX_KEEPER_TOP_UP_TARGET) revert OutOfBounds();
        keeperTopUpTarget = target;
    }

    /// @notice Sends `amount` to the active game's promotion budget. Promotions are funded explicitly, never from profit.
    function fundPromotion(uint256 amount) external onlyGovernance nonReentrant {
        address game = activeGame;
        if (game == address(0) || retiring) revert NoActiveGame();
        promotionsFunded += amount;
        IFwaGame(game).fundPromotion{value: amount}();
        emit PromotionFunded(game, amount);
    }

    /// @notice Starts retiring the active game; its retire path returns everything here.
    function retireGame() external onlyGovernance {
        address game = activeGame;
        if (game == address(0) || retiring) revert NoActiveGame();
        retiring = true;
        IFwaGame(game).retire();
        emit RetireStarted(game);
    }

    /// @notice The active game returns funds. `final_` (only while retiring) closes the game.
    function repay(bool final_) external payable {
        if (msg.sender != activeGame) revert NotGame();
        totalRepaid += msg.value;
        emit Repaid(msg.sender, msg.value, final_);
        if (final_ && retiring) {
            activeGame = address(0);
            retiring = false;
            returnedAt = block.timestamp;
        }
    }

    /// @notice With no game active, after the last game returned and `shutdownDelay` passed, moves the whole
    ///         balance into the protocol-owned ENGINE liquidity. Anyone may call.
    function shutdown(uint160 minSqrtPriceX96) external nonReentrant {
        if (activeGame != address(0) || returnedAt == 0 || block.timestamp < returnedAt + shutdownDelay) {
            revert NotReady();
        }
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToSend();
        liquidity.addLiquidity{value: amount}(minSqrtPriceX96);
        emit Shutdown(amount);
    }

    function setShutdownDelay(uint256 delay) external onlyGovernance {
        _setShutdownDelay(delay);
    }

    function _setShutdownDelay(uint256 delay) internal {
        if (delay < MIN_SHUTDOWN_DELAY || delay > MAX_SHUTDOWN_DELAY) revert OutOfBounds();
        shutdownDelay = delay;
        emit ShutdownDelaySet(delay);
    }
}

interface IKeeperFundView {
    function tipCreditTotal() external view returns (uint256);
    function maintenanceFloor() external view returns (uint256);
    function topUp() external payable;
}
