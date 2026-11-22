// Randgevallen van de scores: weinig data, gaten, eerste dagen, ontbrekende RR/beweging, volgorde, tijdzones.
// Tests met `todo` beschrijven een bekende bug (zie docs/TESTPLAN.md, lijst gevonden bugs). Ze laten CI niet falen;
// haal `todo` weg zodra de bug is opgelost, dan bewaakt de test dat hij niet terugkomt.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as W from '../whoop-scores.js';
import { synthNight, rng } from './synth.js';

const C = W.DEFAULT_CALIBRATION;
const night = synthNight({ seed: 3 }).samples;
const ref = W.analyzeNight(night, C, undefined, 0);
const P = (a, b) => ({ startIdx: a, endIdx: b });
const flatEpochs = (t0, n) => Array.from({ length: n }, (_, i) => ({ t: t0 + i * 60, hr: 55, hrSd: 1, move: 0, skinTemp: NaN, n: 60 }));
const DAY = 1795305600; // 22-11-2026 00:00 UTC

test('RG-01 geen data: geen nacht, belasting en energie 0, geen crash', () => {
  assert.equal(W.analyzeNight([], C), null);
  assert.deepEqual(W.strain([], C).zoneMin, [0, 0, 0, 0, 0, 0]);
  assert.equal(W.calories([], C), 0);
  assert.deepEqual(W.epochs([]), []);
});

test('RG-02 minder dan 30 min data: geen nacht', () => {
  assert.equal(W.analyzeNight(night.slice(0, 25 * 60), C, undefined, 0), null);
});

test('RG-03 geen RR-intervallen: slaap wel, HRV/rust-HR/ademhaling onbekend (NaN, geen 0)', () => {
  const n = W.analyzeNight(night.map((s) => ({ ...s, rr: [] })), C, undefined, 0);
  assert.ok(n && n.asleepMin > 60);
  assert.ok(Number.isNaN(n.hrv) && Number.isNaN(n.resp));
});

test('RG-04 alleen live-data (geen oriëntatie, RR in ~15% van de seconden): nacht en HRV toch te berekenen', () => {
  const r = rng(7);
  const live = night.map((s) => ({ t: s.t, hr: s.hr, rr: r() < 0.15 ? s.rr : [], q: null, skinTemp: null }));
  const n = W.analyzeNight(live, C, undefined, 0);
  assert.ok(n, 'nacht gevonden');
  assert.ok(Number.isFinite(n.hrv) && n.hrv > 5 && n.hrv < 200, `hrv ${n.hrv}`);
  // zonder beweging telt wakker in bed vaker als slaap: nooit minder slaap dan met beweging
  assert.ok(n.asleepMin >= ref.asleepMin);
});

test('RG-05 gat van 2 uur (band af): geen crash, slaap nooit langer dan de gemeten tijd', () => {
  const t0 = night[0].t;
  const gap = night.filter((s) => !(s.t > t0 + 120 * 60 && s.t < t0 + 240 * 60));
  const n = W.analyzeNight(gap, C, undefined, 0);
  assert.ok(n);
  assert.ok(n.asleepMin <= gap.length / 60 + 1, `${n.asleepMin} min slaap uit ${gap.length / 60} min data`);
});

test('RG-06 dubbele seconden: zelfde slaapduur', () => {
  const n = W.analyzeNight(night.flatMap((s) => [s, s]), C, undefined, 0);
  assert.equal(n.asleepMin, ref.asleepMin);
  assert.equal(n.inBedMin, ref.inBedMin);
});

test('RG-07 ongesorteerde invoer (na tijdzonewissel) mag niet crashen', { todo: 'BUG-3: analyzeNight/epochs crasht; DayStore sorteert nu wel' }, () => {
  const shuffled = [...night.slice(100), ...night.slice(0, 100)];
  assert.doesNotThrow(() => W.analyzeNight(shuffled, C, undefined, 0));
});

test('RG-08 belasting en energie nooit negatief, ook bij ongesorteerde invoer', { todo: 'BUG-3: negatieve tijdstap telt als negatieve zoneminuten' }, () => {
  const s = [{ t: 100, hr: 150 }, { t: 50, hr: 150 }, { t: 51, hr: 150 }];
  assert.ok(W.strain(s, C).zoneMin.every((z) => z >= 0));
  assert.ok(W.calories(s, C) >= 0);
});

test('RG-09 herstel eerste nachten (<4 nachten historie) bij normale eigen waarden is niet extreem', { todo: 'BUG-1: valt terug op populatie-basislijn (HRV 60 ms) → 1–2% bij HRV ~30 ms' }, () => {
  const sam = { hrv: 31, rhr: 62, resp: 15.5, sleepPerf: 75, skinTemp: 33.5 };
  for (const h of [0, 1, 3]) {
    const hist = Array.from({ length: h }, () => ({ hrv: 31, rhr: 62, resp: 15.5, skinTemp: 33.5 }));
    const r = W.recovery(sam, hist, C);
    assert.ok(r >= 20 && r <= 80, `${h} nachten historie → ${r}%`);
  }
});

test('RG-10 herstel met identieke historie (sd = 0): ondergrenzen houden het eindig en gemiddeld', () => {
  const hist = Array.from({ length: 5 }, () => ({ hrv: 31, rhr: 62, resp: 15.5, skinTemp: 33.5 }));
  const r = W.recovery({ hrv: 31, rhr: 62, resp: 15.5, sleepPerf: 75, skinTemp: 33.5 }, hist, C);
  assert.ok(r >= 30 && r <= 80, `${r}`);
  const worse = W.recovery({ hrv: 28, rhr: 64, resp: 15.5, sleepPerf: 75, skinTemp: 33.5 }, hist, C);
  assert.ok(worse < r);
});

test('RG-11 herstel blijft binnen 1–99 bij extreme invoer', () => {
  for (const hrv of [1, 5, 300]) for (const rhr of [35, 110]) {
    const r = W.recovery({ hrv, rhr, resp: 15, sleepPerf: 50 }, [], C);
    assert.ok(r >= 1 && r <= 99, `${hrv}/${rhr} → ${r}`);
  }
});

test('RG-12 doorslapen na 08:00 met kort wakker moment blijft één nacht (geen dutje)', { todo: 'BUG-2: blok na 08:00 telt als dutje' }, () => {
  // tz +60: 03:00–08:10 slapen, 25 min wakker, 08:35–10:30 slapen
  const r = W.mainSleep(flatEpochs(DAY, 1440), [P(120, 430), P(455, 570)], C, 60);
  assert.deepEqual(r.main, P(120, 570));
  assert.equal(r.naps.length, 0);
});

test('RG-13 middagdutje blijft een dutje, nachtblokken worden samengevoegd', () => {
  const r = W.mainSleep(flatEpochs(DAY, 1440), [P(114, 171), P(232, 457), P(840, 880)], C, 60);
  assert.deepEqual(r.main, P(114, 457));
  assert.deepEqual(r.naps, [P(840, 880)]);
});

test('RG-14 tijdzone: dezelfde lokale nacht geeft dezelfde hoofdslaap bij UTC+1 en UTC+2', () => {
  const a = W.mainSleep(flatEpochs(DAY, 1440), [P(114, 171), P(232, 457)], C, 60);
  const b = W.mainSleep(flatEpochs(DAY - 3600, 1440), [P(114, 171), P(232, 457)], C, 120);
  assert.deepEqual(a.main, b.main);
});

test('RG-15 consistentie en prestatie bij te weinig gegevens: NaN, nooit een verzonnen getal', () => {
  assert.ok(Number.isNaN(W.sleepConsistency([{ onset: 0, wake: 3600 }])));
  assert.ok(Number.isNaN(W.sleepSufficiency(400, 0)));
  assert.ok(Number.isNaN(W.sleepPerformance({ asleepMin: 400, needMin: 0 }, C)));
});

test('RG-16 losse hartslagpiek (artefact) geeft nauwelijks belasting', () => {
  const s = Array.from({ length: 600 }, (_, i) => ({ t: 1000 + i, hr: i === 300 ? 220 : 60 }));
  assert.ok(W.strain(s, C).strain < 0.5);
});

test('RG-17 nul-minuten in zones geven belasting 0 (niet negatief, niet NaN)', () => {
  const s = Array.from({ length: 3600 }, (_, i) => ({ t: 1000 + i, hr: 58 }));
  const r = W.strain(s, C);
  assert.ok(r.strain >= 0 && Number.isFinite(r.strain));
});

test('RG-18 slaapschuld blijft binnen 0…plafond, ook bij extreme invoer', () => {
  for (const [d, need, slept] of [[0, 480, 0], [500, 480, 0], [0, 480, 900], [0, NaN, 300]]) {
    const v = W.sleepDebt({ prevDebtMin: d, prevNeedMin: need, prevAsleepMin: slept }, C);
    assert.ok(v >= 0 && v <= C.sleep.debtCapMin, `${d}/${need}/${slept} → ${v}`);
  }
});
