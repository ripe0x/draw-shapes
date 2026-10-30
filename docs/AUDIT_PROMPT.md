# Audit prompt: Draw Shapes + ENGINE

Audit for high-impact ways an adversary could take assets, acquire authority, corrupt entitlements, or force
economically harmful state.

## Target and scope

- **Repository:** `ripe0x/draw-shapes`, branch `claude/relaxed-goodall-mmbzpd` (PR #9).
- **Commit:** pin `5494c336f05506c0a29b8bfc7b71cea934b41087`, or record the exact commit you audit.
- **Not deployed.** The system has no mainnet deployment, so "deployed code" for the system itself means the source at
  the pinned commit, compiled exactly as the deploy script compiles it. It is deployed only by `script/deploy.sh` →
  `script/Deploy.s.sol` → `script/DeploySystem.sol`.
- **Onchain evidence applies to the live mainnet dependencies.** Establish their deployed runtime, verified source and
  proxy status yourself. Their addresses are listed in `deployments/dependencies.json` and `script/env/mainnet.env`:
  - Shapes `0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0`
  - Shape Packs `0xf21514B090Da7dF4390803497d6ae673801E5cA7`
  - FWA V2 factory `0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c`
  - FWA clone implementation `0xeaa4d032908a9734a2c7939c0d211c35ad51eb31`
  - FWA VRF service `0xa4adfc35db18326efb3b5d9bf66a8103ec2d5ee2`
  - Uniswap v4 PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`
  - the FWA token and its v4 pool, read from the factory

  The vendored FWA sources under `external/` are a claim to check against the onchain runtime, not evidence.
- **In scope:** everything under `src/` (PoolOwner, FwaGame, PrizeVault, Converter, GenesisFarm, EngineToken,
  EngineHook, ProtocolLiquidity, EngineBuyer, Buyback, KeeperFund, policies, Lens). Also in scope:
  - `script/DeploySystem.sol` and `script/LaunchConfig.sol`: wiring, launch values, the postflight checks and anything a
    deployer could leave behind;
  - how the system interacts with the dependencies above.

  The site (`site/`) and keeper (`keeper/`) are in scope only where they choose parameters that reach the contracts
  (for example `minOut`, slippage, a batch size).
- **Intended behaviour:** you may read `docs/SPEC.md`, `docs/RUNBOOK.md`, `docs/DEPLOY.md`, NatSpec, and the
  `docs/BUILD_PROMPT.md` brief, but only as statements of intended rights, to judge against the code. They are claims,
  not evidence.
- **Do not read:**
  - `docs/SECURITY.md`, `docs/FINAL_REPORT.md`, `docs/IMPLEMENTOR_DECISIONS.md`, `docs/OWNER_QUESTIONS.md`,
    `docs/ECONOMICS.md` or `sim/results/`. These are outputs of earlier agent sessions and include their own risk
    conclusions.
  - Prior audits, incident reports or exploit write-ups about FWA, Shapes or this system.

## Directions

This is a fresh discovery run. Do not read prior audits, incident reports, exploit descriptions, previous agent outputs,
or files produced by earlier audit sessions. Work from deployed code and primary onchain evidence. Use
https://mainnet.gateway.tenderly.co for every Ethereum mainnet RPC call and Foundry fork. Do not broadcast transactions.

First pin a block number and hash. Establish the deployed runtime bytecode, verified source, exact compiler settings,
source-to-runtime match, proxy status, and dependency relationships. Disclose every mismatch or uncertainty.

- **For the dependencies:** compare onchain runtime against the verified source and against the vendored copies in
  `external/`.
- **For the system:**
  - Record the compiler settings from `foundry.toml` (Solidity 0.8.28, legacy codegen, no `via_ir`, optimizer runs)
    and confirm every contract is under 24,576 bytes.
  - Confirm that the contracts `DeploySystem` deploys are the ones you compiled and that the wiring matches the
    postflight.
  - Note where behaviour depends on values read from dependencies at deploy time, for example
    `maxAcquisitionsPerTx` and `MIN_PACK_VALUE`.

The existing fork suites pin block 26,279,000. If you pin a different block, check that the dependency state the tests
rely on still holds.

Before judging code checks, describe the system's purpose and the rights of the protocol, users, and interacting
contracts. Inventory assets it holds or can move, approvals and caller authority it may possess, and outcomes that must
never occur. At minimum, cover:

- **Assets:** ETH in PrizeVault, FwaGame, PoolOwner, KeeperFund, Buyback and the PoolManager; Shapes and Shape Packs
  held by PoolOwner or escrowed at FWA; ENGINE in the farm, ProtocolLiquidity and the pool; the FWA creation-fee
  tokens; the v4 position.
- **Authority:**
  - the timelock and every `onlyGovernance` setter;
  - each contract's one-shot `wire` and the `deployer` power it clears;
  - PoolOwner as FWA pool owner and purchase operator, and its Shapes and Packs approvals to the pool;
  - the hook's fee routing and swap gate;
  - EngineBuyer's registered callers;
  - the farm's ledgers and bonus payers;
  - KeeperFund's payers;
  - the Buyback's profit sources;
  - the vault's active game.
- **Entitlements:**
  - player prizes and FWA refunds;
  - genesis weight, epoch pots and claims, which never expire;
  - conversion eligibility, once per listing;
  - the conversion bonus;
  - keeper tips and credited tips;
  - the vault's capital and its keeper top-up limit;
  - realised profit, which is the only thing that may reach the Buyback.
- **Outcomes that must never occur:**
  - a holder sends value to a destination outside its fixed set;
  - capital or trading fees are counted as profit;
  - booked revenue exceeds what FWA paid;
  - the purchase gate admits a purchase that leaves the board below its floor;
  - the ENGINE price returns above the start tick;
  - an epoch pot changes after finalisation;
  - a prize is converted twice;
  - an unregistered address buys through EngineBuyer during genesis;
  - retirement is blocked permanently;
  - the deploy wallet retains any power.

Compile the pinned source. Use Slither or an equivalent analyzer to enumerate entry points, external calls, state writes,
and call relationships. Reconcile the output manually with the source and ABI, including dynamic calls and callbacks.
Map sequences across functions and transactions. For each consequential path, identify attacker-controlled inputs,
identities, counterparties, prior state, ordering, and return or callback behavior.

Callbacks and dynamic calls that need manual reconciliation include:

- FWA calling `PoolOwner.canPurchase` with a 100,000-gas stipend;
- FWA VRF fulfilment, settlement order and delivery;
- ERC-721 transfers and `onERC721Received`, including delivery failure and `recoverRefundedNFT`;
- Shape Packs `createPackTo`, `redeemTo` and `defaultMakeup`;
- Shapes `mintTo` and `burn`;
- the v4 `unlockCallback` paths in EngineBuyer, ProtocolLiquidity and FwaFeeBuyer;
- the hook's `beforeSwap` and `afterSwap` deltas and its per-block price record;
- every try/catch in `FwaGame.sync`, `_advance` and the retirement steps;
- ETH pushes with gas stipends in KeeperFund;
- `receive` classification in PrizeVault.

Challenge each check as a claim: can execution pass it while violating an intended right? Search across distinct assets
and identities, boundary values, hostile counterparties, nested calls, and material economic states. Execute the
strongest counterexamples in Foundry against the pinned code or fork. Each cited test must show it reached the relevant
path and checks and must assert the harmed asset or right. Use fuzzing where the input or state space warrants it;
inspect its actual output. A reverted attempt excludes only its tested setup and sequence.

Use the existing fork harness (`test/fork/ForkBase.sol`, which deploys through the real `DeploySystem`) with
`MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co`, `--threads 2`, one Forge process at a time. The invariant
handler in `test/invariant/` is a starting point, not a bound on what to try.

Maintain a working path ledger. Give every consequential path one of these dispositions: demonstrated violation;
supported exclusion within an explicit bounded model; attempted with exact search limits; or open. For each open path,
record the next decisive check and whether it is feasible now.

**CRITICAL STOP RULE:** Do not end the turn because a report exists, tests pass, a structural gate fails, or one tool is
rate limited. Treat gate failures and open paths as a work queue. Continue every feasible consequential check, using
another permitted method when one method fails. Before sending a final answer, inspect the ledger: if any consequential
path has a feasible next check, perform it. Preserve progress through context compaction. End with a bounded report only
when no meaningful next check is feasible with the available access and budget. If external access or user input is
genuinely required, state the exact blocker, continue independent work, and ask one specific blocking question.

Keep the ledger in a file under your scratch directory and update it as you go, so it survives compaction. Do not write
it into the repository.

## Report

Report confirmed findings with executable reproduction, prerequisites, impact, and exact affected runtime revision.
Separately report unresolved paths, integrations, tool failures, and the limits of every negative conclusion. Do not
claim the contract is safe, the audit exhaustive, or a failed gate passed.

The "affected runtime revision" for this system is the pinned commit plus the compiler settings, because nothing is
deployed. For a dependency it is its address and runtime code hash at the pinned block. For each finding, state:

- which actor needs which prior state;
- whether governance, a keeper, a player, an FWA owner action or a dependency's behaviour is required;
- whether the deploy script or postflight would have prevented it.
