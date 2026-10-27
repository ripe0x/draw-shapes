// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Interfaces between the Draw Shapes contracts. Holders implement the first group; modules the second.

interface IPrizeVault {
    function activeGame() external view returns (address);
    function repay(bool final_) external payable;
}

/// @notice What GenesisFarm reads from a game: eligible ticket ETH (wei) per epoch and the finality of an epoch.
interface ILedger {
    function epochWeight(uint256 epoch) external view returns (uint256);
    function userWeight(uint256 epoch, address purchaser) external view returns (uint256);
    function isEpochFinal(uint256 epoch) external view returns (bool);
}

interface IFwaGame is ILedger {
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
    function tip(address keeper, uint256 gasUsed, uint256 age, uint256 items, bool retirement)
        external
        returns (uint256 paid);
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
