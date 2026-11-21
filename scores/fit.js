// Kalibratie: fit de parameters van whoop-scores.js op een Whoop-data-export.
import { DEFAULT_CALIBRATION, recoveryDesign, RECOVERY_WEIGHTS, loadFromZoneMinutes, strainFromLoad, percentile } from './whoop-scores.js';

// ---------- CSV ----------
export function parseCSV(text) {
  const rows = []; let row = [], cell = '', q = false;
  text = text.replace(/^﻿/, '');
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (q) { if (ch === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += ch; continue; }
    if (ch === '"') q = true;
    else if (ch === ',') { row.push(cell); cell = ''; }
    else if (ch === '\n' || ch === '\r') { if (ch === '\r' && text[i + 1] === '\n') i++; row.push(cell); rows.push(row); row = []; cell = ''; }
    else cell += ch;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  const head = rows.shift().map((h) => h.trim());
  return rows.filter((r) => r.some((c) => c.trim())).map((r) => Object.fromEntries(head.map((h, i) => [h, r[i]])));
}
/** Kolom op (deel van) de naam, hoofdletterongevoelig; geeft getal of NaN. */
export function col(row, ...names) {
  const keys = Object.keys(row);
  for (const n of names) {
    const k = keys.find((x) => x.toLowerCase().startsWith(n.toLowerCase()));
    if (k !== undefined && row[k] !== undefined && String(row[k]).trim() !== '') {
      const v = Number(String(row[k]).replace('%', '').trim());
      if (Number.isFinite(v)) return v;
    }
  }
  return NaN;
}
const str = (row, name) => { const k = Object.keys(row).find((x) => x.toLowerCase().startsWith(name.toLowerCase())); return k ? row[k] : ''; };
/** Tijd uit de export (lokale tijd) als ms; met de kolom 'Cycle timezone' (bv. UTC+01:00) wordt het echte UTC. */
const time = (s, tz = '') => {
  if (!s) return NaN;
  const m = /([+-]\d\d:\d\d)/.exec(tz || '');
  return Date.parse(s.replace(' ', 'T') + (m ? m[1] : 'Z'));
};
const tzOf = (r) => str(r, 'Cycle timezone');
const mean = (a) => a.reduce((s, v) => s + v, 0) / a.length;
const sd = (a) => { const m = mean(a); return Math.sqrt(a.reduce((s, v) => s + (v - m) ** 2, 0) / Math.max(1, a.length - 1)); };
const rmse = (p, y) => Math.sqrt(mean(p.map((v, i) => (v - y[i]) ** 2)));

// ---------- lineaire algebra ----------
/** Ridge-kleinste-kwadraten: minimaliseer |Xw − y|² + λ|w₁..|² (intercept niet bestraft). */
export function ridge(X, y, lambda = 1e-3) {
  const p = X[0].length, A = Array.from({ length: p }, () => new Array(p + 1).fill(0));
  for (let r = 0; r < X.length; r++) for (let i = 0; i < p; i++) { for (let j = 0; j < p; j++) A[i][j] += X[r][i] * X[r][j]; A[i][p] += X[r][i] * y[r]; }
  for (let i = 1; i < p; i++) A[i][i] += lambda * X.length;
  for (let c = 0; c < p; c++) {
    let piv = c; for (let r = c + 1; r < p; r++) if (Math.abs(A[r][c]) > Math.abs(A[piv][c])) piv = r;
    [A[c], A[piv]] = [A[piv], A[c]];
    if (Math.abs(A[c][c]) < 1e-12) A[c][c] = 1e-12;
    for (let r = 0; r < p; r++) if (r !== c) { const f = A[r][c] / A[c][c]; for (let k = c; k <= p; k++) A[r][k] -= f * A[c][k]; }
  }
  return A.map((r, i) => r[p] / r[i]);
}
/** Nelder–Mead-minimalisatie. */
export function nelderMead(f, x0, { step = 0.5, iters = 2000, tol = 1e-10 } = {}) {
  const n = x0.length;
  let S = [x0.slice()]; for (let i = 0; i < n; i++) { const x = x0.slice(); x[i] += step; S.push(x); }
  let F = S.map(f);
  for (let it = 0; it < iters; it++) {
    const o = F.map((v, i) => i).sort((a, b) => F[a] - F[b]); S = o.map((i) => S[i]); F = o.map((i) => F[i]);
    if (Math.abs(F[n] - F[0]) < tol) break;
    const c = new Array(n).fill(0); for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) c[j] += S[i][j] / n;
    const at = (t) => c.map((v, j) => v + t * (S[n][j] - v));
    const xr = at(-1), fr = f(xr);
    if (fr < F[0]) { const xe = at(-2), fe = f(xe); [S[n], F[n]] = fe < fr ? [xe, fe] : [xr, fr]; }
    else if (fr < F[n - 1]) { S[n] = xr; F[n] = fr; }
    else { const xc = at(0.5), fc = f(xc); if (fc < F[n]) { S[n] = xc; F[n] = fc; } else { for (let i = 1; i <= n; i++) { S[i] = S[i].map((v, j) => S[0][j] + 0.5 * (v - S[0][j])); F[i] = f(S[i]); } } }
  }
  const i = F.indexOf(Math.min(...F)); return { x: S[i], f: F[i] };
}

// ---------- exportbestanden inlezen ----------
export function readCycles(rows) {
  return rows.map((r) => ({
    start: time(str(r, 'Cycle start time'), tzOf(r)), recovery: col(r, 'Recovery score'),
    rhr: col(r, 'Resting heart rate'), hrv: col(r, 'Heart rate variability'), skinTemp: col(r, 'Skin temp'),
    spo2: col(r, 'Blood oxygen'), dayStrain: col(r, 'Day Strain'), maxHr: col(r, 'Max HR'),
    resp: col(r, 'Respiratory rate'), sleepPerf: col(r, 'Sleep performance'),
    asleep: col(r, 'Asleep duration'), need: col(r, 'Sleep need'), debt: col(r, 'Sleep debt'),
    efficiency: col(r, 'Sleep efficiency'), consistency: col(r, 'Sleep consistency'),
    deep: col(r, 'Deep (SWS) duration', 'Deep'), rem: col(r, 'REM duration'), wakeOnset: time(str(r, 'Wake onset'), tzOf(r)),
  })).filter((c) => Number.isFinite(c.start)).sort((a, b) => a.start - b.start);
}
export function readWorkouts(rows) {
  return rows.map((r) => {
    const zones = [1, 2, 3, 4, 5].map((z) => col(r, `HR Zone ${z}`));
    return { strain: col(r, 'Activity Strain'), duration: col(r, 'Duration'), maxHr: col(r, 'Max HR'), zones };
  }).filter((w) => Number.isFinite(w.strain) && w.duration > 0 && w.zones.every(Number.isFinite));
}
export function readSleeps(rows) {
  return rows.map((r) => ({
    cycleStart: time(str(r, 'Cycle start time'), tzOf(r)), onset: time(str(r, 'Sleep onset'), tzOf(r)), wake: time(str(r, 'Wake onset'), tzOf(r)), inBed: col(r, 'In bed duration'), resp: col(r, 'Respiratory rate'), nap: /true|yes|1/i.test(str(r, 'Nap')),
    asleep: col(r, 'Asleep duration'), need: col(r, 'Sleep need'), debt: col(r, 'Sleep debt'), perf: col(r, 'Sleep performance'),
    efficiency: col(r, 'Sleep efficiency'), consistency: col(r, 'Sleep consistency'),
    light: col(r, 'Light sleep'), deep: col(r, 'Deep (SWS)', 'Deep'), rem: col(r, 'REM duration'), awake: col(r, 'Awake duration'),
  })).filter((s) => !s.nap && s.asleep > 0).sort((a, b) => a.cycleStart - b.cycleStart); // export staat nieuwste eerst
}

// ---------- fits ----------
const logit = (p) => Math.log(p / (1 - p));
function recoveryRows(cycles, W, minN, refs) {
  const out = [];
  const valid = cycles.filter((c) => c.hrv > 0 && Number.isFinite(c.rhr));
  for (let i = 0; i < valid.length; i++) {
    const c = valid[i];
    if (!Number.isFinite(c.recovery)) continue;
    const h = valid.slice(Math.max(0, i - W), i);
    if (h.length < minN) continue;
    out.push({ x: recoveryDesign(withSufficiency(c), baselineOf(h), refs), y: c.recovery });
  }
  return out;
}
const withSufficiency = (c) => ({ ...c, sufficiency: c.need > 0 && c.asleep > 0 ? Math.min(100, (100 * c.asleep) / c.need) : NaN });
export function baselineOf(h) {
  const v = (f) => h.map(f).filter(Number.isFinite);
  const ms = (a, dm, ds) => (a.length >= 2 ? [mean(a), sd(a)] : [dm, ds]);
  const D = DEFAULT_CALIBRATION.recovery.baseline;
  const [lnHrvMean, lnHrvSd] = ms(v((c) => (c.hrv > 0 ? Math.log(c.hrv) : NaN)), D.lnHrvMean, D.lnHrvSd);
  const [rhrMean, rhrSd] = ms(v((c) => c.rhr), D.rhrMean, D.rhrSd);
  const [respMean, respSd] = ms(v((c) => c.resp), D.respMean, D.respSd);
  const [tempMean, tempSd] = ms(v((c) => c.skinTemp), D.tempMean, D.tempSd);
  return { lnHrvMean, lnHrvSd, rhrMean, rhrSd, respMean, respSd, tempMean, tempSd };
}
const fitRows = (rows) => ridge(rows.map((r) => r.x), rows.map((r) => logit(Math.min(0.99, Math.max(0.01, r.y / 100)))));
const predictRec = (w, x) => Math.min(99, Math.max(1, Math.round(100 / (1 + Math.exp(-x.reduce((s, v, i) => s + w[i] * v, 0))))));

export function fitRecovery(cycles) {
  // referenties = gemiddelden, zodat ontbrekende slaapdelen neutraal uitvallen
  const avg = (f, d) => { const v = cycles.map(f).filter(Number.isFinite); return v.length ? mean(v) / 100 : d; };
  const D = DEFAULT_CALIBRATION.recovery;
  const refs = {
    sleepRef: avg((c) => c.sleepPerf, D.sleepRef), sufRef: avg((c) => withSufficiency(c).sufficiency, D.sufRef),
    effRef: avg((c) => c.efficiency, D.effRef), consRef: avg((c) => c.consistency, D.consRef),
  };
  let best = null;
  for (const W of [7, 14, 21, 30, 60]) {
    const rows = recoveryRows(cycles, W, Math.min(W, 5), refs);
    if (rows.length < 12) continue;
    // venster kiezen op 5-voudige kruisvalidatie (om-en-om verdeeld)
    const p = [], y = [];
    for (let k = 0; k < 5; k++) {
      const w = fitRows(rows.filter((_, i) => i % 5 !== k));
      rows.forEach((r, i) => { if (i % 5 === k) { p.push(predictRec(w, r.x)); y.push(r.y); } });
    }
    const err = rmse(p, y);
    if (!best || err < best.err) best = { W, err };
  }
  if (!best) return null;
  const rows = recoveryRows(cycles, best.W, Math.min(best.W, 5), refs);
  const w = fitRows(rows);
  // chronologische holdout: fit op de eerste 80 %, test op de laatste 20 %
  const cut = Math.floor(rows.length * 0.8), wh = fitRows(rows.slice(0, cut)), test = rows.slice(cut);
  const holdout = rows.length >= 40 ? rmse(test.map((r) => predictRec(wh, r.x)), test.map((r) => r.y)) : null;
  const valid = cycles.filter((c) => c.hrv > 0 && Number.isFinite(c.rhr));
  return {
    params: {
      windowDays: best.W, ...Object.fromEntries(RECOVERY_WEIGHTS.map((k, i) => [k, w[i]])), ...refs,
      baseline: baselineOf(valid.slice(-best.W)), minHistory: 4,
    },
    stats: { n: rows.length, rmseInSample: rmse(rows.map((r) => predictRec(w, r.x)), rows.map((r) => r.y)), rmseCv: best.err, rmseHoldout: holdout },
  };
}

export function fitStrain(workouts) {
  if (workouts.length < 5) return null;
  const zm = workouts.map((w) => { const z = w.zones.map((p) => (p / 100) * w.duration); return [Math.max(0, w.duration - z.reduce((s, v) => s + v, 0)), ...z]; });
  const y = workouts.map((w) => w.strain);
  const fitW0 = workouts.length >= 15;
  const mk = (p) => ({ strain: { a: Math.exp(p[0]), b: Math.exp(p[1]), zoneWeights: [fitW0 ? Math.exp(p[2]) : 0.2, 1, 2, 3, 4, 5].map((v, i) => (i === 0 ? v : Math.pow(i, fitW0 ? Math.exp(p[3]) : 1))), zone0Floor: DEFAULT_CALIBRATION.strain.zone0Floor } });
  const pred = (c) => zm.map((z) => strainFromLoad(loadFromZoneMinutes(z, c), c));
  const loss = (p) => { const c = mk(p); return mean(pred(c).map((v, i) => (v - y[i]) ** 2)); };
  let best = null;
  for (const a0 of [2, 4, 8]) for (const b0 of [3, 10, 50]) {
    const r = nelderMead(loss, [Math.log(a0), Math.log(b0), Math.log(0.3), 0], { iters: 5000 });
    if (!best || r.f < best.f) best = r;
  }
  const c = mk(best.x);
  return { params: { ...c.strain }, stats: { n: workouts.length, rmse: Math.sqrt(best.f) } };
}

export function fitSleep(sleeps, cycles) {
  if (sleeps.length < 5) return null;
  const strainBefore = (t) => { let s = NaN; for (const c of cycles) { if (c.start < t - 3600e3) s = c.dayStrain; else break; } return s; };
  const ref = DEFAULT_CALIBRATION.sleep.strainRef;
  const rows = sleeps.filter((s) => s.need > 0 && Number.isFinite(s.debt)).map((s) => ({ s, st: strainBefore(s.cycleStart) }));
  let need = null;
  if (rows.length >= 5) {
    const X = rows.map((r) => [1, r.s.debt, Math.max(0, (Number.isFinite(r.st) ? r.st : ref) - ref)]);
    const w = ridge(X, rows.map((r) => r.s.need), 1e-6);
    need = { needBaseMin: w[0], needPerDebtMin: w[1], needPerStrainMin: w[2], strainRef: ref, rmse: rmse(X.map((x) => w[0] + w[1] * x[1] + w[2] * x[2]), rows.map((r) => r.s.need)) };
  }
  // slaapprestatie = c0 + c1·toereikendheid + c2·efficiëntie + c3·consistentie
  const pr = sleeps.filter((s) => s.need > 0 && [s.perf, s.efficiency, s.consistency].every(Number.isFinite));
  let perf = null;
  if (pr.length >= 8) {
    const X = pr.map((s) => [1, Math.min(100, (100 * s.asleep) / s.need), s.efficiency, s.consistency]);
    const w = ridge(X, pr.map((s) => s.perf), 1e-6);
    perf = { perfIntercept: w[0], perfSufficiency: w[1], perfEfficiency: w[2], perfConsistency: w[3], rmse: rmse(X.map((x) => Math.min(100, Math.max(0, w[0] + w[1] * x[1] + w[2] * x[2] + w[3] * x[3]))), pr.map((s) => s.perf)) };
  }
  // slaapschuld: rasterzoeken op schuld(t) = min(cap, a·schuld(t−1) + b·tekort(t−1))
  let debt = null;
  const dr = sleeps.filter((s) => Number.isFinite(s.debt) && s.need > 0);
  if (dr.length >= 8) {
    const cap = Math.max(...dr.map((s) => s.debt));
    for (let a = 0; a <= 1.0001; a += 0.05) for (let b = 0; b <= 1.0001; b += 0.05) {
      const e = dr.slice(1).map((s, i) => Math.min(cap, Math.max(0, a * dr[i].debt + b * (dr[i].need - dr[i].asleep))) - s.debt);
      const r = Math.sqrt(mean(e.map((v) => v * v)));
      if (!debt || r < debt.rmse) debt = { debtCarry: a, debtFromDeficit: b, debtCapMin: cap, rmse: r };
    }
  }
  const recent = sleeps.slice(-30).filter((s) => s.asleep > 0 && Number.isFinite(s.deep) && Number.isFinite(s.rem));
  const perfErr = sleeps.filter((s) => s.need > 0 && Number.isFinite(s.perf)).map((s) => Math.min(100, (100 * s.asleep) / s.need) - s.perf);
  return {
    params: {
      ...(need ? { needBaseMin: need.needBaseMin, needPerDebtMin: need.needPerDebtMin, needPerStrainMin: need.needPerStrainMin, strainRef: ref } : {}),
      ...(perf ? { perfIntercept: perf.perfIntercept, perfSufficiency: perf.perfSufficiency, perfEfficiency: perf.perfEfficiency, perfConsistency: perf.perfConsistency } : {}),
      ...(debt ? { debtCarry: debt.debtCarry, debtFromDeficit: debt.debtFromDeficit, debtCapMin: debt.debtCapMin } : {}),
      ...(recent.length ? { deepFrac: mean(recent.map((s) => s.deep / s.asleep)), remFrac: mean(recent.map((s) => s.rem / s.asleep)) } : {}),
    },
    stats: { n: rows.length, needRmse: need?.rmse ?? null, debtRmse: debt?.rmse ?? null, sufficiencyOnlyMeanAbsErr: perfErr.length ? mean(perfErr.map(Math.abs)) : null, perfRmse: perf?.rmse ?? null },
  };
}

/** Lineaire correctie whoop ≈ a + b·eigen per meetwaarde, uit gekoppelde nachten. */
export function fitCorrections(own, cycles) {
  const out = {};
  for (const [key, wk] of [['hrv', 'hrv'], ['rhr', 'rhr'], ['resp', 'resp'], ['skinTemp', 'skinTemp']]) {
    const pairs = [];
    for (const o of own) {
      const c = cycles.find((c) => Number.isFinite(c.wakeOnset) && Math.abs(c.wakeOnset - o.wake) < 3 * 3600e3);
      if (c && Number.isFinite(c[wk]) && Number.isFinite(o[key])) pairs.push([o[key], c[wk]]);
    }
    if (pairs.length >= 5) { const w = ridge(pairs.map((p) => [1, p[0]]), pairs.map((p) => p[1]), 1e-6); out[key] = [w[0], w[1]]; }
    else if (pairs.length >= 1) out[key] = [mean(pairs.map((p) => p[1] - p[0])), 1]; // alleen offset
  }
  return out;
}

/** Complete kalibratie uit de CSV-teksten van de export. */
export function calibrate({ cycles: cT, workouts: wT, sleeps: sT, own: oT } = {}) {
  const cal = structuredClone(DEFAULT_CALIBRATION), report = {};
  const cycles = cT ? readCycles(parseCSV(cT)) : [];
  const workouts = wT ? readWorkouts(parseCSV(wT)) : [];
  const sleeps = sT ? readSleeps(parseCSV(sT)) : [];
  const maxes = [...cycles.map((c) => c.maxHr), ...workouts.map((w) => w.maxHr)].filter(Number.isFinite);
  if (maxes.length) cal.profile.maxHr = Math.max(...maxes);
  const rhrs = cycles.slice(-30).map((c) => c.rhr).filter(Number.isFinite);
  if (rhrs.length) cal.profile.restingHr = percentile(rhrs, 0.5);
  const rec = fitRecovery(cycles); if (rec) { cal.recovery = rec.params; report.recovery = rec.stats; }
  const st = fitStrain(workouts); if (st) { cal.strain = st.params; report.strain = st.stats; }
  const sl = fitSleep(sleeps, cycles); if (sl) { Object.assign(cal.sleep, sl.params); report.sleep = sl.stats; }
  if (oT) {
    const own = parseCSV(oT).map((r) => ({ wake: time(str(r, 'wake')), hrv: col(r, 'hrv'), rhr: col(r, 'rhr'), resp: col(r, 'resp'), skinTemp: col(r, 'skinTemp', 'skin') }));
    Object.assign(cal.corrections, fitCorrections(own, cycles)); report.corrections = cal.corrections;
  }
  report.counts = { cycles: cycles.length, workouts: workouts.length, sleeps: sleeps.length };
  return { calibration: cal, report };
}
