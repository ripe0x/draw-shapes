# ENGINE implementation plan

Date: 2026-10-24. Input: [BRIEF](BRIEF.md). Findings it builds on: [REVIEW](REVIEW.md). Base: `main` at
`4a13a09`. Nothing in this plan is built yet; this document is the proposal for how to build it.

## 0. Decisions

The review left seven choices. The owner took the recommendations on 2026-10-24; each is recorded here as
the decision the plan builds on, with the phase it affects. Phase 1 copies them into `docs/OWNER_QUESTIONS.md`.

| Decision | Affects |
| --- | --- |
| A1. Base is `main`. The depositor layer (shares, NAV, entry fee, volume cap, founder window, claims, liquidation, retirement by `withdraw`, successor migration) is removed in its own phase before any new feature. The creator's 5 ETH enters through typed funding calls, not `deposit`. The companion model archive (`check_design.py`, `board_economics.json`, `selected_design.json`, `DECISION_REGISTER.md`, scenario outputs) is checked into `docs/engine/model/` before contract work starts; any engine branch held elsewhere is pushed before phase 6 or treated as superseded. | Phase 1, 2 |
| A2. ENGINE Pack ETH exit after 48 hours pays `backing * (10_000 - exitHaircutBps) / 10_000`, haircut launch value equal to the market sell fee (500), routed to the market fee policy. | Phase 3 |
| A3. Original inventory is held by the hook as a balance and sold only to authenticated game buyers along a virtual curve at no less than pool spot. The v4 pool holds circulated tokens and ETH only. | Phase 5 |
| A4. Sponsorship compensation is fair value: `P / 100_000` per eligible settled draw, cumulative cap `1.0 P`. The Punk fund balance sets uptime; the Lens publishes the daily spend and the draws the reserved pot still covers. | Phase 6 |
| A5. Public buys of resale open at hour zero. `publicBuyDelay` stays a policy parameter with launch value 0, so the hour 24 variant is a value change, not code. | Phase 5 |
| A6. One prize wrapper collection carries both modes. An `Eth` row of two or more rungs is a wrapper pack redeemable to ETH; an `Engine` row is a wrapper pack redeemable to ENGINE; single rung `Eth` rows stay plain Shapes. Draw Packs leaves the dependency set, the deploy guards, the fork setup and the release gate. This reverses the Draw Packs decision in `docs/OWNER_QUESTIONS.md`. | Phase 2, 3, 7, 8 |
| A7. One multisig is `admin` of every contract, new and existing. A 72 hour timelock sits in front of the hook policy module and every economic setter on the game (fee split, mix, gas cap, active outcome floor, maintenance floor, GRAIL parameters, sponsorship offer). Keeper tunables (`tipWei`, `batchMin`, `batchMaxAge`, `maxBatch`, `concurrency`, `rotateInterval`, `listWhilePaused`) and the pause flags that stop new risk are direct multisig calls. Nothing can touch earned claims. | Phase 2, 5, 8 |

## 1. Target architecture

Seven contracts, two of them existing. Everything the brief calls "enforced outside the replaceable
module" is immutable code or a constructor constant.

| Contract | New or changed | Role | Immutable guarantees |
| --- | --- | --- | --- |
| `Pool` + `PoolAdmin` + `PoolListing` + `PoolBooks` + `PoolStorage` | changed | The FWA game. Board, settlement, treasury buckets, keeper refunds, GRAIL. Records every accepted request for genesis. Economic setters callable only by the timelock. | Owner proceeds split by fixed bps; retained surplus can only go to `Treasury` |
| `Treasury` | new | Holds retained surplus, reserve, Punk fund, liquidity fund, GRAIL top-up routing. Executes ENGINE purchases (genesis rewards, post genesis burns) and fee allocation. | Can send ETH only to the hook (purchase), the GRAIL fund, a sponsor's earned compensation, or a Punk acquisition it executes itself |
| `PrizePack` | new | ERC721 wrapper around Shapes for every multi-Shape prize and every ENGINE prize. Mode fixed at mint: `Eth` redeems to ETH at once; `Engine` redeems to ENGINE via receipt, with the haircut ETH exit after 48 hours. Replaces Draw Packs. | A pack redeems exactly once; backing can only be paid to the holder or spent on the holder's purchase |
| `Engine` | new | ERC20, 1e9 fixed supply minted once to `Genesis`. Transfer gate during genesis (allowlist of hook, genesis, pack, treasury), fully open after. | No mint function; gate is dropped by the genesis deadline, not by admin |
| `Genesis` | new | Epoch ledger: per request credit, per epoch totals, bonus points, claims, burns of empty epochs and dust. Custody of the 100 million farming allocation; hands the 900 million purchase inventory to the hook at start. | 14 epochs of 86,400 s from `startedAt`; schedule constants; credit only from `Pool` |
| `EngineHook` | new | v4 hook on the ENGINE/ETH pool. Original inventory curve for authenticated buys, fee on public swaps, liquidity gating during genesis, finalizer. Delegates fee bounds and gating parameters to `HookPolicy`. | Fee cap 500 bps; original inventory can leave only through an authenticated buy or the finalizer burn; finalizer runs once, after the deadline, by anyone |
| `HookPolicy` | new, replaceable behind the timelock | Fee level (at most 500), public buy enable time, per-swap limits, gas policy readouts. | Replaced only through `Timelock` |
| `Sponsorship` | new | One posted collection offer, acceptance, exposure reservation, compensation accrual per eligible settled draw, reclaim, early win, cap. Holds the sponsored NFT between listing and win. | Compensation is reserved from the Punk fund before exposure |
| `Lens` | changed | Views for every new contract. | none |

Existing invariants I1, I2, I5, I6, I7 stay with NAV terms removed. New invariants, enforced by the
invariant suite:

- I8 `Engine.totalSupply()` is at most 1e9 and never increases after deployment.
- I9 Original inventory released + original inventory burned + hook original balance = 900 million at all times.
- I10 Farming tokens claimed + claimable (finalised epochs) + reserved (open epochs) + burned (empty epochs, dust) = 100 million.
- I11 Every credited request id maps to exactly one booked Fulfilled sequence; refunded, expired and written-off requests carry no credit.
- I12 A `PrizePack` is in exactly one state: listed, held, awarded-unredeemed, redeemed-to-ENGINE, redeemed-to-ETH, exited-to-ETH. Its Shapes leave the wrapper only in the last three, and only the mode's own redemption or the timed exit applies.
- I13 Treasury ETH out = ENGINE purchases + GRAIL funding + sponsor compensation paid + Punk acquisitions; nothing else.
- I14 Sponsor compensation accrued is at most `1.0 P` and at most the reserved amount; exposure is accepted only while reserved compensation covers the next eligible draw.
- I15 The sum of fee receipts allocated equals fee receipts collected (10 / 45 / 45 after the GRAIL milestone; 90 to GRAIL before it; reserve repair first).
- I16 After the finalizer, the hook holds zero original inventory and public buys are unrestricted.

## 2. Phases

Each phase ends with its tests green under the repository rules (`forge test --match-path` on the
affected files, real Shapes and FWA on the pinned fork, sizes checked when runtime code
changes). Phases 3, 4 and 5 can run in parallel after phase 2 defines the interfaces.

### Phase 1. Specification

Deliverable: `docs/SPEC.md` rewritten as the v2 build input, with `docs/OWNER_QUESTIONS.md` entries 44
onward recording each brief decision and each assumption above. `docs/V1_PROMISES.md` stays historical.

- Remove SPEC 7 (depositor paths), SPEC 13 (exit and migration), the NAV terms of SPEC 4, the admission
  parameters of SPEC 5, and the depositor actions of SPEC 16.
- Rewrite SPEC 9: fixed `boardDepth` (launch 100), per row target = the opening count, like for like
  replacement (captured row is requeued as the same row), no `chooseRow`, no surprise, no band.
- Add sections for the treasury, the ENGINE Pack, the token, genesis, the market, the finalizer, the fee
  policy, sponsorship and the upgrade policy, in the brief's order, each with its invariants from section 1.
- Add the acceptance list from brief section 16 as SPEC 16, mapped to test files (section 4 below).
- Write `docs/external/uniswap-v4.md` (PoolManager address, hook permission bits, custom accounting
  rules, fee units, pinned commits) and `docs/external/wrapped-punks.md` in the style of the existing
  dossiers.

Exit: owner sign-off on SPEC and the seven open questions in REVIEW.

### Phase 2. Game core: remove depositors, add treasury and genesis attribution

Files: `src/Pool.sol`, `src/PoolAdmin.sol`, `src/PoolBooks.sol`, `src/PoolListing.sol`,
`src/PoolStorage.sol`, `src/interfaces/IPool.sol`, `src/lib/PricingLib.sol`, `src/Lens.sol`, new
`src/Treasury.sol`, `src/interfaces/ITreasury.sol`, `src/interfaces/IGenesis.sol`.

Remove:

- `deposit`, `withdraw`, `redeemAndDeposit`, `payClaims`, `sharesOf`, `totalShares`, `nav`, `navCap`,
  `dailyVolume`, `_recordFees` and the day slots, `EntryFee`, `turnoverBps`, `founderWindowSeconds`,
  `depositsOpenAt`, `Claim`, `_payClaims`, `_clearClaims`, `_liquidateForClaims`, `_liquidateOne`,
  `_mostOverweightListedRow`, `startExit`, `exportStep`, `transferGrailEstate`, the import functions,
  `canImport`, `migrateHolder`, `Lifecycle.Exiting`, `Lifecycle.Exported`, `PricingLib.sharesFor`,
  `claimFor`, `entryFeeBps`, `entryContribution`, `chooseRow`, `_surprise`, `rowDepth`.
- Parameters `navCapFloor`, `turnoverBps`, `entryFee`, `founderWindowSeconds`, `surpriseBps`, `restoreK`,
  `bandBps`, `reserveBps` and their setters and env keys.

Add:

- Buckets: `cash` (ordinary operating coverage), `backing`, `receivable`, `maintenance`, `grail.fund`
  as today; `retained` (the retained surplus share of positive margin, swept to `Treasury`). Funding calls
  `fundOrdinary()`, `fundMaintenance()` (exists), `fundGrail()` (exists), each payable by anyone.
  `Treasury` receives its 0.45 ETH reserve and the 0.25 ETH market seed directly.
- `PricingLib.MixRow` gains `mode` (`Eth`, `Engine`). An `Engine` row is listed as a `PrizePack` in
  ENGINE mode wrapping the row's Shapes; an `Eth` row of two or more rungs is a `PrizePack` in ETH mode;
  a single rung `Eth` row is a plain Shape as today. `createPack` and the Draw Packs handle leave
  `PoolListing`, `PoolStorage` and `Params` (A6). The opening board is the
  brief's table as twelve rows (six denominations times two modes, 0.5 ETH ENGINE at zero count).
- Fixed depth: `boardDepth` constructor value (100). Target per row is its opening count. Replacement:
  `_capture` enqueues `capturedRow`. `Deep` compares the board count against `boardDepth`.
- Guards in `_requirePurchasable`: `tx.gasprice <= maxGasPrice` (parameter, launch 0.25 gwei), listed
  ordinary items minus unsettled at least `minActiveOutcomes` (launch 80), `maintenance >=
  maintenanceFloor` (parameter), plus the existing I1 check. All three are parameters behind the timelock
  (A7); a revert reason names the guard so the site can show it.
- Admin split (A7): `PoolAdmin` gains `timelock` beside `admin`. The economic setters require the
  timelock; keeper tunables and pause flags keep `admin`. `adminCall` moves behind the timelock as well,
  since it can reach every external contract.
- Genesis attribution: `_acquire` records `(requestId, purchaser, acceptedAt)` and calls
  `IGenesis.accept(requestId, purchaser, acceptedAt)` while genesis is open; `_capture` on a booked
  Fulfilled sequence calls `IGenesis.credit(requestId, randomWord)`. Refunds, expiries and write-offs
  call nothing. The pool is the only authorised caller of both.
- Margin split: `mintLineOwed` first, then `retainedBps : maintenanceBps : feedBps` (200 / 200 / 100).
  Retained is swept to `Treasury.receiveRetained()` at harvest.
- `Treasury`: buckets `reserve`, `retained`, `punkFund`, `liquidityFund`, `grailRouting`; functions
  `buyForRewards(epoch, minOut)` (genesis only), `buyAndBurn(minOut)` (after genesis), `allocateFees()`
  (the 10 / 45 / 45 rule with the first GRAIL milestone and reserve repair first), `fundGrail()` passthrough,
  `reserveSponsorCompensation` and `paySponsor` (callable by `Sponsorship` only), `acquirePunk(offer)`
  (admin, timelocked, bounded by `punkFund`). Every outflow is one of the I13 categories.

Keep: the FWA purchase ABI and operator, `pullWithShapes` with held Shape reuse, `settle` and `rotate`
with the keeper refund, the GRAIL fund and ladder (feed now 100 bps plus treasury routing), `adminCall`
with its invariant post-check, `sweep`.

Tests: rewrite `test/fork/PoolAdmission.t.sol`, `PoolExit.t.sol` (delete), `PoolDepth.t.sol` (fixed
depth), `PoolReplace.t.sol` (like for like); add `test/fork/PoolGuards.t.sol` (gas cap, active outcomes,
maintenance floor), `test/fork/Treasury.t.sol`; update the invariant handlers (drop depositor actions,
add `fundOrdinary`, treasury sweeps). `PlayMonth` scenario rewritten for a 5 ETH opening with the
brief's board.

Exit: fork suites green, `forge build --sizes` recorded in SPEC 3, gas receipts for `acquireBatch(5)`,
`settle`, `rotate` refreshed in `evidence/`.

### Phase 3. Prize wrapper

Files: `src/PrizePack.sol`, `src/interfaces/IPrizePack.sol`, listing changes in `PoolListing`.

- `mint(uint256[] shapeIds, Mode mode) -> packId` by `Pool` only. Holds the Shapes; `backing` is the
  sum of `valueOf`. `tokenURI` renders the Shapes and the mode (port the Draw Packs renderer, which this
  wrapper replaces per A6; `lib/draw-packs` stays pinned as read-only reference until the port lands).
- `redeemToEth(packId)` by the holder of an `Eth` mode pack at any time: redeems the Shapes at Shapes and
  pays the full backing to the holder. No haircut, no delay; this is the Draw Pack behaviour.
- `award(packId, requestId)` by `Pool` at the booked Fulfilled walk, recording `awardedAt`. The pack is
  already in the winner's wallet by then (FWA delivered it), so award is bookkeeping for the exit clock.
- `redeemToEngine(packId, minOut, deadline)` by the holder: redeems the Shapes at Shapes, receives
  ETH, mints a single-use receipt `(packId, holder, budgetWei, nonce)` and calls
  `EngineHook.buyWithReceipt{value: budget}(receipt, minOut, holder)`. On revert the whole call reverts
  and the pack stays funded (no partial state).
- `exitToEth(packId)` by the holder of an `Engine` mode pack after `awardedAt + 48 hours` while
  unredeemed: redeems the Shapes, pays `backing * (10_000 - exitHaircutBps) / 10_000` to the holder and
  the haircut to `Treasury.allocateFees()` (A2; the haircut equals the market sell fee at launch, 500,
  and is a timelocked parameter).
- Transfer of a pack transfers both rights; genesis credit stays with the original purchaser in `Genesis`.
- The pool's `Item` gains the pack's collection as an ordinary item; I2 counts a pack at its backing.

Tests: `test/fork/PrizePack.t.sol`: capture by a real FWA draw on the fork, ETH mode pack redeemed at once
for full backing, redeem to ENGINE through the hook (phase 5 stub until then), haircut exit after 48 hours, double claim impossible, transfer then redeem,
`recoverRefundedNFT` path, delayed claim after genesis close buying circulated tokens only.

### Phase 4. Token and genesis ledger

Files: `src/Engine.sol`, `src/Genesis.sol`, `src/interfaces/IGenesis.sol`.

- `Engine`: Solady ERC20, `constructor(genesis)` mints 1e9 to `Genesis`. `_beforeTokenTransfer` reverts
  unless `block.timestamp >= Genesis.deadline()` or sender and recipient are both in the fixed allowlist
  (`Genesis`, `EngineHook`, `PrizePack`, `Treasury`, the v4 `PoolManager`). No admin hook into the gate.
- `Genesis`: `start()` by admin once the pool is Live and the hook pool is initialised; sets
  `startedAt`, transfers 900 million to the hook. Epoch `e(t) = (t - startedAt) / 86_400`, 0 to 13.
  `accept(requestId, purchaser, acceptedAt)` stores the epoch. `credit(requestId, randomWord)` increments
  the epoch's success count, assigns bonus points from `keccak256(abi.encode(randomWord, requestId,
  "ENGINE/bonus"))` (0 / 1 / 10 at 90 / 9 / 1 percent), and stores the purchaser's per epoch counts.
- Finalisation: `finaliseEpoch(e)` by anyone once `Pool.nextSequenceToBook()` passes the last sequence
  accepted in epoch `e` (the pool exposes it) and `block.timestamp` is past the epoch end. Computes the
  equal share (80 percent, or 100 when no bonus points) and the bonus share per point; burns the epoch's
  allotment when it has no successes; burns division dust. Schedule: `100_000_000e18 / 14` per epoch,
  remainder to epoch 13.
- `claim(epochs[])` by a purchaser, after finalisation, no expiry. Reward purchases by `Treasury` during
  genesis (`buyForRewards`) add tokens to the epoch's pool before finalisation; after finalisation they go
  to the next open epoch, and after epoch 13 to burn.
- Views for the Lens: per epoch totals, per wallet pending and claimable, the liability of pending
  requests at the boundary.

Tests: `test/unit/Genesis.t.sol` (schedule arithmetic, dust, bonus distribution, all 14 boundaries),
`test/fork/Genesis.t.sol` (accept at acquire, credit at settle, a slippage refund earns nothing, a request
accepted in epoch 13 and settled after the deadline is paid from epoch 13, operational pause does not move
the calendar), invariant handlers for I8, I10, I11.

### Phase 5. Market: hook, policy, finalizer

Files: `src/EngineHook.sol`, `src/HookPolicy.sol`, `src/Timelock.sol` (or a pinned OpenZeppelin
`TimelockController` from `lib/shapes`), `lib/v4-core`, `lib/v4-periphery` submodules,
`script/MineHookAddress.s.sol`.

- Pool: ENGINE/ETH, hook fee dynamic, hook permissions `beforeSwap`, `beforeSwapReturnDelta`,
  `afterSwap`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `afterInitialize`. Address mined for the bits.
- `beforeSwap`: if the swap is an authenticated buy (receipt from `PrizePack`, or a `Treasury` call), fee
  0; fill from pool liquidity while pool spot is at or below the curve price, else from the hook's original
  balance along the curve via return delta (A3). Record released original inventory. Else: public swap;
  revert while `block.timestamp < startedAt + publicBuyDelay` for a buy (launch value 0, A5); charge `policy.feeBps()` (at most
  500, immutable cap) on the ETH side in `afterSwap` and forward it to `Treasury.allocateFees()`.
- `beforeAddLiquidity` / `beforeRemoveLiquidity`: during genesis only the hook's own positions change.
  After the deadline, open.
- Curve: opening price `5e-8` ETH per token, tenfold range, 900 million tokens; closed form in a pure
  library `CurveLib` with unit tests against the brief's model figures.
- Seed: `Treasury` adds the 0.25 ETH as a hook-owned bid position below opening at `start()`.
- `finalise()`: anyone, once, after the deadline. Burns the hook's remaining original balance, records
  the burn in `Genesis`, lifts the public buy and liquidity restrictions. With A3 there is no position
  removal. Protocol liquidity received from fees (the 10 percent) is added as full range hook-owned
  positions on each `allocateFees()`.
- `HookPolicy`: `feeBps` (at most 500), `publicBuyDelay` (launch 0), `maxPublicBuyPerSwap`. Replaced by the
  timelock. Emergency `pauseNewRisk()` by the multisig stops public buys and new positions; never claims.

Tests: `test/fork/EngineHook.t.sol` on the pinned mainnet fork against the deployed `PoolManager`:
receipt buy fills from pool then curve, forged and reused receipts revert, a public buy pays the fee and
cannot reach original inventory from hour zero (I9 under a fuzzed sequence), a nonzero `publicBuyDelay`
blocks public buys until it passes, holder sells through a different router and through direct `PoolManager.unlock` are both
fee-charged, add liquidity during genesis reverts for anyone but the hook, `finalise()` burns exactly
`900e6 - released`, post finalise everything is open and fee capture continues. `test/unit/CurveLib.t.sol`.

### Phase 6. Sponsorship

Files: `src/Sponsorship.sol`, FWA listing of the sponsored NFT through `Pool` (as a GRAIL-style item that
is not an ordinary row).

- `postOffer(collection, referencePrice P, maxOddsBps, minPot)` by admin; P at most the immutable cap for
  the first offer (30 ETH). `accept(tokenId)` by a holder of a verified Wrapped CryptoPunk while
  `Treasury.punkFund() >= minPot`: transfers the NFT, `Pool` lists it at the assigned value that yields
  at most `1 / 100_000` on the live board, `Treasury` reserves compensation for the first tranche of draws.
- Per settled eligible draw `Pool` calls `Sponsorship.onEligibleDraw()`; compensation `P / 100_000`
  (the expected prize loss at the odds cap) accrues to the sponsor, capped at `1.0 P` (A4);
  `Treasury.paySponsor` on `withdrawCompensation()`. The Lens reports the daily spend at the trailing
  draw rate and the number of draws the reserved pot still covers.
- Exposure guard inside `_requirePurchasable`: the listed sponsor weight at current prices and pending
  requests stays within the odds cap, and reserved compensation covers `pending + 1` draws; otherwise the
  pool withdraws the listing (when FWA allows) and stops sponsored exposure. Ordinary play continues.
- `reclaim()` by the sponsor after 30 days while unwon and not fully compensated, honouring pending
  requests. Early win: FWA delivers the NFT to the winner, accrued compensation stays claimable, future
  accrual ends. Cap reached: compensation and reclaim rights end, the NFT becomes protocol owned.
- Outright purchase: `Treasury.acquirePunk` is a separate, timelocked path.

Tests: `test/fork/Sponsorship.t.sol` with the real Wrapped CryptoPunks contract on the fork: accept,
compensation accrual, reclaim, early win by a forced VRF word, funding exhaustion stops exposure without
stopping ordinary draws, uptime readout.

### Phase 7. Scenarios, invariants, evidence

- `test/scenario/Genesis14Days.t.sol`: the brief's launch checks as one lifecycle: 5 ETH opening with the
  exact board, maintenance delayed, an early 0.5 ETH capture, delayed ENGINE claims, every epoch boundary,
  private and public swap authentication, exact primary quota, holder sales through alternate paths,
  pending rewards at close, finalise, sponsor early win and funding exhaustion. Driven at 100 and 300
  draws a day with the existing `PlayMonth` harness pattern and recorded in `evidence/play/`.
- Invariant suite extended with I8 to I16 and the handler reach test CI already runs.
- `sim/lab.html` replaced by `sim/engine.html` modelling the new buckets, genesis and the curve, checked
  against the fork scenario the way the current lab is checked (its "Check against the fork runs" block).
- Gas receipts: `acquireBatch(5)`, `settle`, `rotate`, `redeemToEngine`, `exitToEth`, `claim`, a public
  swap, `finalise`, at 0.25 gwei and 1 gwei, published as the true player cost table.

### Phase 8. Deploy, operations, web, review

- `script/Deploy.s.sol` and `script/deploy.sh`: deploy order `Timelock`, `Engine` + `Genesis`
  (circular: deploy `Genesis` with a predicted `Engine` address via CREATE2), `PrizePack`, `Treasury`,
  `HookPolicy`, `EngineHook` at the mined salt, `Sponsorship`, `PoolAdmin`, `PoolListing`, `Pool`, `Lens`.
  Env keys for every new constant. Postflight readback of each. The existing guards (chain id, ladder,
  code at dependencies, sizes, clean `main` on mainnet) stay; the Draw Packs checks go (A6); add the
  `PoolManager` code check, the hook permission bit check, and a readback that every economic setter's
  authority is the timelock (A7).
- `docs/DEPLOY.md`: launch sequence: fund 5 ETH through the typed calls, `createFwaPool`, `open()`,
  initialise the v4 pool, `Genesis.start()` only when Live and the market is ready, post the sponsor offer.
  `docs/RUNBOOK.md`: keeper adds `finaliseEpoch`, `allocateFees`, `buyForRewards` / `buyAndBurn` cadence.
- Web: remove `/deposit`; add `/genesis` (epochs, your credit, claims), `/pack` (redeem or exit), the
  market view, sponsorship status; publish the per draw split with the mint fee and FWA protocol share
  as the first chart.
- Sepolia rehearsal with a Sepolia `PoolManager` and the testnet ladder, then the independent review of
  `EngineHook`, `Genesis`, `PrizePack` and `Treasury` (the brief names the quota and burn as needing it),
  then the 30 day timelock and multisig setup, then mainnet.
- Legal review runs in parallel from phase 1 and gates phase 8.

## 3. Brief section to work item

| Brief | Phase |
| --- | --- |
| 1 product, 2 contribution | 2 (funding calls, treasury buckets) |
| 3 board, 4 pricing and guards | 2 |
| 5 ENGINE Pack | 3 |
| 6 supply, 7 genesis | 4 |
| 8 market, 9 close | 5 |
| 10 cash policy | 2 (`Treasury.allocateFees`), 5 (fee forwarding) |
| 11 sponsorship | 6 |
| 12 creator income, 13 stress tests | 7 (lab and evidence) |
| 14 participation | web copy, phase 8 |
| 15 upgrade and trust | 5 (policy, timelock), 8 (multisig) |
| 16 delivery boundaries | 1 (SPEC 16), 7, 8 |

## 4. Launch checks to tests

| Brief section 16 check | Test |
| --- | --- |
| Five ETH opening with actual inventory | `Genesis14Days` setup, `PoolBoard` |
| Delayed maintenance | `PoolGuards` (maintenance floor), `Genesis14Days` |
| Early maximum prize | `Genesis14Days` (forced VRF word on the 0.5 ETH row) |
| Delayed ENGINE claims | `PrizePack` (claim after close buys circulated only) |
| Every genesis boundary | `Genesis` unit and fork |
| Private and public swap authentication | `EngineHook` |
| Exact primary quota enforcement | `EngineHook` I9 fuzz, `finalise` exactness |
| Holder sales through alternate paths | `EngineHook` (direct `unlock`, second router) |
| Pending rewards at close | `Genesis` fork (epoch 13 settled after deadline) |
| Liquidity migration | `EngineHook.finalise` (with A3: burn and unlock, no migration) |
| Sponsor early win or funding exhaustion | `Sponsorship` |

## 5. Sequencing and effort

```
Phase 1 (spec)  ─┐
Phase 2 (core)  ─┼─► Phase 3 (pack) ─┐
                 ├─► Phase 4 (genesis)┼─► Phase 7 (scenarios) ─► Phase 8 (deploy, review, mainnet)
                 └─► Phase 5 (market) ┘
                 └─► Phase 6 (sponsor) ┘
```

Rough effort in focused engineer weeks, excluding the independent review and legal: phase 1, 1; phase 2,
2; phase 3, 1; phase 4, 1.5; phase 5, 3; phase 6, 1.5; phase 7, 2; phase 8, 2. About 14 weeks serial,
roughly 9 with phases 3 to 6 in parallel. Phase 5 is the long pole and the one the brief flags for
independent review; start its submodule pins and address mining in week one of phase 2.

## 6. Repository rules this plan keeps

- Solidity 0.8.28, the compiler profiles, via_ir restrictions and remappings in `foundry.toml`. New
  contracts default to the legacy pipeline; a new file joins the via_ir list only when measured over the
  limit, with the measurement recorded in SPEC 3 as today.
- One Solidity writer per repo. Phases 3 to 6 in parallel means parallel branches, each touching its own
  new files plus narrow interface additions, with phase 2 merged first.
- Real Shapes, FWA, Wrapped CryptoPunks and `PoolManager` on the pinned fork; Draw Packs leaves the
  fork setup and SPEC 16 under A6. `FORK_BLOCK` moves once, to a block
  after the v4 mainnet deployment and after any FWA factory change the brief asks to verify (edge, VRF,
  cooldown), and is pinned again.
- `script/deploy.sh <env>` with values-only env files and every existing guard.
- Each brief value lands in `script/env/*.env`, never as a literal in a contract, except the constants
  the brief says are enforced outside the replaceable module (supply, schedule, fee cap, first offer cap).

## 7. Risks

- **Phase 5 correctness.** Custom accounting, return deltas and fee forwarding on v4 are new to this
  codebase. Mitigation: A3 keeps original inventory out of the pool; the hook's own state is three
  numbers (original balance, released, burned); property tests against I9 and I16.
- **Depositor removal breadth.** Phase 2 touches every contract. Mitigation: do it first, alone, with the
  existing fork suites as the regression net before any new feature lands.
- **FWA dependencies the brief asks to verify live.** Pool creation allowance, `inventoryChangeCooldown`,
  `edgeBps`, VRF fee at 0.25 gwei. Any change moves the published cost table. Mitigation: read them in
  the deploy preflight and in `Lens.quote`.
- **Zero conversion of ENGINE mode packs** (review concern 2). Mitigation: A2, and the lab publishes the
  zero conversion row.
- **Renderer port.** Replacing Draw Packs with the wrapper means porting its renderer and losing the
  separate collectible. Mitigation: port the renderer unchanged in phase 3 and keep `lib/draw-packs`
  pinned as reference until mainnet.
- **Sponsor uptake at fair value.** A `1.0 P` cap and `P / 100_000` per draw may attract no Punk holder.
  Mitigation: the offer terms are timelocked parameters; the Punk fund can also buy outright.
- **Bytecode.** `Pool` family near the limit today. Mitigation: phase 2 removes more than it adds; sizes
  measured at each phase.
- **No Forge in the planning container.** Nothing here has been compiled. The first build of phase 2
  will surface interface churn the plan cannot predict.
