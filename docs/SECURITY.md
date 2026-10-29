# Security notes

What the contracts enforce, what they trust, and what is known to be open. **No independent security audit has been
done.** An audit and a legal review are launch requirements and are outside this repository. Nothing is deployed.

## Trust model

| party | can | cannot |
|---|---|---|
| Governance (TimelockController, delay 0 at launch; proposer and executor = the owner's address) | choose the active game, the buyback's profit sources, modules, board, pricing, capital settings, promotion budgets, keeper parameters; retire a game | withdraw from any holder; upgrade any contract; change the token supply, the farm schedule or the genesis end; exempt a router from the genesis gate |
| The deploy wallet | wire each contract once | anything after wiring (`deployer()` is 0, checked by postflight) |
| Keepers and bots | run `sync`, `retireStep`, `Buyback.process`, `GenesisFarm.finalize` and be tipped for work done | choose where value goes; a call with no work reverts and pays nothing |
| Players | buy draws (here or on FWA's site), claim, convert | buy past the purchase gate; convert a prize twice |

Because governance directs all game capital, the timelock delay is the only notice. It is 0 at launch and should be
raised before outside money is material (docs/RUNBOOK.md).

## What the code enforces

- **Custody** (docs/SPEC.md section 2): no holder has a withdraw function or an upgrade path. Every outflow is one of
  a fixed set of destinations; the invariant suite checks it after every fuzzed action (`invariant_custody`).
- **PoolOwner** holds no ETH, Shape or Pack between calls (`invariant_modulesHoldNothing`). It spends exactly the ETH
  the game sends on mints (`BadPayment` otherwise) and forwards every other wei to the game. It has no module and no
  generic call.
- **Purchase gate** (D45): FWA asks `PoolOwner.canPurchase` before every purchase and refuses on a revert or `false`
  (100,000-gas stipend, fails closed). The gate reads only live FWA state and settings pushed by the game, so a board
  cannot be emptied past its floor whether or not anyone syncs (`invariant_gateHeadroom`,
  `test_keeperOutageWithDirectPurchasesThenRecovery`).
- **Books**: cash plus inventory at cost equals capital plus realised results (`invariant_books`); proceeds are booked
  at the highest edge governance has accepted and never exceed what FWA paid or holds (`invariant_bookingNeverAheadOfFwa`);
  only realised profit above protected cash is distributed (`invariant_buybackSpendsProfitOnly`).
- **Keeper funding**: vault top-ups are capped at 1 ETH for good and returned to the vault before any overflow reaches
  the game (`invariant_keeperTopUpsBounded`).
- **Failure isolation** (D46): each `sync` step runs in its own `try`; booking and retirement read no module.
- **Launch** (D50): single-sided, no ETH; the price can never return above the start; sellers can take out only ETH
  buyers put in (`test_singleSidedPriceNeverAboveStart`).
- **Genesis gate**: public buys refused from the game's opening to the fixed end block; the exempt set (EngineBuyer,
  ProtocolLiquidity) is fixed at wiring because a router's address is shared by all its users (D38).

## External dependencies trusted

- **FWA V2** (factory `0xF5A3…300c`, implementation `0xeaa4…eb31`, VRF service `0xa4ad…5ee2`): settlement, the purchase
  operator hook, owner proceeds, delivery and refunds. FWA's owner can change the edge, the inventory cooldown and
  withdraw-only mode; the gate and admission close purchases outside the accepted range, and settlement and retirement
  keep working in withdraw-only mode (fork-tested). A new edge above `maxEdgeBps` needs governance to accept it, and is
  then the booking edge for good.
- **Chainlink VRF** through FWA's service: a word that never arrives expires or times out and is refunded by FWA.
- **Shapes** (`0x6fE9…FAf0`) and **Shape Packs** (`0xf215…5cA7`): mint, burn and redeem return exactly the backing;
  the mint fee goes to the Shapes founder. A Pack's makeup is read from `defaultMakeup` at mint.
- **Uniswap v4 PoolManager** (`0x0000…8A90`) and the ENGINE hook's placement of fees.

## Known limits and open items

- **No audit.** The PoolOwner split, the gate, booking and true-up, Packs, keeper pay and the single-sided launch are
  new in this round.
- **FwaGame size**: 24,195 bytes, 381 under the limit (legacy pipeline, no via_ir). Further features need another split.
- **Gate granularity**: FWA does not tell the operator a purchase's size, so the gate always assumes a batch of 5. A
  board needs at least floor + 5 rows; refunds from FWA's drift guard rise with the in-flight limit on small boards
  (`sim/results/throughput.md`).
- **Buyback price check**: defeats a same-block sandwich, not a manipulation held across a block boundary; the slice
  and the 3% impact cap bound it.
- **Farm selling** (D52): farm rewards sold during genesis can take the opening market's ETH; the start price is the
  floor. A design choice for the owner, not a bug.
- **Keeper economics**: above about 1.6 gwei the operating allocation does not pay for every sync; top-ups from fees
  are capped at 1 ETH. Safety does not depend on keepers; availability does.
- **Governance power**: see the trust model; raise the timelock delay before outside money is material.

## Testing that backs these notes

Pinned mainnet fork (block 26,279,000) with the real FWA, VRF service, Shapes, Shape Packs and PoolManager: unit,
fork (game, accounting, market, resilience, smoke, gas), the invariant suite (12 runs × 40 calls in CI) and a 21-epoch
genesis rehearsal. See docs/FINAL_REPORT.md for counts and docs/SPEC.md section 13.

## Reporting

Report suspected vulnerabilities privately to the repository owner, not in a public issue.
