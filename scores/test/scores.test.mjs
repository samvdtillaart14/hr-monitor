import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as W from '../whoop-scores.js';
import { synthNight } from './synth.js';

const near = (a, b, tol, msg) => assert.ok(Math.abs(a - b) <= tol, `${msg ?? ''} ${a} ≉ ${b} (±${tol})`);
const secs = (rrs, t0 = 1000) => rrs.map((rr, i) => ({ t: t0 + i, hr: 60, rr: [rr], q: null }));

test('RMSSD van een afwisselende reeks', () => {
  const rr = Array.from({ length: 60 }, (_, i) => (i % 2 ? 1050 : 1000));
  near(W.rmssd(W.beats(secs(rr))), 50, 1e-9);
});

test('artefacten (gemiste slag, uitschieter) tellen niet mee', () => {
  const rr = Array.from({ length: 60 }, (_, i) => (i % 2 ? 1050 : 1000));
  rr[20] = 2040; rr[40] = 250;
  const b = W.beats(secs(rr));
  assert.equal(b.filter((x) => !x.ok).length, 2);
  near(W.rmssd(b), 50, 1e-9);
});

test('ademfrequentie uit RSA: 15/min', () => {
  const s = []; let t = 0;
  for (let i = 0; i < 180; i++) { const rr = 1000 + 40 * Math.sin(2 * Math.PI * 0.25 * t); t += rr / 1000; s.push(rr); }
  near(W.respRateWindow(W.beats(secs(s))), 15, 0.5);
});

test('hartslagzones op basis van hartslagreserve', () => {
  const p = { maxHr: 195, restingHr: 55, zoneMode: 'hrr' };
  assert.equal(W.hrZone(100, p), 0);
  assert.equal(W.hrZone(125, p), 1);   // 50 %
  assert.equal(W.hrZone(139, p), 2);   // 60 %
  assert.equal(W.hrZone(195, p), 5);
  assert.equal(W.hrZone(180, { ...p, zoneMode: 'max' }), 5);
});

test('strain: 0 bij rust, monotoon, onder 21', () => {
  assert.equal(W.strainFromLoad(0), 0);
  let prev = 0;
  for (const T of [10, 50, 100, 300, 1000]) { const s = W.strainFromLoad(T); assert.ok(s > prev && s < 21); prev = s; }
  assert.equal(W.strainFromLoad(1e9), 21);
  const run = Array.from({ length: 3600 }, (_, i) => ({ t: i, hr: 150 }));
  const r = W.strain(run, { ...W.DEFAULT_CALIBRATION, profile: { maxHr: 190, restingHr: 50, zoneMode: 'hrr' } });
  near(r.zoneMin[3], 60, 0.02);       // 150 bpm = 71 % HRR → zone 3
  assert.ok(r.strain > 10 && r.strain < 16, String(r.strain));
});

test('recovery: hogere HRV en lagere rust-HR geven een hogere score', () => {
  const hist = Array.from({ length: 20 }, (_, i) => ({ hrv: 60 + (i % 5) - 2, rhr: 55 + (i % 3) - 1, resp: 15, skinTemp: 33.5 }));
  const base = W.recovery({ hrv: 60, rhr: 55, resp: 15, sleepPerf: 85, skinTemp: 33.5 }, hist);
  const good = W.recovery({ hrv: 75, rhr: 52, resp: 15, sleepPerf: 95, skinTemp: 33.5 }, hist);
  const bad = W.recovery({ hrv: 45, rhr: 60, resp: 16.5, sleepPerf: 60, skinTemp: 33.5 }, hist);
  assert.ok(bad < base && base < good, `${bad} ${base} ${good}`);
  assert.ok(good <= 99 && bad >= 1);
});

test('slaapbehoefte en -prestatie', () => {
  near(W.sleepNeedMin({}), 460, 1e-9);
  assert.ok(W.sleepNeedMin({ debtMin: 60, prevDayStrain: 16 }) > 460);
  assert.equal(W.sleepSufficiency(500, 460), 100);
  near(W.sleepSufficiency(368, 460), 80, 1e-9);
  const p = (o) => W.sleepPerformance({ asleepMin: 400, needMin: 460, efficiency: 90, consistency: 70, ...o });
  assert.ok(p({ asleepMin: 460 }) > p({}) && p({ efficiency: 95 }) > p({}) && p({ consistency: 90 }) > p({}));
  assert.ok(p({ asleepMin: 100, efficiency: 50, consistency: 0 }) >= 0);
});

test('slaapconsistentie: gelijke tijden 100 %, verschoven tijden lager', () => {
  const n = (d, onH, offH) => ({ onset: d * 86400 + onH * 3600, wake: d * 86400 + offH * 3600 });
  near(W.sleepConsistency([n(0, 23, 31), n(1, 23, 31), n(2, 23, 31), n(3, 23, 31)]), 100, 1e-9);
  near(W.sleepConsistency([n(0, 23, 31), n(1, 23, 31), n(2, 23, 31), n(3, 25, 33)]), 60, 1e-9); // 6 u overlap / 10 u
  assert.ok(Number.isNaN(W.sleepConsistency([n(0, 23, 31)])));
});

test('synthetische nacht: inslapen, ontwaken, fases, HRV, rust-HR, ademfrequentie', () => {
  const { samples } = synthNight();
  const n = W.analyzeNight(samples);
  near((n.onset - samples[0].t) / 60, 30, 5, 'inslaapmoment');
  near((n.wake - samples[0].t) / 60, 250, 5, 'ontwaakmoment');
  near(n.deepMin / n.asleepMin, 0.20, 0.02, 'diepe slaap');
  near(n.remMin / n.asleepMin, 0.22, 0.02, 'REM');
  near(n.rhr, 50, 2, 'rust-HR uit diepe slaap');
  assert.ok(n.hrv > 40 && n.hrv < 90, String(n.hrv));
  near(n.resp, 15, 0.6, 'ademfrequentie');
  near(n.skinTemp, 33.6, 0.1);
  // diepe slaap vooral in de eerste helft, REM vooral in de tweede
  const half = Math.floor(n.stages.length / 2);
  const cnt = (from, to, s) => n.stages.slice(from, to).filter((x) => x === s).length;
  assert.ok(cnt(0, half, W.STAGE.DEEP) > cnt(half, n.stages.length, W.STAGE.DEEP));
  assert.ok(cnt(half, n.stages.length, W.STAGE.REM) > cnt(0, half, W.STAGE.REM));
});

test('geen slaap in een wakkere opname', () => {
  const { samples } = synthNight({ segments: [{ min: 120, stage: 'wake' }] });
  const n = W.analyzeNight(samples, { ...W.DEFAULT_CALIBRATION, sleep: { ...W.DEFAULT_CALIBRATION.sleep, moveThreshold: 0.05 } });
  assert.equal(n, null);
});

test('nacht met verhoogde hartslag (alcohol): slaap wordt nog steeds gevonden', () => {
  const { samples } = synthNight({ seed: 3 });
  const hot = samples.map((s) => ({ ...s, hr: s.hr + 18, rr: s.rr.map((rr) => Math.round(60000 / (60000 / rr + 18))) }));
  const n = W.analyzeNight(hot);
  assert.ok(n, 'geen slaap gevonden');
  near((n.onset - samples[0].t) / 60, 30, 6);
  near(n.rhr, 68, 3);
});
