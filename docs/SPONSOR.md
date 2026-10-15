# Sponsored prize

Owner decisions of 2026-10-15. A third party lends an ERC-721 (first case: a Wrapped Cryptopunk, about
30 ETH) as a prize on the board. The pool holds the token as a foreign listing (SPEC section 11). Every
term of the deal lives in two contracts outside the pool, so a later deal with other terms is a new pair
of contracts and no pool change.

## Deal terms, first sponsor

- Sponsor lends the punk. The pool lists it at 30 ETH, where it is one draw in about 2.3 million per
  pull and stays until the sponsor is paid.
- Sponsor is paid from the Shapes mint fees the operator earns: 100 percent of every mint fee until
  `cap` (45 ETH, the 30 ETH value plus 50 percent). Payment comes from mint fees and from nothing else.
- When `cap` is reached the punk belongs to the game: its price decays from 30 ETH toward a 0.25 ETH
  floor at 0.001 ETH per settled pull, and the sponsor has no further claim or reclaim right.
- If the punk is won before `cap` is reached, mint fees stop flowing to the sponsor at that moment. The
  sponsor keeps what was paid. The operator owes nothing further.
- After `reclaimAfter` (30 days from listing) and while the punk is unwon and `cap` unpaid, the sponsor may
  reclaim the punk. They keep what was paid, the remainder of `cap` is forfeited, mint fees return to the
  operator.
- Capture proceeds (the ticket FWA pays for the punk) go to the pool's GRAIL fund.

## Contracts

### `FeeSplit`

Set as the Shapes mint fee recipient (`Shapes.setFeeRecipient`). Receives every mint fee.

- Storage: `owner`, `sponsor`, `capWei`, `paidWei`, `prize` (the `SponsoredPrize` address), `ownerBalance`,
  `sponsorBalance`.
- `receive()`: while `paidWei < capWei` and `prize.active()` is true, credit `sponsorBalance` up to the
  remaining cap and `paidWei`; the rest credits `ownerBalance`.
- `withdraw()`: the caller takes their balance.
- `setPrize(address)` and `setSponsor(address, capWei)`: owner, only while `paidWei == 0` and no prize
  is active. A new deal reuses the contract.
- `paidWei` and `capWei` are public.

### `SponsoredPrize`

One per deal. Implements `IForeignController`.

- Constructor: `pool`, `feeSplit`, `sponsor`, `collection`, `tokenId`, `parkedPriceWei` (30 ETH),
  `floorWei` (0.25 ETH), `decayWeiPerPull` (0.001 ETH), `reclaimAfter` (listing time plus 30 days).
- `start(listingId)`: owner, after the admin has called `registerForeign` on the pool. Records the listing
  and `listedAtPull = pool.grail().pulls`, `startedAt = block.timestamp`.
- `active()`: true while the listing is registered on the pool and not captured.
- `phase()`: Parked while `feeSplit.paidWei() < feeSplit.capWei()`, else Hot.
- `tick()`: anyone. In Hot phase computes `next = max(floorWei, parkedPriceWei - decayWeiPerPull *
  (pool.grail().pulls - hotFromPull))` and calls `pool.repriceForeign(listingId, next)` when `next` is at
  least 1 percent below the current price. `hotFromPull` is the pull count when Hot began, set by the
  first `tick` that sees Hot. The keeper calls `tick` on each pass.
- `reclaim()`: sponsor, Parked phase, `block.timestamp >= reclaimAfter`. Calls
  `pool.withdrawForeign(listingId, sponsor)`. After this `active()` is false.
- `onForeignCapture(listingId, tokenId, proceeds)`: payable, pool only. Marks captured, forwards the
  value to `pool.fundGrail()`.
- `rescue(to)`: owner, only when the pool reports the token unlisted after a refunded delivery; calls
  `pool.withdrawForeign(listingId, to)`.

## Operations

1. Deploy `FeeSplit(owner)`. Call `Shapes.setFeeRecipient(feeSplit)`.
2. Deploy `SponsoredPrize` with the terms. `FeeSplit.setSponsor(sponsor, 45 ether)`, `FeeSplit.setPrize(prize)`.
3. Sponsor transfers the punk to the admin. Admin calls `pool.registerForeign(wpunks, id, prize, 30 ether)`.
4. Owner calls `prize.start(listingId)`.
5. Keeper adds `prize.tick()` to each pass once Hot; it is a no-op before.
6. On capture the pool pays the prize contract, which forwards to the GRAIL fund.

## Tests

Fork tests against the real Wrapped Cryptopunks and Shapes contracts. Cover: fees route to the sponsor
until the cap then to the owner; cap reached flips the phase and `tick` decays to the floor and stops;
capture in Parked stops sponsor payments at the paid amount; reclaim after 30 days in Parked returns the
punk and ends payments; reclaim refused in Hot and before 30 days; `onForeignCapture` only from the
pool; proceeds reach the GRAIL fund.
