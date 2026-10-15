# Sponsored prize

Owner decisions of 2026-10-15. A third party lends an ERC-721 (first case: a Wrapped Cryptopunk, about
30 ETH) as a prize on the board. The pool holds the token as a foreign listing (SPEC section 11). Every
term of the deal lives in two contracts outside the pool, so a later deal with other terms is a new pair
of contracts and no pool change.

## Deal terms, first sponsor

- Sponsor lends a punk of the sponsor's choice: any token of the collection that the sponsor owns, picked at
  stake time. The pool lists it at 30 ETH, where it is one draw in about 2.3 million per
  pull and stays until the sponsor is paid.
- Sponsor is paid from the Shapes mint fees the operator earns: 100 percent of every mint fee until
  `cap` (45 ETH, the 30 ETH value plus 50 percent). Payment comes from mint fees.
- When `cap` is reached the punk belongs to the game: its price decays from 30 ETH toward a 0.25 ETH
  floor at 0.001 ETH per settled pull, and the sponsor has no further claim or reclaim right.
- Sponsor risk: a capture in Parked ends the sponsor's payments at the amount paid so far. The punk goes to
  the purchaser and does not return to the sponsor. The sponsor keeps what was paid and the remainder of
  `cap` is not paid.
- After `reclaimAfter` (30 days from the stake) and while the punk is unwon and `cap` unpaid, the sponsor may
  reclaim the punk. They keep what was paid, the remainder of `cap` is forfeited, mint fees return to the
  operator.
- Capture proceeds (the ticket FWA pays for the punk) go to the pool's GRAIL fund.

## Contracts

### `FeeSplit`

Set as the Shapes mint fee recipient (`Shapes.setFeeRecipient`). Receives every mint fee.

- Storage: `owner`, `sponsor`, `capWei`, `paidWei`, `prize` (the `SponsoredPrize` address), `locked`,
  `ownerBalance`, `sponsorBalance`.
- `receive()`: while `paidWei < capWei` and `prize.active()` is true, credit `sponsorBalance` up to the
  remaining cap and `paidWei`; the rest credits `ownerBalance`.
- `withdraw()`: the caller takes their balance.
- `lock()` and `unlock()`: the prize only (`NotPrize`). `SponsoredPrize.stake` locks. The prize unlocks at the
  end of the deal: capture, `reclaim`, `rescue` or `releaseHeld`.
- `setPrize(address)`: owner, only while `paidWei == 0` (`DealLocked`) and unlocked (`Locked`).
- `setSponsor(address, capWei)`: owner, while unlocked (`Locked`). Sets `paidWei` to zero, which starts a new
  deal on the same contract; `ownerBalance` and `sponsorBalance` keep their values. A different sponsor
  needs `sponsorBalance == 0`, so the previous sponsor withdraws first. A new deal calls `setSponsor`
  before `setPrize`.
- `paidWei` and `capWei` are public.

### `SponsoredPrize`

One per deal. Implements `IForeignController`.

- Constructor: `pool`, `feeSplit`, `sponsor`, `capWei` (45 ETH), `collection`, `parkedPriceWei` (30 ETH),
  `floorWei` (0.25 ETH), `decayWeiPerPull` (0.001 ETH), `reclaimDelay` (seconds, 30 days; the deploy
  script reads it from `SPONSOR_RECLAIM_DELAY`). `tokenId` and `reclaimAfter` are zero until `stake` and then
  `block.timestamp + reclaimDelay`.
- `stake(tokenId_)`: sponsor only, once (`AlreadyStaked`). Requires `pool.registrar() == address(this)`
  (`NotRegistrar`), the sponsor's approval of this contract for `tokenId_`, and `feeSplit.sponsor() == sponsor`
  and `feeSplit.capWei() == capWei` (`TermsMismatch`). Pulls the token with `transferFrom(sponsor, this,
  tokenId_)`, approves the pool, records `tokenId = tokenId_`, calls `pool.registerForeign(collection, tokenId, this, parkedPriceWei)`,
  reads the listing id from `pool.foreignListings()`, calls `feeSplit.lock()` and records `listingId`,
  `listedAtPull = pool.grail().pulls`, `startedAt = block.timestamp` and `reclaimAfter = block.timestamp +
  reclaimDelay`. Emits `Staked(listingId, tokenId)`. Transfer, registration and recording happen in one
  transaction.
- `staked()`: true once `stake` has recorded the listing.
- `canStake(tokenId_)`: true when unstaked, the prize is the pool's registrar, and the sponsor owns `tokenId_` and has
  approved the prize for it (single approval or approval for all). The page gates its stake button on it.
- `owner`: `feeSplit.owner()`. The prize contract stores no owner of its own.
- `active()`: true while the prize is staked, not captured, and the pool entry exists with a nonzero
  price. An entry that the pool holds unlisted after a refunded delivery is not active.
- `phase()`: Parked while `feeSplit.paidWei() < capWei` (the constructor value), else Hot.
- `tick()`: anyone. In Hot phase computes `next = max(floorWei, parkedPriceWei - decayWeiPerPull *
  (pool.grail().pulls - hotFromPull))` and calls `pool.repriceForeign(listingId, next)` when `next` is at
  least 1 percent below the current price. A `next` below `floorWei * 102 / 100` becomes `floorWei`. When the
  pool rejects the step to `floorWei` as `RepriceTooSmall`, the price is within 1 percent of the floor and
  `atFloor` becomes true; later `tick` calls do nothing. `hotFromPull` is the pull count when Hot began,
  set by the first `tick` that sees Hot. The keeper calls `tick` on each pass.
- `reclaim()`: sponsor, Parked phase, `block.timestamp >= reclaimAfter` (`TooEarly`). Calls
  `pool.withdrawForeign(listingId, sponsor)`. After this `active()` is false.
- `onForeignCapture(listingId, tokenId, proceeds)`: payable, pool only, for the deal's `listingId`
  (`UnknownEntry` otherwise). Marks captured, unlocks `feeSplit`, forwards the value to `pool.fundGrail()`.
- `rescue(to)`: owner, only when the pool reports the token unlisted after a refunded delivery; calls
  `pool.withdrawForeign(listingId, to)`. In Parked `to` must be the sponsor. Unlocks `feeSplit`.
- `releaseHeld()`: sponsor or owner. Transfers the token this contract holds to the sponsor in Parked and
  to the owner in Hot, then unlocks `feeSplit`. The pool's `exportStep` sends the token of a listing to
  its controller, so after an exit the token sits in this contract until `releaseHeld`. `stake` is atomic, so the
  contract holds the token only after an export.
- `onERC721Received`: accepts the staked token from its collection after `stake`; reverts `WrongToken` for every
  token before `stake`.

## Operations

1. Deploy both contracts and set the deal terms in one run (`script/DeploySponsor.s.sol`). Copy
   `script/env/sponsor.example.env` to `script/env/sponsor.env`, fill the empty values, and run it with
   the keystore account that is `SPONSOR_OWNER`:

       set -a; source script/env/sponsor.env; set +a
       forge build && forge script script/DeploySponsor.s.sol --rpc-url $RPC_URL \
         --account <keystore> --broadcast --slow

   The script deploys `FeeSplit(owner)` (or reuses `SPONSOR_FEE_SPLIT`), deploys `SponsoredPrize`, calls
   `FeeSplit.setSponsor(sponsor, 45 ether)` and `FeeSplit.setPrize(prize)`, and reads every value back. When the
   broadcaster is the pool admin it also calls `pool.setRegistrar(prize)`. Otherwise it logs the line for the
   admin to run:

       cast send <pool> "setRegistrar(address)" <prize> --account <pool admin keystore>

   The pool has one registrar at a time, so a new deal sets it again once the previous prize is staked.
   A broadcast run also writes `deployments/<chainId>-sponsor.json` (`SPONSOR_RECORD` overrides the path)
   with `feeSplit`, `prize` and `collection`; the web app's `/sponsor` page reads it.
2. The Shapes admin sets the fee recipient:

       cast send <shapes> "setFeeRecipient(address)" <feeSplit> --account <shapes admin keystore>

   Mint fees accrue in Shapes per recipient. `Shapes.withdrawFees(feeSplit)` is callable by anyone and
   forwards the accrued fees to `FeeSplit.receive()`, which applies the routing at that moment.
3. The sponsor opens `/sponsor`, chooses a token of the collection it owns, approves the prize contract for that token, and calls
   `prize.stake(tokenId)` from the page. The button is enabled while `prize.canStake(tokenId)` is true. The stake
   registers the listing and locks `FeeSplit`.
4. The prize is active once the pool activates the listing (next settlement).
5. Keeper (`script/keeper.sh`) with `SPONSOR_PRIZE`, `SHAPES` and `FEE_SPLIT` set runs two more steps on each
   pass. It calls `Shapes.withdrawFees(feeSplit)` when `Shapes.feesOwedTo(feeSplit)` is nonzero, so accrued
   fees reach `FeeSplit.receive()` while the prize is active. It calls `prize.tick()` while `prize.active()`
   is true, `prize.phase()` is Hot and `prize.atFloor()` is false. The pool accepts one reprice per `rotateInterval`; a `tick` inside
   the interval leaves the price unchanged and the next `tick` retries.
6. On capture the pool pays the prize contract, which forwards to the GRAIL fund.

## Tests

Fork tests against the real Wrapped Cryptopunks and Shapes contracts. Cover: fees route to the sponsor
until the cap then to the owner; cap reached flips the phase and `tick` decays to the floor and stops;
capture in Parked stops sponsor payments at the paid amount; reclaim after 30 days in Parked returns the
punk and ends payments; reclaim refused in Hot and before 30 days; `onForeignCapture` only from the
pool; proceeds reach the GRAIL fund. `test/fork/Sponsor.t.sol` covers each case, `stake` and `canStake` (sponsor only, registrar role, approval, once, terms), the fees of the pool's
own replacement mints, `tick` while FWA is busy and past the probability cap, `rescue`, and the deploy
script.

## Standing offer: `SponsorOffer`

Owner decision of 2026-10-15. One contract replaces the per-deal pair for the open offer. It is the pool's
registrar and the Shapes mint fee recipient. The bilateral `SponsoredPrize` stays for hand deals.

Terms per collection, set by the owner: `parkedPriceWei`, `floorWei`, `decayWeiPerPull`, `reclaimDelay`,
`capWei`, `maxOpen` (deals that may be unpaid at once), `enabled`. Launch terms for Wrapped Cryptopunks:
parked 32 ETH, cap 48 ETH (the 32 ETH value plus 50 percent), floor 0.25 ETH, decay 0.001 ETH per pull,
reclaim 30 days, `maxOpen` 2. Changing terms affects future takes only.

- `take(collection, tokenId)`: anyone. Requires the collection enabled, open deals below `maxOpen`, the pool
  below its foreign cap, and the caller to own and have approved the token. Pulls the token, registers it on
  the pool at the parked price, opens a deal `{sponsor, collection, tokenId, listingId, capWei, paidWei,
  takenAt, reclaimAfter, phase}` and appends it to the fee queue. Event `Taken(dealId, sponsor, collection,
  tokenId, listingId)`.
- Fees: `receive()` credits the head of the queue (the oldest deal still unpaid and active) up to its remaining
  cap, moves on to the next, and credits the owner with the rest. `withdraw()` pays the caller's balance.
- Phases per deal as in `SponsoredPrize`: Parked until `paidWei == capWei`, then Hot with decay by pulls to
  the floor, `tick(dealId)` by anyone, `atFloor`. A capture ends the deal and its payments. `reclaim(dealId)`
  by the sponsor while Parked after `reclaimAfter`. `releaseHeld(dealId)` after an exit. `rescue(dealId, to)`
  by the owner only when the pool reports the token unlisted, `to` the sponsor while Parked.
- Views: `deals()`, `dealCount()`, `deal(id)`, `queue()` (unpaid active deals in order with remaining cap),
  `expectedWaitWei(collection)` (the sum of remaining caps ahead of a new take; the queue is shared by every
  collection), `canTake(collection, tokenId, who)`, `phase(id)`, `active(id)`, `terms(collection)`.
- Deal terms are copied into the deal at take time: `capWei`, `floorWei`, `decayWeiPerPull`, `parkedPriceWei` and
  `reclaimAfter`.
- Contract: `src/sponsor/SponsorOffer.sol`. Deploy: `script/DeployOffer.s.sol` with `script/env/offer.example.env`.
  The script sets the terms, calls `pool.setRegistrar(offer)` when the broadcaster is the pool admin (otherwise it
  logs the `cast send` line), logs the `Shapes.setFeeRecipient(offer)` step and writes the record.
- Keeper: `script/keeper.sh` with `SPONSOR_OFFER` and `SHAPES` set calls `Shapes.withdrawFees(offer)` when owed and
  `tick(id)` for every deal that is active, Hot and not `atFloor`.
- Record `deployments/<chainId>-offer.json` with `{offer, collection}`. The page reads it in place of the
  per-deal record when present.
- Tests: `test/fork/SponsorOffer.t.sol`.
