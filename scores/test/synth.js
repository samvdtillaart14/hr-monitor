// Deterministische synthetische banddata voor tests (en als gedeelde fixture voor de Swift-tests).
export function rng(seed) {
  let a = seed >>> 0;
  return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
const gauss = (r) => Math.sqrt(-2 * Math.log(r() + 1e-12)) * Math.cos(2 * Math.PI * r());

/** Nacht: `segments` = [{min, stage:'wake'|'light'|'deep'|'rem'}]. Ademhaling 15/min (REM 16,2/min). */
export function synthNight({ seed = 1, t0 = 1763700000, segments } = {}) {
  const r = rng(seed);
  segments ??= [
    { min: 30, stage: 'wake' }, { min: 15, stage: 'light' }, { min: 40, stage: 'deep' }, { min: 30, stage: 'light' }, { min: 20, stage: 'rem' },
    { min: 30, stage: 'light' }, { min: 25, stage: 'deep' }, { min: 30, stage: 'light' }, { min: 30, stage: 'rem' }, { min: 20, stage: 'wake' },
  ];
  const P = {
    wake: { hr: 72, rsa: 15, f: 0.28, move: 0.03, slow: 3 },
    light: { hr: 56, rsa: 40, f: 0.25, move: 0.0004, slow: 1.5 },
    deep: { hr: 50, rsa: 60, f: 0.25, move: 0.0002, slow: 0.5 },
    rem: { hr: 60, rsa: 25, f: 0.27, move: 0.0003, slow: 4 },
  };
  const total = segments.reduce((s, g) => s + g.min * 60, 0);
  const stageAt = (sec) => { let acc = 0; for (const g of segments) { acc += g.min * 60; if (sec < acc) return g.stage; } return segments[segments.length - 1].stage; };
  const samples = Array.from({ length: total }, (_, i) => ({ t: t0 + i, hr: 0, rr: [], q: null, skinTemp: null }));
  // slagen
  let tb = 0, slow = 0;
  while (tb < total) {
    const p = P[stageAt(Math.floor(tb))];
    slow = 0.98 * slow + 0.2 * p.slow * gauss(r);
    const rr = 60000 / p.hr + p.rsa * Math.sin(2 * Math.PI * p.f * tb) + 10 * slow + 4 * gauss(r);
    tb += rr / 1000;
    const i = Math.floor(tb);
    if (i < total) samples[i].rr.push(Math.round(rr));
  }
  // hr per seconde, oriëntatie, temperatuur
  let q = [1, 0, 0, 0], lastHr = 60;
  for (let i = 0; i < total; i++) {
    const s = samples[i], p = P[stageAt(i)];
    if (s.rr.length) lastHr = Math.round(60000 / (s.rr.reduce((a, b) => a + b, 0) / s.rr.length));
    s.hr = lastHr;
    const ax = [gauss(r), gauss(r), gauss(r)], n = Math.hypot(...ax), ang = p.move * Math.abs(gauss(r));
    const h = ang / 2, sn = Math.sin(h), d = [Math.cos(h), (sn * ax[0]) / n, (sn * ax[1]) / n, (sn * ax[2]) / n];
    q = [q[0] * d[0] - q[1] * d[1] - q[2] * d[2] - q[3] * d[3], q[0] * d[1] + q[1] * d[0] + q[2] * d[3] - q[3] * d[2], q[0] * d[2] - q[1] * d[3] + q[2] * d[0] + q[3] * d[1], q[0] * d[3] + q[1] * d[2] - q[2] * d[1] + q[3] * d[0]];
    const nq = Math.hypot(...q); q = q.map((v) => v / nq);
    s.q = q.map((v) => Math.round(v * 1e5) / 1e5);
    s.skinTemp = Math.round((stageAt(i) === 'wake' ? 32.0 : 33.6 + 0.2 * gauss(r)) * 100) / 100;
  }
  return { samples, segments };
}
