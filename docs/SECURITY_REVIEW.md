# Security review: coin-supported engine

Date: 2026-10-23. Scope: everything on `feat/coin-funded-engine` that differs from `origin/main`:
`src/engine/{EngineTreasury,FoundingRound,PrizeSponsorship}.sol`, `src/interfaces/IArtcoins.sol`, the
foreign-listing port and `boardNavCap` in `src/Pool*.sol`, the batch-size change for the EIP-7825 gas
cap, and `script/{EngineDeployer,DeployEngine}.s.sol`.

Method: an independent reviewer (separate agent, read-only, given the code and the owner's requirements,
not the author's conclusions) at commit `971fbdc`; the author's own pass; and the fork tests listed at
the end. This is not an external audit. **A professional audit of the new contracts and the pool change
is still required before mainnet** (see `docs/MAINNET_READINESS.md`).

## Findings and status

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| M1 | Medium | Anyone could `open()` an unseeded pool once the FWA pool's 24 hour opening deadline passed, moving it to Live and locking `activate()` out; the deployment would have to be redone. | **Fixed** in `ec8fc1a`: `activate(fee)` creates the FWA pool in the same transaction that seeds it; `createFwaPool` is no longer reachable through `poolCall`. Test: `test_activationRefusedBeforeFunding` (`open()` reverts `FwaPoolMissing` before activation). |
| M2 | Low to medium | `poolCall(setReserve)` accepted up to 100 percent, letting the owner hold all pool cash as reserve so `harvest` finds nothing free; the founders' earnings leg and buybacks would stall. | **Fixed** in `ec8fc1a`: `setReserve` is capped at 2,500 bps. Test: `test_poolCall_refusesPrincipalAndControlSelectors`. |
| G1 | High (launch blocking) | Since Fusaka, mainnet rejects transactions above 16,777,216 gas (EIP-7825). A pool `settle` listing its 25-item batch used 24.3M gas, an `open()` call up to 13.5M; the anvil rehearsal left such transactions pending forever. On mainnet the board could not have been filled or replenished. | **Fixed**: `MAX_LIST_PER_SETTLE` and `MAX_LIST_PER_ROTATE` 25/20 to 12, `MAX_OPEN_MINTS` 20 to 12, launch `batchMin` 12. Measured worst cases: settle 12.4M, open 10.8M, wind-down step 6.7M, GRAIL merges 3.5M, `acquireBatch(5)` 1.8M, `activate` 1.35M (`test/fork/engine/EngineGas.t.sol`). Found by the author during the deployment rehearsal, not by the reviewer. |
| L1 | Low | The owner sets a collectible bid's price; they could sell their own punk to the treasury at an inflated price, paid from the prize budget. | **Mitigated**: `fillBid` refuses the owner; price bounded by `maxBidWei` (60 ETH) and the prize budget (post-founder money). An owner can still use another address. Residual trust assumption, documented in D17. |
| L2 | Low | Buyback can be sandwiched within its 2 percent impact bound. | **Accepted**: bounded per call (0.5 ETH), once per block; a 5 percent fee each way makes a sandwich cost the attacker about 10 percent of its size. |
| I1 | Info | `PrizeSponsorship.onForeignCapture` re-enters `Pool.fundGrail` during the pool's harvest. | **Accepted**: `fundGrail` only adds to the GRAIL fund; controllers are engine contracts registered by the treasury; the ETH round trip is balanced. A future third-party controller must not be registered without review. |
| I2 | Info | `setCoin` does not require an unrestricted coin. | **Accepted for this config**: launch config sets `restricted = false` and `lpFeePips = 0`, so the treasury never receives coin from the locker. Revisit if the coin terms change. |

## What the reviewer verified as sound

- Public deposits are impossible from the pool's construction (zero NAV cap) and after activation
  (paused); the treasury's own deposit lifts both and restores them in one call.
- The `poolCall` allowlist cannot be bypassed by short calldata or decode mismatches; `setAdmin`,
  `startExit`, `transferGrailEstate`, `setRegistrar`, `registerForeign`, admission setters, `deposit`
  and `withdraw` are refused; guarded selectors are decoded from the same bytes the pool decodes.
- Harvest never classifies principal as earnings: earnings only above `basis`, post-withdraw NAV
  re-checked, share rounding favours the pool, queued claims revert.
- Buyback rebate accounting isolates the treasury's own bounty; every coin bought is burned with a
  supply check.
- `FoundingRound`: release is treasury-only, one shot, only while Funded; refunds only while Refunding;
  distributions hard-capped; pro rata floor division never over-credits.
- `PrizeSponsorship`: no payment after a win, reclaim or completion; reclaim refused while a draw is
  pending; terminal states are terminal.
- Storage: new pool fields are appended after existing ones and shared by all three modules; fresh
  deployment.
- The Artcoins ABI copied into `IArtcoins.sol` matches the v2 source; `recipientsLocked` really
  freezes the bounty recipient.

## Author's additional checks

| Topic | Result |
| --- | --- |
| ETH arriving at the treasury | Every path books its inflow in the same call (release, pool withdrawals, redemptions, foreign capture, buyback rebate, escrow claims inside `buyback` and wind-down); only Artcoins bounty pushes (2,300 gas, `receive` empty) remain unbooked until `collectFees`. ETH conservation by category is asserted after every step of three random action sequences (`EngineInvariants.t.sol`). |
| Founders' custody | Founder payments leave the treasury in the allocating call (`FoundingRound.distribute`); sponsor payments likewise (`PrizeSponsorship.pay`). Nothing credited can be spent by the game. |
| Draw settlement independence | The pool never calls the treasury or the coin market; draws settle with zero trading (`test_gameSettlesWithoutAnyTrading`). |
| Reentrancy | Treasury entrypoints that move ETH or call out are `nonReentrant`; `unlockCallback` checks the PoolManager; `onForeignCapture` checks the pool and only books. `receive` is empty by design. |
| Discretionary starvation of founders | Premium floor (200 bps), reserve cap (2,500 bps), subsidy cap (4 x maintenance target), no owner path to principal or the GRAIL estate, prize budget spent permissionlessly. |
| Sniper window | Buybacks wait 180 minutes after pool creation (`MAX_MEV_WINDOW`). |
| Deployment between steps | No step leaves funds exposed: the escrow releases only inside `activate`; the pool cannot take deposits; the FWA pool exists only from activation; a failed launch refunds founders after the launch window. A front-run of `open()` is impossible before activation. |
| Coin admin | The coin admin can change name, image and description only after `lockRecipients`; the treasury refuses to bind an unlocked coin. |
| Oracle | FWA's VRF word is delivered by the real VRF service; fork tests impersonate its Chainlink coordinator to deliver words (the only way to reproduce fulfillment on a fork). Live Chainlink proofs are not reproduced: coverage gap. |

## Residual trust and limits

- The treasury owner tunes the game (mix, GRAIL parameters, tip, batch, probability cap, reserve within
  the cap, fee split above the premium floor), chooses collectible bids within `maxBidWei`, attaches a
  sponsorship and can start the wind-down. A malicious or careless owner can make the game less
  attractive or slower to earn; they cannot take principal, the GRAIL estate or credited payments.
- The Artcoins owner controls the factory, hook and escrow pointers of the market (outside this repo).
- FWA's owner controls the factory (cooldown, fees, purchase switches).
- Shapes' admin can change the mint fee (capped at 0.01 ETH), which raises replacement costs.
- No formal verification; invariant coverage is seeded sequences on the fork plus the pool's own
  invariant suite.

## Tests behind this review

`forge test --match-path "test/fork/engine/*.t.sol"` (engine: launch, market capture, end-to-end
earnings and burn, founder cap, coverage, wind-down, dormancy, owner fence, sponsorship, bids, ETH
conservation sequences, gas cap), `forge test --match-path test/unit/FoundingRound.t.sol` (escrow and
ledger, fuzzed cap), and the existing suite at block 26,170,000 (`test/unit`, `test/fork`, invariant
reach, PlayMonth). Exact commands, commits and results: `docs/MAINNET_READINESS.md`.
