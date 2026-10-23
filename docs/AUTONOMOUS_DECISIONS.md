# Autonomous decisions: coin-supported Draw Shapes engine

Date: 2026-10-23. Branch `feat/coin-funded-engine`. The owner was unavailable; every material choice
below was made without them and is open to their review. Confidence labels: **verified** (exercised
against real mainnet contracts on a fork), **modeled** (`sim/engine.mjs` on the lab model, 12 seeds,
365 days; tables in `docs/ECONOMIC_VALIDATION.md`), **provisional** (a defensible default that needs
live data), **unresolved** (needs the owner or counsel).

Simulation numbers quoted here are medians unless marked p10 / p90.

---

## D1. Architecture: keep the Pool, put a treasury in front of it

**Question:** Rebuild the game around the coin, or wrap the existing depositor pool?

**Decision:** Keep `Pool`, `PoolAdmin`, `PoolListing` (the FWA V2 game, 422 fork tests) and make a new
`EngineTreasury` its only shareholder and its admin. Three new contracts: `FoundingRound` (escrow and
founder ledger), `EngineTreasury` (all treasury accounting, coin fees, buyback, pool administration),
`PrizeSponsorship` (one sponsor deal). One pool change: `boardNavCap` (D8).

**Why:** The pool already books every FWA settlement into buckets that separate player backing,
receivables, maintenance and the GRAIL fund, and its share accounting turns "ordinary NAV above what the
owner put in" into a clean definition of game earnings (D6). A single shareholder makes the share system
a ledger of principal instead of a depositor product.

**Tradeoff:** Keeps 3 delegatecall modules near EIP-170 (PoolListing 24,400 B, 176 B headroom). The pool
still carries depositor code paths (claims queue, migration) that the engine uses only for withdrawals
and retirement.

**Example:** `treasury.harvest()` withdraws `nav - basis` worth of shares; the pool's own books have
already netted FWA's share, the creator's mint fees, keeper refunds and GRAIL funding out of that NAV.

**Alternative rejected:** A new controller that owns the FWA pool directly. It would re-implement
settlement, replacement, GRAIL merges and exit (thousands of lines already tested) for no economic gain.

**Where:** `src/engine/*`, `script/EngineDeployer.sol`. **Confidence:** verified.

## D2. Founding round size: 20 ETH

**Question:** 25 ETH (provisional), 30 ETH, or another target?

**Decision:** 20 ETH target and hard cap, 48 hour window, 14 day launch window, 0.05 ETH minimum.

**Why:** In every scenario the treasury reserve was never needed to refill the pool (0 ETH refilled at
p90 across all stress rows), and the extra capital of a 25 or 30 ETH round only enlarges the opening
GRAIL fund, which made no measurable difference within a year once trading boosts the GRAIL (wins 11 vs
10 vs 11, largest win 25 ETH in each). Founders reach 1.0x sooner with less capital at risk.

**Tradeoff:** A smaller opening GRAIL fund (9.5 ETH vs 14.5 ETH): the opening five (5 ETH) plus four
1 ETH pieces, instead of enough for a 10 ETH GRAIL within hours. Founders' maximum payout is 24 ETH
instead of 30 ETH.

**Example:** 100 draws and 5 ETH of trading a day: 1.0x at day 113 for 20 ETH, day 140 for 25 ETH,
day 168 for 30 ETH; game earnings 24.2 / 23.9 / 24.1 ETH a year.

**Alternative rejected:** 25 ETH. Same game, 5 ETH more founder capital at risk, 27 days slower to 1.0x.
The deploy path takes any target (`ROUND_TARGET_WEI`), so the owner can choose 25 without code changes.

**Where:** `script/env/engine.mainnet.env`, `script/EngineDeployer.sol` (`_treasuryConfig`).
**Confidence:** modeled.

## D3. Opening deployment of the round

**Question:** How does the round become a game?

**Decision:** `activate()` sends 6 ETH into the pool as ordinary NAV (a board of about 150 to 175 items),
0.5 ETH to maintenance, keeps a reserve of up to 4 ETH, and puts the rest (9.5 ETH for 20 ETH) into the
GRAIL fund, of which 5.005 ETH forms the 5 ETH opening GRAIL at `open()`.

**Why:** 6 ETH is the board depth that keeps a ticket near 0.02 ETH while leaving the GRAIL meaningful
odds (D8 table: 3.5 ETH pool lifts the ticket to 0.0217, 14 ETH cuts GRAIL wins to 4 a year). A 4 ETH
reserve covers two thirds of the pool's NAV, against a modeled worst drawdown that never reached the
80 percent refill line.

**Tradeoff:** Founder capital in the GRAIL fund is prize money: if the GRAIL is won it is gone, and only
an unwon GRAIL fund returns to founders in a wind-down.

**Example:** Fork, block 26,240,000: after activation and `open()` the board listed 150 items, NAV
5.736 ETH (0.264 ETH of opening mint fees), one 5 ETH GRAIL listed, quote 0.01825 ETH per draw.

**Alternative rejected:** Holding 13.5 ETH as reserve (the 25 ETH first draft): idle, never touched in
any simulated year, exactly the "cash under a discretionary reserve label" the brief warns against.

**Where:** `EngineTreasury.activate`, `EngineDeployer._treasuryConfig`. **Confidence:** verified (split
and opening), modeled (sizing).

## D4. Founder payment cap: 1.2x

**Question:** 1.1x, 1.2x or 1.3x of contributions?

**Decision:** 1.2x (`capBps` 12,000), a ceiling on cumulative payments including principal, pro rata,
pull claims, not guaranteed.

**Why:** At the base case the cap is reached in about 5 months; 1.3x adds 15 days of diverted cash flow
for 2.5 ETH more per 25 ETH; 1.1x pays too little for risk capital that can lose its GRAIL share and
depends on unproven demand.

**Tradeoff:** Each 0.1x costs coin buybacks and prizes roughly 2.5 ETH per 25 ETH raised.

**Example:** 25 ETH, 100 draws, 5 ETH trading: cap reached day 155 (1.1x), 168 (1.2x), 183 (1.3x).

**Alternative rejected:** 1.3x, which delays the switch to full buybacks without a measurable recovery
benefit at low volumes (none reach 1.0x at 10 draws and no trading under any cap).

**Where:** `FoundingRound`, `ROUND_CAP_BPS`. **Confidence:** modeled; the investor-rights question is
unresolved (D25).

## D5. Founder allocation: 65 percent of trading receipts, 50 percent of game earnings

**Question:** Which shares of the two cash flows go to founders while they are owed?

**Decision:** Keep the provisional 65 / 50. After the cap: trading receipts go 100 percent to prizes
(and the sponsor share), game earnings 100 percent to buybacks.

**Why:** Founders are paid from both flows, so a working game with dead trading still repays them (300
draws a day, no trading: cap reached day 269) and a dead game with live trading also repays them (no
draws, 5 ETH trading: day 170). Raising either share speeds repayment modestly and costs prizes or
burns one for one; lowering them extends the founder term by months.

**Tradeoff:** While founders are owed, prizes get 35 percent of net trading receipts and buybacks 50
percent of earnings.

**Example:** 100 draws, 5 ETH trading: trading 50 percent gives 1.0x at day 172, 65 percent day 140,
80 percent day 118; earnings 25 / 50 / 75 percent give day 154 / 140 / 130.

**Alternative rejected:** Founders paid only from trading receipts (the earlier proposal): with 0 ETH
trading founders would receive nothing at any draw volume.

**Where:** `EngineTreasury._allocateTrading`, `_allocateEarnings`, `founderTradingBps`,
`founderEarningsBps`. **Confidence:** modeled.

## D6. What counts as game earnings

**Question:** How is distributable game profit measured?

**Decision:** Ordinary pool NAV above `basis`, the principal the treasury put in. Withdrawn only from
free pool cash (cash above claims and the pool's own 10 percent reserve). Maintenance top-ups the
reserve paid are repaid from earnings first. Opening mint fees and any refill must be earned back before
anything is distributed.

**Why:** The pool's margin split already pays the creator's replacement mint fees (mint line), FWA's
half of the edge, keeper refunds (maintenance share) and the GRAIL feed before premium accrues to NAV.
New financing raises `basis`, so it is never earnings.

**Tradeoff:** Distributions start late: the 0.264 ETH of opening mint fees took about 600 fork draws to
recover before the first earnings.

**Example:** Fork, 1,050 draws: NAV 5.736 to 6.070 ETH, 0.070 ETH harvested as earnings, 50 percent to
founders. Model: about 0.00066 ETH of earnings per draw (2.9 percent of the ticket).

**Alternative rejected:** Counting the premium share per capture as earnings. It ignores write-offs,
negative margin carries and the opening mint fee loss.

**Where:** `EngineTreasury.harvest`, `_allocateEarnings`. **Confidence:** verified.

## D7. Coverage first, with a capped maintenance subsidy

**Question:** What is "mandatory coverage", and how is it kept from starving founders?

**Decision:** Every inflow first refills the reserve to `reserveTarget`. The reserve pays two things:
pool maintenance below 0.15 ETH (back to 0.5 ETH) and ordinary NAV below 80 percent of the pool target
(back to the target). Maintenance subsidy that earnings have not repaid is capped at 4 x 0.5 ETH.

**Why:** At 30 gwei the keeper refunds of listing replacements exceed the maintenance share; without the
cap the reserve drained into gas and the coverage-first refill then took every receipt, paying founders
0.29 ETH in a year. With the cap founders were paid in full by day 179.

**Tradeoff:** In a sustained high gas regime keepers stop being refunded once the subsidy cap binds. The
owner's remedy is a higher `maintenanceBps` through `poolCall(setFeeSplit)` (premium floor enforced).

**Example:** Stress row "high gas 30 gwei": founders 30.00 ETH, 1.0x at day 179, lowest reserve 2.71
ETH (p10).

**Alternative rejected:** An uncapped subsidy (starves founders) or no subsidy (the board stops
replenishing whenever gas spikes).

**Where:** `EngineTreasury.maintainCoverage`, `MAX_SUBSIDY_TARGETS`. **Confidence:** modeled.

## D8. Board depth capped at the pool target (pool change)

**Question:** How is the board kept from growing without bound?

**Decision:** New pool parameter `boardNavCap`: board depth is computed from `min(nav, boardNavCap)`.
The treasury sets it to `poolTarget` at activation.

**Why:** The pool sizes its board from all of NAV, so every wei of profit was turned into more listed
items before a harvest could take it: NAV grew from 6 to 20 ETH (100 draws a day) and to 151 ETH (750 a
day) in a year, earnings were trapped as inventory, and the larger board diluted the GRAIL odds. With the
cap NAV holds near 6.5 ETH and earnings rise from 10.9 to 27.9 ETH a year at 100 draws a day.

**Tradeoff:** One more admin parameter in a module with 418 B of headroom. Zero leaves the old behaviour.

**Example:** `sim/engine.mjs` first grid (no cap) vs second grid; `PoolBooks._boardItems`.

**Alternative rejected:** Raising `reserveBps` dynamically: it starves replacements of spendable cash
and leaves the profit locked as "reserve" all the same.

**Where:** `src/PoolStorage.sol`, `src/PoolBooks.sol`, `src/PoolAdmin.sol`, `EngineTreasury.activate`.
**Confidence:** verified (regression suite green), modeled (effect).

## D9. Ordinary prize mix: 50 / 22 / 13 / 10 / 4 / 1

**Question:** Keep 38 / 28 / 19 / 10 / 4 / 1 (0.01 Shape, 0.02 pack, 0.03 pack, 0.05, 0.1, 0.5)?

**Decision:** Move 12 points from packs to the 0.01 Shape: 50 / 22 / 13 / 10 / 4 / 1.

**Why:** The ticket falls from 0.0228 to 0.0204 ETH and the player's expected return stays at 86.9
percent; creator mint fees fall 11 percent because fewer multi-Shape packs are replaced.

**Tradeoff:** Game earnings fall about 13 percent (27.6 to 23.9 ETH a year at 100 draws), and GRAIL wins
fall from 12 to 10 a year (cheaper tickets, fewer pulls of value).

**Example:** Ordinary mix table in `docs/ECONOMIC_VALIDATION.md`.

**Alternative rejected:** "No 3-packs" 50/30/0/14/5/1, equal on ticket (0.0203) and return (87.3) but
removes the 0.03 outcome players see as a middle prize; "heavier top" 30/25/20/16/7/2 raises the ticket
to 0.0272.

**Where:** `EngineDeployer._mix`. **Confidence:** modeled.

## D10. Fee split and premium floor

**Question:** Keep premium 200 / maintenance 100 / feed 400 bps?

**Decision:** Keep it, and let the treasury refuse any `setFeeSplit` with `premiumBps` below 200.

**Why:** Premium 300 would add about 9 ETH of earnings a year at 100 draws for 0.6 points of player
return; the owner set 200 deliberately for the player proposition. The floor stops the owner from
zeroing game earnings, which feed founders and buybacks.

**Tradeoff:** Lower earnings than 300 or 400 bps.

**Example:** Premium 200 / 300 / 400: earnings 23.9 / 33.1 / 41.8 ETH; return 86.9 / 86.3 / 85.1 percent.

**Alternative rejected:** 400 bps: faster repayment by 15 days, two points of player return lost.

**Where:** `EngineDeployer._poolParams`, `EngineTreasury.poolCall`. **Confidence:** modeled.

## D11. GRAIL settings unchanged

**Question:** Change the ladder, list price, decay, floors or probability cap?

**Decision:** No. Target 25 ETH, `listBps` 7,500, decay 0.001 ETH per pull, 1 ETH floors, step rule 14 /
60 days, probability cap 10 percent of selection weight, 5 ETH opening GRAIL.

**Why:** The owner tuned these in October; the engine changes the GRAIL's funding (feed share plus
trading boosts), not its mechanics. After a GRAIL win the fund rebuilds from the feed share and the
prize budget; the ordinary game continues unchanged (stress row "5 ETH GRAIL won on day 1": founders
unaffected, 10 wins in the year).

**Tradeoff:** Odds stay modest: the 5 ETH opening GRAIL is about one draw in 50,000 at face value.

**Where:** `EngineDeployer._poolParams`. **Confidence:** provisional.

## D12. ENGINE coin market terms

**Question:** How to reach about 5 percent total fees, and what reaches the treasury?

**Decision:** Pure skim: LP fee 0, baseline skim 500 bps on the ETH side of every buy and sell, bounty
share 9,000 bps to the treasury, referral 0, the Artcoins MEV skim module (68.69 percent decaying over
69 minutes, all above-baseline skim to the treasury), unrestricted ERC-20, 1e9 supply, the reference
coin-only liquidity layout (three single-sided positions from tick 200,000). The coin admin locks the
fee recipients before the treasury binds the coin.

**Why:** All fees arrive as ETH (no coin-denominated rewards to sell or burn), the treasury's share is
the largest the factory allows (`minProtocolSkimShareBps` 1,000 leaves 9,000 for the bounty), and a
locked recipient means nobody can redirect the stream after founders commit.

**Tradeoff:** No LP fee means the locker positions earn nothing (they are permanent and protocol owned
anyway). The pool launches with zero ETH depth: sellers can only sell into ETH that buyers brought.

**Example:** Fork: a 1 ETH buy paid the treasury exactly 0.045 ETH; a sell of 0.6229 ETH volume paid
0.0280 ETH (4.50 percent); the other 0.5 percent goes to the Artcoins protocol leg.

**Alternative rejected:** LP fee 3 percent plus skim 2 percent: half the fees arrive in the coin and the
LP share is split with the Artcoins protocol locker slot (2,000 bps).

**Where:** `EngineDeployer._coinConfig`, `EngineTreasury.setCoin`. **Confidence:** verified.

## D13. Coin launch through the real factory by its owner

**Question:** The v2 factory is `deprecated` (owner only). How does ENGINE launch?

**Decision:** The Artcoins factory owner `0xCB43…217F9` launches with `deployTokenAsOwner(config,
2000)`. The factory's administrative state is not changed.

**Why:** Un-deprecating the factory would open public launches, a separate decision for Artcoins.

**Where:** `DeployEngine` step `coin`. **Confidence:** verified on the fork; requires the owner's
signature on mainnet.

## D14. Buyback and burn

**Question:** How are earnings turned into burns without MEV loss or keeper trust?

**Decision:** `buyback(maxEthIn, minCoinOut)` is permissionless, once per block, at most 0.5 ETH per
call, stops at 2 percent price movement (v4 `sqrtPriceLimitX96`), waits out the 180 minute sniper
window, burns every coin bought in the same call and checks the supply drop. The 4.5 percent bounty of
its own swap returns to the buyback fund.

**Why:** A 5 percent fee each way makes a sandwich cost the attacker about 10 percent of their size, so
a 0.5 ETH, 2 percent bounded buy is not worth sandwiching; a keeper role would add trust without
adding protection.

**Tradeoff:** Large buyback funds take many blocks to deploy.

**Example:** Fork `test_buyback_burnsAndReconciles`: supply drop equals the burn record, no coin held,
second call in the block reverts.

**Alternative rejected:** Reusing the deployed `BurnRouterV2` (initialised for another coin by the
Artcoins owner) or deploying a new one (owner-run, keeper reward to the caller): an extra contract with
its own owner for logic the treasury needs in about 40 lines.

**Where:** `EngineTreasury.buyback`, `unlockCallback`. **Confidence:** verified.

## D15. Spending the prize budget

**Question:** What stops trading receipts from piling up as discretionary cash?

**Decision:** `boostGrail()` is permissionless and sends the whole prize budget above an open bid's price
into the pool's GRAIL fund. The only discretionary use is a bounded collectible bid (D17).

**Why:** Receipts become better prizes automatically, which is the stated purpose of the 35 percent.

**Example:** 100 draws, 5 ETH trading: 57 ETH reached the GRAIL fund from trading in a year.

**Where:** `EngineTreasury.boostGrail`. **Confidence:** verified (mechanics), modeled (amounts).

## D16. Sponsored prize terms

**Question:** How does a sponsor's NFT become a real prize without the game owing its value?

**Decision:** `PrizeSponsorship`: one active deal; the NFT lists at a published price from the stake
(example terms 8 ETH, about one draw in 85,600 on the fork board); the sponsor is paid up to a cap from
at most 50 percent of the trading receipts left after founders; an early win ends payments (the sponsor
keeps what was paid); reclaim after 30 days only while unwon, short of the cap and with no draw pending;
reaching the cap hands the NFT to the treasury. Ticket proceeds of a win go to the GRAIL fund.

**Why:** The previous design parked the punk at 30 ETH until fully paid, which made it nearly
unwinnable while the sponsor was paid (2 of 12 simulated years saw a win). At 8 ETH 3 of 12 years see a
win at 100 draws a day and every year at 300 draws a day.

**Tradeoff:** The sponsor carries real risk of losing the NFT early; their compensation must price that.
The game never owes the NFT's market value, and its value is never counted as backing.

**Example:** Sponsor table: listed at 8 ETH, 100 draws, 5 ETH trading, cap 36 ETH: sponsor paid 28.5 ETH
(median), won in 3 of 12 years.

**Alternative rejected:** `SponsoredPrize` with Shapes mint fees as compensation (`FeeSplit`): redirects
the creator's mint fee, which the brief forbids; `SponsorOffer` (standing multi-sponsor offer): more
surface than one deal needs.

**Where:** `src/engine/PrizeSponsorship.sol`, `EngineTreasury.setSponsorship`,
`test/fork/engine/EngineSponsor.t.sol`. **Confidence:** verified (mechanics), provisional (terms).

## D17. Treasury collectible purchases

**Decision:** A standing bid: the owner names a token of the immutable `prizeCollection` (Wrapped
Cryptopunks), a price up to 60 ETH and a list price; the holder sells by `fillBid`; the token lists at
once as a treasury-owned foreign listing; its win proceeds return to the prize budget. The owner cannot
fill their own bid.

**Why:** No marketplace integration and no arbitrary calls; the price is the owner's judgement, bounded.

**Tradeoff:** The contract cannot verify a market price. A bid holds prize budget while open.

**Where:** `EngineTreasury.setBid`, `fillBid`. **Confidence:** verified (mechanics).

## D18. Wind-down

**Decision:** The owner, or anyone after 90 days without a paid draw, starts the wind-down. The pool
stops taking draws and exports; pending draws settle at FWA first (FWA holds player refunds); the
treasury redeems the GRAIL estate and its shares; every wei then goes to founders up to their remaining
entitlement and the rest to the buyback fund. Late receipts follow the same order.

**Why:** Founders are the only creditors of the treasury; coin holders hold no claim (no redemption
floor is implied); the creator receives nothing beyond mint fees already earned.

**Example:** Fork: wind-down after 40 draws paid founders 24.72 ETH of a 25 ETH round (first draft).

**Where:** `EngineTreasury.windDown`, `windDownStep`, `_allocateWindDown`. **Confidence:** verified.

## D19. Closing public deposits without a pool change

**Decision:** Pool launch values `navCapFloor = 0`, entry fee 0, founder window 0; deposits paused at
activation. The treasury lifts the floor and the pause inside its own deposit and restores both.

**Why:** A zero cap makes every deposit revert from the pool's construction, so there is no race between
deployment and the pause.

**Where:** `EngineDeployer._poolParams`, `EngineTreasury._deposit`. **Confidence:** verified.

## D20. Owner powers

**Decision:** The owner reaches the pool only through `poolCall`, an allowlist of tuning setters. Denied:
`setAdmin`, `startExit`, `transferGrailEstate`, `setRegistrar`, `registerForeign`, admission setters,
`deposit`, `withdraw`, `createFwaPool`. Guarded: `setFeeSplit` (premium floor), `setPaused` (deposits stay
paused), `setReserve` (at most 2,500 bps), `adminCall` (FWA `recoverRefundedNFT` only), `sweep` (to the
treasury only).

**Why:** The owner runs the game but cannot move principal, take the GRAIL, redirect prizes or fee
streams, or throttle the founders' earnings leg.

**Where:** `EngineTreasury.poolCall`. **Confidence:** verified (`test_poolCall_refusesPrincipalAndControlSelectors`).

## D21. FWA pool created inside activation

**Decision:** `activate(fwaCreationFee)` creates the FWA pool in the same transaction that seeds it.

**Why:** The pool's 24 hour opening deadline starts at FWA pool creation and `open()` is
permissionless; created earlier, anyone could open an empty pool and lock activation out (security
review M1).

**Where:** `EngineTreasury.activate`. **Confidence:** verified.

## D22. What was reused from `claude/next` (PR #5)

| Component | Outcome | Reason |
| --- | --- | --- |
| Foreign listings in `Pool`, `PoolAdmin`, `PoolBooks`, `PoolListing`, `PoolStorage`, `IPool`, `IForeignController`, Lens `foreign()` | Reused unchanged | Generic, reviewed twice, 45 fork tests against Wrapped Cryptopunks |
| `PoolForeign.t.sol`, `PoolAdmin.t.sol` and `Pool.t.sol` changes | Reused | Regression coverage |
| `FeeSplit` | Rejected | Redirects the creator's Shapes mint fees to the sponsor |
| `SponsoredPrize` | Adapted into `PrizeSponsorship` | Kept stake, capture callback, reclaim and release; removed parking and mint fee payment; added capped trading-receipt payments and completion |
| `SponsorOffer` | Rejected | Multi-sponsor standing offer not needed for one deal |
| `DeploySponsor`, `DeployOffer`, sponsor env files | Rejected | Built for `FeeSplit`; replaced by `DeployEngine` step `sponsor` |
| Sponsor web pages, punk art, `/sponsor-prev` | Partly reused in the web app (punk art); prev route dropped | |
| `docs/SPONSOR.md`, `docs/PUNK_VALUE.md` | Superseded by D16 | |

**Confidence:** verified.

## D23. Fork pin for the engine

**Decision:** Engine fork tests pin block 26,240,000; the existing suite keeps 26,170,000.

**Why:** At 26,240,000 the FWA factory has the beta gate off and a zero inventory cooldown, so engine
tests need no FWA owner action; Artcoins v2 is deployed (block 26,157,195). Pool creation there costs
50,000 FWA tokens, which a real holder transfers in the tests.

**Confidence:** verified.

## D24. No custom v4 hook or pool extension

See `docs/V4_HOOK_OPPORTUNITIES.md`. **Confidence:** verified (interfaces), modeled (economics).

## D25. Unresolved items for the owner

- **Investor rights and securities law.** Founders contribute ETH for a capped share of protocol cash
  flows. This may be an investment contract in some jurisdictions. Counsel must review the terms, the
  disclosures on the funding page and who may contribute before the round opens.
- **Artcoins protocol leg.** 10 percent of the skim (0.5 percent of volume) goes to the Artcoins
  protocol fee controller, which splits 86.67 percent to `0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4`
  (a proxy whose owner was not identified) and 13.33 percent to `BurnRouterV2`. If that treasury
  benefits the creator, it is a creator share of coin trading fees, which the brief excludes. The
  factory floor (`minProtocolSkimShareBps` 1,000) cannot be avoided without changing Artcoins.
- **FWA pool creation fee.** 50,000 FWA tokens must reach the pool before activation. Who buys them is
  the owner's decision; the treasury does not.
- **Draw Packs** is a new deployment (2-unit minimum pack) with `OWNER` as admin.

## D26. Price of a draw

**Decision:** Report three numbers separately: FWA fee (the base game price including FWA's 5 percent
edge), VRF fee (0 at block 26,240,000, read live), and wallet gas (not included anywhere).

**Example:** Fork at opening: fee 0.018250 ETH, VRF 0, total 0.018250 ETH. Model average over a year:
0.0204 ETH, rising as GRAIL items join the board (each listed GRAIL item lifts the harmonic mean).

**Confidence:** verified (opening quote), modeled (year average). The brief's "below 0.02 ETH" holds at
opening and is about 2 percent above it on average over the modeled year.
