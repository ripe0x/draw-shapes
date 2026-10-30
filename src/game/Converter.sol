// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {IFWAPool} from "../interfaces/IFWA.sol";
import {IGenesisFarm, IEngineBuyer, IPricingPolicy, IShapePacks} from "../interfaces/IDrawShapes.sol";

interface IGameView {
    function pool() external view returns (IFWAPool);
    function buyer() external view returns (IEngineBuyer);
    function pricing() external view returns (IPricingPolicy);
    function poolOwner() external view returns (IPoolOwnerView);
}

interface IPoolOwnerView {
    function shapes() external view returns (IShapes);
    function packs() external view returns (IShapePacks);
}

interface IBuyerHook {
    function hook() external view returns (address);
}

interface IHookPolicy {
    function policy() external view returns (address);
}

interface IFeeView {
    function feeBps() external view returns (uint256);
}

/// @title Converter
/// @notice Prize conversion: the holder of a Shape or Shape Pack the game's FWA pool delivered turns it into ENGINE.
///         The Shape is burned (the Pack redeemed) for its backing, that ETH buys ENGINE through EngineBuyer (fee-exempt) for the
///         caller, and the conversion bonus is paid from the farm's bonus pool at the executed price.
/// @dev A module: it holds nothing between calls. The ETH that buys is exactly the burned Shape's backing: there is no
///      payable entry point, so no top-up, and EngineBuyer serves only registered callers, so this is no gateway for
///      public buys during the gate. A bonus pool that has run dry never stops a conversion (`allowNoBonus`). Delivery is read from FWA's own record: the listing must be
///      the game's pool's, `Settled` (delivered to its purchaser), and not converted before. Eligibility follows
///      the token, not the original winner. The bonus rate is the pricing policy's, capped at `MAX_BONUS_BPS`
///      and at the market's sell fee, so converting and selling never returns more than the prize's backing.
contract Converter is ReentrancyGuard {
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_BONUS_BPS = 500;

    IGameView public immutable game;
    IGenesisFarm public immutable farm;
    mapping(uint256 listingId => bool) public converted;
    uint256 public conversions;
    uint256 public totalEthIn; // redeemed backing spent buying ENGINE (player conversion purchases)
    uint256 public totalEngineOut;
    uint256 public totalBonus;

    event Converted(
        address indexed holder,
        uint256 indexed listingId,
        address collection,
        uint256 tokenId,
        uint256 backing,
        uint256 engineOut,
        uint256 bonus
    );

    error NotConvertible();
    error BonusUnavailable();

    constructor(address game_, address farm_) {
        game = IGameView(game_);
        farm = IGenesisFarm(farm_);
    }

    receive() external payable {}

    /// @notice True when FWA delivered listing `listingId` of the game's pool and it has not been converted.
    function convertible(uint256 listingId) public view returns (bool ok, address collection, uint256 tokenId) {
        IFWAPool pool = game.pool();
        if (address(pool) == address(0) || converted[listingId]) return (false, address(0), 0);
        IFWAPool.ListingStatus st;
        (collection,,, tokenId,,,, st) = pool.listings(listingId);
        IPoolOwnerView po = game.poolOwner();
        ok = st == IFWAPool.ListingStatus.Settled
            && (collection == address(po.shapes()) || collection == address(po.packs()));
    }

    /// @notice Converts the prize of delivered listing `listingId`, held by the caller, into ENGINE. Reverts if the
    ///         bonus pool cannot cover the bonus unless `allowNoBonus`, in which case whatever it holds is paid.
    function convert(uint256 listingId, uint256 minEngineOut, bool allowNoBonus)
        external
        nonReentrant
        returns (uint256 engineOut, uint256 bonus)
    {
        (bool ok, address collection, uint256 tokenId) = convertible(listingId);
        if (!ok) revert NotConvertible();
        converted[listingId] = true;
        IShapes(collection).transferFrom(msg.sender, address(this), tokenId);
        uint256 before = address(this).balance;
        if (collection == address(game.poolOwner().packs())) IShapePacks(collection).redeemTo(tokenId, payable(this));
        else IShapes(collection).burn(tokenId);
        uint256 value = address(this).balance - before;
        uint256 spent;
        (engineOut, spent) = game.buyer().buy{value: value}(minEngineOut, msg.sender, BPS);
        if (spent < value) SafeTransferLib.forceSafeTransferETH(msg.sender, value - spent);
        bonus = engineOut * bonusBps() / BPS;
        if (bonus != 0) {
            if (farm.bonusPool() < bonus && !allowNoBonus) revert BonusUnavailable();
            bonus = farm.payBonus(msg.sender, bonus);
        }
        ++conversions;
        totalEthIn += spent;
        totalEngineOut += engineOut;
        totalBonus += bonus;
        emit Converted(msg.sender, listingId, collection, tokenId, value, engineOut, bonus);
    }

    /// @notice The bonus rate in force.
    function bonusBps() public view returns (uint256 bps) {
        bps = game.pricing().conversionBonusBps();
        if (bps > MAX_BONUS_BPS) bps = MAX_BONUS_BPS;
        uint256 sellFee = IFeeView(IHookPolicy(IBuyerHook(address(game.buyer())).hook()).policy()).feeBps();
        if (bps > sellFee) bps = sellFee;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
