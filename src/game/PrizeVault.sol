// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Governed} from "../Governed.sol";
import {IFwaGame, IProtocolLiquidity} from "../interfaces/IDrawShapes.sol";

/// @title PrizeVault
/// @notice Holds the game's ETH. It sends it only to the active game (`fund`, anyone) and, once no game is
///         active and the last one has returned everything, to the ENGINE liquidity position (`shutdown`,
///         anyone, after `shutdownDelay`). There is no withdraw.
contract PrizeVault is ReentrancyGuard, Governed {
    uint256 public constant MIN_SHUTDOWN_DELAY = 1 days;
    uint256 public constant MAX_SHUTDOWN_DELAY = 365 days;

    IProtocolLiquidity public immutable liquidity;
    address public activeGame;
    bool public retiring;
    uint256 public returnedAt;
    uint256 public shutdownDelay;
    uint256 public totalFunded;
    uint256 public totalRepaid;

    event GameActivated(address indexed game);
    event Funded(address indexed game, uint256 amount);
    event RetireStarted(address indexed game);
    event Repaid(address indexed game, uint256 amount, bool final_);
    event Shutdown(uint256 amount);
    event ShutdownDelaySet(uint256 delay);

    error GameActive();
    error NoActiveGame();
    error NotGame();
    error NotReady();
    error NothingToSend();

    constructor(address governance_, address liquidity_, uint256 shutdownDelay_) Governed(governance_, true) {
        if (liquidity_ == address(0)) revert ZeroAddress();
        liquidity = IProtocolLiquidity(liquidity_);
        _setShutdownDelay(shutdownDelay_);
    }

    receive() external payable {}

    /// @notice One-shot wiring by the deployer: the first game.
    function wire(address game) external onlyWiring {
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
