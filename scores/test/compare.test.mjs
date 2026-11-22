import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compareNight } from '../compare.mjs';
import { readRecording } from '../analyze.mjs';
import { parseCSV, readCycles, readSleeps } from '../fit.js';
import { synthNight } from './synth.js';

const loc = (ms) => new Date(ms + 3600e3).toISOString().replace('T', ' ').slice(0, 19); // lokale tijd UTC+1

test('opname-CSV van de app inlezen (puntkomma, decimale komma, dubbele seconden)', () => {
  const csv = 'tijd;hr_bpm;huidtemp_c;rr_ms;q0;q1;q2;q3;temp2_c;temp3_c\n'
    + '2026-11-21T03:00:01.000Z;58;33,10;1030 1020;1,000;0,000;0,000;0,000;29,0;31,0\n'
    + '2026-11-21T03:00:00.000Z;57;33,00;1050;0,999;0,010;0,000;0,000;29,0;31,0\n'
    + '2026-11-21T03:00:01.000Z;58;33,10;1030 1020;1,000;0,000;0,000;0,000;29,0;31,0\n';
  const s = readRecording(csv);
  assert.equal(s.length, 2);
  assert.equal(s[0].hr, 57); assert.deepEqual(s[1].rr, [1030, 1020]);
  assert.equal(s[0].skinTemp, 33); assert.equal(s[0].q[0], 0.999);
});

test('nacht naast Whoop-export zetten', () => {
  const { samples } = synthNight();
  const t0 = samples[0].t * 1000, onset = t0 + 30 * 60e3, wake = t0 + 250 * 60e3;
  const cyc = ['Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),Respiratory rate (rpm),Sleep performance %,Wake onset,Sleep need (min),Asleep duration (min),Sleep efficiency %,Sleep consistency %'];
  const slp = ['Cycle start time,Cycle end time,Cycle timezone,Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),Asleep duration (min),In bed duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),Awake duration (min),Sleep need (min),Sleep debt (min),Sleep efficiency %,Sleep consistency %,Nap'];
  for (let d = 10; d >= 0; d--) { // nieuwste eerst, zoals de export
    const on = onset - d * 86400e3, wk = wake - d * 86400e3;
    cyc.push([loc(on), '', 'UTC+01:00', 60, 51, 65, 33.6, 15.1, 70, loc(wk), 300, 210, 95, 80].join(','));
    slp.push([loc(on), '', 'UTC+01:00', loc(on), loc(wk), 70, 15.1, 210, 220, 120, 45, 45, 10, 300, 30, 95, 80, 'false'].join(','));
  }
  const r = compareNight(samples, { cycles: readCycles(parseCSV(cyc.join('\n'))), sleeps: readSleeps(parseCSV(slp.join('\n'))) });
  assert.ok(r.whoop, 'Whoop-nacht niet gevonden');
  assert.equal(r.whoop.sleep.wake, wake);
  const row = (k) => r.rows.find((x) => x[0] === k);
  assert.ok(Math.abs(row('Wakker')[1] - row('Wakker')[2]) < 5 * 60e3);
  assert.ok(Math.abs(row('Rust-HR (bpm)')[1] - 51) < 6);
  assert.ok(row('Consistentie (%)')[1] > 90); // zelfde tijden als de nachten ervoor
  assert.ok(Number.isFinite(row('Recovery (%)')[1]));
});
