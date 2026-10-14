# Draw Shapes web

Next.js app for a local or Sepolia pool: `/` pull, `/deposit` deposit, withdraw and claims, `/protocol` board, GRAIL
tracks, buckets, parameters and the `settle`, `rotate` and `payClaims` buttons. Admin calls use `cast`.

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

## Run against Sepolia

```
NEXT_PUBLIC_CHAIN_ID=11155111 pnpm dev      # reads ../deployments/11155111.json
```

`NEXT_PUBLIC_DEPLOYMENT` takes a record path (relative to `web/`) or the record as JSON. Without it the app reads
`../deployments/<NEXT_PUBLIC_CHAIN_ID>.json` (default 31337). Optional: `NEXT_PUBLIC_RPC_URL` (primary RPC ahead of
the public list on Sepolia and mainnet) and `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` (adds WalletConnect wallets;
without it only browser wallets connect).

Pages read through the Lens in one multicall every 12 seconds. A pull reads the quote, `selectionSlippageBps` and
`inventoryVersion` again at send time.
