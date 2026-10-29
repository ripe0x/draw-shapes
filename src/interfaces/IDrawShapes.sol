// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Interfaces between the Draw Shapes contracts. Holders implement the first group; modules the second.

interface IPrizeVault {
    function activeGame() external view returns (address);
    function repay(bool final_) external payable;
    function topUpKeeper() external returns (uint256 amount);
}

/// @notice What GenesisFarm reads from a game: eligible ticket ETH (wei) per epoch and the finality of an epoch.
interface ILedger {
    function epochWeight(uint256 epoch) external view returns (uint256);
    function userWeight(uint256 epoch, address purchaser) external view returns (uint256);
    function isEpochFinal(uint256 epoch) external view returns (bool);
}

interface IFwaGame is ILedger {
    function poolCreated(address pool) external;
    function receiveFunding() external payable;
    function fundPromotion() external payable;
    function returnOps() external payable;
    function retire() external;
    function retired() external view returns (bool);
}

interface ILaunched {
    function launchedAt() external view returns (uint64);
}

interface IGenesisFarm {
    function EPOCH_BLOCKS() external view returns (uint256);
    function openBlock() external view returns (uint256);
    function genesisEndBlock() external view returns (uint256);
    function currentEpoch() external view returns (uint256);
    function start() external;
    function payBonus(address to, uint256 amount) external returns (uint256 paid);
    function bonusPool() external view returns (uint256);
}

interface IKeeperFund {
    function tip(address keeper, uint256 gasUsed, uint256 work, bool retirement) external returns (uint256 paid);
    function fundKeeper() external payable;
}

interface IEngineBuyer {
    function hook() external view returns (address);
    function buy(uint256 minOut, address to, uint256 maxImpactBps)
        external
        payable
        returns (uint256 engineOut, uint256 ethSpent);
}

interface IProtocolLiquidity {
    function addLiquidity(uint160 minSqrtPriceX96) external payable returns (uint128 liquidity);
}

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @notice The subset of Shape Packs (mainnet 0xf21514B090Da7dF4390803497d6ae673801E5cA7, minimum 3 units) the game uses.
interface IShapePacks {
    function createPackTo(uint256[] calldata shapeIds, uint32[] calldata mintCounts, address to)
        external
        payable
        returns (uint256 packId);
    function redeemTo(uint256 packId, address payable recipient) external;
    function defaultMakeup(uint256 backingWei) external view returns (uint32[] memory mintCounts);
    function quoteMint(uint32[] calldata mintCounts)
        external
        view
        returns (uint256 backingWei, uint256 feeWei, uint256 totalWei, uint256 shapeCount);
    function valueOf(uint256 packId) external view returns (uint256);
    function MIN_PACK_VALUE() external view returns (uint256);
}

/// @notice The pool owner as the game uses it: mints and lists prizes, burns them back to ETH, collects proceeds.
interface IPoolOwner {
    struct Mint {
        uint8 kind; // 0 Shape, 1 Pack
        uint256 backing;
        uint256 cost;
        uint256 price;
    }

    function pool() external view returns (address);
    function costOf(uint8 kind, uint256 backing) external view returns (uint256);
    function mintAndList(Mint[] calldata mints)
        external
        payable
        returns (uint256[] memory listingIds, uint256[] memory tokenIds);
    function withdrawAndBurn(uint256[] calldata listingIds) external returns (uint256 eth);
    function recoverAndBurn(uint256 listingId) external returns (uint256 eth);
    function collectProceeds() external returns (uint256 amount);
    function setAcquisitions(bool enabled) external;
    function setGate(uint256 maxInFlight, uint256 maxEdgeBps, uint256 maxCooldown, uint256 minListed) external;
    function retirePool() external;
}

// ------------------------------------------------------------------ modules

/// @notice Board composition. Row kind 0 = Shape (the only kind the game mints). `backing` is in wei on the Shapes ladder.
interface IBoardPolicy {
    function rowCount() external view returns (uint256);
    function rowAt(uint256 index) external view returns (uint8 kind, uint96 backing);
    function listBatch() external view returns (uint256);
}

interface IPricingPolicy {
    /// @return price Listing price for a prize whose cost (backing + mint fees) is `cost`.
    function listPrice(uint8 kind, uint256 backing, uint256 cost) external view returns (uint256 price);
    function conversionBonusBps() external view returns (uint256);
    /// @return Operating allocation, in bps of a quote's expected replacement cost.
    function opsBps() external view returns (uint256);
}

interface ISwapPolicy {
    function check(address sender, bool isBuy) external view returns (bool allowed, uint256 feeBps);
}

/// @notice Shape of the artcoins v2 renderer interface: the token calls `contractURI(token)`.
interface IMetadataRenderer {
    function contractURI(address token) external view returns (string memory);
}
