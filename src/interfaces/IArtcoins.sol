// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice The parts of the deployed Artcoins v2 stack the engine reads and calls. Struct layouts
///         and signatures are copied from `ripe0x/artcoins` `contracts/artcoins/src/v2/interfaces/`
///         (`IArtCoinsFactoryV2.sol:40-188`, `IArtCoinsHookV2.sol:43-85,347-364`,
///         `IArtCoinsLpLockerV2.sol:21-36,249-304`, `IArtCoinsFeeEscrowV2.sol:106-134`,
///         `ArtCoinsTokenV2.sol:94,207`). Mainnet addresses: `deployments/1.v2.json` of that repo.
interface IArtCoinsFactoryV2 {
    struct TokenConfigV2 {
        address tokenAdmin;
        string name;
        string symbol;
        bytes32 salt;
        string image;
        string description;
        uint256 totalSupply;
        address renderer;
    }

    struct PoolConfigV2 {
        address hook;
        int24 tickIfToken0IsCoin;
        int24 tickSpacing;
        address extension;
        bytes extensionData;
    }

    struct FeeConfigV2 {
        uint24 lpFeePips;
        uint24 baselineSkimBps;
        uint16 bountyBps;
        uint24 maxReferralBpsOfVolume;
        address payable bountyRecipient;
    }

    struct LockerConfigV2 {
        address locker;
        address[] rewardRecipients;
        uint16[] rewardBps;
        int24[] tickLower;
        int24[] tickUpper;
        uint16[] positionBps;
    }

    struct MevConfigV2 {
        address module;
        uint24 startingSkimBps;
        uint32 windowSeconds;
    }

    struct RestrictionConfigV2 {
        bool restricted;
        address[] allowed;
    }

    struct ExtensionConfigV2 {
        address extension;
        uint256 msgValue;
        uint16 extensionBps;
        bytes extensionData;
    }

    struct DeploymentConfigV2 {
        TokenConfigV2 token;
        PoolConfigV2 pool;
        FeeConfigV2 fee;
        LockerConfigV2 locker;
        MevConfigV2 mev;
        RestrictionConfigV2 restriction;
        ExtensionConfigV2[] extensions;
    }

    struct DeploymentInfoV2 {
        address token;
        address hook;
        address locker;
        address mevModule;
        address escrow;
        PoolId poolId;
        bytes32 configHash;
        uint16 version;
        uint40 launchedAt;
        bool restricted;
        address[] extensions;
    }

    function deployToken(DeploymentConfigV2 calldata c) external payable returns (address token);
    function deployTokenAsOwner(DeploymentConfigV2 calldata c, uint16 protocolBps)
        external
        payable
        returns (address token);
    function isCoin(address token) external view returns (bool);
    function deploymentInfo(address token) external view returns (DeploymentInfoV2 memory);
    function deprecated() external view returns (bool);
    function deployFee() external view returns (uint256);
    function owner() external view returns (address);
    function minProtocolSkimShareBps() external view returns (uint16);
    function protocolRecipient() external view returns (address payable);
    function enabledHooks(address hook) external view returns (bool);
    function enabledLockers(address locker) external view returns (bool);
    function enabledMevModules(address module) external view returns (bool);
}

interface IArtCoinsHookV2 {
    struct PoolInfo {
        uint16 version;
        bool restricted;
        uint40 createdAt;
        address launcher;
        address token;
        address locker;
        address mevModule;
        address extension;
    }

    struct SkimConfig {
        uint24 baselineSkimBps;
        uint16 bountyBps;
        uint24 maxReferralBpsOfVolume;
        uint24 lpFeePips;
        address payable bountyRecipient;
        address payable protocolRecipient;
    }

    struct HookGlobals {
        address feeEscrow;
        address extensionAllowlist;
    }

    function poolInfo(PoolId poolId) external view returns (PoolInfo memory);
    function skimConfig(PoolId poolId) external view returns (SkimConfig memory);
    function globals() external view returns (HookGlobals memory);
}

interface IArtCoinsLpLockerV2 {
    struct TokenRewardInfoV2 {
        address token;
        PoolKey poolKey;
        uint256 positionId;
        uint256 numPositions;
        uint16[] rewardBps;
        address[] rewardRecipients;
    }

    function collectRewards(address token) external;
    function tokenRewards(address token) external view returns (TokenRewardInfoV2 memory);
    function rewardRecipients(address token) external view returns (address[] memory);
    function feeEscrow() external view returns (address);
}

interface IArtCoinsFeeEscrowV2 {
    function claim(address feeOwner, address token) external;
    function balances(address feeOwner, address token) external view returns (uint256);
}

interface IArtCoinsTokenV2 {
    function burn(uint256 amount) external;
    function recipientsLocked() external view returns (bool);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}
