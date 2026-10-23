# Uniswap v4 hook opportunities for ENGINE

Date: 2026-10-23. Inputs: the deployed Artcoins v2 hook `0x2f7976bf73dE8e1D49D4c687404e527a75b0e8Cc`
(`ripe0x/artcoins` `contracts/artcoins/src/v2/hooks/ArtCoinsHookV2.sol`), its pool-extension interface
(`src/hooks/interfaces/IArtCoinsPoolExtension.sol`), the extension allowlist
`0xddbC9EE6A8E08b4afC208B9dD1f283506E669C11`, and the fork measurements in
`test/fork/engine/EngineFork.t.sol`.

## Recommendation

**Launch ENGINE on the standard Artcoins v2 infrastructure, unchanged, with no pool extension.** No
hook or extension idea below beats what the treasury already does with ordinary fee collection, and
every one of them adds per-swap gas, attack surface or an Artcoins owner dependency to the launch. The
one idea worth revisiting later is a swap-time buyback extension (idea 5), and only after the market
has real depth.

## What the deployed stack allows

| Fact | Source | Consequence |
| --- | --- | --- |
| One v4 pool has one hook address. ENGINE's pool uses the Artcoins v2 hook. | v4 `PoolKey.hooks`; `ArtCoinsHookV2.sol:167-173` | A second custom hook cannot be attached to the same pool. A different hook means a different pool and a split market. |
| The hook takes the skim on the ETH side and pushes the bounty leg to the treasury with a 2,300 gas stipend, escrowing on failure. | `ArtCoinsHookV2.sol:395-451` | The treasury cannot run logic when a fee arrives. It books receipts on its next call (`collectFees`). |
| A pool extension gets `afterSwap(key, params, delta, false, extData)` last in the swap, in a `call` capped at 2,000,000 gas, with failure and return data ignored, no ETH value, and only after the sniper window started and never for the locker. | `ArtCoinsHookV2.sol:105,506-523` | An extension can observe swaps and act inside the trader's open unlock, at the trader's gas cost. It cannot change fees, return deltas or receive the skim. |
| An extension is fixed per pool at launch (`PoolConfigV2.extension`) and must be enabled on the allowlist by the Artcoins owner or an admin first. | `ArtCoinsHookV2.sol:185-189`, allowlist `setPoolExtension` | Any extension is an Artcoins owner action before launch and is frozen for the coin's life. No v2 extension is enabled today. |
| Fee terms (LP fee, skim, bounty share, referral cap) are frozen at launch. | `IArtCoinsFactoryV2.sol:14-18` | Coverage-dependent fee routing inside the hook is impossible; routing must live in the treasury. |

## Ideas evaluated

### 1. Per-swap prize funding through an `afterSwap` extension

- **Behaviour:** each swap would move a slice of value straight into the GRAIL fund.
- **Benefit over Artcoins as is:** none. The extension receives no ETH, so it cannot fund anything; the
  bounty leg already reaches the treasury on every swap, and `collectFees` plus `boostGrail` move it
  to the GRAIL fund in two permissionless calls. "Transparency" is already on chain: `FeeDelivered`
  per swap and `TradingReceipts` / `GrailBoosted` per collection.
- **Cost:** an extension call on every swap (cold calls into the pool and the treasury, tens of
  thousands of gas), a pool call from inside a v4 unlock, and a launch-time allowlisting by the
  Artcoins owner.
- **Verdict:** rejected.

### 2. Allocation at fee receipt instead of by keeper

- **Behaviour:** split receipts the moment they arrive, so no keeper call is needed.
- **Reality:** the hook pushes with a 2,300 gas stipend (`call` with gas 0), which cannot run an
  allocation. A heavy `receive` would make every push fail into the escrow, and the escrow `claim`
  would then run the allocation with the claimer's gas, which is the keeper call again under another
  name. An extension cannot help because it never sees the ETH.
- **What we did instead:** `receive` is empty so pushes land; `collectFees` is permissionless and also
  runs at the start of every `buyback`. Late collection loses nothing: unbooked ETH is still the
  treasury's, and the 65/35 split applies whenever it is booked.
- **Verdict:** rejected; the keeper call is cheap and cannot be front-run for profit.

### 3. Coverage-dependent fee routing

- **Behaviour:** route more of the fee to reserves when coverage is weak, more to prizes when strong.
- **Reality:** the hook's split is frozen at launch, and routing by on-chain state inside a swap would
  let a trader choose the routing by ordering transactions. The treasury already applies the rule
  deterministically to every booked receipt: reserve to target first, then founders, then the sponsor,
  then prizes (`EngineTreasury._allocateTrading`). That is the same policy without a hook, and the
  owner cannot alter it.
- **Verdict:** rejected; implemented in the treasury instead.

### 4. Trading-linked prize entries (a draw ticket or raffle weight per swap)

- **Behaviour:** traders above some size get a free draw or extra odds.
- **Problem:** with a 5 percent skim (4.5 percent to the treasury), any entry worth more than about
  5 percent of the swap plus gas pays for itself through wash trading: buy and sell repeatedly, collect
  entries. That manufactures volume, drains prizes to wash traders, and makes draw odds depend on
  market behaviour, which the owner ruled out. Any entry worth less than that is decorative.
- **Verdict:** rejected on economics, not on engineering.

### 5. Swap-time buyback inside the trader's unlock

- **Behaviour:** an extension holding the buyback fund buys and burns a little ENGINE inside sells, the
  way the v1 `ArtCoinsAutoBurnPoolExtension` did for LAYER. Buys would land exactly when sell pressure
  appears, with no separate keeper transaction to sandwich.
- **Benefit:** real but small. The treasury's standalone buyback is already bounded at 0.5 ETH per call
  and 2 percent price impact, and a 5 percent fee each way makes sandwiching it unprofitable unless the
  attacker's round trip earns more than about 10 percent.
- **Costs and risks:** the extension must hold treasury ETH (a second custody point), run swaps inside
  someone else's unlock within 2,000,000 gas, and survive adversarial ordering (a seller can size sells
  to trigger buys at the worst price). It needs Artcoins owner allowlisting before launch and is frozen
  for the coin's life, so a bug cannot be fixed. Every sell pays its gas.
- **Verdict:** not for the first release. Revisit only after the market shows depth and sell pressure
  that the standalone buyback measurably handles worse.

### 6. Dynamic LP fee tied to game state

- **Reality:** the Artcoins hook sets the LP fee once at initialization; the pool's dynamic-fee flag
  is the hook's, and the hook exposes no update path. Changing it means a different hook and a split
  market.
- **Verdict:** impossible on the chosen factory.

## Gas, MEV and failure notes for the standard path

- Swaps pay the hook's skim logic and two stipend pushes; the treasury adds nothing to a swap.
- Treasury buybacks pay the same 5 percent skim; the 4.5 percent bounty comes back to the treasury and
  is returned to the buyback fund (`Buyback(ethSpent, rebate, coinBurned)`), so a buyback's real cost
  is the 0.5 percent protocol leg plus price impact.
- If fee collection or swapping fails (escrow rotated, PoolManager paused, coin market drained), draws
  keep settling: the pool never calls the treasury or the market (`test_gameSettlesWithoutAnyTrading`).

## Measured on the fork

`test_market_feeCaptureOnBuyAndSell` at block 26,240,000, real factory launch, after the sniper window:

| Swap | ETH volume | Treasury receipt | Share |
| --- | --- | --- | --- |
| Buy 1 ETH of ENGINE | 1.000000 ETH | 0.045000 ETH | 4.50 % |
| Sell half the coins | 0.622868 ETH (0.591724 ETH out after the skim) | 0.028029 ETH | 4.50 % |

The remaining 0.5 percent of volume is the Artcoins protocol leg (10 percent of the skim,
`minProtocolSkimShareBps` 1,000, paid to `ProtocolFeeControllerV2` `0x183De82db1b7AAb798328AB1d7AE181ff39460c2`).
No LP fee is configured, so there are no coin-denominated rewards.
