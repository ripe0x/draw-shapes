// Engine economics on top of the lab model.
//
// usage: node sim/engine.mjs [--quick] [--out docs/ECONOMIC_VALIDATION.data.md]
//
// The game itself is the unchanged `simulate` of sim/lab.html (the block between MODEL BEGIN and
// MODEL END): board, FWA pricing, settlement, margin split, keeper refunds, GRAIL mints, merges and
// decay. This file adds what EngineTreasury does once a day: book trading receipts, harvest pool NAV
// above the basis, refill coverage, boost the GRAIL fund, pay founders and the sponsor, and fund
// buybacks. Every rule mirrors src/engine/EngineTreasury.sol; the contract wins on any difference.
import { readFileSync, writeFileSync } from 'node:fs';

const html = readFileSync(new URL('./lab.html', import.meta.url), 'utf8');
const model = html.slice(html.indexOf('// MODEL BEGIN'), html.indexOf('// MODEL END'));
const { simulate, defaultParams } = new Function(`${model}; return { simulate, defaultParams };`)();

// Measured on the fork (test/fork/engine/EngineFork.t.sol, test_market_feeCaptureOnBuyAndSell):
// the treasury receives 4.5 percent of the ETH side of every swap after the sniper window.
const CAPTURE = 0.045;
// Measured on the fork (test/fork/engine/EngineGas.t.sol): a settle listing 12 items used 12.4M gas,
// about 1,000,000 gas per listed item (mint, pack, FWA listing). The lab's own default is 150,000.
const GAS_PER_ITEM = 1_000_000;
// A buyback pays the 5 percent skim and gets the 4.5 percent bounty back: 0.5 percent leaves.
const BUYBACK_LEAK = 0.005;

// Opening split of a round (script/EngineDeployer.sol `_treasuryConfig`): 6 ETH ordinary pool,
// 0.5 ETH maintenance, a reserve of up to 4 ETH that leaves at least the opening five (5.005 ETH)
// for the GRAIL, and the rest of the round in the GRAIL fund.
export function allocation(roundEth) {
  const poolTarget = 6, maint = 0.5;
  const reserveTarget = Math.min(4, roundEth - poolTarget - maint - 5.005);
  return { roundEth, poolTarget, maint, reserveTarget, grailSeed: roundEth - poolTarget - maint - reserveTarget };
}

export const LAUNCH_MIX = [50, 22, 13, 10, 4, 1];

export function engineDefaults() {
  return {
    capBps: 12000, tradingBps: 6500, earningsBps: 5000,
    ...allocation(20), maintFloor: 0.15, poolFloorBps: 8000, mix: LAUNCH_MIX,
    // 0.1 gwei is about ten times the base fee at the fork block (0.0096 gwei); stress rows go to 30.
    premiumBps: 300, mintFee: 0.001, gasPriceGwei: 0.1,
    drawsPerDay: 100, tradingEthPerDay: 5, days: 365,
    demand: null, trading: null, keeperOff: null, forceGrailDay: undefined,
    sponsor: null, // { value, price, capEth, shareBps, fromDay, reclaimDay }
  };
}

function quantile(xs, q) {
  const s = [...xs].sort((a, b) => a - b);
  if (!s.length) return NaN;
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil(q * s.length) - 1))];
}

export function runEngine(cfg, seed) {
  const P = defaultParams();
  P.openingEth = cfg.poolTarget; P.openingDepositors = 1;
  P.entryFloorBps = 0; P.entryCapBps = 0; P.navCapFloor = 1e12; P.founderWindowDays = 0;
  P.depositPerDay = 0; P.withdrawBpsPerDay = 0;
  P.ticketsPerDay = cfg.drawsPerDay; P.premiumBps = cfg.premiumBps; P.mintFee = cfg.mintFee;
  P.gasPriceGwei = cfg.gasPriceGwei; P.boardNavCap = cfg.poolTarget; P.gasPerItem = GAS_PER_ITEM;
  P.batchMin = 12;
  if (cfg.mix) P.rows.forEach((r, i) => { r.share = cfg.mix[i]; });
  if (cfg.mutateParams) cfg.mutateParams(P);

  const cap = cfg.roundEth * cfg.capBps / 1e4;
  const reserveTarget = cfg.reserveTarget ?? (cfg.roundEth - cfg.poolTarget - cfg.grailSeed - cfg.maint);
  const opening = cfg.roundEth - cfg.poolTarget - cfg.grailSeed - cfg.maint;
  const T = {
    reserve: Math.min(opening, reserveTarget), prize: Math.max(0, opening - reserveTarget), buyback: 0,
    basis: cfg.poolTarget, owed: 0,
    founders: 0, fromTrading: 0, fromEarnings: 0, trading: 0, earnings: 0, coverageIn: 0,
    sponsorPaid: 0, grailBoosted: 0, buybackSpent: 0, maintFunded: 0, poolRepaired: 0,
    day1x: -1, day12x: -1, minReserve: Infinity, minNavGap: 0,
  };
  const sp = cfg.sponsor ? { ...cfg.sponsor, listed: false, paid: 0, done: false } : null;

  function toCoverage(x) {
    const add = Math.min(x, Math.max(0, reserveTarget - T.reserve));
    T.reserve += add; T.coverageIn += add; return add;
  }
  function payFounders(x) {
    const p = Math.min(x, cap - T.founders);
    T.founders += p; return p;
  }
  function onDay(day, api) {
    // trading receipts
    const vol = cfg.trading ? cfg.trading(day) : cfg.tradingEthPerDay;
    let r = vol * CAPTURE;
    if (r > 0) {
      T.trading += r;
      r -= toCoverage(r);
      const f = payFounders(r * cfg.tradingBps / 1e4); T.fromTrading += f; r -= f;
      if (sp && sp.listed && !sp.done) {
        const s = Math.min(r * sp.shareBps / 1e4, sp.capEth - sp.paid);
        sp.paid += s; T.sponsorPaid += s; r -= s;
        if (sp.paid >= sp.capEth - 1e-12) sp.done = true;
      }
      T.prize += r;
    }
    const keeperUp = !(cfg.keeperOff && cfg.keeperOff(day));
    if (keeperUp) {
      // harvest earnings or returned principal, bounded by free cash
      const nav = api.nav();
      const free = Math.max(0, api.cash() - nav * P.reserveBps / 1e4);
      if (nav > T.basis + 0.001) {
        const amt = Math.min(nav - T.basis, free);
        if (amt >= 0.001) {
          api.take(amt); T.earnings += amt;
          const repay = Math.min(amt, T.owed); T.owed -= repay; T.reserve += repay;
          let rest = amt - repay; rest -= toCoverage(rest);
          const f = payFounders(rest * cfg.earningsBps / 1e4); T.fromEarnings += f;
          T.buyback += rest - f;
        }
      } else if (T.basis > cfg.poolTarget && nav > cfg.poolTarget) {
        const amt = Math.min(nav - cfg.poolTarget, free);
        if (amt > 0) { api.take(amt); T.basis -= amt; T.reserve += amt; }
      }
      // coverage from the reserve
      if (api.maint() < cfg.maintFloor) {
        const x = Math.min(T.reserve, cfg.maint - api.maint(), Math.max(0, 4 * cfg.maint - T.owed));
        T.reserve -= x; T.owed += x; T.maintFunded += x; api.addMaint(x);
      }
      const nav2 = api.nav();
      if (nav2 < cfg.poolTarget * cfg.poolFloorBps / 1e4) {
        const x = Math.min(T.reserve, cfg.poolTarget - nav2);
        T.reserve -= x; T.basis += x; T.poolRepaired += x; api.put(x);
      }
      // prize budget to the GRAIL fund, buyback fund to the market
      if (T.prize >= 0.01) { api.addToFund(T.prize); T.grailBoosted += T.prize; T.prize = 0; }
      if (T.buyback > 0) { T.buybackSpent += T.buyback * (1 - BUYBACK_LEAK); T.buyback = 0; }
    }
    // sponsor listing and reclaim
    if (sp) {
      if (!sp.listed && !sp.gone && day >= sp.fromDay) { api.addForeign(sp.value, sp.price); sp.listed = true; }
      if (sp.listed && !api.hasForeign()) { sp.listed = false; sp.gone = 'won'; sp.wonDay = day; }
      if (sp.listed && sp.reclaimDay !== undefined && day >= sp.reclaimDay && !sp.done) {
        api.removeForeign(); sp.listed = false; sp.gone = 'reclaimed';
      }
    }
    if (T.day1x < 0 && T.founders >= cfg.roundEth - 1e-9) T.day1x = day;
    if (T.day12x < 0 && T.founders >= cap - 1e-9) T.day12x = day;
    T.minReserve = Math.min(T.minReserve, T.reserve);
    T.minNavGap = Math.min(T.minNavGap, api.nav() - cfg.poolTarget);
  }

  const res = simulate(P, seed, cfg.days, [cfg.days], {
    onDay, initialFund: cfg.grailSeed, initialMaint: cfg.maint,
    ticketsAt: cfg.demand || undefined, keeperOff: cfg.keeperOff || undefined, forceGrailDay: cfg.forceGrailDay,
  });
  const A = res.check;
  const snap = res.snaps[cfg.days];
  return {
    founders: T.founders, foundersX: T.founders / cfg.roundEth, fromTrading: T.fromTrading, fromEarnings: T.fromEarnings,
    day1x: T.day1x, day12x: T.day12x, trading: T.trading, earnings: T.earnings,
    creatorMint: A.mintFees, grailBoosted: T.grailBoosted, buybackSpent: T.buybackSpent,
    sponsorPaid: T.sponsorPaid, sponsorOutcome: sp ? (sp.gone || (sp.done ? 'completed' : 'listed')) : '-',
    maintFunded: T.maintFunded, poolRepaired: T.poolRepaired, minReserve: T.minReserve, reserve: T.reserve,
    ticket: snap.ticketAvg, rtp: snap.expReturn, grailHits: res.events.filter(e => !e.foreign).length,
    grailPaid: res.events.filter(e => !e.foreign).reduce((a, e) => a + e.prize, 0),
    largestHit: res.events.filter(e => !e.foreign).reduce((a, e) => Math.max(a, e.prize), 0),
    keeperShort: snap.keeperShortfall ?? 0, nav: res.series.nav[res.series.nav.length - 1],
  };
}

export function distribution(cfg, seeds) {
  const runs = [];
  for (const s of seeds) runs.push(runEngine(cfg, s));
  const pick = k => runs.map(r => r[k]);
  const q = k => [quantile(pick(k), 0.1), quantile(pick(k), 0.5), quantile(pick(k), 0.9)];
  const reached = k => runs.filter(r => r[k] >= 0).length / runs.length;
  const medDay = k => { const xs = pick(k).filter(x => x >= 0); return xs.length ? quantile(xs, 0.5) : -1; };
  return { runs, q, reached, medDay };
}

// ------------------------------------------------------------------ report

const fmt = (x, d = 2) => (x === -1 || Number.isNaN(x)) ? '-' : x.toFixed(d);
const tri = a => `${fmt(a[0])} / ${fmt(a[1])} / ${fmt(a[2])}`;

function grid(title, rows, seeds, cols) {
  let out = `\n### ${title}\n\n| Scenario | ${cols.map(c => c[0]).join(' | ')} |\n|${'---|'.repeat(cols.length + 1)}\n`;
  for (const [label, cfg] of rows) {
    const D = distribution(cfg, seeds);
    out += `| ${label} | ${cols.map(c => c[1](D, cfg)).join(' | ')} |\n`;
    process.stderr.write('.');
  }
  return out;
}

const C = {
  founders: ['Founders paid, ETH (p10 / p50 / p90)', D => tri(D.q('founders'))],
  x: ['Multiple of capital (p50)', D => fmt(D.q('foundersX')[1])],
  d1: ['Days to 1.0x (share reaching; p50 day)', D => `${fmt(D.reached('day1x') * 100, 0)}% ; ${fmt(D.medDay('day1x'), 0)}`],
  d12: ['Days to cap (share; p50 day)', D => `${fmt(D.reached('day12x') * 100, 0)}% ; ${fmt(D.medDay('day12x'), 0)}`],
  tr: ['From trading (p50)', D => fmt(D.q('fromTrading')[1])],
  er: ['From earnings (p50)', D => fmt(D.q('fromEarnings')[1])],
  earn: ['Game earnings (p10 / p50 / p90)', D => tri(D.q('earnings'))],
  mint: ['Creator mint fees (p50)', D => fmt(D.q('creatorMint')[1])],
  boost: ['To GRAIL from trading (p50)', D => fmt(D.q('grailBoosted')[1])],
  bb: ['Buyback ETH (p10 / p50 / p90)', D => tri(D.q('buybackSpent'))],
  mf: ['Maintenance subsidy (p50 / p90)', D => `${fmt(D.q('maintFunded')[1])} / ${fmt(D.q('maintFunded')[2])}`],
  rep: ['Reserve spent on pool refill (p50 / p90)', D => `${fmt(D.q('poolRepaired')[1])} / ${fmt(D.q('poolRepaired')[2])}`],
  minRes: ['Lowest reserve (p10)', D => fmt(D.q('minReserve')[0])],
  ticket: ['Ticket (p50)', D => fmt(D.q('ticket')[1], 4)],
  rtp: ['Expected return (p50)', D => fmt(D.q('rtp')[1], 3)],
  hits: ['GRAIL wins (p10 / p50 / p90)', D => tri(D.q('grailHits')).replace(/\.00/g, '')],
  big: ['Largest win, ETH (p50)', D => fmt(D.q('largestHit')[1], 1)],
  sp: ['Sponsor paid (p50); outcomes', D => `${fmt(D.q('sponsorPaid')[1])}; ${summary(D.runs.map(r => r.sponsorOutcome))}`],
};
function summary(xs) { const m = {}; for (const x of xs) m[x] = (m[x] || 0) + 1; return Object.entries(m).map(([k, v]) => `${k} ${v}`).join(', '); }

function main() {
  const quick = process.argv.includes('--quick');
  const outIdx = process.argv.indexOf('--out');
  const out = outIdx > 0 ? process.argv[outIdx + 1] : null;
  const seeds = Array.from({ length: quick ? 4 : 12 }, (_, i) => i + 1);
  const base = engineDefaults();
  const t0 = Date.now();
  let md = `<!-- generated by node sim/engine.mjs; ${seeds.length} seeds per row, 365 days, p10 / p50 / p90 across seeds -->\n`;

  md += grid('Founder recovery: draws per day x trading ETH per day (20 ETH round, 1.2x cap = 24 ETH)',
    [10, 30, 100, 300, 750].flatMap(n => [0, 5, 25, 100].map(v => [`${n} draws, ${v} ETH trading`, { ...base, drawsPerDay: n, tradingEthPerDay: v }])),
    seeds, [C.founders, C.d1, C.d12, C.tr, C.er, C.earn, C.bb, C.mf, C.rep, C.minRes]);

  md += grid('Opening capital (100 draws, 5 ETH trading)',
    [15, 20, 25, 30, 40].map(e => [`${e} ETH (GRAIL ${allocation(e).grailSeed.toFixed(1)}, reserve ${allocation(e).reserveTarget.toFixed(1)})`, { ...base, ...allocation(e) }]),
    seeds, [C.founders, C.x, C.d1, C.earn, C.minRes, C.hits]);

  md += grid('Board depth: ordinary pool target (100 draws, 5 ETH trading)',
    [3.5, 6, 9, 14].map(p => [`${p} ETH pool`, { ...base, poolTarget: p }]),
    seeds, [C.ticket, C.rtp, C.earn, C.hits, C.big, C.founders]);

  md += grid('GRAIL opening funding (100 draws, 5 ETH trading)',
    [[5.005, 'opening five only (reserve 8.5)'], [9.5, '9.5 ETH (reserve 4, launch)']].map(([g, l]) => [l, { ...base, grailSeed: g, reserveTarget: 20 - 6 - 0.5 - g }]),
    seeds, [C.hits, C.big, C.ticket, C.rtp, C.founders]);

  md += grid('Price and mint configuration (100 draws, 5 ETH trading)',
    [[200, 0.001], [300, 0.001], [400, 0.001], [200, 0.002]].map(([pr, mf]) => [`premium ${pr} bps, mint fee ${mf}`, { ...base, premiumBps: pr, mintFee: mf }]),
    seeds, [C.ticket, C.rtp, C.earn, C.mint, C.founders, C.d1]);

  const MIXES = {
    'current 38/28/19/10/4/1': [38, 28, 19, 10, 4, 1],
    'more singles 50/22/13/10/4/1': [50, 22, 13, 10, 4, 1],
    'no 3-packs 50/30/0/14/5/1': [50, 30, 0, 14, 5, 1],
    'heavier top 30/25/20/16/7/2': [30, 25, 20, 16, 7, 2],
  };
  md += grid('Ordinary mix (100 draws, 5 ETH trading)',
    Object.entries(MIXES).map(([l, sh]) => [l, { ...base, mix: sh }]),
    seeds, [C.ticket, C.rtp, C.earn, C.mint, C.hits, C.founders]);

  md += grid('Founder terms (100 draws, 5 ETH trading)',
    [[11000, 6500, 5000], [12000, 6500, 5000], [13000, 6500, 5000], [12000, 5000, 5000], [12000, 8000, 5000], [12000, 6500, 2500], [12000, 6500, 7500], [12000, 10000, 10000]]
      .map(([c, t, e]) => [`cap ${c / 1e4}x, trading ${t / 100}%, earnings ${e / 100}%`, { ...base, capBps: c, tradingBps: t, earningsBps: e }]),
    seeds, [C.founders, C.d1, C.d12, C.boost, C.bb]);

  md += grid('Stress (base 100 draws, 5 ETH trading unless stated)', [
    ['launch 300/day, then 10/day from day 30', { ...base, drawsPerDay: 300, demand: d => (d < 30 ? 1 : 1 / 30) }],
    ['heavy draws, little trading: 750 draws, 0.5 ETH', { ...base, drawsPerDay: 750, tradingEthPerDay: 0.5 }],
    ['heavy trading, little play: 10 draws, 100 ETH', { ...base, drawsPerDay: 10, tradingEthPerDay: 100 }],
    ['trading stops after day 30', { ...base, trading: d => (d < 30 ? 25 : 0) }],
    ['no paid draws at all', { ...base, drawsPerDay: 0.0001 }],
    ['5 ETH GRAIL won on day 1', { ...base, forceGrailDay: 1 }],
    ['gas 1 gwei', { ...base, gasPriceGwei: 1 }],
    ['gas 5 gwei', { ...base, gasPriceGwei: 5 }],
    ['gas 5 gwei, owner raises maintenance to 400 bps', { ...base, gasPriceGwei: 5, mutateParams: P => { P.maintBps = 400; } }],
    ['gas 30 gwei', { ...base, gasPriceGwei: 30 }],
    ['keeper down 3 days in 10', { ...base, keeperOff: d => d % 10 < 3 }],
    ['keeper down days 30 to 60', { ...base, keeperOff: d => d >= 30 && d < 60 }],
    ['reduced refill: 4 hour batches, 5 gwei', { ...base, gasPriceGwei: 5, mutateParams: P => { P.batchMaxAge = 4 * 3600; } }],
  ], seeds, [C.founders, C.d1, C.earn, C.rep, C.minRes, C.hits]);

  md += grid('Sponsored Wrapped Cryptopunk (value 30 ETH, cap 36 ETH, half the post-founder trading share)', [
    ['no sponsor', { ...base }],
    ['listed at 30 ETH (parked style)', { ...base, sponsor: { value: 30, price: 30, capEth: 36, shareBps: 5000, fromDay: 1 } }],
    ['listed at 8 ETH', { ...base, sponsor: { value: 30, price: 8, capEth: 36, shareBps: 5000, fromDay: 1 } }],
    ['listed at 8 ETH, 300 draws, 25 ETH trading', { ...base, drawsPerDay: 300, tradingEthPerDay: 25, sponsor: { value: 30, price: 8, capEth: 36, shareBps: 5000, fromDay: 1 } }],
    ['listed at 8 ETH, reclaimed day 60', { ...base, sponsor: { value: 30, price: 8, capEth: 36, shareBps: 5000, fromDay: 1, reclaimDay: 60 } }],
  ], seeds, [C.sp, C.founders, C.ticket, C.rtp, C.hits]);

  // Comparison: the original depositor pool (lab defaults: 55 ETH opening cohort, deposits, withdrawals,
  // NAV-sized board) and a coin-only launch that opens once trading receipts have paid for the opening.
  md += `\n### Comparison with the depositor model and a coin-only launch (100 draws a day)\n\n`;
  md += `| Model | Capital at open | Days until the game opens | Ticket (p50) | Expected return (p50) | GRAIL wins (p50) | Who is paid from game earnings | Year-one figure (p50) |\n|---|---|---|---|---|---|---|---|\n`;
  {
    const deps = seeds.map(sd => { const P = defaultParams(); P.ticketsPerDay = 100; return simulate(P, sd, 365, [365]).snaps[365]; });
    const q = k => quantile(deps.map(s => s[k]), 0.5);
    md += `| Depositor pool (lab defaults) | 55 ETH from depositors | 0 | ${fmt(q('ticketAvg'), 4)} | ${fmt(q('expReturn'), 3)} | ${fmt(q('grailHits'), 0)} | depositors, indefinitely | depositor NAV per share annualised ${fmt(q('annualised') * 100, 1)}%, end NAV ${fmt(q('nav'), 1)} ETH |\n`;
    const E = distribution({ ...base, tradingEthPerDay: 5 }, seeds);
    md += `| Engine, 20 ETH round | 20 ETH from founders | 0 | ${fmt(E.q('ticket')[1], 4)} | ${fmt(E.q('rtp')[1], 3)} | ${fmt(E.q('grailHits')[1], 0)} | founders to 1.2x, then buybacks | founders paid ${fmt(E.q('founders')[1])} ETH, buybacks ${fmt(E.q('buybackSpent')[1])} ETH |\n`;
    const need = 6 + 0.5 + 5.005;
    for (const v of [5, 25]) {
      const wait = Math.ceil(need / (v * CAPTURE));
      const C1 = distribution({ ...base, roundEth: need, poolTarget: 6, maint: 0.5, grailSeed: 5.005, reserveTarget: 0, capBps: 10000, tradingBps: 0, earningsBps: 0, tradingEthPerDay: v, days: 365 - wait }, seeds);
      md += `| Coin-only launch, ${v} ETH trading a day | none | ${wait} | ${fmt(C1.q('ticket')[1], 4)} | ${fmt(C1.q('rtp')[1], 3)} | ${fmt(C1.q('grailHits')[1], 0)} | buybacks only | buybacks ${fmt(C1.q('buybackSpent')[1])} ETH in the ${365 - wait} days left |\n`;
    }
    md += `| Coin-only launch, no trading | none | never | - | - | - | - | the game never opens |\n`;
  }

  md += `\nRun time ${((Date.now() - t0) / 1000).toFixed(0)} s.\n`;
  if (out) writeFileSync(out, md); else console.log(md);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
