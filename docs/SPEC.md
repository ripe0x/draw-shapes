# Draw Shapes + ENGINE: specification (as built)

This is the system as implemented in `src/`, from `docs/BUILD_PROMPT.md` and the sustainability follow-up to PR #9
(funding routes, ordinary prize mix, accounting, capital, clean genesis end). Decisions are in
`docs/IMPLEMENTOR_DECISIONS.md` (cited as D<n>; D31 onward cover the follow-up). Economics, sims and gas:
`docs/ECONOMICS.md`. Operations: `docs/DEPLOY.md`, `docs/RUNBOOK.md`. No independent audit has been done.

## 1. What it is

A real-money NFT gacha on Ethereum mainnet. Players pay ETH for a VRF draw from a board of Shapes (ETH-backed NFTs,
burnable for their backing) and, if governance chooses, Shape Packs (bundles of Shapes, redeemable for their backing)
on an FWA V2 custom pool that our PoolOwner contract owns. The house is a protocol-owned prize
inventory that replenishes itself from gameplay. ENGINE is the token. During a 21-epoch genesis every delivered pull
earns ENGINE in proportion to its ticket ETH. After genesis there are no rewards.

Money has three separate routes (D31):

| source | goes to | is it profit? |
|---|---|---|
| ENGINE trading fees (3% hook fee) | PrizeVault, then the game as capital | no |
| opening capital, contributions, returned capital | PrizeVault, then the game as capital | no |
| owner proceeds of pulls | the game: revenue | revenue, against the prizes' cost |
| realised, distributable game profit | Buyback: buys ENGINE and burns all of it | yes, only this |
| explicit promotion budgets | the game's promotion budget, accounted apart | no |

The founder's only income is the Shapes mint fee (0.001 ETH per Shape minted, including each Shape inside a Pack), paid
by the game to the Shapes contract.
There is no other founder allocation or revenue skim.

## 2. Custody and governance (D21)

Governance is an OpenZeppelin `TimelockController` with `minDelay = 0` at launch; proposer and executor are the owner's
governance address; there is no admin. Every setter is timelock-only. Every contract that holds ETH, NFTs or ENGINE has
no withdraw function and no upgrade path. Code-enforced outflows:

| holder | ETH / tokens may go only to |
|---|---|
| PrizeVault | the active game as capital (`fund`) or promotion budget (`fundPromotion`), KeeperFund (`topUpKeeper`, ≤ 1 ETH over its life), ProtocolLiquidity (`shutdown`) |
| FwaGame | the vault (`repay`, `releasePromotion`), PoolOwner (exactly the cost of the prizes it mints), KeeperFund (operating allocation), Buyback (distributable profit) |
| PoolOwner | Shapes and Shape Packs (exactly the mint cost the game sent), FwaGame (every other wei: redemptions, burns, owner proceeds); prizes only to FWA (listing) or burned / redeemed |
| Buyback | EngineBuyer (one bounded purchase per call); every ENGINE bought is burned in the same call |
| KeeperFund | keepers (tips), the vault (its top-ups back, first), the game (overflow above target, `returnOps`) |
| GenesisFarm | claimants (`claim`), the Converter's caller (`payBonus`), burns of unearned allocation |
| ProtocolLiquidity | the pool position only (no remove) |
| EngineHook | holds nothing; fees go from the PoolManager to the PrizeVault |

Governance chooses the active game, the buyback's profit sources, promotion budgets and every module, so governance
can direct all capital; the timelock delay is the only notice, and it is 0 at launch. The site's Terms say this.

## 3. Contracts

Holders (no upgrade path): `PrizeVault`, `PoolOwner`, `FwaGame`, `GenesisFarm`, `Buyback`, `KeeperFund`, `EngineToken`,
`ProtocolLiquidity`, `EngineHook`. Modules (replaceable by the timelock; hold nothing between calls): `BoardPolicy`,
`PricingPolicy`, `SwapPolicy`, `EngineBuyer`, `Converter`, `EngineRenderer`. Read-only: `Lens`. Deploy helper:
`FwaFeeBuyer`. Shared base: `Governed` (immutable `governance`, one-shot `wire` by the deployer).

Removed in the follow-up: `Treasury` (its sink table could send revenue anywhere), `GrailFund`, `GrailPolicy` (per-pull
GRAIL decay) and `EmissionSchedule` (the schedule is now frozen in the farm).

Runtime sizes (legacy codegen, optimizer 200): see `docs/ECONOMICS.md` section 9; FwaGame is the largest at 24,195
bytes, 381 under 24,576, after moving pool ownership, minting and the purchase gate into PoolOwner (D44).

## 4. PrizeVault (capital)

- `receive()`: counts ETH from the PoolManager as `tradingFees` (the hook's fee arrives that way, mid-swap) and anything
  else as `contributions`. Neither is ever profit.
- `wire(game, keeperFund, keeperTopUpTarget)` (deployer, once) and `setActiveGame(game)` (timelock): only when no game
  is active.
- `topUpKeeper()` anyone (the game calls it in every sync): refills KeeperFund to its maintenance floor plus
  `keeperTopUpTarget` (0.1 ETH; ≤ 0.5) from the vault's balance, at most `KEEPER_TOP_UP_LIMIT` (1 ETH) over the vault's
  life (D48). What KeeperFund sends back is counted as `keeperReturned`, not as a contribution.
- `fund()` anyone: sends the whole balance to the active game (`receiveFunding`, counted as `capitalIn`) unless it is
  retiring. All trading fees reach the game this way, even above its capital needs.
- `fundPromotion(amount)` timelock: sends `amount` to the active game's promotion budget (`promotionsFunded`).
- `retireGame()` timelock; `repay(final_)` from the active game; `shutdown(minSqrtPriceX96)` anyone, after the last game
  returned and `shutdownDelay` (30 days at launch) passed: whole balance into `ProtocolLiquidity.addLiquidity`.

## 5. PoolOwner and FwaGame

`PoolOwner` (D44) creates and owns the FWA pool and holds the prizes; `FwaGame` keeps the books and drives it.

PoolOwner (constructor: governance, Shapes, Shape Packs or zero, factory, expected FWA implementation; `wire(game)`):

- `createPool(salt)` anyone, once: pays the FWA creation fee from FWA it holds (D4), stores the pool, reads FWA's
  `maxAcquisitionsPerTx` (5) as `maxBatch`, becomes the pool's purchase operator, approves it for Shapes and Shape Packs,
  burns leftover FWA and reports the pool to the game (`poolCreated`), which pushes the gate settings. The pool's owner
  is PoolOwner forever.
- `canPurchase(address)` (FWA's purchase operator hook; FWA calls it for every purchase, its own site included, with a
  100,000-gas stipend and refuses on a revert or `false`), D45: false when FWA's unsettled requests ≥ `maxInFlight`
  (10), when FWA's `edgeBps > maxEdgeBps` or `inventoryChangeCooldown > maxCooldown`, or when
  `activeListingCount < unsettled + maxBatch + minListed`, `minListed = ceil(minLiveBps × rows)`. Reads only live FWA
  state and settings the game pushes (`setGate`, game only), so it holds whether or not anyone syncs.
- Game only: `mintAndList(mints)` payable (mints each prize with exactly its cost: a Shape by `mintTo`, a Pack by
  `createPackTo` with the fewest Shapes, and lists them in one `listNFTs`; reverts unless the ETH sent equals the sum),
  `withdrawAndBurn(ids)`, `recoverAndBurn(id)` (Shapes burned, Packs redeemed; all ETH to the game), `collectProceeds`,
  `setAcquisitions`, `retirePool`. `costOf(kind, backing)`: a Shape's backing + mint fee, or a Pack's backing + one mint
  fee per Shape inside; 0 for a Pack below Shape Packs' minimum or without Shape Packs.

FwaGame: constructor takes a `Config` (governance, factory, PoolOwner, vault, farm, buyback, KeeperFund, board, pricing,
buyer, `Capital`, `marketLead`).

### 5.1 Opening and admission
- `openGame()` timelock: requires the ENGINE market to have been open at least `marketLead` (48 h at launch, read from
  the hook's `launchedAt`), every board row listed, and `cash() ≥ reserveTarget`. Sets `opened`, starts the farm clock
  (`openBlock`; genesis ends at `openBlock + 21 × 7,200`), and admits purchases.
- Admission (D36, D45): FWA's own `ACQUISITIONS_ENABLED` switch is on exactly when `opened && !paused && !retiring &&
  admissible()`, where `admissible()` = FWA `edgeBps ≤ maxEdgeBps` and `inventoryChangeCooldown ≤ maxCooldown` and live
  board rows ≥ `minLiveBps` of the board; `sync` applies it. The purchase gate above refuses earlier and without a sync
  (in-flight requests and a full batch counted). Both bind direct FWA purchases, not only the site. Settlement,
  delivery, refunds and withdrawals continue while purchases are closed. `setPaused(bool)` timelock.

### 5.2 The walk (D6, D24)

`sync(maxCount)` anyone, tipped: cranks FWA `processAcquisitions`; resolves open requests that became terminal; sees new
sequences; collects owner proceeds through PoolOwner and trues the books up to them; pays the operating allocation and
distributable profit; when maintenance is due lists replacements and ends an expired promotion; applies admission;
tops KeeperFund up from the vault. Each step runs in its own `try` and a failing one emits `StepFailed` (D46); booking
reads no module. Reverts `NoWork` with no progress.

- Cursor `seenSeq` over every issued sequence; at first sight `epochAccepted[epoch]++` with
  `epoch = (requestBlock − openBlock) / 7,200`. Terminal statuses `Fulfilled`, `Expired`, `Refunded`, `TimedOut`,
  `DeliveryRefunded` resolve (`epochResolved++`).
- `Fulfilled` adds the request's ticket ETH (its escrowed FWA fee, not the VRF fee) to the purchaser's weight
  (`epochWeight`, `userWeight`) and books the capture. Refunded, expired and undelivered requests add nothing.
- `DeliveryPending`: FWA has taken the prize out of the draw, so the game vacates its row at once (replaced at the next
  restock) and keeps the prize carried at cost. After `DELIVERY_GRACE_BLOCKS` (57,600) it counts resolved without weight
  so the epoch can become final, and stays open for its economics. `DeliveryRefunded`: the prize is recovered and burned
  or redeemed (backing back to cash, mint fees written off); if recovery fails the request stays open and is retried.
- `isEpochFinal(e)`: the epoch has ended, every request issued in it has been seen, `accepted == resolved`.

### 5.3 Accounting (D32, D33)

Inventory is capital carried at cost (backing + mint fee). Per captured board prize:

- revenue += owner proceeds `paid − (paid − base)/2`, `base = paid / (1 + bookingEdgeBps)`, where `bookingEdgeBps` is
  the highest FWA edge governance has ever accepted (D47), so a booked result never exceeds FWA's own split whatever the
  configuration later does; once no request is outstanding and FWA holds no proceeds for the game, the difference to
  what FWA actually paid (`proceedsCollected − proceedsBooked`) is added to revenue (`TrueUp`);
- prize expense += the prize's carried cost, once (the replacement purchase is a capital movement, not an expense);
- operating allocation += the listing's `opsBps` (3%, fixed at listing) of the expected replacement cost
  `base / (1 + markup)`, the listing's markup also fixed at listing.

Burning a held prize (retirement, a refunded delivery, an ended promotion) writes off its mint fee. KeeperFund's
overflow above its target comes back (`returnOps`) and reduces the net operating expense.

- `profit() = revenue + opsReturned − prizeExpense − opsAccrued` (signed, cumulative: losses carry forward; capital never
  enters it). `distributed` is what has gone to the buyback.
- `protectedCash() = replacementsOwed + opsOwed + reserveTarget + exposure`, with `exposure = min(FWA unsettled requests ×
  the largest prize cost minted, inventory cost)` (D49).
- `distributable() = min(profit − distributed, cash − protectedCash)`, zero while retiring or when either is not
  positive. `_pay` (each sync and retirement step) first pays the operating allocation to KeeperFund once replacements
  are covered (during retirement, from any cash), then sends `distributable()` to the buyback.
- `cash() = balance − promoBudget`. Every counter is public; `Lens.accounts` returns them together.

### 5.4 Inventory (D9, D35, D49, D51)

One listing per board row (bitmap `liveRows`, ≤ 200 rows); a row is a Shape (kind 0) or a Shape Pack (kind 1, backing ≥
Shape Packs' 0.03 ETH minimum). Maintenance is due only when no request is in flight (FWA would stage new listings),
unless the board is within `maxInFlight + 5` rows of the gate's floor; and then when `listBatch` (3) rows wait, or
`maintenanceInterval` (5 min, and at least six FWA inventory cooldowns) has passed since the last inventory change, or
a promotion has ended. Each restock pays PoolOwner to mint prizes for up to 20 empty rows while cash covers them and
list them in one call. Price = `PricingPolicy.listPrice`, clamped to `[cost, cost × 1.05]`; markup and operating
allocation are fixed per listing. A board change applies to a row when it is next vacated.

### 5.5 Promotions (D37)

`fundPromotion()` payable (the vault, or anyone) adds to `promoBudget`. `startPromotion(backing, priceBps, endBlock)`
timelock: one at a time, the prize's full cost reserved from the budget (its maximum obligation), listed once at
`priceBps` of cost and never repriced (no per-pull decay), price ≥ 50% of backing and win probability ≤ 10%, end at a win
or `endBlock` (≤ 30 days out). An unwon prize is withdrawn and burned at the next window after its end. Its proceeds and
cost stay in the budget (`promoProceeds`, `promoSpent`); turnover seen while it is live is `promoTurnover`.
`releasePromotion(amount)` timelock returns unspent budget to the vault as capital.

### 5.6 Retirement and governance

- `retire()` (vault only) retires the FWA pool; `retireStep(maxCount)` anyone, tipped (may spend the keeper floor):
  advance; once nothing is unsettled and every sequence is seen, withdraw up to 20 Active or Staged listings per call
  (Shapes burned, Packs redeemed); then repay everything to the vault. A prize stuck in delivery quarantine does not block it (D30). Works
  while the factory is withdraw-only.
- `setModule("board"|"pricing"|"buyer", addr)`; `setCapital(Capital)` with `reserveTarget ∈ [2 × max board backing,
  1,000 ETH]`, `maintenanceInterval ≤ 1 day`, `minLiveBps ∈ [5,000, 10,000]`, `maxInFlight ∈ [1, 20]`,
  `maxEdgeBps ≤ 1,000` (raises `bookingEdgeBps` when above it), `maxCooldown ≤ 1 day`; each change is pushed to the gate.

## 6. Converter (module, D10, D38)

`convert(listingId, minEngineOut, allowNoBonus)`: listing of the game's pool, status `Settled`, collection Shapes or Shape
Packs, not converted before (one time per listing; eligibility follows the token). Pulls the prize from the caller,
burns the Shape or redeems the Pack, and buys ENGINE through `EngineBuyer` for the caller with exactly the ETH it
returned: `convert` is not payable and measures
the burn's ETH, so nothing can top it up. Adds `bonusBps()` of the output from the farm's bonus pool while it lasts;
an empty pool never stops a conversion (`allowNoBonus`). `bonusBps() = min(conversionBonusBps, 500, sell fee)`.
Counters `conversions`, `totalEthIn` (player conversion purchases), `totalEngineOut`, `totalBonus`.

## 7. GenesisFarm (D34)

- Holds the 190M genesis allocation and the 10M bonus pool. Clock: `openBlock` (set once by a ledger's `start()`),
  `EPOCH_BLOCKS` 7,200, `GENESIS_EPOCHS` 21, `genesisEndBlock() = openBlock + 151,200`: fixed, no shorten or extend.
- Schedule (frozen): `stepWeight(e)` = 8 for the 14 steady epochs, then 7, 6, …, 1 (87.5% … 12.5%), summing to 140.
  `allocationCap(e) = F × w(e)/140` (F/17.5 when steady; the last epoch takes the rounding, so the caps sum to F).
  `rateCapOf(e) = rateCap × w(e)/8` ENGINE per ETH of eligible ticket ETH; `rateCap` is fixed at deploy from the launch
  price (10% of ticket ETH at the launch price).
- `potOf(e) = min(allocationCap(e), epochWeight(e) × rateCapOf(e) / 1e18)`; rewards pro rata by `userWeight`, rounded
  down (dust stays in the farm). Zero participation: pot 0. Epochs ≥ 21: cap 0, so requests at or after the end block
  earn nothing, while a request accepted before it keeps its epoch however late it settles.
- `finalize(epochs[])` anyone, tipped: for each final epoch fixes the pot and burns `allocationCap − pot`, which nobody
  can earn any more. `claim(epochs[])` finalizes as needed and pays; claims never expire; an epoch held open by a stuck
  delivery does not block any other epoch. `reserved()` = unfinalized caps + unclaimed fixed pots.
- `payBonus(to, amount)` from the registered Converter: pays up to what the pool holds. `retireBonus()` anyone, after
  genesis end: burns what is left; conversion continues without a bonus.
- Ledgers: up to 4 games (`addLedger`, never removed); weight and finality are summed/required across them.

## 8. Buyback and KeeperFund

- `Buyback` (D39): receives profit only from registered sources (plain ETH from the game, counted as `profitReceived`), and
  the buyer's change; anything else reverts. `process(minOut)` anyone, tipped: at most once per `minSpacing` (1 h), one
  purchase of `min(balance, sliceWei)` (slice 0.05 ETH, a maximum), refused when the price has moved more than
  `maxDeviationBps` (2%) against the buyer since the block opened (the hook records the opening price), capped at
  `maxImpactBps` (3%) price impact; every ENGINE bought is burned. A keeper's `minOut` can only tighten these limits.
  Works through the genesis transition (EngineBuyer is exempt from the gate).
- `KeeperFund` (D16, D48): funded by the game's operating allocation and topped up by the vault (`topUp`, vault only,
  counted as `capitalHeld`); overflow above `keeperTargetWei` goes back to the vault first (up to `capitalHeld`), then to
  the game (`returnOps`). `tip(keeper, gasUsed, work, retirement)` from registered payers (game, buyback, farm): nothing
  for no work; otherwise `min(tipCap, (gasUsed + gasOverhead) × min(tx.gasprice, maxGasPrice)) + flatFee`, the flat fee
  at most once per `feeInterval` per payer. Pays what it can and never reverts for lack of balance, so settlement never
  depends on it; keeps `maintenanceFloor` for retirement. Bounds: tip cap ≤ 0.05 ETH, gas price cap ≤ 100 gwei,
  overhead ≤ 200,000, flat fee ≤ 0.005 ETH, interval ≤ 1 day.

## 9. Token, market, liquidity

- `EngineToken` "ENGINE", 18 decimals, 1,000,000,000 minted once: 800M to ProtocolLiquidity, 200M to the farm (190M
  genesis + 10M bonus), D40. `burn`, ERC-2612 permit, renderer-backed `contractURI()`/`tokenURI()`.
- `EngineHook` (v4): `beforeInitialize` only from ProtocolLiquidity, once. Every swap asks `SwapPolicy.check(sender,
  isBuy)`; buys may be refused, sells never (D17). Fee placement: exact-in buy in `beforeSwap`, exact-out buy and
  exact-in sell in `afterSwap`, exact-out sells revert. Fee from the PoolManager straight to the PrizeVault. Cap 500 bps,
  or 9,500 bps within 3 h of initialisation. `blockOpenPrice()`: the price before the first swap of the current block.
- `SwapPolicy`: fee 300 (≤ 500); gate: from `openBlock` until `genesisEndBlock`, buys from non-exempt senders refused;
  it lifts by itself at the end block, at the ordinary fee, with no transaction from anyone. Exempt = EngineBuyer and
  ProtocolLiquidity, fixed at wiring with no setter: the hook's `sender` is whoever called `PoolManager.swap`, so a shared
  router can never be exempted (D38). Anti-snipe extra buy fee 5,000 bps decaying over 60 min.
- `EngineBuyer.buy(minOut, to, maxImpactBps)`: registered callers only (Converter, Buyback); exact-ETH-in with a price
  limit; unspent ETH back to the caller.
- `ProtocolLiquidity` (D50): `launch()` timelock once, not payable: initialises the pool at the immutable `startTick`
  (a multiple of 200) and adds every ENGINE it holds as one single-sided position over `[TICK_LOWER, startTick)`. Buys
  move the price into the range; it can never return above the start, and sellers can only take out ETH buyers put
  in. `addLiquidity(minSqrtPriceX96)` (full range) by the vault or the timelock; no remove.

## 10. Launch sequence

1. Deploy (`script/deploy.sh`), postflight. 2. `ProtocolLiquidity.launch()`, no ETH: the public market runs for 48 h,
buys and sells. 3. Fund the vault with the opening capital; `fund()`; `sync` until the board is listed.
4. `openGame()`: genesis starts, public buys through the protocol pool close, sells keep working, conversions and
profit-funded buys continue. 5. At `genesisEndBlock` public buys reopen automatically: no owner transaction, keeper,
reward cleanup, delivery or claim is needed. The game keeps running on its own capital and results.

## 11. Keeper jobs and Lens

Tipped: `FwaGame.sync`, `FwaGame.retireStep`, `Buyback.process`, `GenesisFarm.finalize`. Tip = gas used at the gas
price paid (capped) plus an hourly flat fee (section 8); no progress, no tip (calls revert `NoWork`). The hosted keeper
(`keeper/`) acts when work has waited 6 h, when the basefee is below 1 gwei, or at once when the purchase gate is closed
with rows waiting.

`Lens`: `game`, `accounts` (the books), `funding` (trading fees, promotions, profit received, ETH spent on buybacks,
ENGINE burned, conversion purchases), `inventory` (live listings with current probabilities), `targetBoard` (modelled
full board), `market`, `epochs`, `claimable`, `conversionQuote`, `work` (including the gate's answer).

## 12. Launch values

`script/LaunchConfig.sol`, explained in `docs/ECONOMICS.md`: board 30 × 0.01 / 45 × 0.05 / 25 × 0.5 ETH Shapes (15.15 ETH
at cost), restock trigger 3 rows, markup 500, operating allocation 300, conversion bonus 200, hook fee 300, anti-snipe
5,000 over 60 min, reserve target 12 ETH, maintenance 5 min, admission fill 80%, in-flight limit 10, max edge 500, max
cooldown 5 min, market lead 48 h, start tick from the environment (184,200 recommended, ≈ 10 ETH FDV), rate cap 10% of
ticket ETH at the start price, slice 0.05 ETH, spacing 1 h, impact 300, deviation 200, keeper tip cap 0.05 ETH, gas
price cap 5 gwei, overhead 70,000, flat fee 0.0003 ETH hourly, keeper target 0.5 ETH and floor 0.05 ETH, seed 0.05 ETH,
vault top-up target 0.1 ETH (≤ 1 ETH lifetime), shutdown delay 30 days, liquidity impact cap 500.

## 13. Acceptance (what the test suite covers)

`forge test` on a pinned mainnet fork (block 26,279,000) with the real Shapes, FWA factory, VRF service, FWA token and
hook, and the v4 PoolManager: unit suites (`test/unit`), fork suites (`test/fork`: game, accounting and admission,
market including the single-sided launch, smoke, gas receipts, and resilience: keeper outage, reverting modules,
booking under configuration changes, Shape Packs end to end, keeper top-ups), the invariant suite
(`test/invariant/Custody.t.sol`: custody, books, ledger, farm bounds, buyback spends profit only, modules and PoolOwner
hold nothing, escrow, keeper top-ups, booking never ahead of FWA, gate headroom) and the genesis rehearsal
(`test/scenario`). The follow-up's
cases are listed in `docs/FINAL_REPORT.md`.
