# Runbook: operating the engine

Launch steps: `docs/DEPLOY.md`. Rules: `docs/SPEC.md` section 17. Numbers behind the settings:
`docs/AUTONOMOUS_DECISIONS.md`.

## Local rehearsal

```bash
script/engine-local.sh start
```

Forks mainnet at block 26,240,000 on anvil port 8546 (chain id 31337) and broadcasts every launch step as
real transactions: deploy, round (four anvil founders fill 20 ETH), coin (impersonating the Artcoins
factory owner, the only party allowed to launch), lock, bind, the FWA creation fee from a real FWA
holder, activate, open, sponsorship with a real Wrapped Cryptopunk. Writes `deployments/engine-31337.json`
(git ignored).

```bash
script/engine-local.sh play 20
```

Twenty draws by anvil account 6, VRF words delivered as the Chainlink coordinator, keeper settles, then the
treasury keeper calls.

```bash
script/engine-local.sh stop
```

Web app against the rehearsal: `cd web && NEXT_PUBLIC_DEPLOYMENT=../deployments/engine-31337.json
NEXT_PUBLIC_ANVIL_RPC=http://127.0.0.1:8546 pnpm dev --port 3002`.

## Keeper

```bash
DEPLOYMENT_RECORD=deployments/engine-1.json RPC_URL=https://mainnet.gateway.tenderly.co KEYSTORE_ACCOUNT=<keeper keystore> script/keeper.sh
```

Each pass simulates and, when the simulation succeeds, sends:

| Call | Contract | When it does work | Who pays gas |
| --- | --- | --- | --- |
| `settle(20)` | Pool | `settleDue()` nonzero: a replacement batch, an old queue, a thin or a short board | refunded from maintenance when it lists or reprices |
| `rotate()` | Pool | `rotateDue()` nonzero: GRAIL mints and merges, held items, claims | refunded once per rotate interval when inventory changed |
| `collectFees()` | Treasury | unbooked trading receipts exist | keeper |
| `harvest()` | Treasury | pool NAV above basis by at least 0.001 ETH in free cash | keeper |
| `maintainCoverage()` | Treasury | maintenance below 0.15 ETH or NAV below 80 percent of the pool target | keeper |
| `boostGrail()` | Treasury | prize budget above the open bid's price by 0.01 ETH | keeper |
| `buyback(max, minOut)` | Treasury | buyback fund nonzero, 3 hours after the market opened, once a block | keeper |

Every one of these is permissionless. If the operator's keeper stops, anyone can run the same calls; draws
keep settling through FWA and players can call `settle` themselves.

## Watch

| Signal | Read | Action |
| --- | --- | --- |
| Maintenance below 0.15 ETH and `coverageOwed` at 2 ETH | `pool.maintenance()`, `treasury.coverageOwed()` | gas is above what the maintenance share covers: raise `maintenanceBps` with `poolCall(setFeeSplit)` (premium stays at least 200) |
| Pool NAV below 4.8 ETH | `pool.nav()` | `maintainCoverage()` refills from the reserve |
| Reserve below target | `treasury.reserve()`, `reserveTarget()` | refills itself from the next receipts or earnings; no action |
| GRAIL won | `GrailCaptured` events | fund rebuilds from the feed share and `boostGrail`; no action |
| Sponsored prize won or reclaimed | `PrizeSponsorship` events | `setSponsorship(0, 0)` then a new deal if wanted |
| No draws for weeks | `treasury.dormant()` | after 90 days anyone may start the wind-down |
| Factory, hook or escrow changes at Artcoins | `hook.globals()`, `locker.feeEscrow()` | the treasury reads the escrow live; check `collectFees` still succeeds |

## Wind-down

```bash
cast send <treasury> 'windDown()' --account <owner keystore> --rpc-url https://mainnet.gateway.tenderly.co
```

Then call `windDownStep()` until `settled()` is true. The pool stops taking draws; FWA settles or refunds
pending draws (players claim refunds at the FWA pool); the export redeems the board; the GRAIL estate is
redeemed; founders are paid up to their entitlement; the rest goes to the buyback fund. A sponsored NFT
goes back to its sponsorship contract, where `release()` sends it to the sponsor (or to the treasury if
the sponsor was paid in full).
