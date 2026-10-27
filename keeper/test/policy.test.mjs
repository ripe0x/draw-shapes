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

test("lists only jobs with work", () => {
  const w = { syncable: 0n, unlistedRows: 0n, syncAge: 0n, unallocated: 5n, distributeAge: 9n, buybackReady: true,
    buybackSlice: 1n, grailOwed: 0n, retireUnearnedReady: false, keeperFundAvailable: 0n };
  assert.deepEqual(jobs(w).map((j) => j.name), ["distribute", "buyback"]);
});
