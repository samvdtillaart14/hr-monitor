// Schrijft test/fixtures/night.json: synthetische invoer + uitkomsten van de JS-versie.
// De Swift-tests lezen dit bestand en moeten dezelfde uitkomsten geven.
import { writeFileSync } from 'node:fs';
import * as W from '../whoop-scores.js';
import { synthNight } from './synth.js';

const { samples } = synthNight({ seed: 7 });
const night = W.analyzeNight(samples);
const run = Array.from({ length: 2400 }, (_, i) => ({ t: 5000 + i, hr: Math.round(110 + 60 * Math.sin(i / 700)) }));
const hist = Array.from({ length: 20 }, (_, i) => ({ hrv: 60 + (i % 5) - 2, rhr: 55 + (i % 3) - 1, resp: 15 + 0.1 * (i % 4), skinTemp: 33.5 }));
const nightIn = { hrv: 62, rhr: 54, resp: 15.4, sleepPerf: 71, skinTemp: 33.7, sufficiency: 76, efficiency: 88 };
const recCal = structuredClone(W.DEFAULT_CALIBRATION);
Object.assign(recCal.recovery, { wHrv: 0.15, wSleep: 1.3, wHrvSleep: 1.0, wSuf: 2.3, wEff: 0.05, wCons: -0.25, sleepRef: 0.64, sufRef: 0.67, effRef: 0.83, consRef: 0.58 });
const fx = {
  calibration: W.DEFAULT_CALIBRATION,
  input: {
    t0: samples[0].t,
    hr: samples.map((s) => s.hr),
    rr: samples.map((s) => s.rr),
    q: samples.map((s) => s.q),
    skinTemp: samples.map((s) => s.skinTemp),
  },
  expected: {
    night: { ...night, stages: night.stages.map((s) => 'WLDR'[s]).join('') },
    workout: { input: run.map((s) => s.hr), ...W.strain(run) },
    recovery: { history: hist, night: nightIn, calibration: recCal, score: W.recovery(nightIn, hist, recCal), scoreDefault: W.recovery(nightIn, hist) },
    sleepPerf: { asleepMin: 400, needMin: 470, efficiency: 88, consistency: 72, perf: W.sleepPerformance({ asleepMin: 400, needMin: 470, efficiency: 88, consistency: 72 }) },
    consistency: { nights: [[0, 82800, 111600], [1, 84600, 113400], [2, 81000, 109800], [3, 90000, 115200]].map(([d, a, b]) => ({ onset: d * 86400 + a, wake: d * 86400 + b })) },
    sleepNeed: { debtMin: 45, prevDayStrain: 15, napMin: 20, need: W.sleepNeedMin({ debtMin: 45, prevDayStrain: 15, napMin: 20 }) },
  },
};
fx.expected.consistency.value = W.sleepConsistency(fx.expected.consistency.nights);
writeFileSync(new URL('./fixtures/night.json', import.meta.url), JSON.stringify(fx));
console.log('fixture geschreven', JSON.stringify(fx).length, 'bytes');
