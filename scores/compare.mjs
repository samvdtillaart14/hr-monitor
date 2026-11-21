#!/usr/bin/env node
// Vergelijk een nacht uit de app met Whoop:
//   node scores/compare.mjs <whoop_historie_….csv> <whoop-export-map> [whoop-calibration.json]
// Zoekt in de export de slaap met het dichtstbijzijnde ontwaakmoment en zet alles naast elkaar.
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import * as W from './whoop-scores.js';
import { parseCSV, readCycles, readSleeps } from './fit.js';
import { readRecording } from './analyze.mjs';

export function compareNight(samples, { cycles, sleeps }, cal = W.DEFAULT_CALIBRATION) {
  const n = W.analyzeNight(samples, cal);
  if (!n) return null;
  const wakeMs = n.wake * 1000;
  const ws = sleeps.reduce((a, b) => (Math.abs(b.wake - wakeMs) < Math.abs(a.wake - wakeMs) ? b : a));
  if (Math.abs(ws.wake - wakeMs) > 6 * 3600e3) return { n, whoop: null };
  const wc = cycles.reduce((a, b) => (Math.abs(b.wakeOnset - ws.wake) < Math.abs(a.wakeOnset - ws.wake) ? b : a));
  // eigen slaapprestatie: Whoop's slaapbehoefte (die hangt af van schuld uit eerdere nachten), eigen toereikendheid/efficiëntie/consistentie
  const prev = sleeps.filter((s) => s.wake < ws.wake - 3600e3).slice(-3).map((s) => ({ onset: s.onset / 1000, wake: s.wake / 1000 }));
  const tz = -new Date(ws.wake).getTimezoneOffset(); // alleen voor de klok; voor overlap maakt de offset niet uit zolang hij gelijk is
  const consistency = W.sleepConsistency([...prev, { onset: n.onset, wake: n.wake }], tz);
  const sufficiency = W.sleepSufficiency(n.asleepMin, ws.need);
  const perf = W.sleepPerformance({ asleepMin: n.asleepMin, needMin: ws.need, efficiency: n.efficiency, consistency }, cal);
  // geschiedenis voor de basislijn = Whoop's eigen waarden van de nachten ervoor
  const hist = cycles.filter((c) => c.wakeOnset < ws.wake - 3600e3 && c.hrv > 0);
  const ours = W.recovery({ hrv: n.hrv, rhr: n.rhr, resp: n.resp, skinTemp: n.skinTemp, sleepPerf: perf, sufficiency, efficiency: n.efficiency, consistency }, hist, cal);
  const modelOnWhoopInputs = W.recovery({ hrv: wc.hrv, rhr: wc.rhr, resp: wc.resp, skinTemp: wc.skinTemp, sleepPerf: wc.sleepPerf,
    sufficiency: ws.need > 0 ? Math.min(100, (100 * ws.asleep) / ws.need) : NaN, efficiency: ws.efficiency, consistency: ws.consistency }, hist, cal);
  const rows = [
    ['Inslapen', new Date(n.onset * 1000), new Date(ws.onset)],
    ['Wakker', new Date(n.wake * 1000), new Date(ws.wake)],
    ['In bed (min)', n.inBedMin, ws.inBed],
    ['Geslapen (min)', n.asleepMin, ws.asleep],
    ['Licht (min)', n.lightMin, ws.light],
    ['Diep (min)', n.deepMin, ws.deep],
    ['REM (min)', n.remMin, ws.rem],
    ['Wakker in bed (min)', n.awakeMin, ws.awake],
    ['Efficiëntie (%)', n.efficiency, ws.efficiency],
    ['Consistentie (%)', consistency, ws.consistency],
    ['Slaapprestatie (%)', perf, ws.perf],
    ['HRV (ms)', n.hrv, wc.hrv],
    ['Rust-HR (bpm)', n.rhr, wc.rhr],
    ['Ademfrequentie (/min)', n.resp, wc.resp],
    ['Huidtemp (°C)', n.skinTemp, wc.skinTemp],
    ['Recovery (%)', ours, wc.recovery],
    ['Recovery-model op Whoop-invoer', modelOnWhoopInputs, wc.recovery],
  ];
  return { n, whoop: { sleep: ws, cycle: wc }, rows };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [file, dir, calFile] = process.argv.slice(2);
  if (!file || !dir) { console.error('Gebruik: node scores/compare.mjs <opname.csv> <export-map> [whoop-calibration.json]'); process.exit(1); }
  const cal = calFile ? JSON.parse(readFileSync(calFile, 'utf8')) : W.DEFAULT_CALIBRATION;
  const rd = (f) => (existsSync(join(dir, f)) ? parseCSV(readFileSync(join(dir, f), 'utf8')) : []);
  const res = compareNight(readRecording(readFileSync(file, 'utf8')), { cycles: readCycles(rd('physiological_cycles.csv')), sleeps: readSleeps(rd('sleeps.csv')) }, cal);
  if (!res) { console.log('Geen slaap gevonden in de opname.'); process.exit(0); }
  if (!res.whoop) { console.log('Geen Whoop-slaap binnen 6 uur van ons ontwaakmoment; is de export van na deze nacht?'); process.exit(0); }
  const f = (v) => (v instanceof Date ? v.toLocaleString('nl-NL', { timeZone: 'Europe/Amsterdam' }) : Number.isFinite(v) ? (Math.abs(v) < 100 && v % 1 ? v.toFixed(1) : Math.round(v)) : '–');
  const d = (a, b) => (a instanceof Date ? `${Math.round((a - b) / 60000)} min` : Number.isFinite(a) && Number.isFinite(b) ? (a - b > 0 ? '+' : '') + (Math.abs(a - b) < 10 ? (a - b).toFixed(1) : Math.round(a - b)) : '');
  console.log('| | Eigen | Whoop | Verschil |\n|---|---|---|---|');
  for (const [k, a, b] of res.rows) console.log(`| ${k} | ${f(a)} | ${f(b)} | ${d(a, b)} |`);
}
