# Deploy

One contract (`script/Deploy.s.sol`), one wrapper (`script/deploy.sh <env>`), one values file per
environment (`script/env/<env>.env`). Every environment runs the same guards, build, broadcast,
readback and record code.

## Commands

```
# Dry run: every guard, simulation, would-be record. No wallet, broadcast or verification.
DRY_RUN=1 script/deploy.sh mainnet

# Local fork: broadcasts with the unlocked anvil account and creates the FWA pool.
anvil --fork-url https://ethereum-rpc.publicnode.com --port 8645 --chain-id 31337
RPC_URL=http://127.0.0.1:8645 script/deploy.sh anvil

# Mainnet: keystore signer, Etherscan verification.
ETHERSCAN_API_KEY=... script/deploy.sh mainnet
```

`KEYSTORE_PASSWORD_FILE` and `ETHERSCAN_API_KEY` come from the shell. Env files hold values only.

## What the wrapper checks

- Every required value is set. `mainnet.env` ships with `KEYSTORE_ACCOUNT` and `DRAW_PACKS` empty.
- The env matches its chain id and the RPC answers with that chain id.
- The build remaps `ladder/` to the ladder named by `LADDER`.
- Shapes, the FWA factory and Draw Packs have code. The factory `implementation()` and
  `vrfService()` equal the env values.
- Mainnet runs from a clean `main`. A dry run reports a branch or tree failure and continues.
- Pool, PoolAdmin and Lens runtime code fits 24576 bytes. A local fork started with
  `--disable-code-size-limit` can run with `ANVIL_DISABLE_SIZE_LIMIT=1`.
- `.env` is untracked. `--slow` is always passed.

`Deploy.s.sol` then checks the chain: mainnet pins Shapes, the factory, the fee split, the entry
curve, `rotateInterval` 3600 and the 24 hour opening deadline. Draw Packs must have a minimum pack
value of two ladder units and wrap the same Shapes. After the broadcast it reads every constructor
value back from the pool.

## Record

`deployments/<chainId>.json` holds the addresses (`pool`, `adminModule`, `lens`, ...), `gitCommit`,
`blockNumber` and `deployedAt`. A local run writes `deployments/31337-<port>.json`, which git ignores. A broadcast with
`CREATE_POOL=1` (anvil only) adds `fwaPool` and `openingDeadlineAt`.

## After the deploy

The pool is Opening and takes deposits at once. The admin then:

1. Calls `createFwaPool(expectedFee)`. The factory must allow the admin to create a pool, and the
   pool must hold the fee in the FWA token. The opening deadline starts here. The call sets the
   pool as the FWA `purchaseOperator`, so FWA accepts purchases made through the pool's `acquire`
   and `acquireBatch` only.
2. Calls `setPurchaseGate(false)` while the FWA site buys directly at the FWA pool. This sets the
   `purchaseOperator` to zero. `setPurchaseGate(true)` sets it back to the pool once the site
   routes purchases through the pool. `purchaseOperator()` on the FWA pool shows the state.
3. Waits for `openingDeadlineAt`.
4. Calls `open()` until `lifecycle()` returns Live. Each call runs one restock.
