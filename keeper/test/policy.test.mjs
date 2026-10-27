import { test } from "node:test";
import assert from "node:assert/strict";
import { shouldAct, jobs } from "../src/policy.mjs";

const gate = 1_000_000_000n;
const after = 21_600n;

test("acts only after six hours or below the basefee gate", () => {
  assert.equal(shouldAct({ ageSeconds: 100n, basefeeWei: 5n * gate, backupAfterSeconds: after, basefeeGateWei: gate }), false);
  assert.equal(shouldAct({ ageSeconds: 21_601n, basefeeWei: 5n * gate, backupAfterSeconds: after, basefeeGateWei: gate }), true);
  assert.equal(shouldAct({ ageSeconds: 100n, basefeeWei: gate - 1n, backupAfterSeconds: after, basefeeGateWei: gate }), true);
});

const idle = { syncable: 0n, unlistedRows: 0n, syncAge: 0n, admissionChange: false, buybackReady: false,
  buybackSlice: 0n, buybackPriceOk: true, finalizable: [], bonusRetireReady: false, keeperFundAvailable: 0n };

test("lists only jobs with work", () => {
  assert.deepEqual(jobs(idle), []);
  const w = { ...idle, buybackReady: true, buybackSlice: 1n, finalizable: [3n, 4n] };
  assert.deepEqual(jobs(w).map((j) => j.name), ["buyback", "finalize"]);
  assert.deepEqual(jobs(w)[1].args, [[3n, 4n]]);
  assert.deepEqual(jobs({ ...idle, admissionChange: true }).map((j) => j.name), ["sync"]);
});

test("leaves a buyback whose price moved this block", () => {
  assert.deepEqual(jobs({ ...idle, buybackReady: true, buybackSlice: 1n, buybackPriceOk: false }), []);
});
