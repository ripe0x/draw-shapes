# Draw Shapes

## Project context

- Current behavior: [SPEC](docs/SPEC.md). Decisions and superseded choices: [OWNER_QUESTIONS](docs/OWNER_QUESTIONS.md). [V1_PROMISES](docs/V1_PROMISES.md) is the historical simplification proposal, not the current decision log.
- Operations: [DEPLOY](docs/DEPLOY.md) and [PLAY](docs/PLAY.md). Dependency assumptions: [docs/external](docs/external/).
- The previous `shapes-on-fwa-v2` implementation is read-only reference. Use named source paths in [PORT_NOTES](docs/PORT_NOTES.md); its old design is not new scope.

## Development and release

- Keep one Solidity writer per repo and one Forge process per worktree.
- Use `forge test --match-path <affected-test-file>` for changed behavior. Keep Solidity 0.8.28, the compiler profiles, `via_ir` restrictions, remappings and dependency pins in `foundry.toml`; pin integration fork inputs. Check deployed bytecode sizes when runtime code changes.
- Preserve [SPEC section 16 release gates](docs/SPEC.md#16-acceptance): real Shapes, Draw Packs and FWA on a pinned mainnet fork, function tests, I1–I7 invariants, lifecycle scenarios, gas receipts and Sepolia rehearsal. Broad checks follow the global frozen-candidate rules.
- Launch the protocol-owned engine with `script/engine.sh <env> <step>` and `script/DeployEngine.s.sol` (shared code in `script/EngineDeployer.sol`) with values-only `script/env/engine.<env>.env`; preserve every [DEPLOY](docs/DEPLOY.md) guard and readback. `script/deploy.sh` is the pre-engine depositor path, local only. Engine fork tests pin `ENGINE_FORK_BLOCK` 26,240,000 (`test/fork/engine/`). Global broadcast-confirmation rules still apply.

Global rules apply; in-flight tasks keep their accepted plans and valid evidence.
