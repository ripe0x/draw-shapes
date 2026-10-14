# Draw Shapes web

Next.js app for a local or Sepolia pool. Admin calls use `cast`.

| Route | Content |
| --- | --- |
| `/` | Live board summary, carousel of listed items, pull card, what a pull can draw, both GRAIL tracks. |
| `/pull` | Pull card with batch size 1 to 5, price breakdown, pay with Shapes, the wallet's pulls with their reveal. |
| `/deposit` | Deposit with the entry contribution preview, position, withdraw, claims queue and `payClaims`. |
| `/protocol` | Live state, board and odds, GRAIL tracks, buckets and NAV, upkeep with `settle`, `rotate` and `payClaims`, parameters. |

Art is each token's on-chain `tokenURI` image (Shapes and Draw Packs). The carousel, the deposit card fan and the draw
reel read every active FWA listing: the first read walks back from `nextListingId` until it has `activeListingCount`
listings, then each minute reads the new ids and rechecks the known active ones.

## Install and generate the ABI

```
cd web && pnpm install
forge build              # repo root, writes ../out
pnpm abi                 # writes app/lib/abi/{pool,lens,external}.ts from IPool, Lens, IFWAClone, IShapes
```

The generated files are committed, so `pnpm build` works without forge.

## Run against anvil

```
anvil --fork-url https://ethereum-rpc.publicnode.com --port 8545 --chain-id 31337
RPC_URL=http://127.0.0.1:8545 script/deploy.sh anvil      # repo root, writes deployments/31337-8545.json
NEXT_PUBLIC_DEPLOYMENT=../deployments/31337-8545.json pnpm dev
```

`script/local.sh start` does the same and also opens the pool. For another port set `NEXT_PUBLIC_ANVIL_RPC`
(default `http://127.0.0.1:8545`) and point `NEXT_PUBLIC_DEPLOYMENT` at that port's record.

On chain 31337 the wallet menu offers "Use anvil test wallet": a wagmi mock connector that sends from anvil account 2
through the anvil RPC, which signs for its default accounts. `script/local.sh start` funds that account.

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
