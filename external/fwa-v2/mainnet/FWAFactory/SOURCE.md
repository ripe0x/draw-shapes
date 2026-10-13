# FWAFactory

Verified source of the Ethereum mainnet `FWAFactory`, vendored unchanged at the published file paths.

| field | value |
| --- | --- |
| address | `0xf5a3a153164791ab579c3d9ba5dbecf7cdfd300c` (`https://evm.now/address/0xf5a3a153164791ab579c3d9ba5dbecf7cdfd300c?chainId=1`) |
| source | Blockscout verified-source API, `https://eth.blockscout.com/api/v2/smart-contracts/0xf5a3a153164791ab579c3d9ba5dbecf7cdfd300c` |
| fetch date | 2026-09-30 |
| verified at | 2026-09-23T16:13:56.583215Z |
| main file | `src/userowned/FWAFactory.sol` |
| compiler | solc `0.8.30+commit.73712a01` |
| evm version | `prague` |
| optimizer | enabled `True`, runs `1` |
| via IR | `True` |
| metadata | `appendCBOR` `False`, `bytecodeHash` `none` |
| libraries | none |
| runtime size | 21570 bytes |

## Constructor

`constructor(address,address,uint256,bytes32,uint32,uint32,uint16,uint32,address,address)`

| # | name | type | mainnet value |
| --- | --- | --- | --- |
| 1 | `owner_` | `address` | `0x019817aD02a31B990433542097bE29D97613E8Cb` |
| 2 | `coordinator_` | `address` | `0xD7f86b4b8Cae7D942340FF628F82735b7a20893a` |
| 3 | `subscriptionId_` | `uint256` | `13528218201316887322096866654762701461841676300946602228905009947392252708648` |
| 4 | `keyHash_` | `bytes32` | `0x8077df514608a09f83e4e8d300645594e5d7234665448ba83f51a50f842bd3d9` |
| 5 | `callbackGasLimit_` | `uint32` | `900000` |
| 6 | `routerCallbackGasLimit_` | `uint32` | `1200000` |
| 7 | `requestConfirmations_` | `uint16` | `3` |
| 8 | `selectionTimeoutBlocks_` | `uint32` | `30` |
| 9 | `fwaToken_` | `address` | `0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845` |
| 10 | `fwairPfps_` | `address` | `0x29f1cBC8eccD64B0cE777f5Da45c72C47383a620` |

ABI-encoded constructor arguments as published:

```
0x000000000000000000000000019817ad02a31b990433542097be29d97613e8cb000000000000000000000000d7f86b4b8cae7d942340ff628f82735b7a20893a1de8b33d9a06786c8b3c9cdddd9e61609d3d04d85447cece8808dd47aeae07288077df514608a09f83e4e8d300645594e5d7234665448ba83f51a50f842bd3d900000000000000000000000000000000000000000000000000000000000dbba00000000000000000000000000000000000000000000000000000000000124f800000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000a0df17b5ac76ababa36e1450e2cbcd18a620c84500000000000000000000000029f1cbc8eccd64b0ce777f5da45c72c47383a620
```

## Files

Every file sits under this folder at the path Blockscout publishes.

- `src/userowned/FWAFactory.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol`
- `lib/solady/src/auth/Ownable.sol`
- `lib/solady/src/utils/LibClone.sol`
- `lib/solady/src/utils/ReentrancyGuard.sol`
- `lib/solady/src/utils/SafeTransferLib.sol`
- `src/userowned/interfaces/IFWACloneFactory.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/interfaces/IVRFV2PlusMigrate.sol`

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
`test/fwa-stack/fixtures/FWAFactory.runtime.hex`, with immutable slots masked.
