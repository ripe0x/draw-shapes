# Draw Shapes web

Next.js app for a local or Sepolia pool. Admin calls use `cast`.

| Route | Content |
| --- | --- |
| `/` | Live board summary, carousel of listed items, headline prizes, pull card, what a pull can draw, both GRAIL tracks. |
| `/pull` | Headline prizes, pull card with batch size 1 to 5, price breakdown (FWA fee, VRF fee, gas extra), pay with Shapes, FWA refund credit, the wallet's pulls with their reveal. |
| `/fund` | FoundingRound: target, committed, chain-time countdowns, contribute/refund before release; entitlement and claim after release. Replaces `/deposit`, which redirects here. |
| `/treasury` | ENGINE coin and market terms, treasury totals and buckets, pool NAV vs basis, GRAIL, founders outstanding, collectible bid, status, and permissionless keeper calls. |
| `/sponsor` | The single sponsored-prize deal (terms, state, odds, payments) with sponsor stake/claim/reclaim, or "no sponsorship is open". |
| `/protocol` | Live state, board and odds, GRAIL tracks, buckets and NAV, upkeep with `settle`, `rotate` and `payClaims`, parameters, link to `/treasury`. |

Art is each token's on-chain `tokenURI` image (Shapes and Draw Packs). The carousel, the deposit card fan and the draw
reel read every active FWA listing: the first read walks back from `nextListingId` until it has `activeListingCount`
listings, then each minute reads the new ids and rechecks the known active ones.

## Install and generate the ABI

```
cd web && pnpm install
forge build              # repo root, writes ../out
pnpm abi                 # writes app/lib/abi/{pool,lens,treasury,round,sponsorship,external}.ts from IPool, Lens, EngineTreasury, FoundingRound, PrizeSponsorship, IFWAClone, IShapes
```

The generated files are committed, so `pnpm build` works without forge.

## Run against anvil

```
script/engine-local.sh start      # repo root: anvil mainnet fork on 8546, full engine launch, writes deployments/engine-31337.json
NEXT_PUBLIC_DEPLOYMENT=../deployments/engine-31337.json NEXT_PUBLIC_ANVIL_RPC=http://127.0.0.1:8546 pnpm dev --port 3002
```

The engine record carries `pool`, `lens`, `treasury`, `round`, `coin`, `sponsorship`, `fwaPool` and the other
deployed addresses; a zero address means that contract is not deployed yet. `script/engine-local.sh play 20` adds
draws.

On chain 31337 the wallet menu offers "Use anvil test wallet": a wagmi mock connector that sends from anvil account 2
through the anvil RPC, which signs for its default accounts. `script/engine-local.sh start` funds that account (a founder in the rehearsal).

After any anvil restart, reset the wallet's account nonce because the chain state reset (MetaMask: Settings, Advanced, Clear activity tab data; Rabby: clear pending).

## Run against Sepolia

```
NEXT_PUBLIC_CHAIN_ID=11155111 pnpm dev      # reads ../deployments/11155111.json
```

`NEXT_PUBLIC_DEPLOYMENT` takes a record path (relative to `web/`) or the record as JSON. Without it the app reads
`../deployments/<NEXT_PUBLIC_CHAIN_ID>.json` (default 31337). Optional: `NEXT_PUBLIC_RPC_URL` (primary RPC ahead of
the public list on Sepolia and mainnet) and `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` (adds WalletConnect wallets;
without it only browser wallets connect).

Pages read through the Lens (and the `IPool` bucket getters Lens does not return) in one multicall every 12 seconds. A pull reads the quote, `selectionSlippageBps` and
`inventoryVersion` again at send time.
