# Draw Shapes + ENGINE

A real-money NFT gacha on Ethereum mainnet: players pay ETH for a VRF draw from a board of Shapes on an FWA V2 custom
pool the protocol owns, and earn ENGINE during a 21-day genesis; a share of the game's revenue buys ENGINE back for
the life of the game. Specification: `docs/SPEC.md`. No independent audit has been done.

Agent guidance: [AGENTS.md](AGENTS.md).

```
src/            holders, modules, Lens
script/         DeploySystem.sol (shared deploy + postflight), Deploy.s.sol, deploy.sh, env/, rehearse-anvil.sh
test/           unit, fork (pinned mainnet), invariant (custody), scenario (genesis rehearsal)
sim/            engine_genesis.py and its results
site/           Next.js player site
keeper/         backup keeper (Node, viem)
docs/           SPEC, ECONOMICS, DEPLOY, RUNBOOK, decisions, receipts
external/       vendored FWA V2 sources, read only
```

Tests: `MAINNET_RPC_URL=<archive rpc> forge test --threads 2`.
