# Deploy

One wrapper, one script: `script/deploy.sh <anvil|sepolia|mainnet>` runs `script/Deploy.s.sol` with the values of
`script/env/<env>.env`. The deployment routine itself is `script/DeploySystem.sol`; the fork tests run the same
routine, so what is tested is what is broadcast. Nobody but the owner broadcasts to mainnet.

## What the owner funds

| item | amount | paid by | when |
|---|---|---|---|
| FWA pool creation fee | 50,000 FWA, bought with ETH on FWA's v4 pool (~ETH at spot + `FWA_FEE_MARGIN_BPS`, launch 5 %) | deploy wallet | during deploy (`FwaFeeBuyer`) |
| Deploy gas | ~34M gas (measured on the anvil fork) | deploy wallet | during deploy |
| `KEEPER_SEED` | 0.5 ETH recommended (docs/ECONOMICS.md section 4) | deploy wallet | during deploy (KeeperFund constructor) |
| Opening capital | 3.0 ETH recommended: board 2.15 ETH incl. mint fees + reserve 0.75 + 0.1 | anyone, sent to PrizeVault | launch step 1 |
| `LAUNCH_ETH` | 5 ETH recommended (docs/ECONOMICS.md section 6) | governance, through the timelock | launch step 2 |

The deploy wallet keeps nothing: postflight checks it holds no role and no ENGINE and that every `deployer()` is 0.

## Env file keys (values only, no secrets)

`CHAIN_ID`, `RPC_URL_DEFAULT`, `LADDER`, `FOUNDRY_PROFILE` (Sepolia), `VERIFY`, `REQUIRE_MAIN_BRANCH`, `WALLET_MODE`,
`KEYSTORE_ACCOUNT`, `DEPLOYER`, `GOVERNANCE`, `SHAPES`, `SHAPE_PACKS`, `FWA_FACTORY`, `FWA_IMPLEMENTATION`,
`FWA_VRF_SERVICE`, `POOL_MANAGER`, `FWA_FEE_MARGIN_BPS`, `CREATE_FWA_POOL`, `KEEPER_SEED`, `LAUNCH_ETH`,
`OPENING_CAPITAL_ETH`. Secrets come from the shell only: the keystore password (`KEYSTORE_PASSWORD_FILE`) and
`ETHERSCAN_API_KEY`. `GOVERNANCE` must differ from `DEPLOYER`. Economic launch values are not in env files; they are
fixed in `script/LaunchConfig.sol` so every environment deploys the same game (Sepolia scales backings by the
Shapes `unit()`).

## Guards (deploy.sh, before anything runs)

Required keys set; chain id matches the environment; RPC reachable; Shapes, FWA factory, PoolManager (and Shape Packs
when set) have code; the factory's `implementation()` and `vrfService()` equal the pinned values; mainnet requires the
`main` branch and a clean tree; `.env` is not tracked; the build carries the right Shapes ladder; every holder's runtime
is under 24,576 bytes.

## Deploy order (DeploySystem._deploySystem)

1. TimelockController(minDelay 0, proposer = executor = `GOVERNANCE`, no admin).
2. Treasury, KeeperFund (seeded with `KEEPER_SEED`), EmissionSchedule, EngineRenderer.
3. GenesisFarm and ProtocolLiquidity with the predicted EngineToken address; then EngineToken minting 100M to
   ProtocolLiquidity and 900M to the farm (address checked against the prediction).
4. SwapPolicy; EngineHook at a CREATE2-mined address carrying exactly its permission bits; EngineBuyer.
5. BoardPolicy, PricingPolicy, GrailPolicy; PrizeVault; FwaGame; Converter; Buyback; GrailFund; FwaFeeBuyer; Lens.
6. Wiring, each `wire` once by the deployer: Treasury (keeper fund, table Buyback 9,000 / GRAIL 1,000); KeeperFund
   payers (FwaGame, Treasury, Buyback, GrailFund, farm); farm (FwaGame ledger, Buyback depositor, Converter bonus payer,
   keeper fund); SwapPolicy (hook, exempt EngineBuyer and ProtocolLiquidity); ProtocolLiquidity (hook, vault adder);
   EngineBuyer callers (Converter, Buyback); vault (first game).
7. FWA pool: `FwaFeeBuyer.buyTo(game, fee)` buys FWA straight into FwaGame; `FwaGame.createPool(salt)`.

## Postflight (DeploySystem.postflight, inside the simulation)

Reads back and refuses on any mismatch: timelock delay 0, roles (governance proposer/executor; deployer none);
supply 1B, 100M at ProtocolLiquidity, 900M at the farm, none at the deployer; farm split 100M / 10M / 790M; every
holder and module governed by the timelock with `deployer() == 0`; hook references (engine, launcher, treasury,
policy); ProtocolLiquidity hook and vault adder; swap policy hook, exempt set, fee 300, anti-snipe 5,000 / 60 min;
EngineBuyer callers (Converter, Buyback; not FwaGame); farm ledger, depositor, bonus payer, keeper fund, 21 epochs of
7,200 blocks; vault active game and liquidity; FwaGame references, reserve target, maintenance interval; burn share;
keeper seed and floor; KeeperFund payers; treasury table (two sinks, 9,000 + 1,000 = 10,000); FWA pool exists, its
owner is FwaGame, `purchaseOperator` is zero; gate end equals genesis end (max before the game opens).

Forge simulates the whole script before broadcasting, so a failed check stops the run before the first transaction.
After a broadcast, `deploy.sh` reads the supply, governance and FWA pool owner back from the chain and writes
`deployments/<chainId>.json`.

## Dry runs done in this build

- Anvil fork of mainnet at block 26,279,000: full broadcast with an impersonated deploy wallet (no key), then the
  launch sequence through the real timelock (`script/rehearse-anvil.sh`): fund the vault, fill the 100-row board,
  open the market, advance 48 h, open the game. All steps passed.
- Sepolia: `DRY_RUN=1 GOVERNANCE=<any> script/deploy.sh sepolia` simulates every contract, the wiring and the
  postflight against Sepolia Shapes and the Sepolia v4 PoolManager. The Sepolia FWA factory is an older stack whose
  `createPool(bytes32,uint256,address)` reverts, so `CREATE_FWA_POOL=false` there: the Sepolia rehearsal covers
  everything except FWA. Nothing was broadcast to Sepolia.

## Commands

```
# local rehearsal (no keys; time travel happens only on the local fork)
MAINNET_RPC_URL=<archive rpc> script/rehearse-anvil.sh

# Sepolia simulation
GOVERNANCE=<address> DRY_RUN=1 script/deploy.sh sepolia

# mainnet: simulation first, then the owner's broadcast with their keystore
DRY_RUN=1 script/deploy.sh mainnet
KEYSTORE_ACCOUNT=<name> script/deploy.sh mainnet
```
