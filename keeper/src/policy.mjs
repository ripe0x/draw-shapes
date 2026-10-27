// When the backup keeper acts (BUILD_PROMPT 4.6): only when the work has waited longer than BACKUP_AFTER_SECONDS,
// or when the basefee is below BACKUP_BASEFEE_GATE. Never otherwise: bots are welcome to do the work first.

/**
 * @param {object} p
 * @param {bigint} p.ageSeconds seconds since the job last ran (its work has waited at most this long)
 * @param {bigint} p.basefeeWei current block basefee
 * @param {bigint} p.backupAfterSeconds
 * @param {bigint} p.basefeeGateWei
 */
export function shouldAct({ ageSeconds, basefeeWei, backupAfterSeconds, basefeeGateWei }) {
  return ageSeconds > backupAfterSeconds || basefeeWei < basefeeGateWei;
}

/** The jobs with work available, in the order the keeper runs them. A buyback whose price check fails this block
 *  (someone moved the price since the block opened) is left for a later block. */
export function jobs(work) {
  const out = [];
  if (work.syncable > 0n || work.unlistedRows > 0n || work.admissionChange) out.push({ name: "sync", age: work.syncAge });
  if (work.buybackReady && work.buybackPriceOk) out.push({ name: "buyback", age: null });
  if (work.finalizable.length > 0) out.push({ name: "finalize", age: null, args: [work.finalizable] });
  if (work.bonusRetireReady) out.push({ name: "retireBonus", age: null });
  return out;
}
