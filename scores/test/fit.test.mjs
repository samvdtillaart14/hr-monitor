import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as W from '../whoop-scores.js';
import { parseCSV, calibrate, nelderMead, ridge } from '../fit.js';
import { rng } from './synth.js';

const near = (a, b, tol, msg) => assert.ok(Math.abs(a - b) <= tol, `${msg ?? ''} ${a} ≉ ${b} (±${tol})`);
const g = (r) => Math.sqrt(-2 * Math.log(r() + 1e-12)) * Math.cos(2 * Math.PI * r());
const iso = (ms) => new Date(ms).toISOString().replace('T', ' ').slice(0, 19);

test('CSV met aanhalingstekens, komma’s en BOM', () => {
  const rows = parseCSV('﻿a,"b, c",d\n1,"x ""y""",3\r\n');
  assert.deepEqual(rows, [{ a: '1', 'b, c': 'x "y"', d: '3' }]);
});

test('ridge en Nelder–Mead vinden bekende oplossingen', () => {
  const X = [[1, 0], [1, 1], [1, 2], [1, 3]], w = ridge(X, [1, 3, 5, 7], 0);
  near(w[0], 1, 1e-9); near(w[1], 2, 1e-9);
  const r = nelderMead((p) => (p[0] - 3) ** 2 + (p[1] + 1) ** 2, [0, 0]);
  near(r.x[0], 3, 1e-4); near(r.x[1], -1, 1e-4);
});

/** Maakt een nep-export die met bekende parameters is gegenereerd, en controleert dat calibrate ze terugvindt. */
function fakeExport() {
  const r = rng(42), truth = structuredClone(W.DEFAULT_CALIBRATION);
  Object.assign(truth.recovery, { windowDays: 30, intercept: 0.3, wHrv: 1.4, wRhr: -0.6, wResp: -0.3, wSleep: 2.0, wTemp: -0.2 });
  Object.assign(truth.strain, { a: 3.5, b: 10, zoneWeights: [0.3, 1, 2, 3, 4, 5] });
  const cyc = ['Cycle start time,Cycle end time,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),Blood oxygen %,Day Strain,Max HR (bpm),Respiratory rate (rpm),Sleep performance %,Wake onset'];
  const slp = ['Cycle start time,Sleep onset,Wake onset,Sleep performance %,Asleep duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),Awake duration (min),Sleep need (min),Sleep debt (min),Nap'];
  const hist = []; let prevStrain = 10;
  const day0 = Date.UTC(2026, 0, 1, 23);
  for (let d = 0; d < 150; d++) {
    const start = day0 + d * 86400e3;
    const n = { hrv: Math.exp(Math.log(65) + 0.2 * g(r)), rhr: 54 + 2.5 * g(r), resp: 15 + 0.6 * g(r), skinTemp: 33.4 + 0.25 * g(r), sleepPerf: Math.min(100, 85 + 10 * g(r)) };
    const rec = hist.length >= 5 ? W.recovery(n, hist, truth) : '';
    const strain = Math.max(4, 11 + 3 * g(r));
    const debt = Math.max(0, 40 + 25 * g(r)), need = 470 + 0.4 * debt + 4 * Math.max(0, prevStrain - 10);
    const asleep = need * n.sleepPerf / 100;
    cyc.push([iso(start), iso(start + 86400e3), rec, n.rhr.toFixed(0), n.hrv.toFixed(0), n.skinTemp.toFixed(2), 96, strain.toFixed(1), 180 + Math.round(10 * r()), n.resp.toFixed(1), Math.round(n.sleepPerf), iso(start + 8 * 3600e3)].join(','));
    slp.push([iso(start), iso(start), iso(start + 8 * 3600e3), Math.round(n.sleepPerf), asleep.toFixed(0), (asleep * 0.55).toFixed(0), (asleep * 0.21).toFixed(0), (asleep * 0.24).toFixed(0), 30, need.toFixed(0), debt.toFixed(0), 'false'].join(','));
    prevStrain = Number(strain.toFixed(1));
    // n is afgerond in de CSV; geschiedenis zoals Whoop hem zou zien
    hist.push({ hrv: Math.round(n.hrv), rhr: Math.round(n.rhr), resp: Math.round(n.resp * 10) / 10, skinTemp: Math.round(n.skinTemp * 100) / 100 });
  }
  const wo = ['Workout start time,Duration (min),Activity name,Activity Strain,Max HR (bpm),HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,HR Zone 5 %'];
  for (let i = 0; i < 40; i++) {
    const dur = 20 + 100 * r(), raw = [r(), r(), r(), r() * 0.6, r() * 0.3], s = raw.reduce((a, b) => a + b, 0) / (0.6 + 0.4 * r());
    const z = raw.map((v) => Math.round((100 * v) / s));
    const zm = [dur * (1 - z.reduce((a, b) => a + b, 0) / 100), ...z.map((p) => (p / 100) * dur)];
    wo.push([iso(day0 + i * 3 * 86400e3), dur.toFixed(0), 'Running', W.strainFromLoad(W.loadFromZoneMinutes(zm, truth), truth).toFixed(1), 185, ...z].join(','));
  }
  return { truth, cycles: cyc.join('\n'), sleeps: slp.join('\n'), workouts: wo.join('\n') };
}

test('kalibratie vindt de parameters van een gesimuleerde Whoop terug', () => {
  const ex = fakeExport();
  const { calibration: c, report } = calibrate(ex);
  assert.equal(c.recovery.windowDays, 30);
  assert.ok(report.recovery.rmseInSample < 2.5, `recovery RMSE ${report.recovery.rmseInSample}`);
  near(c.recovery.wHrv, 1.4, 0.25, 'wHrv'); near(c.recovery.wRhr, -0.6, 0.2, 'wRhr'); near(c.recovery.wSleep, 2.0, 0.4, 'wSleep');
  assert.ok(report.strain.rmse < 0.15, `strain RMSE ${report.strain.rmse}`);
  near(c.sleep.needBaseMin, 470, 3); near(c.sleep.needPerDebtMin, 0.4, 0.03); near(c.sleep.needPerStrainMin, 4, 0.5);
  near(c.sleep.deepFrac, 0.21, 0.01); near(c.sleep.remFrac, 0.24, 0.01);
  assert.ok(c.profile.maxHr >= 180 && c.profile.maxHr <= 190);
  near(c.profile.restingHr, 54, 2);
});
