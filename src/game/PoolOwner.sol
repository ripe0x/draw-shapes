// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {Governed} from "../Governed.sol";
import {IFWAPool, IFWAFactory, FWA_ACQUISITIONS_ENABLED} from "../interfaces/IFWA.sol";
import {IFwaGame, IPoolOwner, IShapePacks, IBurnable} from "../interfaces/IDrawShapes.sol";

/// @title PoolOwner
/// @notice Creates and permanently owns the Draw Shapes FWA V2 pool and holds its prizes. On the game's instruction it
///         mints Shapes and Shape Packs with the game's ETH and lists them in the same call, withdraws or recovers
///         prizes and turns them back into ETH (a Shape burned, a Pack redeemed), collects FWA's owner proceeds, and
///         switches purchases. Every ETH it receives goes to the game. It is also FWA's purchase operator:
///         `canPurchase` admits a purchase only while live FWA state leaves the board safe (D45), whether or not
///         anyone has synced, and whether the purchase came through our site or FWA's.
/// @dev No module, no generic execute and no withdraw. ETH leaves only to Shapes and Packs (exactly the mint cost the
///      game paid) and to the game. NFTs leave only to FWA (listing) and are otherwise burned or redeemed.
contract PoolOwner is IPoolOwner, ReentrancyGuard, Governed {
    uint8 internal constant KIND_PACK = 1;
    uint256 public constant MAX_IN_FLIGHT = 20;

    IShapes public immutable shapes;
    IShapePacks public immutable packs;
    IFWAFactory public immutable factory;
    address public immutable expectedImplementation;
    IFwaGame public game;
    address public pool;

    // purchase gate (set by the game)
    uint256 public maxInFlight;
    uint256 public maxEdgeBps;
    uint256 public maxCooldown;
    uint256 public minListed;
    /// @notice Most requests one FWA purchase can open (FWA's `maxAcquisitionsPerTx`, read at creation): `canPurchase`
    ///         is asked once per transaction and is not told the batch size, so it assumes a full batch.
    uint256 public maxBatch;

    event PoolCreated(address pool, uint256 creationFee);
    event GateSet(uint256 maxInFlight, uint256 maxEdgeBps, uint256 maxCooldown, uint256 minListed);

    error NotGame();
    error PoolExists();
    error BadPayment();

    constructor(address governance_, address shapes_, address packs_, address factory_, address implementation_)
        Governed(governance_, true)
    {
        if (shapes_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        shapes = IShapes(shapes_);
        packs = IShapePacks(packs_);
        factory = IFWAFactory(factory_);
        expectedImplementation = implementation_;
    }

    /// @notice One-shot wiring by the deployer: the game this contract serves.
    function wire(address game_) external onlyWiring {
        if (game_.code.length == 0) revert ZeroAddress();
        game = IFwaGame(game_);
    }

    modifier onlyGame() {
        if (msg.sender != address(game)) revert NotGame();
        _;
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ pool

    /// @notice Creates the FWA pool, paying the factory's FWA creation fee from FWA this contract holds (D4), becomes
    ///         its purchase operator and approves it for Shapes and Packs. Once; anyone. Leftover FWA is burned.
    function createPool(bytes32 salt) external nonReentrant returns (address created) {
        if (pool != address(0)) revert PoolExists();
        address fwa = factory.fwaToken();
        uint256 fee = factory.poolCreationFee();
        SafeTransferLib.safeApprove(fwa, address(factory), fee);
        created = factory.createPool(salt, fee, expectedImplementation);
        pool = created;
        maxBatch = factory.maxAcquisitionsPerTx();
        IFWAPool(created).setPurchaseOperator(address(this));
        shapes.setApprovalForAll(created, true);
        if (address(packs) != address(0)) IERC721Approve(address(packs)).setApprovalForAll(created, true);
        uint256 left = SafeTransferLib.balanceOf(fwa, address(this));
        if (left != 0) IBurnable(fwa).burn(left);
        game.poolCreated(created);
        emit PoolCreated(created, fee);
    }

    /// @notice FWA's purchase operator hook, called for every purchase (FWA's own site included) with a 100,000-gas
    ///         stipend; a revert or a false answer refuses the purchase before anything is paid. Reads only live FWA
    ///         state and this contract's gate settings, never the game's books, so it holds while nobody syncs.
    ///         Refuses when: `maxInFlight` requests are unsettled; FWA's edge or inventory cooldown is above range; or
    ///         the prizes in the draw, less every unsettled request and one full batch, would fall below `minListed`.
    function canPurchase(address) external view returns (bool) {
        IFWAPool p = IFWAPool(pool);
        uint256 u = p.unsettledAcquisitionCount();
        if (u >= maxInFlight) return false;
        if (factory.edgeBps() > maxEdgeBps || factory.inventoryChangeCooldown() > maxCooldown) return false;
        return p.activeListingCount() >= u + maxBatch + minListed;
    }

    /// @notice Sets the purchase gate. The game only (from its capital settings and its board).
    function setGate(uint256 maxInFlight_, uint256 maxEdgeBps_, uint256 maxCooldown_, uint256 minListed_)
        external
        onlyGame
    {
        if (maxInFlight_ == 0 || maxInFlight_ > MAX_IN_FLIGHT) revert OutOfBounds();
        maxInFlight = maxInFlight_;
        maxEdgeBps = maxEdgeBps_;
        maxCooldown = maxCooldown_;
        minListed = minListed_;
        emit GateSet(maxInFlight_, maxEdgeBps_, maxCooldown_, minListed_);
    }

    function setAcquisitions(bool enabled) external onlyGame {
        IFWAPool(pool).setBool(FWA_ACQUISITIONS_ENABLED, enabled);
    }

    function retirePool() external onlyGame {
        IFWAPool(pool).retirePool();
    }

    /// @notice Sends FWA's accrued owner proceeds to the game. Returns the amount (0 when none).
    function collectProceeds() external onlyGame nonReentrant returns (uint256 amount) {
        IFWAPool p = IFWAPool(pool);
        if (p.ownerProceeds() == 0) return 0;
        amount = p.withdrawOwnerProceeds();
        SafeTransferLib.safeTransferETH(address(game), amount);
    }

    // ------------------------------------------------------------------ prizes

    /// @notice What a prize of `backing` costs to mint: a Shape's backing plus its mint fee, or a Pack's backing plus
    ///         one mint fee per Shape in its default (fewest-Shapes) makeup. Zero for a Pack below Shape Packs' minimum, or on a
    ///         chain without Shape Packs (`packs` unset), so such rows are skipped.
    function costOf(uint8 kind, uint256 backing) public view returns (uint256) {
        if (kind != KIND_PACK) return backing + shapes.mintFee();
        if (address(packs) == address(0) || backing < packs.MIN_PACK_VALUE()) return 0;
        (,, uint256 total,) = packs.quoteMint(packs.defaultMakeup(backing));
        return total;
    }

    /// @notice Mints every prize in `mints` with exactly the ETH sent (the sum of their costs) and lists them in one
    ///         FWA call. The game only.
    function mintAndList(Mint[] calldata mints)
        external
        payable
        onlyGame
        nonReentrant
        returns (uint256[] memory listingIds, uint256[] memory tokenIds)
    {
        uint256 n = mints.length;
        IFWAPool.ListingInput[] memory inputs = new IFWAPool.ListingInput[](n);
        tokenIds = new uint256[](n);
        uint256 spent;
        for (uint256 i; i < n; ++i) {
            Mint calldata m = mints[i];
            spent += m.cost;
            address collection;
            if (m.kind == KIND_PACK) {
                collection = address(packs);
                tokenIds[i] =
                    packs.createPackTo{value: m.cost}(new uint256[](0), packs.defaultMakeup(m.backing), address(this));
            } else {
                collection = address(shapes);
                tokenIds[i] = shapes.mintTo{value: m.cost}(m.backing, address(this));
            }
            inputs[i] = IFWAPool.ListingInput(collection, tokenIds[i], m.price);
        }
        if (spent != msg.value) revert BadPayment();
        listingIds = IFWAPool(pool).listNFTs(inputs);
    }

    /// @notice Withdraws listings FWA holds as Active or Staged, turns each prize into ETH and sends it all to the game.
    function withdrawAndBurn(uint256[] calldata listingIds) external onlyGame nonReentrant returns (uint256 eth) {
        IFWAPool(pool).withdrawListingsTo(listingIds, address(this));
        uint256 before = address(this).balance;
        for (uint256 i; i < listingIds.length; ++i) {
            _burn(listingIds[i]);
        }
        eth = address(this).balance - before;
        SafeTransferLib.safeTransferETH(address(game), eth);
    }

    /// @notice Recovers a prize whose purchaser took FWA's delivery refund, turns it into ETH and sends it to the game.
    function recoverAndBurn(uint256 listingId) external onlyGame nonReentrant returns (uint256 eth) {
        IFWAPool(pool).recoverRefundedNFT(listingId);
        uint256 before = address(this).balance;
        _burn(listingId);
        eth = address(this).balance - before;
        SafeTransferLib.safeTransferETH(address(game), eth);
    }

    function _burn(uint256 listingId) internal {
        (address collection,,, uint256 tokenId,,,,) = IFWAPool(pool).listings(listingId);
        if (collection == address(packs)) packs.redeemTo(tokenId, payable(address(this)));
        else shapes.burn(tokenId);
    }
}

interface IERC721Approve {
    function setApprovalForAll(address operator, bool approved) external;
}
