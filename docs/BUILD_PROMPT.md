# Draw Shapes + ENGINE: build prompt

You are the implementer. This file is your whole brief. Read all of it before writing code. It is
self-contained: intent, decisions, architecture, parameters, rules, test plan, deliverables, and the
list of things you must not do. Work in `ripe0x/draw-shapes` on the branch you were given. The
owner is not available during the build; where this brief leaves a decision open, decide it
yourself using section 2, record it in `docs/IMPLEMENTOR_DECISIONS.md`, and keep going.

Written 2026-10-26 after the design sessions. Supersedes `docs/SPEC.md`, `docs/V1_PROMISES.md`,
`docs/PORT_NOTES.md` and the depositor-pool code in `src/`. The earlier handoff and the
`draw-shapes-base` build are reference only.

---

## 1. What this is

A real-money NFT gacha on Ethereum mainnet. Players pay ETH for a verifiably random draw from a
board of **Shapes** (ETH-backed NFTs; a Shape can always be burned by its holder for its backing)
and **Draw Packs** (bundles of Shapes). The draws run on **FWA V2** (Fake World Assets) custom
pools: FWA provides the engine (listings, Chainlink VRF, settlement, delivery, its own site);
we provide the house (a protocol-owned prize inventory) and a token.

**ENGINE** is the token. Its purpose is to drive play: for a 21-day genesis window every pull earns
ENGINE, and for the whole life of the game a share of the game's revenue buys ENGINE back, half of
it burned and half paid to that day's players. During genesis the only way to acquire ENGINE is to
play (public buys are closed; sells are never closed).

The owner is a solo operator with a small audience and organic marketing only. Their income is the
Shapes mint fee (0.001 ETH per Shape minted), nothing else. The game's own ETH is held so that nobody,
the owner included, can withdraw it.

## 2. Intent and priorities (use these to decide anything this brief doesn't)

1. **Simple over clever.** Fewer contracts, fewer parameters, fewer paths. If a feature needs a
   mechanism to make it safe, question the feature first. The previous build was over-engineered;
   do not port it.
2. **Holders dumb and fixed; deciders modular and replaceable.** Contracts that hold ETH, NFTs or
   tokens are minimal and have no upgrade path. Policy lives in modules behind addresses
   governance can change. A module may decide anything; it never holds anything.
3. **Flexible, not locked.** This is v1. Governance is a timelock with **delay 0 at launch**
   (the owner will raise it later). Every tunable has an in-contract bound; within the bound the
   timelock moves it freely. Immutable only where it must be (token supply, the FWA pool, the
   vault's lack of a withdraw).
4. **Custody is the one hard promise.** Game ETH leaves holders only to the active game, the
   treasury's registered sinks, the farm, or the ENGINE liquidity position. Never to an EOA.
5. **Play is the point.** When a design choice trades token economics against reasons to play,
   choose play.
6. **Measure, don't guess.** Economic parameters come from fork gas receipts and the sims, recorded
   with their inputs.
7. **Everything FWA-related is in blocks; everything token-related reads the ledger's clock.**

## 3. Decisions already made (do not reopen; the owner's reasons are in `docs/OWNER_QUESTIONS.md`)

| Topic | Decision |
|---|---|
| Chain / venue | Ethereum mainnet, FWA V2 custom pool. Our contract creates and permanently owns the pool (FWA ownership cannot be transferred). |
| Prizes | Shapes `0x6fe9193276bf7abcbee44ab7afd717d637d6faf0` (mint fee 0.001 ETH/Shape, ladder 0.01 … 100 ETH) and Draw Packs `0xf21514b090da7df4390803497d6ae673801e5ca7` (verify on the fork that this is the Draw Packs variant with `MIN_PACK_VALUE = 2 units`; if not, record it and build against the Shapes-only board until the owner decides). |
| Pool model | Protocol-owned house. No depositors. All vault assets go to the active game immediately (no caps, no notice beyond the timelock). |
| Pricing | Listing price = backing + mint fees + a governance-set **markup** (launch 3%, cap 5%) earmarked for keeper gas. FWA charges EV × 1.05; we receive EV × 1.025. No settlement fee of ours. `purchaseOperator` left unset so FWA's site can sell our pulls. |
| Token | "ENGINE" / "ENGINE", 18 decimals, supply 1,000,000,000 minted once. Our own contracts (not artcoins), with `contractURI`/`tokenURI` and a pluggable renderer. No bonus weights. |
| Supply split | 10% to the launch liquidity position; 10% to the genesis farm; 1% to the prize-conversion bonus pool; 79% to the farm as a **seasons reserve** that governance can only (a) schedule as a future farming season or (b) burn. It can never be transferred elsewhere. Unused genesis allocation (empty days) and unused bonus are burned at genesis end. |
| Market | One Uniswap v4 ETH/ENGINE pool on our own hook, LP fee 0, full-range protocol-owned position, no remove. Hook fee 3% of the ETH side on every swap, to the treasury (cap 5%). Opens 48 h before the game. |
| Gate | From game open to genesis end, **public buys revert; sells always work**. Buys are allowed only from FwaGame (prize conversion) and registered treasury sinks (buybacks). |
| Genesis | 21 daily epochs in blocks (7,200 blocks each) from the game-open block. Emission tapers linearly from 1.5× the average day to 0.5× (same total). Each epoch's pot is split pro rata among that epoch's delivered pulls (one unit per pull). An epoch is claimable once every pull accepted in it is terminal. Claims never expire. Governance may shorten genesis (one way, min 7 epochs, 2 full epochs' notice); cut epochs are burned. |
| Prize conversion | A winner may convert a Shape won from our pool into ENGINE: FwaGame burns the Shape for its backing, buys ENGINE from the pool with that ETH (fee-exempt), adds a 2% bonus from the bonus pool, and sends the ENGINE to the player. Allowed during and after genesis. Only token IDs our pool delivered. |
| Buybacks | Run from genesis day one. Treasury revenue is split by a governance table across sinks. Launch table: BuybackBurn 45%, BuybackReward 45%, GrailFund 10%. BuybackReward deposits what it buys into the farm's current epoch. |
| Keeper gas | Paid from the markup (pull-based), never from trading fees. Our keeper is a backup; bots are welcome. |
| GRAILs | Large Shapes (0.5 → 1 → 5 ETH ladder) listed through FwaGame below backing with a probability cap and per-pull decay; funded by the GrailFund sink. Policy in a module, bounds in the contract. |
| Visuals | The mainnet Shapes renderer as-is for NFTs. ENGINE gets a custom renderer (on-chain SVG; pick a simple, clean design; the owner may replace it). |
| Governance | OpenZeppelin `TimelockController`, `minDelay = 0` at launch, proposer/executor = the owner's governance address from the env file. Every setter is timelock-only. |
| Site / terms | Next.js site with a Terms page and clickwrap on first wallet connect; no country blocking; operator name and contact from env. |
| Later, not now | Pulls paid in ENGINE through our site; a second farming season from the reserve; a "buy and stake FWA" sink; the collection-coin machine. Design nothing for these beyond the module seams. |

## 4. Architecture

```
PrizeVault      holds game ETH; sends only to the active game; takes it back on retire; shutdown → LP
FwaGame         creates/owns the FWA pool; mints & lists prizes; sync walk (books captures, credits the
                ledger, queues replacements); conversion; GRAIL listing; margin → Treasury, markup → KeeperFund;
                retire → everything back to the vault.   Modules: BoardPolicy, PricingPolicy, GrailPolicy,
                ConversionPolicy, GameRevenueRouter, EngineBuyer
GenesisFarm     holds the farm allocation + seasons reserve; pays claims from the ledger; accepts pot deposits;
                shorten; retireUnearned (burn).          Module: EmissionSchedule (allocationOf)
Treasury        holds revenue; distribute() splits by table to sinks
Sinks           BuybackBurn, BuybackReward, GrailFund, KeeperFund   (each: receive() + process())
                KeeperFund pays what TipPolicy says.   Modules: EngineBuyer (shared), TipPolicy
EngineToken     fixed supply, burn, contractURI/tokenURI → Renderer (module)
EngineHook      takes the fee SwapPolicy says and enforces its allow/deny; nothing else.   Module: SwapPolicy
ProtocolLiquidity  initialises the pool, holds the full-range position, addLiquidity (no remove)
Lens            read-only aggregation for the site and keeper
```

Holders (fixed, no upgrade path): PrizeVault, FwaGame, GenesisFarm, Treasury, EngineToken,
ProtocolLiquidity, EngineHook. Deciders (replaceable via timelock; views + events, or forward
in-call; never hold a balance): BoardPolicy, PricingPolicy, GrailPolicy, ConversionPolicy,
GameRevenueRouter, EngineBuyer, EmissionSchedule, SwapPolicy, TipPolicy, Renderer, the sinks.

The rule, stated once: a holder has exactly one settable module address per kind of decision; a
holder never contains a number you might want to change; a module never holds a balance between
calls. What stays rigid on purpose: the vault's outflow set, the FWA retire path, the token supply,
the farm's claim arithmetic and finality rule, the hook's fee-taking mechanics. Those are the trust
surface; a seam there is an escape hatch.

The FWA pool owner cannot be changed, so FwaGame is the one holder that cannot be swapped; it must
be the smallest holder you can write, with every policy question pushed to a module. If a better
venue appears, FwaGame retires (returns everything to the vault) and governance activates a new game.

### 4.1 PrizeVault

- `receive()`; `activeGame` set by timelock; `fund()` sends the whole balance to the active game
  (callable by anyone once a game is active); the game repays via `repay()`.
- `retireGame()` (timelock): marks the game retiring; the game's own `retire()` path returns funds.
- `shutdown()`: when no game is active and the last game has returned, anyone may move the balance to
  `ProtocolLiquidity.addLiquidity` with a price limit, after a governance-set delay.
- No withdraw. No other outflow. Keep it under ~120 lines.

### 4.2 FwaGame

- Constructor creates the FWA pool through the factory (needs the 50,000 FWA creation fee, supplied by
  the deploy script from the deploy wallet; record the exact flow). Stores the pool address immutably.
- **Inventory**: mints Shapes / Packs from vault ETH per `BoardPolicy`, lists at `PricingPolicy`
  prices with `listNFTs` (batches ≤ `MAX_INVENTORY_BATCH` = 20), tracks every listing and token ID it
  has ever listed and delivered.
- **Sync walk** `sync(uint256 maxCount)` (permissionless, tipped): walks `requestIdAtSequence` from
  the last booked sequence while the acquisition is terminal (`Fulfilled`, `Expired`, `Refunded`,
  `TimedOut`, `DeliveryRefunded`; treat `DeliveryPending` as not terminal). For each: book the capture
  (proceeds − captured backing − mint line = margin), credit the ledger (epoch = `(requestBlock −
  openBlock) / EPOCH_BLOCKS`, purchaser +1 unit; count accepted and resolved per epoch), queue the
  replacement row, then list queued replacements if the FWA inventory cooldown allows. Recover
  `DeliveryRefunded` NFTs back into inventory. Withdraw owner proceeds when available.
- **Ledger**: `epochTotals(epoch) → (accepted, resolved, units)`, `userEpoch(epoch, purchaser) → units`,
  `openBlock`, `activated`. Pulls accepted before `openBlock` (none should exist) and after genesis
  end still count units (the farm pays post-genesis pots from them).
- **Revenue**: every revenue wei FwaGame books goes to one settable `GameRevenueRouter` module in
  the same call, tagged by source (`Markup`, `Margin`, `GrailCapture`). The router forwards by a
  per-source table and holds nothing. Launch table: Markup → KeeperFund (until its target, overflow
  → Treasury); Margin → Treasury; GrailCapture → Treasury. Keeper gas stays pull-based because the
  Markup row points at KeeperFund; governance can repoint any row. Mint fees are paid at mint time to
  the Shapes contract (that is the owner's income; never touch it).
- **Conversion** `convert(tokenId, minEngineOut)`: only Shapes delivered by our pool, once each;
  burn for backing → `EngineHook`-exempt buy from the pool → + 2% bonus (from the bonus pool, at the
  executed price) → transfer to caller. Reverts if the bonus pool is empty of the bonus (still
  converts without the bonus if `allowNoBonus` is set by the caller).
- **GRAILs**: `GrailFund` sink calls `fundGrail()`; when the fund covers backing + mint fee of the
  next ladder step, mint and list a GRAIL at `GrailPolicy.listPrice` (bounded: never below
  `MIN_GRAIL_PRICE_BPS` of backing, probability share never above `MAX_GRAIL_PROB_BPS`), reprice per
  pull by the policy within the same bounds.
- **Retire** `retire()` (timelock) then `retireStep()` (anyone): `retirePool()`, process until
  `unsettledAcquisitionCount == 0`, `withdrawListingsTo(ids, this)`, burn held Shapes for backing,
  unpack Packs, repay the vault. Must work while the factory is `globalWithdrawOnly`.
- Bounds in-contract: markup ≤ 500 bps; board size ≤ `MAX_BOARD`; replacement batch ≤ 20; GRAIL
  bounds above; keeper tip bounds (4.6).

### 4.3 GenesisFarm

Port the held farm contract from the earlier handoff (Appendix A there) with these changes: no bonus
weights (100% by units); epochs in blocks via the ledger (`openBlock`, `EPOCH_BLOCKS`); `allocationOf`
delegates to `EmissionSchedule`; `deposit(amount)` from a registered sink adds to the current epoch's
pot (post-genesis epochs have pots only from deposits; they are claimable by the same finality rule);
`seasonsReserve` balance with `scheduleSeason(start, epochs, amount)` and `burnReserve(amount)`
(timelock only; no other outflow); `retireUnearned` burns cut epochs, empty genesis epochs and the
unused bonus pool at genesis end.

### 4.4 Treasury and sinks

- Treasury: `receive()`; `sinks[] (address, bps)` summing to 10,000, set by timelock; `distribute()`
  pushes the balance by bps; a sink must have code; a sink never holds a balance between calls.
- `BuybackBurn.process(minOut)`: buys ENGINE through `EngineBuyer` in slices (`sliceWei`,
  `minSpacing`, `maxImpactBps`), burns; caller tip per 4.6. Runs from genesis day one.
- `BuybackReward.process(minOut)`: same buy, then `GenesisFarm.deposit`.
- A future sink (for example "buy and stake $FWA") is a new contract with `receive()` + `process()`
  and one row in the table; nothing deployed changes.
- `GrailFund`: forwards to `FwaGame.fundGrail()`.
- `KeeperFund`: holds the keeper allowance (target `keeperTargetWei`), pays tips; `fundKeeper()` from
  FwaGame; overflow back to Treasury.

### 4.5 Token, hook, liquidity

- `EngineToken`: Solady ERC-20 + Permit, fixed supply minted in the constructor to the recipients the
  deploy script passes (ProtocolLiquidity, GenesisFarm), `burn`, `contractURI()`/`tokenURI()` via a
  settable `IMetadataRenderer` (take the interface shape from `ripe0x/artcoins` `src/v2/renderer/`,
  not the code). Admin of metadata = timelock.
- `EngineHook` (v4, mainnet PoolManager; verify its address on the fork): on every swap it asks the
  `SwapPolicy` module `(sender, isBuy, amountSpecified) → (allowed, feeBps)`, reverts `SwapNotAllowed`
  if not allowed, and takes `feeBps` of the ETH side (hard cap 500 in the hook) to Treasury. The hook
  contains no fee rule of its own. Exact-output sells revert (as in the Base hook). Only
  ProtocolLiquidity may initialise the pool, once. `setSwapPolicy` is timelock-only.
- `SwapPolicy` (module, launch version): fee 300 bps; `gateEnd` block before which a buy whose
  `sender` is not in `exempt` is disallowed; `exempt` = FwaGame, EngineBuyer and registered sinks
  (also fee 0); an anti-snipe decaying extra fee for the first `snipeWindow` seconds after pool open
  (launch 50% → 0 over 60 minutes; can be 0). Asymmetric fees, fee holidays or a different gate are
  a new policy module, never a hook change.
- `EngineBuyer` (module): `buy(minOut) payable → engineOut`, the one place that knows how to buy
  ENGINE (today: the v4 pool through PoolManager). FwaGame's conversion and both buyback sinks call
  it. Changing the venue or route is one address change.
- `ProtocolLiquidity`: initialises ETH/ENGINE at the launch price from `LAUNCH_ETH` and the 10% float,
  full range, tick spacing 200; `addLiquidity(minSqrtPrice)` (treasury/vault/timelock), no remove.

### 4.6 Keeper tips (adjustable, timelock)

Every keeper-callable function (`sync`, `retireStep`, `distribute`, every sink's `process`,
`retireUnearned`) pays its caller from KeeperFund, which pays what the `TipPolicy` module returns
for `(gasUsed, basefee, age)`, capped by KeeperFund's own `tipCap`. Launch policy:

```
tip = min(tipCap, gasUsed × min(basefee, basefeeCap) × (10_000 + premiumBps) / 10_000)
    + bounty(age)
bounty(age) = maxBounty × min(age, rampSeconds) / rampSeconds     // age = seconds since work became available
```

Launch values: `premiumBps` 2,000, `basefeeCap` 30 gwei, `tipCap` 0.01 ETH, `maxBounty` 0.002 ETH,
`rampSeconds` 6 h. The bounty rises with how long the work has waited, so bots compete only when it is
worth it and nobody races in the first minutes. Our hosted keeper is a backup: it calls only when
`age > backupAfterSeconds` (launch 6 h) or when `basefee < backupBasefeeGate` (launch 1 gwei), never
otherwise. If KeeperFund is below the tip, the call still succeeds and pays what it can; it never
reverts for lack of tip.

### 4.7 Lens

One read contract the site and keeper use: board, quotes, epoch state and finality, claimable per
wallet, conversion quote, treasury table and sink states, keeper work available with ages, gate state.

## 5. Parameters (launch values; every one bounded in-contract and settable by the timelock)

| Parameter | Launch | Bound |
|---|---|---|
| Board | 100 items, mix from `docs/OWNER_QUESTIONS.md` (62 × 0.01 Shape, 26 × 0.02 Pack, 7 × 0.03 Pack, 4 × 0.05, 1 × 0.1) | `MAX_BOARD` 200 |
| Markup | 300 bps | ≤ 500 |
| Hook fee | 300 bps | ≤ 500 |
| Anti-snipe | 50% → 0 over 60 min | ≤ 90%, ≤ 3 h |
| Gate end | genesis end | — |
| Genesis | 21 epochs × 7,200 blocks; taper 1.5× → 0.5× | min 7 on shorten |
| Farm | 100,000,000 ENGINE | — |
| Bonus pool | 10,000,000 ENGINE, 2% of backing per conversion | bonus ≤ 500 bps |
| Treasury table | Burn 4,500 / Reward 4,500 / GRAIL 1,000 | sums to 10,000 |
| Buyback | slice 0.05 ETH, spacing 1 h, impact cap 3% | — |
| Keeper | per 4.6 | tipCap ≤ 0.05 ETH, maxBounty ≤ 0.01 ETH |
| GRAIL | ladder 0.5/1/5 ETH; list ≥ 80% of backing; prob cap 5%; decay per policy | list ≥ 50%, prob ≤ 10% |
| Launch liquidity | `LAUNCH_ETH` from env (owner decides; default the sims recommend) | — |

Re-run the sims (port from `draw-shapes-base/sim/`, mainnet gas, 21 days, FWA lean pricing, the taper,
the gate, 50/50 buyback) and set the per-pull expectations, `LAUNCH_ETH` recommendation and keeper
budget from them. Record inputs and outputs in `docs/ECONOMICS.md`.

## 6. Rules for the build

1. **Start fresh.** Delete `src/`, `test/`, `script/*.sol`, `web/` and the old docs listed at the
   top. Keep: `test/fork/ForkBase.sol` (the pinned-fork harness; move it to the new tree),
   `deployments/dependencies.json`, `external/`, `lib/` and its pins, `foundry.toml` structure,
   `.github/workflows`, `docs/external/`, `docs/DEPLOY.md` and `docs/RUNBOOK.md` (rewrite them),
   `docs/OWNER_QUESTIONS.md` (append; do not delete history). Rewrite `AGENTS.md` for the new tree.
2. **Read, don't port.** Use the old `src/`, `ripe0x/draw-shapes-base` (branch
   `claude/dreamy-allen-twdsex`; clone read-only to `/home/user/ripe0x/draw-shapes-base`) and
   `ripe0x/artcoins` (public mirror) to learn FWA's interface quirks, the booking walk, the v4 hook
   patterns and the renderer interface. Write every contract from this brief.
3. **Solidity 0.8.28, legacy codegen, every holder under 24 KB with headroom.** If a holder doesn't
   fit, it is too big; split policy out, don't switch to `via_ir`.
4. **No `delegatecall`, no proxies, no `selfdestruct`, no `tx.origin`.** Raw calls to addresses only
   through the treasury's registered sinks and the keeper tip.
5. **Pull, never push, for anything owed to a person** (claims, refunds, tips credited if a push fails).
6. **Bounds in the contract**, not only in the deploy script.
7. **Custody invariant first.** Before the holders are written, write
   `test/invariant/Custody.t.sol`: a handler that calls every public function of every contract with
   fuzzed inputs, and an invariant that every ETH/NFT/ENGINE outflow from a holder lands on an
   allowlisted destination. It stays in CI forever.
8. **Pinned mainnet fork, real contracts, for every game test.** Real Shapes, Draw Packs, FWA factory,
   FWA VRF service (drive the VRF callback through the real service path with pranks), real v4
   PoolManager. Pin `FORK_BLOCK`; no mocks for anything that exists on mainnet.
9. **Gas receipts are a release gate.** Measure `sync` (per pull, cold and warm), `claim`,
   `distribute`, each `process`, `convert`, on the fork at 1 / 5 / 20 gwei; write them into
   `docs/ECONOMICS.md`; derive the keeper budget and confirm the 3% markup covers replacement at the
   gas you measured, or say what it covers.
10. **Deploy script with postflight.** `script/Deploy.s.sol` + `script/deploy.sh <env>` reading a
    values-only env file; after each step it reads back supply, recipients, ownership (everything
    owned by the timelock, nothing by the deploy wallet), the FWA pool owner, the treasury table, the
    hook config, the gate end, and refuses to continue on any mismatch. Dry run on an anvil fork and
    on Sepolia (if the FWA factory exists there; otherwise record that the Sepolia rehearsal covers
    everything except FWA and say so).
11. **Keep one Forge process per worktree; use `--match-path` for changed tests.**
12. **Commit as you go, with plain commit messages for a public audience. No model names anywhere.**

## 7. Test plan (all must pass before you report done)

- Unit: every holder and module; bounds; setter access; emission taper sums to the allocation.
- Fork: pool creation and permanent ownership; listing and the inventory cooldown; a pull through
  FWA's real `acquire` with the VRF callback; the sync walk over every terminal status including
  `TimedOut` and `DeliveryRefunded` recovery; replacement and the markup/margin/mint-line split to the
  wei; conversion; GRAIL mint/list/reprice/capture; buybacks splitting burn/reward; gate (public buy
  reverts, sell passes, game buy passes); anti-snipe decay; retire path including under
  `globalWithdrawOnly`; vault fund/repay/shutdown.
- Invariants: custody (rule 7); solvency (vault + game NAV ≥ what was lent minus booked losses);
  ledger = delivered pulls per epoch; farm never pays more than allocation + deposits; treasury table
  always sums to 10,000; sinks hold nothing between calls.
- Scenario, on the fork with block/time manipulation (local only): **the full genesis rehearsal**:
  deploy, 48 h pre-market with buys and sells, game open (gate on), 21 epochs of pulls with late
  deliveries and one timeout, daily sync/distribute/buybacks, claims per epoch as they become final,
  shorten once in a separate run, genesis end (gate off, `retireUnearned`), post-genesis epochs paid
  from deposits only, a second game registered after retiring the first, and shutdown to the LP.
- Sizes: `forge build --sizes` in CI with a hard fail over 24,576 bytes.
- Gas receipts per rule 9.

## 8. Site and keeper

- `site/` (Next.js): Terms (version date = launch date) and clickwrap on first connect; play
  (quotes from FWA, `acquire`/`acquireBatch` on our pool with the user as purchaser; pulls can also
  happen on FWA's site and still count); claim; convert; genesis dashboard (epoch, pot, your units,
  finality); stats. Env: `NEXT_PUBLIC_OPERATOR_NAME`, `NEXT_PUBLIC_CONTACT`, addresses from
  `deployments/<env>.json`. Never embed a private key or API secret.
- `keeper/` (Node, viem): a backup keeper per 4.6 (`sync`, `distribute`, sink `process`, `claim`
  is not a keeper job). Reads work and ages from Lens. Dockerfile. No hosting setup (the owner picks
  hosting; document what it needs: `MAINNET_RPC_URL`, a funded key, nothing else).

## 9. Deliverables

1. `docs/SPEC.md`: the system as built, from this brief, with exact function names and bounds.
2. `docs/ECONOMICS.md`: sims, gas receipts, parameter derivations, the farming break-even table.
3. `docs/DEPLOY.md` and `docs/RUNBOOK.md`: deploy order, env file keys (names only), postflight
   checks, the owner-funded items (50,000 FWA for the pool, opening capital, `LAUNCH_ETH`, gas), the
   launch sequence (deploy → fund vault → open market → 48 h → open game → 21 days → genesis end),
   keeper ops, retire/shutdown, and what governance can change and within what bounds.
4. `docs/OWNER_QUESTIONS.md`: append every decision from section 3 with the date and reason.
5. `docs/IMPLEMENTOR_DECISIONS.md`: **a running list of every decision you made that this brief left
   open**, with what you chose, why, and what the alternative was. The owner reviews this once at the
   end. Include anything you found that contradicts this brief.
6. Contracts, tests, scripts, site, keeper as above; CI green; gas receipts and sizes in the docs.
7. A final report: what is done, what is not, test counts, sizes, gas, and the exact next steps that
   need the owner (section 10).

## 10. What you must not do (the owner does these)

- Broadcast to mainnet or spend real assets. Prepare and dry-run only.
- Create, print, commit, export or ask for private keys or production secrets.
- Claim a testnet deploy, an audit or legal review that didn't happen. Say plainly that no
  independent audit has been done.
- Use time manipulation anywhere but local fork tests; never claim real elapsed time.
- Publish, post or send messages on the owner's behalf. Provision paid services.
- Reopen the decisions in section 3. If you believe one is wrong, build it as decided and write the
  argument in `docs/IMPLEMENTOR_DECISIONS.md`.

## 11. Verified external facts (2026-10-26)

| Item | Value |
|---|---|
| FWA factory | `0xf5a3a153164791ab579c3d9ba5dbecf7cdfd300c`: `poolCreationEnabled` true, `betaAccess` false, creation fee 50,000 FWA, `edgeBps` 500 |
| FWA clone implementation / VRF service / FWA token | `0xeaa4d032908a9734a2c7939c0d211c35ad51eb31` / `0xa4adfc35db18326efb3b5d9bf66a8103ec2d5ee2` / `0xa0df17b5ac76ababa36e1450e2cbcd18a620c845`; VRF request fee 0 today |
| FWA pool behaviour (vendored source `external/fwa-v2/mainnet/FWAClone/src/userowned/FWAClone.sol`) | owner permanent (`OwnershipLocked`); only owner lists; buyer pays EV × 1.05, owner accrues EV × 1.025; `withdrawListingsTo` needs `unsettledAcquisitionCount == 0`; `retirePool()` keeps callbacks/claims/withdrawals working; records in `acquisitions(requestId)`, `acquisitionMeta(requestId)` (`sequence`, `randomWord`), `requestIdAtSequence`; `MAX_INVENTORY_BATCH` 20; factory can set `globalWithdrawOnly` |
| v4 PoolManager (mainnet) | verify on the fork before use; the Base build's `ProtocolLiquidity`/`EngineHook` show the integration shape |
| Reference board economics (FWA lean, markup 0) | EV 0.01404 ETH, player pays 0.01474, expected backing 0.01281 (86.9%), expected mint fees 0.00123, FWA 0.00035, house 0.00035 per pull. With the 3% markup, recompute. |
| Farming break-even | at 300 pulls/day and gas 1 / 5 / 20 gwei, a pull's loss is 0.0021 / 0.0029 / 0.0059 ETH; rewards above that per pull attract bots. The sims (`draw-shapes-base/sim/`, and the mainnet variants described in `docs/ECONOMICS.md` once you write it) model this. |
| $FWA's own genesis, for reference | 2% of supply/day for 15 days with buys closed and sells open fell 60% in-window and 98% in fees after; the fixes built into this design are: smaller farm, taper, buybacks from day one, prize conversion as the in-window buy path, sells never closed. |

Start with `docs/SPEC.md`, then the custody invariant, then the holders, then the modules, then the
rest. Report when everything in section 7 passes.
