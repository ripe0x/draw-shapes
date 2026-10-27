# Runbook

Operating Draw Shapes + ENGINE after deployment. Governance actions go through the TimelockController
(`schedule` then `execute`; delay 0 at launch). `script/rehearse-anvil.sh` shows each launch action as a timelock
call on a local fork.

## Launch sequence

| step | who | action |
|---|---|---|
| 0 | owner | `script/deploy.sh mainnet` with `LAUNCH_ETH_WEI` set to the launch amount (docs/DEPLOY.md). Record `deployments/1.json`. |
| 1 | governance | `ProtocolLiquidity.launch()` with `value = LAUNCH_ETH`. The public market opens; the first 60 minutes carry the anti-snipe fee; buys and sells are open. Trading fees go to the PrizeVault. |
| 2 | — | 48 hours of public market (`openGame` refuses earlier). |
| 3 | anyone | Send the opening capital (about 28 ETH) to PrizeVault; call `PrizeVault.fund()`; call `FwaGame.sync(50)` until `liveCount()` is 100 (five calls; each lists 20). |
| 4 | governance | `FwaGame.openGame()` (needs the full board and 12 ETH cash). FWA purchases open, genesis starts (`openBlock`), public buys on the protocol pool close; sells, conversions and profit-funded buybacks continue. |
| 5 | keepers | `FwaGame.sync` as requests and empty rows accumulate, `Buyback.process` (hourly, when there is profit), `PrizeVault.fund` when trading fees have arrived, `GenesisFarm.finalize` as epochs become final. Players claim each epoch once final; claims never expire. |
| 6 | — | 21 epochs of 7,200 blocks (~21 days). |
| 7 | nobody needed | At `genesisEndBlock` public buys reopen by themselves at the ordinary fee. Afterwards, anyone may call `GenesisFarm.retireBonus()` to burn the unused conversion bonus. There are no rewards after genesis. |

## Keeper operations

- Jobs and tips: docs/SPEC.md section 11. Bots are welcome; the hosted keeper (`keeper/`) is a backup that acts only
  when work has waited 6 hours or the basefee is below 1 gwei. Keepers are paid per item of progress; calls without
  progress revert and pay nothing.
- Cadence that the operating allocation pays for: one `sync` per about 10 pulls (docs/ECONOMICS.md section 4). Syncing
  after every pull costs more gas than the allocation brings.
- Keeper fund: `KeeperFund.available(false)` is what tips can use; below the 0.05 ETH floor only retirement steps are
  paid. It is refilled by the game's operating allocation; above 0.5 ETH the excess returns to the game. Top it up by
  sending ETH to KeeperFund if gas spikes for long.
- Watch: `Lens.work(addrs)` (requests waiting, unlisted rows, admission change, buyback readiness and price check,
  finalizable epochs), `Lens.accounts(game)` (profit, distributed, protected cash, replacements owed),
  `Lens.game(addrs).acquisitionsEnabled` and `admissible`.
- A delivery that fails (`DeliveryPending`) does not stop anything: its row is replaced at the next window; the purchaser
  can `retryNFTDelivery` or, after 7 days, `refundFailedDelivery`, after which the game recovers and burns the prize. If
  nobody acts, the epoch becomes final after the grace period without weight for that pull.

## Conditions that pause distributions or new purchases

| condition | effect | what to do |
|---|---|---|
| profit since launch minus distributed ≤ 0 (losses carried) | no distribution | nothing: ordinary play earns it back |
| cash ≤ replacements owed + operating allocation owed + reserve target + unsettled requests × largest prize | no distribution | nothing |
| board below 80% listed (cash cannot refill it) | new purchases close; settlement continues | add capital (send ETH to the vault, `fund`) or wait for proceeds |
| more than 20 unsettled FWA requests | new purchases close until they settle | nothing: `sync` reopens |
| FWA edge above 5% or inventory cooldown above 5 minutes | new purchases close | decide whether to accept FWA's new setting (`setCapital` raises `maxEdgeBps` / `maxCooldown`) |
| governance `setPaused(true)` | new purchases close | `setPaused(false)` |
| retirement started | purchases end, no distribution | `retireStep` until retired |

## Promotions

1. Governance: `PrizeVault.fundPromotion(amount)` (from vault capital) or anyone sends to `FwaGame.fundPromotion()`.
2. Governance: `FwaGame.startPromotion(backing, priceBps, endBlock)`. The prize's full cost is reserved; it is listed
   once and never repriced; at most 30 days; price ≥ 50% of backing and win probability ≤ 10%.
3. It ends at a win or at `endBlock` (the next maintenance window withdraws and burns an unwon prize). Report:
   `Lens.accounts` (`promoFunded`, `promoSpent`, `promoProceeds`, `promoTurnover`).
4. Governance: `FwaGame.releasePromotion(amount)` returns what is left to the vault as capital.

## What governance can change, and within what bounds

| contract | setter | bound |
|---|---|---|
| FwaGame | `setModule(board/pricing/buyer)` | module must have code |
| FwaGame | `setCapital(Capital)` | reserve ∈ [2 × max board backing, 1,000 ETH]; interval ≤ 1 day; fill 50 … 100%; outstanding 5 … 1,000; edge ≤ 1,000 bps; cooldown ≤ 1 day |
| FwaGame | `setPaused`, `startPromotion`, `releasePromotion` | promotion: one at a time, pre-funded in full, ≤ 30 days, price ≥ 50% of backing, probability ≤ 10% |
| BoardPolicy | `setBoard(kinds, backings, listBatch)` | ≤ 200 Shape rows, batch 1 … 20 |
| PricingPolicy | `set(markupBps, conversionBonusBps, opsBps)` | markup and bonus ≤ 500; ops ≤ markup (FwaGame clamps markup and ops to 500; Converter caps bonus at the sell fee) |
| SwapPolicy | `setFee`, `setSnipe` | fee ≤ 500; snipe ≤ 9,000 bps over ≤ 3 h; exemptions fixed at wiring; the hook caps at 500 (9,500 in the first 3 h) and never blocks sells |
| EngineHook | `setPolicy` | — |
| Buyback | `setParams(slice, spacing, impact, deviation)`, `setBuyer`, `setSource` | slice ≤ 10 ETH; spacing ≤ 1 day; impact and deviation 1 … 2,000 |
| KeeperFund | `setParams`, `setPayer`, `setOverflow` | see SPEC section 8 |
| GenesisFarm | `addLedger`, `setBonusPayer`, `setKeeperFund` | the schedule, caps and end block are fixed |
| EngineBuyer | `setCaller` | — |
| ProtocolLiquidity | `setAdder`, `setMaxImpact`, `addLiquidity` | impact 1 … 2,000 |
| PrizeVault | `setActiveGame`, `retireGame`, `setShutdownDelay`, `fundPromotion` | a new game only after the last repaid in full; delay 1 … 365 days |
| EngineToken | `setRenderer` | must have code |

Governance can direct all game capital through `setActiveGame` and the buyback's profit sources; the timelock delay is
the notice. Raise the delay (`TimelockController.updateDelay`, itself a timelock call) before outside money is material.

## Retire a game

1. Governance: `PrizeVault.retireGame()`. FwaGame retires its FWA pool (no new purchases; settlement continues).
2. Anyone: `FwaGame.retireStep(50)` repeatedly. It waits for FWA to settle everything outstanding (pending words
   expire after 30 blocks), then withdraws and burns 20 prizes per call, then repays everything to the vault and
   clears the vault's active game. Works while the FWA factory is withdraw-only.

## A new game

Deploy a new FwaGame (same constructor `Config`), buy its FWA fee with `FwaFeeBuyer.buyTo(newGame, fee)` and call
`createPool`. Governance: `GenesisFarm.addLedger(newGame)`, `KeeperFund.setPayer(newGame, true)`,
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
