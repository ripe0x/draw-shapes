# Review of the ENGINE brief

Date: 2026-10-24. Reviewed: [BRIEF](BRIEF.md) (owner, 2026-10-23) against this repository at `main`
(`4a13a09`), `docs/SPEC.md`, `docs/OWNER_QUESTIONS.md`, the vendored FWA V2 sources and `docs/external/`.
Nothing was deployed or simulated on chain; the arithmetic below was recomputed independently from the
repository's listing formula. Forge is not installed in the review container, so no suite was run.

## Summary

The brief is internally consistent and unusually careful about what it does and does not promise. Every
figure in sections 3, 4, 11 and 12 reproduces to the stated precision from `PricingLib.listingPrice`, FWA's
inverse weights and FWA's owner/protocol split. Its FWA mechanics are correct. Its trust posture (hard cap,
no team allocation, burn of untouched inventory, no transfer lock after genesis, timelock) is credible.

Four things need a decision before implementation starts, in this order:

1. **The brief is written against code that is not in this repository.** `main` is a depositor-funded
   vault. There is no engine branch, no founder note, no foreign NFT work, no ERC20, no Uniswap code, and
   the referenced commit `2c70c15` does not exist here. "No outside ETH depositors" removes roughly a third
   of the current contracts. Section 16's "keep" and "remove" lists therefore do not apply as written.
2. **The 48 hour ETH exit makes the ENGINE Pack weakly dominated by cash for every winner who does not
   already want tokens.** The headline "40 percent of outcomes purchase ENGINE" can be close to zero in
   practice. This is a design choice to make deliberately, not a defect.
3. **Where original inventory lives in the v4 market.** Putting it in a liquidity position and then
   policing public buys with a ledger is the hardest version of the requirement. Holding it in the hook
   and selling it only to authenticated buyers along a virtual curve makes the quota structural and the
   finalizer a plain burn.
4. **The creator's Shapes mint fee is the largest take in the ticket**, 7.3 percent of the game payment
   against 2.6 percent retained for ENGINE. The brief discloses it, but the framing "no additional
   operator fee" will be read against that number by holders.

Everything else is either a refinement or a question. Details follow, strengths first.

## What checks out

Recomputed from `backing * (10_000 + 500) / 10_000 + mintFee * rungs` per listing, weight `1e36 / price`,
FWA fee `harmonicMean * 1.05`, owner proceeds `paid - (paid - base) / 2`:

| Claim in the brief | Recomputed |
| --- | --- |
| Board backing 2.73 ETH, opening mint fees 0.148 ETH, 1.122 ETH liquid | 2.730, 0.148, 1.122 |
| FWA game payment 0.01777338 ETH | 0.01777338 |
| ENGINE selection probability 40.10 percent | 40.100 percent |
| Backing per draw 0.01489290, mint fee 0.00128948, ENGINE backing 0.00595668 | exact |
| Retained 0.00046713, maintenance 0.00046713, feed 0.00023356 | exact (margin includes the owner's half of FWA's edge) |
| Backing is 83.79 percent of the payment | 83.79 |
| Punk assigned value 16.93 ETH for 1 in 100,000 | 16.927 |
| 14 day mint fees 1.805 / 5.416 / 13.540 ETH; ENGINE purchases 8.339 / 25.018 / 62.545 ETH | exact |
| Post genesis monthly retained 1.401 / 4.204 / 10.510 ETH | exact |
| 0.995 percent chance of a win within 1,000 draws | 0.995 |

The 133.59 million final supply in the 300 draw, 80 percent sale, no outside buying case is also plausible
on a back of envelope: the same tokens cycle through farmers about five times, so 25 ETH of purchases at an
average price near 0.73 of opening buys roughly 570 million tokens of volume while releasing only 33.6
million of original inventory. The companion model is not in the repository, so this is a plausibility
check, not a reproduction.

FWA facts the brief relies on, confirmed in the vendored sources (`external/fwa-v2`, `docs/external/fwa-v2.md`):

- `edgeBps` 500, protocol share `(paid - base) / 2`, `base = min(fee, weightedBackingTotal / totalWeight)`
  snapshotted at request time.
- Selection weight `1e36 / price`, so a 100 item board with 40 ENGINE listings at the same prices as their
  ETH twins gives 40.10 percent, not 40.
- `listNFT` accepts any collection with code (`InvalidCollection` only for an EOA address). Delivery is
  `transferFrom` followed by an `ownerOf` check. A plain ERC721 wrapper is deliverable, and FWA never
  calls into the prize, so "no swap inside the randomness callback" is already how the system works.
- `maxOutstandingRequestsPerPool` 10, `maxAcquisitionsPerTx` 5, `selectionTimeoutBlocks` 30,
  `DELIVERY_WINDOW` 7 days. Requests settle strictly in sequence order through `processAcquisitions`, which
  makes per epoch finalisation well defined (below).
- Pool creation needs a beta allowance or `maxPoolsPerWallet`, and a fee in the FWA token
  (`docs/OWNER_QUESTIONS.md` entry 31). The brief's "acquisition of any required FWA creation tokens" is
  right to budget for it.

Design points that fit the existing code well:

- Epoch assignment at request acceptance, credit at booked Fulfilled, bonus from
  `keccak256(randomWord, requestId, domain)`: `PoolBooks._walk` and `_capture` already book exactly this
  event with the request's random word, and the replacement draw already uses the same hash shape with a
  different domain. A keeper cannot pick an epoch (FWA fixes the sequence) or skip a result (the walk is
  in order).
- Fixed depth and like for like replacement are a strict simplification of SPEC 9: `chooseRow`, the
  surprise upgrade, the band cap and the NAV driven `boardItems()` all go away.
- The fee split setter already takes three lines summing to at most 1,000 bps; 200 / 200 / 100 is a value
  change. Maintenance at 200 is the increase decision 9g anticipated.
- The "at least 80 active ordinary outcomes" guard is the existing `concurrency` reopen guard with a
  larger margin.

## Material concerns

### 1. Base code mismatch and missing artefacts

Checked: the repository has two branches (`main` and this one), 98 commits, no object `2c70c15…`, and no
file matching ENGINE, hook, Uniswap, ERC20, founder note or foreign NFT outside the vendored FWA sources.
The companion archive (`check_design.py`, `board_economics.json`, `selected_design.json`,
`DECISION_REGISTER.md`, the 38 scenarios) is not in the repository either.

Consequences:

- `main` implements depositors: `deposit`, `withdraw`, shares, ordinary NAV, the entry fee, the volume
  cap, the founder window, queued claims, claim liquidation, retirement and successor migration (SPEC 4,
  6, 7, 13). The brief's "no outside ETH depositors" removes all of it. That is about 1,500 lines across
  `Pool`, `PoolAdmin`, `PoolBooks`, `Lens`, the deposit page and most of `sim/lab.html`.
- Section 16's instruction to keep "the useful foreign NFT work from the current engine branch" has no
  referent here. If that branch exists elsewhere, it needs to be pushed before the plan's sponsorship
  phase; otherwise the Punk sponsorship is greenfield.
- The pricing formula the brief cites is the one on `main` (`PricingLib.listingPrice`), so the arithmetic
  is unaffected. Only the "keep and remove" scope is.

Ask: confirm `main` is the base and the depositor layer is to be removed, and check the model archive and
the engine branch into the repository (or state that they are superseded).

### 2. The 48 hour ETH exit dominates the token path

For a winner, the ENGINE path is: wait for the claim window, buy ENGINE at zero project fee, hold or sell
at a 5 percent fee and whatever slippage the market has. The ETH path is: wait 48 hours, take the full
backing in ETH. Cash is at least as good as tokens for anyone who does not want to hold ENGINE, and
strictly better for anyone who would sell. Rational farmers, the people the brief says it is recruiting,
will take the ETH.

The brief acknowledges the risk ("explicitly included as a risk to assumed market purchase volumes") and
models half conversion (end spot 0.796 against 0.968). It does not model zero conversion, which is the
rational-seller outcome. At zero conversion the ENGINE Pack is an ETH Shape with a 48 hour delay and the
game's only purchase flow is the 2 percent retained surplus.

Options, each a real tradeoff, for the owner to pick:

- Keep the exit but make the two paths equal in value: the ETH exit pays `backing * (1 - fee)` with the
  haircut routed exactly where the sell fee would have gone. Neither path then dominates.
- Make the mode a one time choice at claim rather than a fallback: the winner picks ETH or ENGINE within
  the window and the pick is final; after the window only ENGINE remains, with the 48 hour exit kept
  solely for the case where execution is impossible (market paused, hook upgrade).
- Accept the dominance and present the 40 percent as an upper bound, with zero conversion as the base case
  in the published model.

The first is the smallest change and is honest about the economics. Whatever is chosen, the published
numbers should include the zero conversion row.

### 3. Prize purchases are mostly recycling, and the reporting should say so

In the brief's own 300 draw, 80 percent sale, no outside buying case: 25.0 ETH of game purchases plus the
0.25 ETH seed leave 1.70 ETH in the market after 14 days. About 23.5 ETH went through the market to
sellers, and the only sellers in that scenario are farmers. Game purchases consume resale inventory first,
so during genesis "the game buys ENGINE" mostly means "the game pays ETH to whoever sold last".

Section 10 already says fees on resale are recycling and section 14 says purchase flow is not permanent
buy pressure. The gap is in section 12's table, where "14 day ENGINE prize purchases 25.018 ETH" sits next
to creator income without the net figure. Report gross purchases, net ETH retained by the market and
original inventory released side by side.

### 4. The mint fee is the largest take, and it is the creator's

Per draw: Shapes mint fee 0.00129 ETH (7.3 percent of the game payment, 0.001 ETH times 1.29 expected
rungs), FWA protocol 0.00042 (2.4 percent), retained for ENGINE 0.00047 (2.6 percent), maintenance 0.00047,
GRAIL feed 0.00023. The creator, as Shapes operator, receives the mint fee. Over the 14 day genesis at 300
draws a day that is 5.4 ETH gross, which exceeds the 5 ETH contribution.

This is disclosed (section 12) and partly mitigated by held Shape reuse through `pullWithShapes`. Two
things would make it fair to all readers: publish the per draw split including the mint fee and the FWA
protocol share as the first "where the ticket goes" chart, and decide explicitly whether any part of the
mint fee is committed to the system (for instance, the maintenance top-ups decision 10f already relies
on). "No additional operator fee" is true; "the creator earns the mint fee" is the operative sentence.

### 5. v4 architecture: where original inventory lives

The brief puts original inventory in a liquidity position spanning a tenfold range, then requires the
hook to stop public buys from reaching it, make game buys consume resale first, give honest partial fills,
and at close withdraw the positions, burn the untracked remainder and re-add permanent positions at the
same marginal price. Each of those is a custom accounting step inside `beforeSwap` and
`beforeAddLiquidity`, and they interact with v4's own rounding. The brief itself calls it "the most
important new implementation requirement".

Alternative: the hook holds the 900 million original tokens as a plain balance, outside any position.
Only an authenticated game buy can draw on it, along a virtual curve the hook evaluates (the brief's
opening price and tenfold range), at no less than the pool's current spot so the two prices cannot be
arbitraged. Everything the public can touch is pool liquidity, which by construction is circulated tokens
plus ETH. Then:

- "Public buyers never purchase untouched original inventory" is structural, not a ledger check.
- "Game purchases consume resale first" becomes "route the game buy through the pool when the pool is
  cheaper, else the curve", a one-line comparison.
- The finalizer burns the hook's remaining balance. No position removal, no re-add, no marginal price
  matching. Protocol liquidity stays where it is.
- The honest partial fill for public buys is unnecessary: a public buy is a normal swap against pool
  liquidity.

The cost is that the primary sale is a hook-owned curve rather than a Uniswap position, so the brief's
"initial primary position" language changes and the curve math needs its own unit tests. Recommend this
design unless there is a reason to keep original inventory inside the pool that the brief does not state.

Either way the hook address must be mined for its permission bits, `v4-core` and `v4-periphery` become
pinned submodules, and the mainnet `PoolManager` joins the pinned fork inputs.

### 6. The sponsorship pays twice the fair rate and cannot run continuously from the pot

Expected prize loss per eligible draw is `P / 100,000`; compensation is `2 P / 100,000`, capped at `1.5 P`
after 75,000 draws. At P = 30 ETH and 300 draws a day that is 0.18 ETH a day, and a 1 ETH pot funds
1,667 draws (about five and a half days) before "stop accepting sponsored draws" fires. The pot's inflow
is 2.25 percent of fee paying trading, so continuous sponsorship at 300 draws a day needs about 8 ETH a
day of public trading. The sponsorship will be intermittent, every on/off changes the ticket by about
1 percent (`(N + 1) / (W + 1 / V)` against `N / W`), and when the Punk is captured FWA pays the pool
roughly 0.0178 ETH for it.

This can be the intent (a marketing spend) but the brief does not say so. Options: pay `P / 100,000`
(fair), or keep 2× and state the daily budget and expected uptime, or price the compensation off the
realised probability each draw rather than the maximum.

### 7. Smaller points

- **First 24 hours.** Holders can sell but only the game can buy, so day one sells land on the 0.25 ETH
  bid side. At 300 draws a day the farmers' day one equal share is about 5.7 million tokens at 80 percent
  sale, roughly 0.29 ETH at the opening price, more than the seed. Game buys that day (about 1.8 ETH) catch
  up, but the brief gives no reason for delaying public buys of resale, which by definition is not original
  inventory. Consider opening public buys of resale from hour zero.
- **Gas price cap.** A `tx.gasprice` check in `acquire` is implementable, and FWA's site already re-reads
  the quote at the intended fee. It should be a parameter with a timelocked setter, and the published cost
  table should show the ticket at 0.25, 1 and 5 gwei since the VRF fee scales with gas.
- **Epoch edge cases to specify.** A request refunded for slippage or timeout earns nothing (the brief
  says so). A `DeliveryPending` write-off should also earn nothing, and the rule should say whether a
  delivery that later completes earns retroactively (recommend: no, credit only at the booked Fulfilled
  walk). An epoch finalises when `nextSequenceToBook` passes the last sequence accepted inside it, which is
  monotone because FWA settles in order. Per epoch integer dust needs a destination (recommend: the same
  burn as empty epochs).
- **The 1.122 ETH liquid in the ordinary allocation** has no stated job. Replacement mints are funded by
  the mint line, so this is the negative margin and slippage refund buffer. Name it as the "defined
  operating coverage" section 10 refers to.
- **Draw Packs is not deployed on mainnet** (`script/env/mainnet.env`, `DRAW_PACKS=`). The ETH pack rows
  (0.02, 0.03) depend on it. The ENGINE Pack wrapper could carry both modes, which removes that dependency
  and gives one prize collection. That reverses an owner decision and is noted as an option only.
- **Bytecode budget.** `Pool`, `PoolAdmin` and `PoolListing` are each within about 3 KB of EIP-170.
  Removing the depositor layer frees room for genesis attribution and the gas and inventory guards; the
  token, wrapper, hook, genesis ledger and sponsorship must be separate contracts anyway.
- **Repository rules.** AGENTS.md pins Solidity 0.8.28 and the via_ir restrictions. `v4-core` builds under
  0.8.26 or later and needs via_ir for `PoolManager` in tests; the fork tests will use the deployed mainnet
  `PoolManager`, so only the hook and periphery helpers compile locally. Check this early.
- **Wording.** "Approximately 7.142857 million" is `100_000_000 / 14`; say the remainder of 2 tokens goes
  to epoch 14. "Verified Wrapped CryptoPunk" should name the contract address. "Mature buybacks" needs a
  definition before it can be exempt from the fee.

## Open questions for the owner

1. Base: `main` with the depositor layer removed? Where are the engine branch and the model archive?
2. ENGINE Pack exit: haircut, one time choice, or accept the dominance and publish zero conversion?
3. Original inventory in a position with a ledger, or in the hook with a virtual curve?
4. Sponsorship compensation at 2× or 1× expected loss, and is intermittent uptime acceptable?
5. Public buys of resale from hour zero or hour 24?
6. One prize wrapper for both modes (drops Draw Packs) or Draw Packs for ETH packs as decided?
7. Admin: which multisig, and does the 72 hour timelock also govern the game's `PoolAdmin` setters?

Decisions, 2026-10-24: the owner took the recommendation on every question.

1. Base is `main`, depositors removed first; the model archive goes into `docs/engine/model/`.
2. The 48 hour exit pays backing less a haircut equal to the sell fee.
3. Original inventory lives in the hook on a virtual curve; the pool holds circulated tokens only.
4. Sponsor compensation is `P / 100,000` per eligible draw, capped at `1.0 P`; uptime follows the pot.
5. Public buys of resale open at hour zero; the delay stays a parameter at 0.
6. One prize wrapper carries both modes; Draw Packs leaves the dependency set.
7. One multisig everywhere; the 72 hour timelock covers the hook policy and every economic setter on the
   game; keeper tunables and risk-stopping pauses stay direct.

[PLAN](PLAN.md) section 0 records them as decisions A1 to A7.
