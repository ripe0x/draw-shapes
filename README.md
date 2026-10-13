# Draw Shapes

A pooled prize vault on Shapes and one FWA V2 custom pool. Specification: `docs/SPEC.md`.

```
src/            Pool.sol, Lens.sol, interfaces
test/unit       mock based unit tests
test/fork       pinned mainnet fork suite (real Shapes, Draw Packs, FWA V2)
script/         Deploy.s.sol, deploy.sh, env/<env>.env
deployments/    dependencies.json, <chainId>.json records
docs/           SPEC.md, V1_PROMISES.md, external/ dependency dossiers
external/       vendored FWA V2 sources, read only
```
