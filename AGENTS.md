# Draw Shapes + ENGINE

## Project context

- Current behavior: [SPEC](docs/SPEC.md). Build brief: [BUILD_PROMPT](docs/BUILD_PROMPT.md). Decisions: the owner's in
  [OWNER_QUESTIONS](docs/OWNER_QUESTIONS.md) (entries 44 onward), the implementor's in
  [IMPLEMENTOR_DECISIONS](docs/IMPLEMENTOR_DECISIONS.md). Numbers: [ECONOMICS](docs/ECONOMICS.md).
- Operations: [DEPLOY](docs/DEPLOY.md) and [RUNBOOK](docs/RUNBOOK.md). Dependency assumptions: [docs/external](docs/external/)
  and the vendored verified FWA sources in `external/fwa-v2/mainnet/`.
- Layout: `src/game` (PrizeVault, FwaGame, Converter), `src/token` (EngineToken, GenesisFarm, EngineHook,
  ProtocolLiquidity, EngineBuyer, EngineRenderer), `src/treasury` (Treasury, KeeperFund, sinks), `src/policy`
  (modules), `src/Lens.sol`, `script/` (DeploySystem shared by the deploy script and the fork tests), `test/{unit,fork,
  invariant,scenario}`, `sim/`, `site/`, `keeper/`.

## Development and release

- Keep one Solidity writer per repo and one Forge process per worktree. Fork suites are memory hungry: use `--threads 2`.
- Use `forge test --match-path <affected-test-file>` for changed behavior. Keep Solidity 0.8.28, legacy codegen (no
  `via_ir` for any contract), remappings and dependency pins in `foundry.toml`; fork tests pin `FORK_BLOCK`
  (26,279,000) and read `MAINNET_RPC_URL` (an archive endpoint). Check deployed sizes (`forge build --sizes --skip test`)
  when runtime code changes; FwaGame has ~3 KB of headroom.
- Release gates: real Shapes, FWA and the v4 PoolManager on the pinned fork; unit, fork, invariant (custody stays in CI)
  and the genesis rehearsal; gas receipts (`test/fork/Gas.t.sol --isolate` → `docs/receipts/gas.json`); Sepolia
  simulation (everything except FWA).
- Deploy only with `script/deploy.sh <env>` and values-only env files; preserve every guard and the postflight in
  `script/DeploySystem.sol`. Never broadcast to mainnet from an automated session.

Global rules apply; in-flight tasks keep their accepted plans and valid evidence.
