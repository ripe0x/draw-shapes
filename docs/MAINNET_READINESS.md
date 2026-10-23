# Mainnet readiness

Date: 2026-10-23. Branch `feat/coin-funded-engine`. **Nothing has been broadcast to mainnet.** "Ready"
below means the implementation, tests, simulation and launch scripts are complete and exercised against
real mainnet contracts on forks. It does not mean the legal, security or economic assumptions are proven.

## Verdict

The engine is implementation-complete and fork-verified end to end. **It is not cleared for a mainnet
launch** until the owner closes the items under "Blocking before the round opens". None of them needs
more code from this branch, except fixes an external audit may find.

## Tested commits

| Commit | Content |
| --- | --- |
| `971fbdc` | Engine core: foreign-listing port, FoundingRound, EngineTreasury, PrizeSponsorship, `boardNavCap`, first fork tests |
| `ec8fc1a` | Security review fixes (FWA pool created in `activate`, reserve cap, no self-filled bids), step deploy script, simulator results, decision and hook docs |
| `ecfe589` | EIP-7825 batch sizes, premium 300, measured gas model, SPEC/DEPLOY/RUNBOOK/SECURITY/ECONOMIC docs |
| see PR head | Frontend, readiness record |

## Test commands and results

Fork RPC: `https://mainnet.gateway.tenderly.co`. Results at commit `ecfe589` unless noted.

| Command | Fork block | Result |
| --- | --- | --- |
| `forge test --match-path "test/fork/engine/*.t.sol"` | 26,240,000 (`ENGINE_FORK_BLOCK`) | 26 passed, 0 failed (EngineFork 13, EngineSponsor 9, EngineInvariants 3, EngineGas 1) |
| `FORK_BLOCK=26170000 forge test --match-path "test/unit/*.t.sol"` | none / 26,170,000 | 103 passed (includes FoundingRound 9, fuzzed cap) |
| `FORK_BLOCK=26170000 forge test --match-path "test/fork/*.t.sol"` | 26,170,000 | 424 tests: 419 passed, 5 failed on the old 20/25 batch-size assertions; those 5 updated and re-run: PoolBoard 19/19, PoolReplace 41/41, PoolDepth 9/9 |
| `FORK_BLOCK=26170000 forge test --match-path "test/invariant/*.t.sol" --match-test test_handlerReachesEveryPath` | 26,170,000 | 1 passed |
| `FORK_BLOCK=26170000 forge test --match-path test/scenario/PlayMonth.t.sol --match-test "test_play100PerDay\|test_playPullPastHourEnd"` | 26,170,000 | 2 passed |
| `forge build --sizes --skip test --skip script` | | every deployed contract under 24,576 B: Pool 23,778, PoolAdmin 24,158, PoolListing 24,400, Lens 17,848, EngineTreasury 24,359, PrizeSponsorship 5,326, FoundingRound 3,015 |
| `node sim/engine.mjs --out sim/engine-results.md` | | 72 scenarios x 12 seeds x 365 days, tables in `docs/ECONOMIC_VALIDATION.md` |
| `script/engine-local.sh start` | 26,240,000 (anvil, Fusaka rules) | every launch step broadcast as real transactions: see "Deployment rehearsal" |
| `cd web && pnpm typecheck && pnpm build` | | see PR description |

Not run: the full invariant campaign (`test/invariant/*` beyond the reach test) and the other PlayMonth
scenarios; these are frozen-candidate checks (`CANDIDATE_RUN=1`) for the release milestone.

## Verified external addresses and settings

Live reads at block **26,253,574** through `https://mainnet.gateway.tenderly.co`. Addresses from
`deployments/dependencies.json` (this repo) and `deployments/1.v2.json` (`ripe0x/artcoins`).

| Dependency | Address | Live settings |
| --- | --- | --- |
| Shapes | `0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0` | `mintFee` 0.001 ETH, `unit` 0.01 ETH, `feeRecipient` `0xD4ba7cA95f3983514DDa317C4428CDb8F59c7e72`, `admin` `0xCB43078C32423F5348Cab5885911C3B5faE217F9` |
| FWA V2 factory | `0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c` | owner `0x019817aD02a31B990433542097bE29D97613E8Cb`; `betaAccess` false; `inventoryChangeCooldown` 0; `poolCreationFee` 50,000 FWA; `edgeBps` 500; `maxAcquisitionsPerTx` 5; `maxOutstandingRequestsPerPool` 10; `selectionSlippageBps` 1,000; creation, purchases and VRF enabled |
| FWA implementation / VRF service / token | `0xEaa4d032908A9734a2c7939c0D211c35ad51eb31` / `0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2` / `0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845` | factory `implementation()` and `vrfService()` match |
| Artcoins v2 factory | `0x9b17bf6f97F5429368E11028BC637479b4667f7b` | owner `0xCB43…217F9`; **`deprecated` true (owner-only launches)**; `deployFee` 0.069 ETH; `minProtocolSkimShareBps` 1,000; `defaultProtocolFeeBps` 2,000; `protocolRecipient` `0x183De82db1b7AAb798328AB1d7AE181ff39460c2`; `tokenDeployer` `0xB2f0086E6EE82f059AD1736dD265a783cE50f473` |
| Artcoins hook | `0x2f7976bf73dE8e1D49D4c687404e527a75b0e8Cc` | enabled; escrow `0x32845df52436a737C9623Af1d461A1c9999BBc1e`; extension allowlist `0xddbC9EE6A8E08b4afC208B9dD1f283506E669C11` |
| Artcoins locker | `0x1e2456861B864B96FFe6b34066b12FBD7EEb23fC` | enabled; escrow as above; `keeperRewardBps` 0 |
| Artcoins MEV skim module | `0xFbb55b4C13b8517C000e2686efB12F0FAAFc9072` | enabled |
| Uniswap v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` | code present (about 24 KB) |
| Wrapped Cryptopunks | `0xb7F7F6C52F2e2fdb1963Eab30438024864c313F6` | `name` "Wrapped Cryptopunks", `totalSupply` 371 |
| Base fee | | 0.061 gwei at the read |

Manifest caveat: the Artcoins manifest records `repoCommit` `fbe07c76` with bytecode marked verified; that
commit is not in the local clone. The engine pins the ABI it uses (`src/interfaces/IArtcoins.sol`) and the
fork tests exercise the deployed bytecode, which is what matters for integration.

## Deployment rehearsal

`script/engine-local.sh start` on anvil forked at 26,240,000 (chain id 31337, Fusaka rules including the
EIP-7825 transaction gas cap) broadcast, as real transactions through `script/engine.sh` and
`DeployEngine`: deploy (Draw Packs, modules, pool, Lens, treasury, admin handover), round, four founders
contributing 20 ETH, coin launch by the impersonated Artcoins factory owner, recipient lock, bind, the
FWA creation fee from a real holder, activate, open (175 items), sponsorship with a real Wrapped
Cryptopunk staked. Readback results are in the rehearsal log; the record is
`deployments/engine-31337.json` (not committed).

The first rehearsal is what found the EIP-7825 problem (D27): its 25-item `open` and `settle`
transactions never mined.

## Blocking before the round opens

1. **Legal review of the founding round.** Contributors fund ETH for a capped share of protocol cash
   flows; this may be a security or an investment contract. Counsel must approve the terms, eligibility
   and the disclosures on `/fund` (D25).
2. **External audit** of `src/engine/*` and the pool changes (foreign listings, `boardNavCap`, batch
   sizes). The review here is internal (`docs/SECURITY_REVIEW.md`).
3. **Owner decisions:** round size (20 ETH recommended, D2), founder terms (1.2x, 65 / 50, D4 and D5),
   premium 300 (D10), mix (D9), coin terms (D12, immutable after launch).
4. **Artcoins protocol leg.** 0.5 percent of trading volume goes to the Artcoins protocol fee controller
   (86.67 percent of it to `0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4`). If that benefits the creator it
   conflicts with "the creator earns only the Shape mint fee" (D25).
5. **Signers:** the treasury `OWNER` (a multisig is recommended; it can tune the game and start a
   wind-down), `DEPLOYER`, `TOKEN_ADMIN`, and the Artcoins factory owner for the coin launch. Fill
   `script/env/engine.mainnet.env` and create Foundry keystores.

## Operator actions at launch (in order; `docs/DEPLOY.md`)

1. Dry-run every step (`script/engine.sh mainnet <step>` without `BROADCAST`).
2. `deploy` (DEPLOYER). Draw Packs is deployed here unless `DRAW_PACKS` is set.
3. `round` (OWNER). Publish the funding page.
4. After funding: `coin` (Artcoins factory owner signs `deployTokenAsOwner`), `lock` (TOKEN_ADMIN),
   `bind` (OWNER).
5. Acquire 50,000 FWA tokens and send them to the pool **immediately before** `activate` (they cannot be
   swept out if the launch is abandoned).
6. `activate` (OWNER), wait 24 hours, `open` (anyone).
7. Optional: `sponsor` (OWNER) once a sponsor has signed terms; the sponsor stakes from `/sponsor`.
8. Start `script/keeper.sh` with the mainnet record; host the web app with
   `NEXT_PUBLIC_DEPLOYMENT=../deployments/engine-1.json NEXT_PUBLIC_CHAIN_ID=1`.
9. Verify every page against live values.

## Known limitations and coverage gaps

- **VRF:** fork tests deliver words by impersonating the Chainlink coordinator through the real FWA VRF
  service; live Chainlink fulfillment is not reproduced. The VRF fee is priced at `tx.gasprice`
  (1,500,000 x 1.3 x gas price, `serviceFlatWei` 0); fork-test quotes read it as 0 because their calls
  carry no gas price. Players pay it on top of the FWA fee.
- **Sepolia rehearsal** (SPEC section 16 gate) is replaced by the mainnet-fork broadcast rehearsal: Artcoins
  v2 and Wrapped Cryptopunks are not on Sepolia. The owner should confirm this gate change.
- **Coin market:** buyback price effects and liquidity depth are not modeled; the pool launches with
  zero ETH depth (coin-only positions).
- **Demand:** draws and trading are model inputs. Nothing shows that prizes raise play or that burns
  raise trading.
- **Gas:** at more than about 0.5 gwei keeper refunds exceed the maintenance share; the subsidy cap
  protects founders but keepers then need a higher `maintenanceBps` (D7, D28).
- **Trusted parties outside this repo:** Artcoins owner (factory, hook, escrow pointers), FWA owner
  (factory settings), Shapes admin (mint fee up to 0.01 ETH).
- **Owner trust inside:** tuning, collectible bids up to 60 ETH, sponsorship terms, wind-down timing
  (`docs/SECURITY_REVIEW.md`, residual trust).
