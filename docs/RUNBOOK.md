# Runbook

Operating Draw Shapes + ENGINE after deployment. Governance actions go through the TimelockController
(`schedule` then `execute`; delay 0 at launch). `script/rehearse-anvil.sh` shows each launch action as a timelock
call on a local fork.

## Launch sequence

| step | who | action |
|---|---|---|
| 0 | owner | `script/deploy.sh mainnet` (docs/DEPLOY.md). Record `deployments/1.json`. |
| 1 | anyone | Send the opening capital (3 ETH recommended) to PrizeVault; call `PrizeVault.fund()`; call `FwaGame.sync(50)` until `liveCount()` is 100 (five calls; each lists 20). |
| 2 | governance | `ProtocolLiquidity.launch()` with `value = LAUNCH_ETH`. The market opens; the first 60 minutes carry the anti-snipe fee. Buys and sells are open (pre-market). |
| 3 | — | 48 hours of pre-market. |
| 4 | governance | `FwaGame.openGame()`. FWA purchases open, the farm clock starts (`openBlock`), public buys on the canonical pool close until genesis end. |
| 5 | keepers | Daily: `FwaGame.sync`, `Treasury.distribute`, `Buyback.process` (hourly), `GrailFund.process`. Players claim each epoch once final. |
| 6 | — | 21 epochs of 7,200 blocks (~21 days). |
| 7 | anyone | At genesis end public buys reopen; call `GenesisFarm.retireUnearned()` once every genesis epoch is final. |

Optional: governance seeds the first GRAIL with `FwaGame.fundGrail{value: ...}()`; otherwise it lists when the
GrailFund sink has sent enough (0.501 ETH for the first 0.5 ETH GRAIL).

## Keeper operations

- Jobs and tips: docs/SPEC.md section 10. Bots are welcome; the hosted keeper (`keeper/`) is a backup that acts only
  when work has waited 6 hours or the basefee is below 1 gwei.
- Keeper fund: `KeeperFund.available(false)` is what tips can use; below the 0.05 ETH floor only retirement steps
  are paid. Top it up by sending ETH to KeeperFund. Raise the markup (≤ 5 %) or let replacements wait for cheap gas
  if it runs dry (docs/ECONOMICS.md section 4).
- Watch: `Lens.work(addrs)` (requests waiting, unlisted rows, ages), `FwaGame.distributable()` (0 means revenue is
  rebuilding the reserve), `FwaGame.openCount()` (requests waiting on FWA; a `DeliveryPending` stays here until
  settled), `KeeperFund.available(false)`.
- A delivery that fails (`DeliveryPending`) does not stop anything: the purchaser can `retryNFTDelivery` or, after 7
  days, `refundFailedDelivery`; the game recovers and relists the prize. If nobody acts, the epoch becomes final
  after the grace period without a unit for that pull.

## What governance can change, and within what bounds

| contract | setter | bound |
|---|---|---|
| FwaGame | `setModule(board/pricing/grail/buyer)` | module must have code |
| FwaGame | `setCapital(reserveTarget, maintenanceInterval)` | reserve ∈ [2 × max board backing, 1,000 ETH]; interval ≤ 1 day |
| FwaGame | `setAcquisitionsEnabled` | — |
| BoardPolicy | `setBoard(kinds, backings, listBatch)` | ≤ 200 rows, batch 1 … 20 (FwaGame lists Shape rows only) |
| PricingPolicy | `set(markupBps, conversionBonusBps)` | ≤ 500 each (FwaGame clamps markup to 500; Converter caps bonus at the sell fee) |
| GrailPolicy | `set(ladder, startBps, floorBps, decayBps, decayPulls)` | FwaGame enforces price ≥ 50 % of backing and win probability ≤ 10 % |
| SwapPolicy | `setFee`, `setSnipe`, `setExempt` | fee ≤ 500; snipe ≤ 9,000 bps over ≤ 3 h; the hook caps at 500 (9,500 in the first 3 h) and never blocks sells |
| EngineHook | `setPolicy` | — |
| Treasury | `setSinks`, `setKeeperFund` | ≤ 8 sinks with code, no duplicates, sum 10,000 |
| Buyback | `setParams(slice, spacing, impact, burnShare)`, `setBuyer` | slice 0.005 … 10 ETH; spacing ≤ 1 day; impact 1 … 2,000; burn share ≤ 10,000 |
| GrailFund | `setGame` | — |
| KeeperFund | `setParams`, `setPayer` | see SPEC section 8 |
| GenesisFarm | `shorten`, `scheduleSeason`, `burnReserve`, `addLedger`, `setDepositor`, `setBonusPayer`, `setKeeperFund` | shorten one way, ≥ 7 epochs, 2 full epochs' notice; seasons: after genesis, 7 epochs' notice, ≤ genesis average per epoch, no overlap, ≤ 8 |
| EngineBuyer | `setCaller` | — |
| ProtocolLiquidity | `setAdder`, `setMaxImpact`, `addLiquidity` | impact 1 … 2,000 |
| PrizeVault | `setActiveGame`, `retireGame`, `setShutdownDelay` | a new game only after the last repaid in full; delay 1 … 365 days |
| EngineToken | `setRenderer` | must have code |

Governance can direct all game capital through `setActiveGame` and `setSinks`; the timelock delay is the notice. Raise
the delay (`TimelockController.updateDelay`, itself a timelock call) before outside money is material.

## Retire a game

1. Governance: `PrizeVault.retireGame()`. FwaGame retires its FWA pool (no new purchases; settlement continues).
2. Anyone: `FwaGame.retireStep(50)` repeatedly. It waits for FWA to settle everything outstanding (pending words
   expire after 30 blocks), then withdraws and burns 20 prizes per call, then repays everything to the vault and
   clears the vault's active game. Works while the FWA factory is withdraw-only.

## A new game

Deploy a new FwaGame (same constructor `Config`), buy its FWA fee with `FwaFeeBuyer.buyTo(newGame, fee)` and call
`createPool`. Governance: `GenesisFarm.addLedger(newGame)`, `KeeperFund.setPayer(newGame, true)`,
`GrailFund.setGame(newGame)`, `PrizeVault.setActiveGame(newGame)`, and deploy a Converter for it
(`GenesisFarm.setBonusPayer`, `EngineBuyer.setCaller`). Anyone: `PrizeVault.fund()`, `sync` to fill the board.
Governance: `openGame()` (the farm clock does not restart). Rehearsed in `test/scenario/GenesisRehearsal.t.sol`.

## Shutdown

With no game active and the last game repaid, after `shutdownDelay` (30 days), anyone may call
`PrizeVault.shutdown(minSqrtPriceX96)`: the whole vault goes into the protocol-owned ENGINE liquidity, with the
half-swap capped at 5 % price impact; leftovers stay in ProtocolLiquidity for the next addition.

## Incidents

- FWA pauses purchases or sets withdraw-only: nothing to do; settlement and retirement still work.
- A module misbehaves: governance replaces it (`setModule`, `setPolicy`, `setSinks`, `setBuyer`).
- KeeperFund empty: top it up; jobs still run (they pay what they can and never revert for lack of tip).
- Reserve below target after a run of large wins: revenue stops leaving the game until it refills; no action needed.
