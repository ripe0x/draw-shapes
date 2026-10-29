# Runbook

Operating Draw Shapes + ENGINE after deployment. Governance actions go through the TimelockController
(`schedule` then `execute`; delay 0 at launch). `script/rehearse-anvil.sh` shows each launch action as a timelock
call on a local fork.

## Launch sequence

| step | who | action |
|---|---|---|
| 0 | owner | `script/deploy.sh mainnet` with `START_TICK` set to the chosen start price (docs/DEPLOY.md; recommended 184,200 ≈ 10 ETH FDV). Record `deployments/1.json`. |
| 1 | governance | `ProtocolLiquidity.launch()`, with no ETH: the whole 80% float becomes one single-sided position below the start price, which is the lowest valuation ENGINE can ever trade at. The public market opens; the first 60 minutes carry the anti-snipe fee; buys and sells are open (sells only return ETH buyers have paid in). Trading fees go to the PrizeVault. |
| 2 | — | 48 hours of public market (`openGame` refuses earlier). |
| 3 | anyone | Send the opening capital (about 28 ETH) to PrizeVault; call `PrizeVault.fund()`; call `FwaGame.sync(50)` until `liveCount()` is 100 (five calls; each lists 20). Each sync also tops KeeperFund up from trading fees (within 1 ETH over the vault's life). |
| 4 | governance | `FwaGame.openGame()` (needs the full board and 12 ETH cash). FWA purchases open, genesis starts (`openBlock`), public buys on the protocol pool close; sells, conversions and profit-funded buybacks continue. |
| 5 | keepers | `FwaGame.sync` as requests and empty rows accumulate, `Buyback.process` (hourly, when there is profit), `PrizeVault.fund` when trading fees have arrived, `GenesisFarm.finalize` as epochs become final. Players claim each epoch once final; claims never expire. |
| 6 | — | 21 epochs of 7,200 blocks (~21 days). |
| 7 | nobody needed | At `genesisEndBlock` public buys reopen by themselves at the ordinary fee. Afterwards, anyone may call `GenesisFarm.retireBonus()` to burn the unused conversion bonus. There are no rewards after genesis. |

## Keeper operations

- Jobs and tips: docs/SPEC.md section 11. Bots are welcome; the hosted keeper (`keeper/`) is a backup that acts when
  work has waited 6 hours, when the basefee is below 1 gwei, or at once when the purchase gate is refusing purchases
  with rows waiting (`Lens.work(...).gateOpen` false). Keepers are paid the gas they used at the gas price they paid
  (up to 5 gwei, at most 0.05 ETH a call) plus a 0.0003 ETH flat fee at most once an hour per job; calls without work
  revert and pay nothing.
- Safety does not depend on keepers: the purchase gate reads FWA directly and stops purchases while a batch of 5
  could take the board below its floor, whether or not anyone syncs. Keepers decide only how long the game stays
  paused for a restock.
- Cadence that the operating allocation pays for: one `sync` per about 10 pulls (docs/ECONOMICS.md section 4).
  Replacements list once 3 rows wait or 5 minutes after the last change, and only when no request is in flight
  unless the board is near the gate's line.
- Keeper fund: `KeeperFund.available(false)` is what tips can use; below the 0.05 ETH floor only retirement steps are
  paid. It is refilled by the game's operating allocation and topped up from trading fees by every sync (floor + 0.1
  ETH, at most 1 ETH over the vault's life); above 0.5 ETH the excess returns, first to the vault (its top-ups), then
  to the game. Send ETH to KeeperFund if gas spikes for long.
- Watch: `Lens.work(addrs)` (requests waiting, unlisted rows, admission change, gate state, buyback readiness and
  price check, finalizable epochs), `Lens.accounts(game)` (profit, distributed, protected cash, replacements owed),
  `Lens.game(addrs).acquisitionsEnabled`, `admissible` and `gateOpen`; `StepFailed` events from FwaGame (a module or
  external call reverting inside `sync`).
- A delivery that fails (`DeliveryPending`) does not stop anything: its row is replaced at the next restock; the purchaser
  can `retryNFTDelivery` or, after 7 days, `refundFailedDelivery`, after which the game recovers and burns the prize. If
  nobody acts, the epoch becomes final after the grace period without weight for that pull.

## Conditions that pause distributions or new purchases

| condition | effect | what to do |
|---|---|---|
| profit since launch minus distributed ≤ 0 (losses carried) | no distribution | nothing: ordinary play earns it back |
| cash ≤ replacements owed + operating allocation owed + reserve target + unsettled requests × largest prize | no distribution | nothing |
| fewer than 80% of rows + 5 + the unsettled requests listed | the purchase gate refuses purchases (here and on FWA's site); settlement continues | nothing if cash covers the replacements (the next `sync` restocks); otherwise add capital (send ETH to the vault, `fund`) or wait for proceeds |
| board below 80% listed (cash cannot refill it) | admission closes FWA's purchase switch too | as above |
| 10 unsettled FWA requests | the gate refuses until they settle | nothing |
| FWA edge above 5% or inventory cooldown above 5 minutes | new purchases close (gate and admission) | decide whether to accept FWA's new setting (`setCapital` raises `maxEdgeBps` / `maxCooldown`; proceeds are then booked at the higher edge for good, and trued up to what FWA pays) |
| `StepFailed("maintenance")` or `("admission")` | that step skipped; booking, payment and tips continue | replace the failing module (`setModule`) |
| governance `setPaused(true)` | new purchases close | `setPaused(false)` |
| retirement started | purchases end, no distribution | `retireStep` until retired |

## Promotions

1. Governance: `PrizeVault.fundPromotion(amount)` (from vault capital) or anyone sends to `FwaGame.fundPromotion()`.
2. Governance: `FwaGame.startPromotion(backing, priceBps, endBlock)`. The prize's full cost is reserved; it is listed
   once and never repriced; at most 30 days; price ≥ 50% of backing and win probability ≤ 10%.
3. It ends at a win or at `endBlock` (the next maintenance withdraws and burns an unwon prize). Report:
   `Lens.accounts` (`promoFunded`, `promoSpent`, `promoProceeds`, `promoTurnover`).
4. Governance: `FwaGame.releasePromotion(amount)` returns what is left to the vault as capital.

## What governance can change, and within what bounds

| contract | setter | bound |
|---|---|---|
| FwaGame | `setModule(board/pricing/buyer)` | module must have code |
| FwaGame | `setCapital(Capital)` | reserve ∈ [2 × max board backing, 1,000 ETH]; interval ≤ 1 day; fill 50 … 100% (a board needs at least the floor + 5 rows for the gate to admit anything); in flight 1 … 20; edge ≤ 1,000 bps (the highest ever set becomes the booking edge); cooldown ≤ 1 day |
| FwaGame | `setPaused`, `startPromotion`, `releasePromotion` | promotion: one at a time, pre-funded in full, ≤ 30 days, price ≥ 50% of backing, probability ≤ 10% |
| BoardPolicy | `setBoard(kinds, backings, listBatch)` | ≤ 200 rows of Shapes (kind 0) or Shape Packs (kind 1, backing ≥ Shape Packs' 0.03 ETH minimum); `listBatch` (the restock trigger) 1 … 20; rows change as they are next vacated |
| PricingPolicy | `set(markupBps, conversionBonusBps, opsBps)` | markup and bonus ≤ 500; ops ≤ markup (FwaGame clamps markup and ops to 500; Converter caps bonus at the sell fee) |
| SwapPolicy | `setFee`, `setSnipe` | fee ≤ 500; snipe ≤ 9,000 bps over ≤ 3 h; exemptions fixed at wiring; the hook caps at 500 (9,500 in the first 3 h) and never blocks sells |
| EngineHook | `setPolicy` | — |
| Buyback | `setParams(slice, spacing, impact, deviation)`, `setBuyer`, `setSource` | slice ≤ 10 ETH; spacing ≤ 1 day; impact and deviation 1 … 2,000 |
| KeeperFund | `setParams`, `setPayer`, `setOverflow` | see SPEC section 8 |
| GenesisFarm | `addLedger`, `setBonusPayer`, `setKeeperFund` | the schedule, caps and end block are fixed |
| EngineBuyer | `setCaller` | — |
| ProtocolLiquidity | `setAdder`, `setMaxImpact`, `addLiquidity` | impact 1 … 2,000 |
| PrizeVault | `setActiveGame`, `retireGame`, `setShutdownDelay`, `fundPromotion`, `setKeeperTopUpTarget` | a new game only after the last repaid in full; delay 1 … 365 days; top-up target ≤ 0.5 ETH, lifetime top-ups ≤ 1 ETH (fixed) |
| EngineToken | `setRenderer` | must have code |

Governance can direct all game capital through `setActiveGame` and the buyback's profit sources; the timelock delay is
the notice. Raise the delay (`TimelockController.updateDelay`, itself a timelock call) before outside money is material.

## Retire a game

1. Governance: `PrizeVault.retireGame()`. FwaGame retires its FWA pool (no new purchases; settlement continues).
2. Anyone: `FwaGame.retireStep(50)` repeatedly. It waits for FWA to settle everything outstanding (pending words
   expire after 30 blocks), then withdraws 20 prizes per call (Shapes burned, Packs redeemed), then repays everything to the vault and
   clears the vault's active game. Works while the FWA factory is withdraw-only.

## A new game

Deploy a new PoolOwner and FwaGame (same constructor `Config`, pointing at the new PoolOwner), `PoolOwner.wire(newGame)`,
buy its FWA fee with `FwaFeeBuyer.buyTo(newPoolOwner, fee)` and call `PoolOwner.createPool`. Governance: `GenesisFarm.addLedger(newGame)`, `KeeperFund.setPayer(newGame, true)`,
`KeeperFund.setOverflow(newGame)`, `Buyback.setSource(newGame, true)`, `PrizeVault.setActiveGame(newGame)`, and deploy
a Converter for it (`GenesisFarm.setBonusPayer`, `EngineBuyer.setCaller`). Anyone: `PrizeVault.fund()`, `sync` to fill the board.
Governance: `openGame()` (the farm clock does not restart). Rehearsed in `test/scenario/GenesisRehearsal.t.sol`.

## Shutdown

With no game active and the last game repaid, after `shutdownDelay` (30 days), anyone may call
`PrizeVault.shutdown(minSqrtPriceX96)`: the whole vault goes into the protocol-owned ENGINE liquidity, with the
half-swap capped at 5 % price impact; leftovers stay in ProtocolLiquidity for the next addition.

## Incidents

- FWA pauses purchases or sets withdraw-only: nothing to do; settlement and retirement still work.
- A module misbehaves: governance replaces it (`setModule`, `setPolicy`, `setBuyer`).
- KeeperFund empty: top it up; jobs still run (they pay what they can and never revert for lack of tip).
- A run of large wins: losses are carried and distributions stop until profit and cash recover; rows wait for cash if
  the reserve is exhausted. No action needed; capital may be added through the vault (it never counts as profit).
