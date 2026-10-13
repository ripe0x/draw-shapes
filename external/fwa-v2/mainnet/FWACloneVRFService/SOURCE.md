# FWACloneVRFService

Verified source of the Ethereum mainnet `FWACloneVRFService`, vendored unchanged at the published file paths.

| field | value |
| --- | --- |
| address | `0xa4adfc35db18326efb3b5d9bf66a8103ec2d5ee2` (`https://evm.now/address/0xa4adfc35db18326efb3b5d9bf66a8103ec2d5ee2?chainId=1`) |
| source | Blockscout verified-source API, `https://eth.blockscout.com/api/v2/smart-contracts/0xa4adfc35db18326efb3b5d9bf66a8103ec2d5ee2` |
| fetch date | 2026-09-30 |
| verified at | 2026-09-23T16:04:57.058870Z |
| main file | `src/userowned/FWACloneVRFService.sol` |
| compiler | solc `0.8.30+commit.73712a01` |
| evm version | `prague` |
| optimizer | enabled `True`, runs `1` |
| via IR | `True` |
| metadata | `appendCBOR` `False`, `bytecodeHash` `none` |
| libraries | none |
| runtime size | 15687 bytes |

## Constructor

`constructor(address,address,uint256,bytes32,uint16,uint32,uint32,uint256,uint256)`

| # | name | type | mainnet value |
| --- | --- | --- | --- |
| 1 | `factory_` | `address` | `0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c` |
| 2 | `coordinator_` | `address` | `0xD7f86b4b8Cae7D942340FF628F82735b7a20893a` |
| 3 | `subscriptionId_` | `uint256` | `13528218201316887322096866654762701461841676300946602228905009947392252708648` |
| 4 | `keyHash_` | `bytes32` | `0x8077df514608a09f83e4e8d300645594e5d7234665448ba83f51a50f842bd3d9` |
| 5 | `requestConfirmations_` | `uint16` | `3` |
| 6 | `poolCallbackGasLimit_` | `uint32` | `900000` |
| 7 | `routerCallbackGasLimit_` | `uint32` | `1200000` |
| 8 | `minimumBuffer_` | `uint256` | `350000000000000000` |
| 9 | `maxFulfillmentCost_` | `uint256` | `400000000000000000` |

ABI-encoded constructor arguments as published:

```
0x000000000000000000000000f5a3a153164791ab579c3d9ba5dbecf7cdfd300c000000000000000000000000d7f86b4b8cae7d942340ff628f82735b7a20893a1de8b33d9a06786c8b3c9cdddd9e61609d3d04d85447cece8808dd47aeae07288077df514608a09f83e4e8d300645594e5d7234665448ba83f51a50f842bd3d9000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000dbba00000000000000000000000000000000000000000000000000000000000124f8000000000000000000000000000000000000000000000000004db732547630000000000000000000000000000000000000000000000000000058d15e176280000
```

## Files

Every file sits under this folder at the path Blockscout publishes.

- `src/userowned/FWACloneVRFService.sol`
- `lib/chainlink-evm/contracts/src/v0.8/shared/access/ConfirmedOwner.sol`
- `lib/chainlink-evm/contracts/src/v0.8/shared/access/ConfirmedOwnerWithProposal.sol`
- `lib/chainlink-evm/contracts/src/v0.8/shared/interfaces/IOwnable.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2PlusInternal.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/interfaces/IVRFMigratableConsumerV2Plus.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol`
- `lib/solady/src/utils/ReentrancyGuard.sol`
- `lib/solady/src/utils/SafeTransferLib.sol`
- `src/userowned/interfaces/IFWACloneFactory.sol`

## Published remappings

The published build used these remappings. `foundry.toml` profile `fwa-stack` resolves `solady/` and
`@chainlink/contracts/` inside this folder, which is the only part of the list these sources use.

- `:@chainlink/contracts/=lib/chainlink-evm/contracts/`
- `:@ensdomains/=lib/v4-core/node_modules/@ensdomains/`
- `:@openzeppelin/contracts/=lib/v4-core/lib/openzeppelin-contracts/contracts/`
- `:@openzeppelin/contracts@4.9.6/=test/bitmons/vendor/openzeppelin-4.9.6/`
- `:@uniswap/v4-core/=lib/v4-core/`
- `:@uniswap/v4-periphery/=lib/v4-periphery/`
- `:chainlink-evm/=lib/chainlink-evm/`
- `:ds-test/=lib/v4-core/lib/forge-std/lib/ds-test/src/`
- `:erc4626-tests/=lib/v4-core/lib/openzeppelin-contracts/lib/erc4626-tests/`
- `:forge-gas-snapshot/=lib/v4-periphery/lib/permit2/lib/forge-gas-snapshot/src/`
- `:forge-std/=lib/forge-std/src/`
- `:hardhat/=lib/v4-core/node_modules/hardhat/`
- `:openzeppelin-contracts/=lib/v4-core/lib/openzeppelin-contracts/`
- `:permit2/=lib/v4-periphery/lib/permit2/`
- `:project/=/`
- `:solady-0.1.26/=lib/solady-0.1.26/`
- `:solady/=lib/solady/`
- `:solmate/=lib/v4-core/lib/solmate/`
- `:v4-core/=lib/v4-core/src/`
- `:v4-periphery/=lib/v4-periphery/`

## Parity

`FOUNDRY_PROFILE=fwa-stack forge test --match-contract BytecodeParity` compiles this folder with
the settings above and compares the runtime with the mainnet runtime in
`test/fwa-stack/fixtures/FWACloneVRFService.runtime.hex`, with immutable slots masked.
