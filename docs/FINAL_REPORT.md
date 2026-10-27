# Final report: Draw Shapes + ENGINE build

Date: 2026-10-27. Branch: `claude/relaxed-goodall-mmbzpd`. No independent audit has been done, nothing was broadcast
to any live network, and no private key was created or used. Time manipulation happened only in local fork tests and
on a local anvil fork.

## Done

- **Contracts** (`src/`), Solidity 0.8.28, legacy codegen, every contract under EIP-170:
  holders PrizeVault, FwaGame, GenesisFarm, Treasury, KeeperFund, EngineToken, ProtocolLiquidity, EngineHook; modules
  BoardPolicy, PricingPolicy, GrailPolicy, SwapPolicy, EmissionSchedule, EngineBuyer, Converter, EngineRenderer, Buyback,
  GrailFund; Lens; FwaFeeBuyer. Built from the task text, adopting the 2026-10-26 amendment (D2).
- **Tests**: 82 tests, all passing on a pinned mainnet fork (block 26,279,000) with the real Shapes, Shape Packs, FWA
  factory, FWA VRF service (callbacks driven through the real service), FWA token and hook, and Uniswap v4 PoolManager.
  - unit 33 (farm 16, treasury and keeper fund 11, modules/vault/token 6), including fuzzed taper and table sums;
  - fork 39 (game 25, market 12, smoke 1, gas receipts 1): pool creation and permanent ownership, listing and the
    cooldown, real `acquire` + VRF, every terminal status (Fulfilled, Expired, Refunded on slippage, TimedOut,
    DeliveryRefunded recovery), a delivery that never completes (walk continues; epoch final after grace), accepted from
    FWA issuance, the revenue split to the wei, protected capital, conversion (incl. a secondary holder and the bonus
    capped by the sell fee), Pack rows skipped, GRAIL list/reprice/capture and hard bounds, buyback single purchase
    split burn/reward, slice shrink and impact cap, gate (pre-market open, closed from `openBlock`, sells pass,
    EngineBuyer passes, reopens at genesis end), anti-snipe decay, retirement (incl. under `globalWithdrawOnly` and with a
    stuck delivery), vault fund/repay/shutdown, a second game;
  - invariants 8 (custody, solvency, ledger vs FWA, farm bounds, treasury table, empty sinks/modules, escrow) over 480
    fuzzed calls each from four actors;
  - scenario 2: the full 21-epoch genesis rehearsal (48 h pre-market, out-of-order words, a timeout, daily keeper jobs,
    claims as epochs finalise, gate lift, `retireUnearned`, post-genesis deposit pots, a second game after retiring the
    first, shutdown into the liquidity position) and a shorten run.
- **Sizes** (runtime bytes): FwaGame 21,495; Lens 10,806; GenesisFarm 10,070; ProtocolLiquidity 8,578; EngineHook 5,308;
  EngineBuyer 4,190; KeeperFund 4,132; Treasury 3,855; Buyback 3,497; Converter 3,489; EngineToken 2,940; PrizeVault 2,787.
- **Gas** (fork, isolated): `acquire` 585k; `sync` 1.12M for one pull plus its replacement, ~465k per further pull;
  `distribute` 197k; `Buyback.process` 434k; `GrailFund.process` 161k; `convert` 348k; `claim` 210k. The 3 % markup covers
  replacement gas in batches of 20 at or below ~0.75 gwei (79 % at 1 gwei, 16 % at 5). Details: docs/ECONOMICS.md.
- **Deploy**: `script/deploy.sh` + `script/Deploy.s.sol` + shared `script/DeploySystem.sol` with preflight and a full
  postflight. Dry runs: anvil fork of mainnet (full broadcast plus the launch sequence through the real timelock, then the
  keeper and the site against it); Sepolia simulation covering everything except FWA (the Sepolia factory is an older
  stack, D22).
- **Sims**: `sim/engine_genesis.py` (21 days on mainnet gas, the taper, the gate, the buyback split, conversion, farmer
  equilibrium, reserve from adverse sequences, keeper budget at 10/30/100/300 pulls/day, post-genesis operability,
  `LAUNCH_ETH` against drawdown). Results in docs/ECONOMICS.md.
- **Site** (`site/`): static Next.js with Terms and first-connect clickwrap, play (FWA `acquire`/`acquireBatch` with the
  player as purchaser, VRF fee quoted at current gas), genesis dashboard, claim, convert, stats. Builds and renders live
  state against the anvil deployment. **Keeper** (`keeper/`): viem backup keeper with the 6 h / 1 gwei policy, simulates
  every write, Dockerfile; ran a real `sync` on the anvil fork.
- **Docs**: SPEC, ECONOMICS, DEPLOY, RUNBOOK, OWNER_QUESTIONS (entries 44-60), IMPLEMENTOR_DECISIONS (D1-D30), AGENTS,
  README, docs/external/fwa-v2.md section 17. CI workflow runs sizes, all Forge suites, keeper checks, the site build and
  the sim.

## Not done, or different from the brief

- Packs are not listed by this FwaGame (D3): the two-unit Draw Packs collection does not exist on mainnet, the brief says
  build Shapes-only until the owner decides, and the code was removed to keep FwaGame within size with headroom. Adding
  Packs later means a new FwaGame (another 50,000 FWA).
- `GameRevenueRouter`, `ConversionPolicy`, `TipPolicy` and ledger-bound seasons from the amendment were not built as
  separate contracts (D2).
- FWA's VRF fee is not zero (D29): about 0.00195 ETH per pull at 1 gwei, paid by players to FWA. It nearly doubles the
  farming break-even and lowers the `LAUNCH_ETH` recommendation to 5 ETH.
- The custody promise is a governance trust model, not a lock (D21): governance picks the game and the sinks, and the
  timelock delay (0 at launch) is the only notice.
- The FWA factory was verified on-chain and against vendored verified source, not against FWA's website (D28).
- No Sepolia broadcast and no mainnet broadcast (owner actions). The fork tests need an archive RPC; the public Tenderly
  gateway rate-limits, so CI should use a private `MAINNET_RPC_URL` secret.

## Next steps that need the owner

1. Read docs/IMPLEMENTOR_DECISIONS.md and decide on: Packs (D3), the trust model wording (D21), the VRF fee impact (D29).
2. Choose `LAUNCH_ETH` (recommended 5 ETH), opening capital (recommended 3 ETH), `KEEPER_SEED` (recommended 0.5 ETH).
3. Fill `GOVERNANCE` (and `KEEPER_ACCOUNT` name) in `script/env/mainnet.env`; make sure the deploy wallet holds ETH for the
   FWA fee purchase (50,000 FWA at spot + 5 %), the keeper seed and ~34M gas.
4. Commission an independent audit before outside money is material.
5. Merge to `main`, run `DRY_RUN=1 script/deploy.sh mainnet`, then broadcast with the owner's keystore.
6. Launch sequence (docs/RUNBOOK.md): fund the vault and fill the board, `ProtocolLiquidity.launch()` with `LAUNCH_ETH`,
   48 h, `FwaGame.openGame()`.
7. Host the keeper (needs `MAINNET_RPC_URL` and a funded key, nothing else) and the static site (set
   `NEXT_PUBLIC_OPERATOR_NAME`, `NEXT_PUBLIC_CONTACT`, and copy `deployments/1.json`).
8. **Raise the timelock delay** (`TimelockController.updateDelay`) before outside money is material; at launch it is 0,
   which means governance can redirect all game capital without notice.
