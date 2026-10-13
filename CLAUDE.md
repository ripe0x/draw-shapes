# Draw Shapes: working rules

Build input is `docs/SPEC.md`. Owner decisions are in `docs/V1_PROMISES.md`. The previous
implementation lives in `../shapes-on-fwa-v2` as read-only reference; port named files by path,
never grep it for design.

## Testing

1. A change runs only the tests that cover it: `forge test --match-path <touched test file>`.
   `forge build --sizes` only when bytecode changed. No test covers the change: add one.
2. Full suites run in CI on the PR.
3. Workers verify what they typed and report the files touched and the command run.
4. The director picks one gate per batch from the union of touched files.
5. Commit when the targeted gate is green and the change is coherent. Push only when the owner
   says so.

## Workers

- Open every worker prompt with: you are a hands-on implementer, not a coordinator; do the work
  yourself; never spawn sub-agents.
- Sonnet for decided designs. Name the model in the packet.
- One worker per repo at a time for Solidity; one forge process per worktree.

## Code

- Plain technical comments: what it is, what it does, once. No metaphor, no narration.
- One word per concept, as named in `docs/SPEC.md`.
- Never write a private key or secret into any file.
