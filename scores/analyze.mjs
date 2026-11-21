#!/usr/bin/env node
// Analyseer een opname van de app: node scores/analyze.mjs <whoop_historie_….csv> [whoop-calibration.json]
// Leest whoop_historie_*.csv (tijd;hr_bpm;huidtemp_c;rr_ms;q0..q3;…) of hartslag_*.csv (tijd;hr_bpm;rr_ms;…).
// Print slaap, fases, HRV, rust-HR, ademfrequentie, Strain, en een regel voor eigen-nachten.csv.
import { readFileSync } from 'node:fs';
import * as W from './whoop-scores.js';

export function readRecording(text) {
  const lines = text.replace(/^﻿/, '').split(/\r?\n/).filter(Boolean);
  const head = lines.shift().split(';');
  const ix = (n) => head.indexOf(n);
  const num = (v) => (v === undefined || v === '' ? NaN : Number(v.replace(',', '.')));
  const byT = new Map();
  for (const l of lines) {
    const c = l.split(';');
    const t = Math.floor(Date.parse(c[ix('tijd')]) / 1000);
    if (!Number.isFinite(t)) continue;
    const q = ix('q0') >= 0 ? [0, 1, 2, 3].map((k) => num(c[ix('q' + k)])) : null;
    byT.set(t, {
      t, hr: num(c[ix('hr_bpm')]) || 0,
      rr: (c[ix('rr_ms')] || '').split(' ').filter(Boolean).map(Number).filter(Number.isFinite),
      q: q && q.every(Number.isFinite) ? q : null,
      skinTemp: ix('huidtemp_c') >= 0 ? num(c[ix('huidtemp_c')]) : null,
    });
  }
  return [...byT.values()].sort((a, b) => a.t - b.t);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [file, calFile] = process.argv.slice(2);
  if (!file) { console.error('Gebruik: node scores/analyze.mjs <opname.csv> [whoop-calibration.json]'); process.exit(1); }
  const cal = calFile ? JSON.parse(readFileSync(calFile, 'utf8')) : W.DEFAULT_CALIBRATION;
  const samples = readRecording(readFileSync(file, 'utf8'));
  const fmt = (t) => new Date(t * 1000).toLocaleString('nl-NL', { timeZone: 'Europe/Amsterdam' });
  console.log(`${samples.length} seconden, ${fmt(samples[0].t)} – ${fmt(samples[samples.length - 1].t)}`);
  const n = W.analyzeNight(samples, cal);
  if (!n) { console.log('Geen slaap gevonden.'); } else {
    const need = W.sleepNeedMin({}, cal);
    console.log(`Slaap ${fmt(n.onset)} – ${fmt(n.wake)}: in bed ${n.inBedMin} min, geslapen ${n.asleepMin} min (wakker ${n.awakeMin}, licht ${n.lightMin}, diep ${n.deepMin}, REM ${n.remMin}), efficiëntie ${n.efficiency.toFixed(0)} %`);
    console.log(`HRV ${n.hrv.toFixed(0)} ms · rust-HR ${n.rhr.toFixed(0)} · ademfrequentie ${n.resp.toFixed(1)} /min · huidtemp ${n.skinTemp.toFixed(2)} °C`);
    const perf = W.sleepPerformance({ asleepMin: n.asleepMin, needMin: need, efficiency: n.efficiency }, cal);
    console.log(`Slaapprestatie ${perf.toFixed(0)} % (behoefte ${need.toFixed(0)} min zonder schuld/strain; consistentie onbekend, 70 % aangenomen)`);
    console.log(`Recovery (zonder eigen geschiedenis, op gekalibreerde basislijn) ${W.recovery({ ...n, sleepPerf: perf }, [], cal)} %`);
    console.log(`eigen-nachten.csv-regel:\nwake,hrv,rhr,resp,skinTemp\n${new Date(n.wake * 1000).toISOString()},${n.hrv.toFixed(1)},${n.rhr.toFixed(1)},${n.resp.toFixed(2)},${n.skinTemp.toFixed(2)}`);
  }
  const s = W.strain(samples, cal);
  console.log(`Strain over de hele opname ${s.strain.toFixed(1)} (zoneminuten ${s.zoneMin.map((m) => m.toFixed(0)).join('/')})`);
}
