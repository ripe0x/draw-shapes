# Runbook

Operator steps for a local run and for a live launch. Deploy mechanics are in `docs/DEPLOY.md`.
Parameters and lifecycle are in `docs/SPEC.md` (sections 5, 6, 10, 12, 13).

## Local run

```
script/local.sh start    # fork, deploy, FWA pool, fund wallets, deposit, warp, open() until Live
ONCE=1 script/local.sh keeper   # one keeper pass; drop ONCE=1 to loop every INTERVAL seconds (default 15)
script/local.sh stop
```

Set `LOCAL_EXTRA_WALLETS="0xYourWallet"` before `start` so your own wallet is funded on the fork; a real address
carries only its mainnet balance otherwise, and the wallet refuses a pull it cannot pay for.

`start` forks mainnet on port 8545 (`FORK_RPC` overrides the upstream), deploys through
`script/deploy.sh anvil`, sets the FWA `inventoryChangeCooldown` to 0, deposits `LOCAL_OPENING_ETH`
(default 50) from the admin, warps past `openingDeadlineAt` and calls `open()` until the pool is
Live. It prints the pool, lens and FWA pool addresses, `Lens.quote(1)`, `nav()`, `settleDue()` and
`rotateDue()`. The record is `deployments/31337-8545.json`. Anvil accounts 1, 2 and 3 are the
keeper and two test wallets, each funded with `LOCAL_WALLET_ETH` (default 1000).

### Local VRF

Nothing fulfils VRF on anvil, so a pull stays Pending. `script/local.sh fulfill` impersonates the
FWA VRF service's `s_vrfCoordinator`, sends `rawFulfillRandomWords` to the service with a random
word for each Pending acquisition from `nextSequenceToProcess()` to `lastIssuedSequence()`, then
calls `processAcquisitions(20)` and logs the request id and resulting status. `LOCAL_VRF=1
script/local.sh keeper` runs the same step at the start of every pass, before `settle`. Use it on
anvil only.

Warping 1000 seconds (`evm_increaseTime`, `evm_mine`) makes `rotateDue()` nonzero and shows the
keeper rotate path.

## What to watch

Lens (read-only, one call each):

- `quote(count)`: fee, vrf, total and whether pulls are open.
- `nav()`, `sharePrice()`, `position(account)`.
- `board()`: per row backing, list price, count, listed count, target.
- `grail()`: GRAIL fund, cycle, parameters and every GRAIL item.
- `claims()`: unpaid withdrawal queue, `cash`, claims bucket.
- `reopenStatus()`: each guard `acquireBatch` applies, with its numbers.
- `settleDue()` and `rotateDue()`: reason codes the keeper acts on (0 means none).
- Pool `maintenance()`: keeper refund bucket. Refunds stop at zero.

Reserve. `cash` holds `reserveBps` of NAV (launch 1,000, 10 percent) so withdrawals pay at once, replacement mints
run at settle before the capture's proceeds are harvested, and deposited Shapes can be held. Every point of reserve
is capital off the board. Once the keeper cadence and the withdrawal pattern are seen, lower it with
`setReserve(bps)`; the previous design ran at zero.

Keeper log, one line per transaction:

```
<time> settle(20) reason=1 status=0x1 gas=412345 refundWei=2100000000000000 https://evm.now/tx/<hash>?chainId=1
```

`refundWei` is read from the `Settled` or `Rotated` event. A `rotate` that leaves inventory
unchanged keeps `rotateDue()` nonzero, so the keeper waits one `rotateInterval` before the next
attempt. A `skipped: simulation reverts` line means the call would revert and no gas was spent.
With `SPONSOR_PRIZE`, `SHAPES` and `FEE_SPLIT` set, each pass also sends `withdrawFees` to Shapes and `tick` to the prize (docs/SPONSOR.md, Operations).

## Live launch

Replace `$POOL`, `$RPC`, `$FEE` and amounts. The signer flags are the same for every line:

```
SIGN="--account $KEYSTORE_ACCOUNT --password-file $KEYSTORE_PASSWORD_FILE"
```

1. Create the FWA pool. `$FEE` is the factory creation fee; the pool must hold it in the FWA token.
   The opening deadline starts here.
   `cast send --rpc-url $RPC $SIGN $POOL 'createFwaPool(uint256)' $FEE`
2. Deposit the opening cohort. Opening NAV is cash, so shares mint 1:1.
   `cast send --rpc-url $RPC $SIGN $POOL 'deposit()' --value $AMOUNT`
3. After `openingDeadlineAt`, call `open()` until `lifecycle()` returns 1 (Live). Each call lists at
   most 20 items and anyone may call it. The pool is Live once a call lists fewer than 20 items or
   `listedCount` is at least `minItems`. `settleDue()` then returns Deep and `settle` finishes the board up to
   `boardItems()`.
   `cast send --rpc-url $RPC $SIGN $POOL 'open()'`
4. Founder window premium. Right after the pool is Live, move 100 bps from the feed to the premium.
   The sum stays 700, so list prices and tickets are unchanged. `admission()` on Lens shows
   `depositsOpenAt`; revert the split in the same block or later.
   `cast send --rpc-url $RPC $SIGN $POOL 'setFeeSplit(uint16,uint16,uint16)' 300 100 300`
   At `depositsOpenAt`:
   `cast send --rpc-url $RPC $SIGN $POOL 'setFeeSplit(uint16,uint16,uint16)' 200 100 400`
5. Start the keeper once the pool is Live.
   `WALLET_MODE=keystore KEYSTORE_ACCOUNT=$KEYSTORE_ACCOUNT KEYSTORE_PASSWORD_FILE=$KEYSTORE_PASSWORD_FILE RPC_URL=$RPC POOL=$POOL INTERVAL=15 script/keeper.sh`
6. Refill the keeper bucket from Shapes mint fee revenue when the basefee is high.
   `cast send --rpc-url $RPC $SIGN $POOL 'fundMaintenance()' --value $AMOUNT`

## Pause and exit

Pause pulls and deposits (first flag pulls, second flag deposits). Settlement of issued pulls,
`settle` and `rotate` continue.

```
cast send --rpc-url $RPC $SIGN $POOL 'setPaused(bool,bool)' true true
cast send --rpc-url $RPC $SIGN $POOL 'setPaused(bool,bool)' false false
```

Exit. `$DEST` is the pool itself for retirement or a successor pool for migration.

```
cast send --rpc-url $RPC $SIGN $POOL 'startExit(address)' $DEST
cast send --rpc-url $RPC $SIGN $POOL 'exportStep(uint256)' 20   # anyone; repeat until lifecycle() is 3 (Exported)
cast send --rpc-url $RPC $SIGN $POOL 'payClaims()'              # anyone; pays queued claims in order from cash
cast send --rpc-url $RPC $SIGN $POOL 'withdraw(uint256)' $SHARES   # holders, retirement only
```

After a migration, each holder is minted successor shares with `migrateHolder(address)` on the
successor pool.
