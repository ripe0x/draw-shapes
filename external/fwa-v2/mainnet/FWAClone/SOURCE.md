# FWAClone

Verified source of the Ethereum mainnet `FWAClone`, vendored unchanged at the published file paths.

| field | value |
| --- | --- |
| address | `0xeaa4d032908a9734a2c7939c0d211c35ad51eb31` (`https://evm.now/address/0xeaa4d032908a9734a2c7939c0d211c35ad51eb31?chainId=1`) |
| source | Blockscout verified-source API, `https://eth.blockscout.com/api/v2/smart-contracts/0xeaa4d032908a9734a2c7939c0d211c35ad51eb31` |
| fetch date | 2026-09-30 |
| verified at | 2026-09-23T16:07:57.483766Z |
| main file | `src/userowned/FWAClone.sol` |
| compiler | solc `0.8.30+commit.73712a01` |
| evm version | `prague` |
| optimizer | enabled `True`, runs `1` |
| via IR | `True` |
| metadata | `appendCBOR` `False`, `bytecodeHash` `none` |
| libraries | none |
| runtime size | 20933 bytes |

## Constructor

`constructor(address,address)`

| # | name | type | mainnet value |
| --- | --- | --- | --- |
| 1 | `factory_` | `address` | `0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c` |
| 2 | `service_` | `address` | `0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2` |

ABI-encoded constructor arguments as published:

```
0x000000000000000000000000f5a3a153164791ab579c3d9ba5dbecf7cdfd300c000000000000000000000000a4adfc35db18326efb3b5d9bf66a8103ec2d5ee2
```

## Files

Every file sits under this folder at the path Blockscout publishes.

- `src/userowned/FWAClone.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol`
- `lib/chainlink-evm/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol`
- `lib/solady/src/auth/Ownable.sol`
- `lib/solady/src/tokens/ERC721.sol`
- `lib/solady/src/utils/ReentrancyGuard.sol`
- `lib/solady/src/utils/SafeTransferLib.sol`
- `src/FWAConfigKeys.sol`
- `src/userowned/interfaces/IFWACloneFactory.sol`
- `src/userowned/interfaces/IPurchaseOperator.sol`

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
`test/fwa-stack/fixtures/FWAClone.runtime.hex`, with immutable slots masked.
