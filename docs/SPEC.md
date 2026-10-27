# Draw Shapes + ENGINE: specification (as built)

This is the system as implemented in `src/`, from `docs/BUILD_PROMPT.md` (task text, 4d3e811 and the amendment
ecdc9eb). Decisions the brief left open, and where the build differs from it, are in
`docs/IMPLEMENTOR_DECISIONS.md` (cited as D<n>). Economics and gas: `docs/ECONOMICS.md`. Operations:
`docs/DEPLOY.md`, `docs/RUNBOOK.md`. No independent audit has been done.

## 1. What it is

A real-money NFT gacha on Ethereum mainnet. Players pay ETH for a VRF draw from a board of Shapes (ETH-backed
NFTs, burnable for their backing) on an FWA V2 custom pool that our contract owns. The house is a protocol-owned
prize inventory. ENGINE is the token: during a 21-epoch genesis every delivered pull earns ENGINE; for the whole
life of the game 90 % of the treasury buys ENGINE back, half burned and half paid to that epoch's players.
From game open to genesis end the canonical ENGINE pool refuses public buys; sells always work.

The owner's income is the Shapes mint fee (0.001 ETH per Shape minted), paid by the game to the Shapes contract.

## 2. Custody and governance (D21)

Governance is an OpenZeppelin `TimelockController` with `minDelay = 0` at launch; proposer and executor are the
owner's governance address; there is no admin. Every setter is timelock-only. Every contract that holds ETH,
NFTs or ENGINE has no withdraw function and no upgrade path. Code-enforced outflows:

| holder | ETH / tokens may go only to |
|---|---|
| PrizeVault | the active game (`fund`), ProtocolLiquidity (`shutdown`) |
| FwaGame | the vault (`repay`), Shapes (mint cost), Treasury (margin line), KeeperFund (markup line) |
| Treasury | registered sinks (`draw`, up to each sink's allocation) |
| KeeperFund | keepers (tips), Treasury (overflow above target) |
| GenesisFarm | claimants (`claim`), the Converter's caller (`payBonus`), burns |
| ProtocolLiquidity | the pool position only (no remove) |
| EngineHook | holds nothing; fees go from the PoolManager to the Treasury |

Governance chooses the active game, the treasury sinks and every module, so governance can direct all capital;
the timelock delay is the only notice, and it is 0 at launch. The site's Terms say this.

## 3. Contracts

Holders (no upgrade path): `PrizeVault`, `FwaGame`, `GenesisFarm`, `Treasury`, `KeeperFund`, `EngineToken`,
`ProtocolLiquidity`, `EngineHook`. Modules (replaceable by the timelock; hold nothing between calls):
`BoardPolicy`, `PricingPolicy`, `GrailPolicy`, `SwapPolicy`, `EmissionSchedule` (fixed in the farm, D12),
`EngineBuyer`, `Converter`, `EngineRenderer`, the sinks `Buyback` and `GrailFund`. Read-only: `Lens`.
Deploy helper: `FwaFeeBuyer`. Shared base: `Governed` (immutable `governance`, one-shot `wire` by the deployer).

Runtime sizes (legacy codegen, optimizer 200): FwaGame 21,223; GenesisFarm 10,070; Lens 10,806;
ProtocolLiquidity 8,578; EngineHook 5,308; EngineBuyer 4,190; KeeperFund 4,132; Treasury 3,855; Converter 3,489;
Buyback 3,497; EngineToken 2,940; PrizeVault 2,787 bytes. All under 24,576.

## 4. PrizeVault

- `receive()`. `wire(game)` (deployer, once) and `setActiveGame(game)` (timelock): only when no game is active,
  which means the previous one repaid in full (`repay(true)` clears it).
- `fund()` anyone: sends the whole balance to the active game (`receiveFunding`) unless it is retiring.
- `retireGame()` timelock: marks retiring and calls the game's `retire()`.
- `repay(final_)` from the active game; `final_` while retiring closes it and stamps `returnedAt`.
- `shutdown(minSqrtPriceX96)` anyone: no active game, `returnedAt != 0`, `shutdownDelay` passed (launch 30 days,
  bound 1 day … 365 days): whole balance to `ProtocolLiquidity.addLiquidity`.

## 5. FwaGame

Constructor takes a `Config` struct (governance, Shapes, factory, expected FWA implementation, vault, farm,
Treasury, KeeperFund, the four modules, `reserveTarget`, `maintenanceInterval`).

- `createPool(salt)` anyone, once: pays the factory's FWA creation fee from FWA it holds (bought for it by
  `FwaFeeBuyer`, D4), stores the pool, approves it for Shapes, burns leftover FWA. The pool's owner is FwaGame
  forever (FWA `OwnershipLocked`). `purchaseOperator` is never set, so FWA's own site sells our pulls.
- `openGame()` timelock: enables FWA acquisitions; starts the farm clock if not started. `setAcquisitionsEnabled`.
- `fundGrail()` payable, anyone, not while retiring: the GRAIL reserve (GrailFund sink, or the owner seeding).
- `sync(maxCount)` anyone, tipped: cranks FWA `processAcquisitions`; resolves open requests that became terminal;
  sees new sequences; withdraws owner proceeds; routes distributable revenue; at a maintenance window lists
  replacements and steps the GRAIL. Reverts `NoWork` with no progress.
- Walk (D24): cursor `seenSeq` over every issued sequence; at first sight `epochAccepted[epoch]++` with
  `epoch = (requestBlock − farm.openBlock) / 7,200`. Terminal statuses `Fulfilled`, `Expired`, `Refunded`,
  `TimedOut`, `DeliveryRefunded` resolve (`epochResolved++`); `Fulfilled` credits one unit to the purchaser
  (`epochUnits`, `userUnits`) and books the capture; `DeliveryRefunded` recovers the NFT to be relisted.
  `Pending`/`Ready`/`DeliveryPending` stay open; a `DeliveryPending` older than `DELIVERY_GRACE_BLOCKS` (57,600)
  counts resolved without a unit and stays open for its economics.
- `isEpochFinal(e)`: the epoch has ended, every issued request in it has been seen, `accepted == resolved`.
  `epochTotals(e) → (accepted, resolved, units)`.
- Booking (D7): from `paid` and the live FWA `edgeBps`, `base`, `proceeds`, `markupLine`, `marginLine`,
  `expectedCost`; lines become pending; `replacementsOwed += cost`; realised `expectedCost − cost` into
  `bookedGain`/`bookedLoss`. A GRAIL capture advances the ladder and adds to `grailCapturedBacking`.
- Capital (D23): `cash() = balance − grailReserve`; `distributable() = cash − replacementsOwed − reserveTarget`
  (floored at 0). Pending lines leave only up to `distributable`, markup first. `nav() = cash + inventoryBacking`.
- Inventory (D9, D25): one listing per board row (bitmap `liveRows`); at a window (a full `listBatch` waiting, or
  `maintenanceInterval` since the last change) mints Shapes for empty rows while cash pays and lists them in one
  `listNFTs` call; Pack rows are skipped (D3). Price = `PricingPolicy.listPrice`, clamped to
  `[cost, cost × 1.05]`; the listing's markup is snapshotted.
- GRAIL: when no GRAIL is listed and `grailReserve ≥ backing + mint fee` of `GrailPolicy.grailBacking(step)`,
  mint and list it; reprice at windows from `GrailPolicy.grailPrice(backing, pullsSinceListed)`. Hard bounds:
  price ≥ 50 % of backing (`MIN_GRAIL_PRICE_BPS`), win probability ≤ 10 % (`MAX_GRAIL_PROB_BPS`).
- Retirement: `retire()` (vault only) retires the FWA pool; `retireStep(maxCount)` anyone, tipped (may spend the
  keeper floor): advance; once FWA has nothing unsettled, every sequence is seen and nothing is open, withdraw up to
  20 listings per call to itself and burn them for backing; then repay the whole balance to the vault (`final`).
  Works while the factory is `globalWithdrawOnly` (tested).
- Governance: `setModule("board"|"pricing"|"grail"|"buyer", addr)`; `setCapital(reserveTarget, maintenanceInterval)`
  with `reserveTarget ∈ [2 × max board backing, 1,000 ETH]`, `maintenanceInterval ≤ 1 day`.
- Hard bounds: board ≤ 200 rows (`MAX_BOARD`), ≤ 20 listings per window (`MAX_LIST_BATCH`), markup ≤ 500 bps.

## 6. Converter (module, D10)

`convert(listingId, minEngineOut, allowNoBonus)`: listing of the game's pool, status `Settled`, collection Shapes,
not converted. Pulls the Shape from the caller, burns it, buys ENGINE through `EngineBuyer` for the caller with the
backing (no fee, no gate, impact uncapped; `minEngineOut` protects), adds `bonusBps()` of the output from the farm's
bonus pool. `bonusBps() = min(PricingPolicy.conversionBonusBps, 500, SwapPolicy.feeBps)`. Reverts `BonusUnavailable`
when the pool cannot cover the bonus unless `allowNoBonus`.

## 7. GenesisFarm

- Holds 100M genesis, 10M bonus pool, 790M seasons reserve. Clock: `openBlock` (set once by a ledger's `start()`),
  `EPOCH_BLOCKS` 7,200, `genesisEpochs` 21. `currentEpoch()`, `genesisEndBlock()`.
- Ledgers: up to 4 games (`addLedger`, never removed); units and finality are summed/required across them.
- `potOf(e)` = genesis allocation (`e < genesisEpochs`, from the immutable `EmissionSchedule`, capped by the
  remaining budget) + season allocation + deposits + rolled-in; snapshotted at the first claim.
- `claim(epochs[])`: each final, unclaimed, with units; pays `pot × userUnits / units`. Claims never expire.
- `deposit(amount)` from the registered depositor (Buyback) into the current epoch. `rollover(e)` moves the
  non-genesis part of a final empty epoch into the current one.
- `payBonus(to, amount)` from registered bonus payers (Converter): pays up to what the pool holds.
- `retireUnearned()` anyone, tipped, after genesis end with every genesis epoch final, once: burns the genesis
  allocation of empty epochs and the unused bonus pool.
- `shorten(n)` timelock: one way, `n ≥ 7`, `n ≥ currentEpoch + 3`; burns the cut epochs' allocations now.
- `scheduleSeason(start, epochs, amount)` timelock (D14) and `burnReserve(amount)`; the reserve has no other outflow.
- `EmissionSchedule.allocationOf(e, T) = T(3(N−1) − 2e) / (2N(N−1))`, N = 21, last epoch takes the remainder;
  sums to T exactly (fuzzed).

## 8. Treasury, sinks, KeeperFund

- Treasury: `receive()`; `wire(keeperFund, sinks, bps)` once, `setSinks` timelock (≤ 8 sinks, each with code, no
  duplicates, sum 10,000; returns all allocations). `distribute()` anyone, tipped: allocates the unallocated balance
  by the table (`owed`). `draw(amount)` by a sink up to its `owed`.
- `Buyback.process(minOut)`: at most once per `minSpacing` (launch 1 h, ≤ 1 day); slice
  `min(sliceWei, max(owed/4, 0.005 ETH))` (launch slice 0.05 ETH, bound 0.005 … 10); one purchase through
  `EngineBuyer` capped at `maxImpactBps` (launch 300, ≤ 2,000); `burnShareBps` (launch 5,000) burned, the rest
  deposited into the farm's current epoch; unspent ETH back to the Treasury; tipped.
- `GrailFund.process()`: draws its allocation and calls `FwaGame.fundGrail`; tipped. `setGame` timelock.
- KeeperFund (D16): `fundKeeper()` (overflow above `keeperTargetWei` to the Treasury); `tip(keeper, gasUsed, age,
  items, retirement)` from registered payers; `quoteTip`; `available(retirement)`; `withdrawTips()`.
  Bounds: premium ≤ 10,000 bps, basefee cap ≤ 500 gwei, tip cap ≤ 0.05 ETH, max bounty ≤ 0.01 ETH, ramp 1 s … 7 days,
  overhead ≤ 200k gas, target ≤ 100 ETH, floor ≤ min(10 ETH, target).

## 9. Token, market, liquidity

- `EngineToken` "ENGINE"/"ENGINE", 18 decimals, 1,000,000,000 minted once in the constructor (100M to
  ProtocolLiquidity, 900M to the farm; exact total checked), `burn`, ERC-2612 permit, `contractURI()` and
  `tokenURI()` from the timelock-settable renderer (`IMetadataRenderer.contractURI(token)`, the artcoins v2 shape).
- `EngineRenderer`: on-chain SVG gear with the burned share of supply.
- `EngineHook` (v4, PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`): `beforeInitialize` only from
  ProtocolLiquidity, once, ETH/ENGINE, LP fee 0, tick spacing 200. Every swap asks `SwapPolicy.check(sender, isBuy)`;
  buys may be refused (`SwapNotAllowed`), sells never (D17). Fee placement: exact-in buy in `beforeSwap`, exact-out
  buy and exact-in sell in `afterSwap`, exact-out sells revert. Fee taken from the PoolManager straight to the
  Treasury. Cap 500 bps, or 9,500 bps within 3 h of initialisation.
- `SwapPolicy`: fee 300 (≤ 500); gate: from `farm.openBlock` to `farm.genesisEndBlock`, buys from non-exempt
  senders refused; exempt = EngineBuyer and ProtocolLiquidity (D27), fee 0; anti-snipe extra buy fee
  `snipeStartBps × remaining/window` (launch 5,000 over 60 min; ≤ 9,000 and ≤ 3 h).
- `EngineBuyer.buy(minOut, to, maxImpactBps)`: registered callers only (Converter, Buyback); exact-ETH-in swap with a
  price limit from `maxImpactBps`; unspent ETH back to the caller.
- `ProtocolLiquidity`: `launch()` timelock once, price = held ENGINE / `msg.value`, full range (ticks ±887,200);
  `addLiquidity(minSqrtPriceX96)` by the vault or the timelock: half-swap capped by `maxImpactBps` (launch 500,
  ≤ 2,000) and the caller's limit, then adds what it can; leftovers stay for the next addition; no remove.

## 10. Keeper jobs and tips

Tipped: `FwaGame.sync`, `FwaGame.retireStep`, `Treasury.distribute`, `Buyback.process`, `GrailFund.process`,
`GenesisFarm.retireUnearned`. Tip = `min(tipCap, (gasUsed + gasOverhead) × min(basefee, basefeeCap) × (1 + premium))
+ maxBounty × min(age, ramp)/ramp × min(items, 20)/20`. The hosted keeper (`keeper/`) calls only when work has
waited `BACKUP_AFTER_SECONDS` (6 h) or the basefee is below `BACKUP_BASEFEE_GATE` (1 gwei).

## 11. Lens

`game(addrs)`, `market(addrs)`, `epochs(farm, user, from, to)`, `claimable(farm, user, from, to)`,
`conversionQuote(addrs, backing)` (spot estimate), `treasuryTable(treasury)`, `work(addrs)` (requests waiting,
unlisted rows, ages, treasury state, buyback readiness, `retireUnearned` readiness, keeper fund).

## 12. Launch values

See `script/LaunchConfig.sol` and `docs/ECONOMICS.md` section 1. Board 80 × 0.01 / 15 × 0.05 / 5 × 0.1 ETH Shapes,
list batch 20, markup 300, bonus 200, GRAIL ladder 0.5 / 1 / 5 ETH at 95 % decaying 1 % per 100 pulls to 80 %,
hook fee 300, anti-snipe 5,000 over 60 min, reserve target 0.75 ETH, maintenance interval 30 min, table Buyback 9,000
/ GRAIL 1,000, burn share 5,000, slice 0.05 ETH, spacing 1 h, impact 300, keeper as section 8 with target 0.5 ETH and
floor 0.05 ETH, shutdown delay 30 days, liquidity impact cap 500.

## 13. Acceptance (what the test suite covers)

`forge test` on a pinned mainnet fork (block 26,279,000) with the real Shapes, Shape Packs, FWA factory, VRF service,
FWA token and hook, and the v4 PoolManager: unit suites (`test/unit`), fork suites (`test/fork`: game, market, smoke,
gas receipts), the invariant suite (`test/invariant/Custody.t.sol`: custody, solvency, ledger, farm bounds, treasury
table, empty sinks, escrow) and the genesis rehearsal (`test/scenario`). Size check: `forge build --sizes --skip test`
fails CI over 24,576 bytes.
