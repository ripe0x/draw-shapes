# Deploy

Local run, launch steps and keeper operation: `docs/RUNBOOK.md`.

One contract (`script/Deploy.s.sol`), one wrapper (`script/deploy.sh <env>`), one values file per
environment (`script/env/<env>.env`). Every environment runs the same guards, build, broadcast,
readback and record code.

## Commands

```
# Dry run: every guard, simulation, would-be record. No wallet, broadcast or verification.
DRY_RUN=1 script/deploy.sh mainnet

# Local fork: broadcasts with the unlocked anvil account and creates the FWA pool.
anvil --fork-url https://ethereum-rpc.publicnode.com --port 8545 --chain-id 31337
RPC_URL=http://127.0.0.1:8545 script/deploy.sh anvil

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
- Pool, PoolAdmin, PoolListing and Lens runtime code fits 24576 bytes. A local fork started with
  `--disable-code-size-limit` can run with `ANVIL_DISABLE_SIZE_LIMIT=1`.
- `.env` is untracked. `--slow` is always passed.

`Deploy.s.sol` deploys `PoolAdmin`, `PoolListing`, `Pool` (constructed with both module addresses) and `Lens`, in that
order. It then checks the chain: mainnet pins Shapes, the factory, the fee split, the entry
fee, the turnover, the founder window, `rotateInterval` 900 and the 24 hour opening deadline. Draw Packs must have a minimum pack
value of two ladder units and wrap the same Shapes. After the broadcast it reads every constructor
value back from the pool, including `tipWei`, `adminModule` and `listingModule`.

## Record

`deployments/<chainId>.json` holds the addresses (`pool`, `adminModule`, `listingModule`, `lens`, ...), `gitCommit`,
`blockNumber` and `deployedAt`. A local run writes `deployments/31337-<port>.json`, which git ignores. A broadcast with
`CREATE_POOL=1` (anvil only) adds `fwaPool` and `openingDeadlineAt`.

## After the deploy

The pool is Opening and takes deposits at once. The admin then:

1. Calls `createFwaPool(expectedFee)`. The factory must allow the admin to create a pool, and the
   pool must hold the fee in the FWA token. The opening deadline starts here. The call sets the
   pool as the FWA `purchaseOperator`, so FWA accepts purchases made through the pool's `acquire`
   and `acquireBatch` only. `purchaseOperator()` on the FWA pool returns the pool.
2. Waits for `openingDeadlineAt`.
3. Calls `open()` until `lifecycle()` returns Live. Each call lists at most 20 items.

## Keeper

Run a keeper on a short interval. It reads `Lens.settleDue()` (or `Pool.settleDue()`) and calls `Pool.settle(20)`
whenever `settleDue() != None`. A nonzero value means a batch, an age or a thin board reason holds and funded work is
queued. The caller receives a refund from `maintenance` when the call lists an item or reprices a GRAIL item. `settle` lists while the
factory's `inventoryChangeCooldown` is 0 or `listWhilePaused` is on.

Keeper funding: `maintenanceBps` 100 covers mint and list gas up to about 2 gwei. Above that, top the bucket up with
`Pool.fundMaintenance()` (payable, anyone) from Shapes mint fee revenue, which the operator receives at the Shapes
contract. Watch `maintenance()` on Lens or Pool; refunds stop when it is empty and the board relists only on the thin
trigger until it is refilled.

The keeper also reads `rotateDue()` and calls `Pool.rotate()` whenever `rotateDue() != None`. A nonzero value means the
spacing since `lastRotateAt` has passed and a reason holds: Claim, GrailStep or Held. A rotate that leaves
inventory unchanged keeps its reason true, so the keeper simulates the call or backs off between attempts.
