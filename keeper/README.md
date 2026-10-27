# Backup keeper

Runs the Draw Shapes keeper jobs (`FwaGame.sync`, `Treasury.distribute`, `Buyback.process`, `GrailFund.process`,
`GenesisFarm.retireUnearned`) only as a backup: when a job's work has waited longer than `BACKUP_AFTER_SECONDS`
(6 h) or the basefee is below `BACKUP_BASEFEE_GATE_GWEI` (1 gwei). Claims are not a keeper job. Every write is
simulated first. Tips come from KeeperFund like anyone else's.

Hosting needs: Node 22 (or the Dockerfile, built from the repository root: `docker build -f keeper/Dockerfile .`),
`MAINNET_RPC_URL`, and `KEEPER_PRIVATE_KEY` for a wallet holding a little ETH for gas. Nothing else. Never commit the
key; pass it as a runtime secret.

```
cd keeper && npm install && npm run check
MAINNET_RPC_URL=... KEEPER_PRIVATE_KEY=... DEPLOYMENT=../deployments/1.json npm start
```
