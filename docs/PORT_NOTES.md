# Port notes

Files carried from `shapes-on-fwa-v2` and what each still needs.

- `src/lib/PricingLib.sol`: imports `Histogram` and `Skim` from the old `PoolStore.sol`. Replace
  with the mix-table types from SPEC section 9 and drop the skim branch.
- `test/unit/PricingLib.t.sol`: follows the library.
- `test/fork/ForkBase.sol`: imports the old controller interface and `Skim`. Keep the FWA
  factory-owner prank setup, the pinned block and the Shapes handles; remove the rest.
- `src/interfaces/IFWAClone.sol`, `IFWACloneFactory.sol`: unchanged.
- `script/deploy.sh`, `script/env/*.env`: wrapper pattern and values-only env files. The deploy
  script it calls is rewritten for `Pool.sol`.

## Draw Packs

`lib/draw-packs` is the Draw Packs fork (local submodule until it has a remote). Fork tests deploy
it in `setUp` with `new ShapePacks(shapes, renderer, admin, "Draw Packs", "DRAW", 2)` from
`draw-packs/ShapePacks.sol` and `draw-packs/ShapePackRenderer.sol`. Mainnet Shape Packs
`0xf215…` keeps a three-unit minimum and is unsuitable for 0.02 rows.
