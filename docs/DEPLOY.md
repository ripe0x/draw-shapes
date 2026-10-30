# Deploy

One wrapper, one script: `script/deploy.sh <anvil|sepolia|mainnet>` runs `script/Deploy.s.sol` with the values of
`script/env/<env>.env`. The deployment routine itself is `script/DeploySystem.sol`; the fork tests run the same
routine, so what is tested is what is broadcast. Nobody but the owner broadcasts to mainnet.

## What the owner funds

| item | amount | paid by | when |
|---|---|---|---|
| FWA pool creation fee | 50,000 FWA, bought with ETH on FWA's v4 pool (~ETH at spot + `FWA_FEE_MARGIN_BPS`, launch 5 %) | deploy wallet | during deploy (`FwaFeeBuyer`) |
| Deploy gas | ~41.6M gas (estimated by forge on the anvil fork; PoolOwner added) | deploy wallet | during deploy |
| `KEEPER_SEED` | 0.05 ETH (the maintenance floor); later keeper pay is topped up from trading fees within a 1 ETH lifetime limit (D48) | deploy wallet | during deploy (KeeperFund constructor) |
| Launch liquidity | **none**: the launch is single-sided (D50). `START_TICK` sets the start price, the lowest valuation ENGINE can trade at, and the genesis rate cap; recommended 184,200 (≈ 10 ETH FDV, `sim/results/launch.md`) | — | launch step 1 |
| Opening capital | about 28 ETH recommended: board 15.15 ETH at cost + reserve target 12 ETH + about 1 ETH working cash (docs/ECONOMICS.md section 5) | anyone, sent to PrizeVault | launch step 3 |

The deploy wallet keeps nothing: postflight checks it holds no role and no ENGINE and that every `deployer()` is 0.

## Env file keys (values only, no secrets)

`CHAIN_ID`, `RPC_URL_DEFAULT`, `LADDER`, `FOUNDRY_PROFILE` (Sepolia), `VERIFY`, `REQUIRE_MAIN_BRANCH`, `WALLET_MODE`,
`KEYSTORE_ACCOUNT`, `DEPLOYER`, `GOVERNANCE`, `SHAPES`, `SHAPE_PACKS`, `FWA_FACTORY`, `FWA_IMPLEMENTATION`,
`FWA_VRF_SERVICE`, `POOL_MANAGER`, `FWA_FEE_MARGIN_BPS`, `CREATE_FWA_POOL`, `KEEPER_SEED`, `START_TICK`
(required: a multiple of 200; it fixes the start price and the farm's rate cap), `OPENING_CAPITAL_ETH`. Secrets come from the shell only: the keystore password (`KEYSTORE_PASSWORD_FILE`) and
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
2. KeeperFund (seeded with `KEEPER_SEED`), EngineRenderer.
3. GenesisFarm (190M genesis, 10M bonus, rate cap from `START_TICK`: 10% of 1 ETH in ENGINE at the start price) and
   ProtocolLiquidity (`START_TICK`) with the predicted EngineToken address; then EngineToken minting 800M to ProtocolLiquidity and 200M to the farm (address checked
   against the prediction).
4. SwapPolicy; PrizeVault (it receives the hook's fees, so it exists before the hook); EngineHook at a CREATE2-mined
   address carrying exactly its permission bits, fee recipient = PrizeVault; EngineBuyer.
5. BoardPolicy (Pack minimum read from Shape Packs' `MIN_PACK_VALUE`; none allowed without Shape Packs),
   PricingPolicy (markup 500, ops 300, bonus 200); Buyback; PoolOwner; FwaGame; Converter; FwaFeeBuyer; Lens.
6. Wiring, each `wire` once by the deployer: KeeperFund payers (FwaGame, Buyback, farm), overflow (FwaGame) and
   vault (top-ups); farm
   (FwaGame ledger, Converter bonus payer, keeper fund); SwapPolicy (hook, exempt EngineBuyer and ProtocolLiquidity,
   fixed); ProtocolLiquidity (hook, vault adder); EngineBuyer callers (Converter, Buyback); PoolOwner (FwaGame); vault (first game,
   KeeperFund and the 0.1 ETH top-up target); Buyback (FwaGame as its profit source).
7. FWA pool: `FwaFeeBuyer.buyTo(poolOwner, fee)` buys FWA straight into PoolOwner; `PoolOwner.createPool()` (salt fixed in its constructor; skipped if someone already called it) creates
   the pool, makes PoolOwner its purchase operator, approves Shapes and Shape Packs, burns leftover FWA and reports
   the pool to FwaGame, which pushes the purchase gate's settings.

## Postflight (DeploySystem.postflight, inside the simulation)

Reads back and refuses on any mismatch: timelock delay 0, roles (governance proposer/executor; deployer none); supply
1B, 800M at ProtocolLiquidity, 200M at the farm, none at the deployer; farm budget 190M / bonus 10M and the rate cap;
every holder and module governed by the timelock with `deployer() == 0`; funding routes (hook fee recipient = vault, the
vault's PoolManager, FwaGame's buyback and the buyback's profit source, KeeperFund overflow = FwaGame); hook references;
ProtocolLiquidity hook and vault adder; swap policy hook, exempt set, fee 300, anti-snipe 5,000 / 60 min; EngineBuyer
callers (Converter, Buyback; not FwaGame); farm ledger, bonus payer, keeper fund, 21 epochs of 7,200 blocks; vault
active game and liquidity; FwaGame references, capital and admission settings, market lead; pricing; buyback limits;
keeper seed, floor, payers, tip cap and flat fee; vault top-up wiring and target; PoolOwner references and
collections; booking edge; start tick; the pool salt and FWA's predicted pool address; FWA pool exists, its owner and `purchaseOperator` are PoolOwner, the gate's
in-flight limit, range and batch (FWA's `maxAcquisitionsPerTx`); gate end equals genesis end (max before the game
opens).

Forge simulates the whole script before broadcasting, so a failed check stops the run before the first transaction.
After a broadcast, `deploy.sh` reads the supply, governance and FWA pool owner back from the chain and writes
`deployments/<chainId>.json`.

## Dry runs done in this build

- Anvil fork of mainnet at block 26,279,000: full broadcast with an impersonated deploy wallet (no key), then the
  launch sequence through the real timelock (`script/rehearse-anvil.sh`): open the market, fund the vault, fill the
  100-row board, advance 48 h, open the game, one pull through FWA. Rerun for the sustainability follow-up and for
  the collection-games changes (single-sided launch with no ETH); results in `docs/FINAL_REPORT.md`.
- Sepolia: `DRY_RUN=1 GOVERNANCE=<any> script/deploy.sh sepolia` simulates every contract, the wiring and the
  postflight against Sepolia Shapes and the Sepolia v4 PoolManager. The Sepolia FWA factory is an older stack whose
  `createPool(bytes32,uint256,address)` reverts, so `CREATE_FWA_POOL=false` there: the Sepolia rehearsal covers
  everything except FWA. Sepolia has no Shape Packs, so the board allows no Pack rows there. Rerun for the
  collection-games changes (PoolOwner without Packs, single-sided launch at the Sepolia `START_TICK`): passed.
  Nothing was broadcast to Sepolia.

## Commands

```
# local rehearsal (no keys; time travel happens only on the local fork; it sets FOUNDRY_OFFLINE so forge does not wait
# on signature lookups through a proxy)
MAINNET_RPC_URL=<archive rpc> script/rehearse-anvil.sh

# Sepolia simulation
GOVERNANCE=<address> DRY_RUN=1 script/deploy.sh sepolia

# mainnet: simulation first, then the owner's broadcast with their keystore
DRY_RUN=1 script/deploy.sh mainnet
KEYSTORE_ACCOUNT=<name> script/deploy.sh mainnet
```
