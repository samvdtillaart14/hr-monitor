#!/usr/bin/env node
// Gebruik: node scores/calibrate.mjs <map-met-whoop-export> [eigen-nachten.csv] > whoop-calibration.json
// De map bevat physiological_cycles.csv, workouts.csv en sleeps.csv (uitgepakte Whoop-export).
// eigen-nachten.csv (optioneel): kolommen wake,hrv,rhr,resp,skinTemp uit deze app, voor bias-correctie.
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { calibrate } from './fit.js';

const [dir, ownPath] = process.argv.slice(2);
if (!dir) { console.error('Gebruik: node scores/calibrate.mjs <export-map> [eigen-nachten.csv]'); process.exit(1); }
const read = (f) => (existsSync(join(dir, f)) ? readFileSync(join(dir, f), 'utf8') : undefined);
const { calibration, report } = calibrate({
  cycles: read('physiological_cycles.csv'), workouts: read('workouts.csv'), sleeps: read('sleeps.csv'),
  own: ownPath ? readFileSync(ownPath, 'utf8') : undefined,
});
console.error(JSON.stringify(report, null, 2));
console.log(JSON.stringify(calibration, null, 2));
