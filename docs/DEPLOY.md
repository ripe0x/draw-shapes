# Deploy: protocol-owned engine

One script (`script/DeployEngine.s.sol`, launch values in `script/EngineDeployer.sol`), one wrapper
(`script/engine.sh <env> <step>`), one values file per environment (`script/env/engine.<env>.env`). The
fork tests (`test/fork/engine/`) and the anvil rehearsal (`script/engine-local.sh`) run the same deploy
code. Nothing here broadcasts to mainnet without `BROADCAST=1` and the step's own signer.

`script/deploy.sh` and `script/Deploy.s.sol` are the pre-engine depositor-pool path. They remain for the
PlayMonth scenario and local runs and refuse mainnet.

## Commands

```bash
script/engine.sh mainnet deploy
```

Without `BROADCAST=1` every step is a simulation against the RPC (the dry run): guards, calls and
readbacks run, nothing is sent, no record is written.

```bash
BROADCAST=1 KEYSTORE_ACCOUNT_DEPLOYER=<keystore name> script/engine.sh mainnet deploy
```

Signers come from Foundry keystores named in the shell (`KEYSTORE_ACCOUNT_DEPLOYER`, `_OWNER`,
`_ARTCOINS_SIGNER`, `_TOKEN_ADMIN`, `_KEEPER`). No key, password or API secret goes in an env file or
on the command line. Mainnet broadcasts require a clean `main` checkout; set `RPC_URL_BROADCAST` to a
private relay so the sequence does not sit in the public mempool. Reads use the Tenderly public gateway
`https://mainnet.gateway.tenderly.co`.

Full rehearsal on an anvil mainnet fork (every step broadcast as real transactions, port 8546):

```bash
script/engine-local.sh start
```

## Launch sequence

Each row is one step and one decision point. Steps that cannot be atomic are listed with what happens
if the sequence stops after them.

| # | Step | Signer | Command | Checks and readbacks | If the sequence stops here |
| --- | --- | --- | --- | --- | --- |
| 1 | Verify dependencies | none | `script/engine.sh mainnet status` after `deploy` dry run | Shapes, FWA factory, Artcoins factory, hook, locker, MEV module and PoolManager have code; ladder unit 0.01 ETH; Artcoins hook, locker and MEV module enabled; bounty share within the factory floor; FWA `poolCreationFee` and `betaAccess` read live (`docs/MAINNET_READINESS.md`) | Nothing deployed |
| 2 | Deploy contracts | DEPLOYER | `deploy` | Draw Packs (when `DRAW_PACKS` empty), PoolAdmin, PoolListing, Pool, Lens, EngineTreasury; pool admin handed to the treasury; every launch value read back (admission closed, entry fee 0, founder window 0, treasury terms, Artcoins addresses); record `deployments/engine-1.json` | Contracts hold no ETH. The pool refuses deposits (NAV cap 0). Abandoning costs only gas. |
| 3 | Open the founding round | OWNER | `round` | Round names the treasury, target, cap 12,000 bps; treasury names the round. The 48 hour window starts now. | Contributions sit in escrow. Missed target: refunds after the deadline. Funded but not launched within 14 days: refunds. The owner can `cancel()` before release. |
| 4 | Wait for funding | none | `status` | `round.state()` = Funded (1) | as above |
| 5 | Launch ENGINE | ARTCOINS_SIGNER (the Artcoins factory owner) | `coin` | `deployTokenAsOwner(_coinConfig, 2000)`; readback: bounty recipient = treasury, skim 500, bounty 9,000, LP fee 0, referral 0; coin recorded | The coin trades and its bounty pushes accrue to the treasury unbooked. If the round later refunds, the owner may open a new round (`setFoundingRound` accepts a replacement after Refunding). Founders are not exposed. |
| 6 | Lock fee recipients | TOKEN_ADMIN | `lock` | `recipientsLocked()` true | Until locked the coin admin could repoint the fee stream; the treasury refuses to bind an unlocked coin. |
| 7 | Bind the coin | OWNER | `bind` | `setCoin` re-checks factory, pool key, hook, recipient, fee terms, lock | Founders still in escrow |
| 8 | Pay the FWA creation fee | anyone | ERC-20 transfer of `poolCreationFee()` FWA tokens (50,000 FWA at block 26,240,000) to the pool | pool FWA balance at least the fee | Tokens stay in the pool; `sweep` cannot move ERC-20, so do this immediately before step 9 |
| 9 | Activate | OWNER | `activate` | `activationCheck()` 0; creates the FWA pool, releases the escrow, deposits 6 ETH, funds GRAIL and maintenance, keeps the reserve; deposits stay paused, NAV cap floor 0, board NAV cap = pool target; FWA pool recorded; opening deadline printed | Paid play cannot start for 24 hours. Nothing is spendable except through the pool's own rules. |
| 10 | Open the board | anyone (KEEPER) | `open` after `openingDeadlineAt` | `open()` until Live (at most 12 items a call, each call under 11M gas), then `settle(20)` while due | A partly opened board is safe; any later call continues |
| 11 | Sponsorship (optional) | OWNER, then the sponsor | `sponsor` with `SPONSOR_*` terms, then the sponsor stakes from `/sponsor` | registrar = sponsorship; terms read back | No sponsor exposure until the stake |
| 12 | Verify public views | operator | web app against `deployments/engine-1.json` | `/`, `/pull`, `/fund`, `/treasury`, `/sponsor`, `/protocol` render live values only | |
| 13 | Keepers | KEEPER | `DEPLOYMENT_RECORD=deployments/engine-1.json script/keeper.sh` | settle and rotate when due; treasury `collectFees`, `harvest`, `maintainCoverage`, `boostGrail`, `buyback` when they would succeed | Everything is permissionless; anyone can take over |

## Guards the wrapper and the script enforce

- Chain id of the RPC equals the env file's; mainnet broadcasts only from a clean `main`.
- Each step's signer is set; keystores come from the shell.
- `deploy` refuses to overwrite an existing record without `REDEPLOY=1`.
- Every step reads its preconditions and its results back and reverts on a mismatch.
- `activate` refuses unless the pool holds the FWA creation fee and `activationCheck()` is 0.

## Gas

Mainnet caps a transaction at 16,777,216 gas (EIP-7825). Measured worst cases
(`test/fork/engine/EngineGas.t.sol`): `settle` listing 12 items 12.4M, `open()` 10.8M, wind-down step
6.7M, GRAIL merges 3.5M, `acquireBatch(5)` 1.8M, `activate` 1.35M. One listed item costs about 1M gas.
Opening a 175 item board costs about 175M gas in total (0.0017 ETH at 0.01 gwei, 0.18 ETH at 1 gwei),
paid by whoever calls `open` and `settle` (refunded from maintenance only for `settle`).
