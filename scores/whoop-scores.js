// Whoop-achtige scores uit ruwe banddata (HR, RR, oriëntatie, huidtemperatuur).
// Pure functies, geen afhankelijkheden: draait in de browser én in Node.
// De Swift-versie (ios/WhoopScores) volgt exact dezelfde stappen en parameters.
//
// Invoer: samples, één per seconde: { t: unix-s, hr: bpm|0, rr: [ms,…], q: [4 floats]|null, skinTemp: °C|null }
// Parameters: zie DEFAULT_CALIBRATION; overschrijf ze met de uitvoer van calibrate.mjs.

export const DEFAULT_CALIBRATION = {
  version: 1,
  profile: { maxHr: 190, restingHr: 55, zoneMode: 'hrr', weightKg: 75, heightCm: 180, age: 30, male: true, kcalScale: 1 },
  strain: {
    // strain = min(21, a · ln(1 + T/b)), T = gewogen zoneminuten
    a: 3.7, b: 8,
    zoneWeights: [0.7, 1, 3.8, 8.2, 14.3, 22], // zone 0 … 5 (≈ k^1,9)
    zone0Floor: 0.3,                    // onder deze fractie HRR telt een minuut niet mee
  },
  recovery: {
    windowDays: 30, intercept: 0.4,
    wHrv: 1.0, wRhr: -0.5, wResp: -0.2, wSleep: 1.5, wTemp: 0.0, wHrvSleep: 0, wSuf: 0, wEff: 0, wCons: 0,
    sleepRef: 0.85, sufRef: 0.8, effRef: 0.85, consRef: 0.7,
    baseline: { lnHrvMean: Math.log(60), lnHrvSd: 0.25, rhrMean: 55, rhrSd: 3, respMean: 15, respSd: 0.8, tempMean: 33.5, tempSd: 0.3 },
    minHistory: 4,
    baselinePersonal: false, // true = baseline hierboven komt uit je eigen data (kalibratie)
  },
  sleep: {
    needBaseMin: 460, needPerDebtMin: 0.3, needPerStrainMin: 3, strainRef: 10,
    // prestatie = c0 + c1·toereikendheid + c2·efficiëntie + c3·consistentie (alle in %)
    perfIntercept: -72.7, perfSufficiency: 0.771, perfEfficiency: 0.754, perfConsistency: 0.386,
    deepFrac: 0.20, remFrac: 0.22,
    moveThreshold: 0,     // 0 = automatisch per opname
    hrAboveRest: 20, maxGapMin: 15, minPeriodMin: 30,
    // slaap die (deels) tussen nightStartHour en nightEndHour lokale tijd valt is nachtslaap, nooit een dutje;
    // blokken binnen nightMergeGapMin van elkaar worden één nacht (de tussentijd telt als wakker)
    nightStartHour: 22, nightEndHour: 8, nightMergeGapMin: 240,
    // een blok buiten dat venster hoort toch bij de nacht als het er binnen zoveel minuten op aansluit (uitslapen)
    nightExtendGapMin: 60,
    // ...en alleen als de gemiddelde HR in dat blok hooguit zoveel bpm boven die van de hoofdslaap ligt
    extendMaxHrRise: 4,
    // een los staartje slaap korter dan edgeRunMin na het wakker worden telt niet mee (Whoop stopt dan ook)
    edgeRunMin: 20,
    // extra wakker-regel op ruwe beweging (× drempel); 0 = uit
    wakeMoveFactor: 0,
    hrvFrom: 'lastDeep',
    // slaapschuld = min(cap, carry·schuld gisteren + fromDeficit·(behoefte − geslapen) gisteren)
    debtCarry: 0.1, debtFromDeficit: 0.55, debtCapMin: 127,
  },
  // slaapstress 0–3 per minuut: offset + (HR − basis-rust-HR)/hrScale − (ln RMSSD − basis-ln-HRV)/hrvScale
  stress: { offset: 0, hrScale: 10, hrvScale: 0.5 },
  corrections: { hrv: [0, 1], rhr: [0, 1], resp: [0, 1], skinTemp: [0, 1] }, // whoop ≈ a + b·eigen
};

// ---------- hulpfuncties ----------
const mean = (a) => (a.length ? a.reduce((s, v) => s + v, 0) / a.length : NaN);
const sd = (a) => { if (a.length < 2) return 0; const m = mean(a); return Math.sqrt(a.reduce((s, v) => s + (v - m) ** 2, 0) / (a.length - 1)); };
export function percentile(arr, p) {
  const a = arr.filter(Number.isFinite).sort((x, y) => x - y);
  if (!a.length) return NaN;
  const i = (a.length - 1) * p, lo = Math.floor(i), hi = Math.ceil(i);
  return a[lo] + (a[hi] - a[lo]) * (i - lo);
}
const median = (a) => percentile(a, 0.5);
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const sigmoid = (x) => 1 / (1 + Math.exp(-x));
const zscores = (a) => { const v = a.filter(Number.isFinite); const m = mean(v), s = sd(v) || 1; return a.map((x) => (Number.isFinite(x) ? (x - m) / s : 0)); };
function movingAvg(a, w) {
  const h = Math.floor(w / 2);
  return a.map((_, i) => { let s = 0, n = 0; for (let j = i - h; j <= i + h; j++) if (j >= 0 && j < a.length) { s += a[j]; n++; } return s / n; });
}
function movingMedian(a, w) {
  const h = Math.floor(w / 2);
  return a.map((_, i) => median(a.slice(Math.max(0, i - h), Math.min(a.length, i + h + 1))));
}
const correct = (v, c) => (Number.isFinite(v) && c ? c[0] + c[1] * v : v);

// ---------- RR-intervallen ----------
/** Bouwt een slagreeks [{t, rr, ok}] met tijdstempels uit de cumulatieve RR-som, en markeert artefacten. */
export function beats(samples) {
  const out = [];
  let clock = null;
  for (const s of samples) {
    if (!s.rr || !s.rr.length) continue;
    if (clock === null || Math.abs(clock - (s.t + 1)) > 2) { clock = s.t; if (out.length) out[out.length - 1].segEnd = true; }
    for (const rr of s.rr) { clock += rr / 1000; out.push({ t: clock, rr, ok: true, segEnd: false }); }
  }
  // artefacten: buiten 300–2000 ms of > 20 % afwijking van de lokale mediaan (11 slagen)
  for (let i = 0; i < out.length; i++) {
    const b = out[i];
    if (b.rr < 300 || b.rr > 2000) { b.ok = false; continue; }
    const win = [];
    for (let j = Math.max(0, i - 5); j <= Math.min(out.length - 1, i + 5); j++) if (out[j].rr >= 300 && out[j].rr <= 2000) win.push(out[j].rr);
    const m = median(win);
    if (Math.abs(b.rr - m) / m > 0.2) b.ok = false;
  }
  return out;
}

/** RMSSD (ms) over opeenvolgende geldige slagen binnen één segment. */
export function rmssd(bs) {
  let s = 0, n = 0;
  for (let i = 1; i < bs.length; i++) {
    if (!bs[i].ok || !bs[i - 1].ok || bs[i - 1].segEnd) continue;
    const d = bs[i].rr - bs[i - 1].rr; s += d * d; n++;
  }
  return n >= 10 ? Math.sqrt(s / n) : NaN;
}

/**
 * Strenge RMSSD voor de nacht-HRV (zoals Whoop): alleen paren van geldige slagen met |ΔRR| ≤ 17 % van de vorige slag,
 * en het venster telt alleen als minstens 80 % van de paren bruikbaar is. NaN anders.
 */
export function rmssdStrict(bs) {
  let s = 0, n = 0, pairs = 0;
  for (let i = 1; i < bs.length; i++) {
    if (bs[i - 1].segEnd) continue; // gat in de RR-reeks: geen paar
    pairs++;
    if (!bs[i].ok || !bs[i - 1].ok) continue;
    const d = bs[i].rr - bs[i - 1].rr;
    if (Math.abs(d) > 0.17 * bs[i - 1].rr) continue;
    s += d * d; n++;
  }
  return n >= 10 && n >= 0.8 * pairs ? Math.sqrt(s / n) : NaN;
}

/** Ademfrequentie (/min) uit respiratoire sinusaritmie: piek in 0,15–0,5 Hz van het RR-tachogram. */
export function respRateWindow(bs) {
  const good = bs.filter((b) => b.ok);
  if (good.length < 40) return NaN;
  const t0 = good[0].t, T = good[good.length - 1].t - t0;
  if (T < 60) return NaN;
  const fs = 4, n = Math.floor(T * fs);
  const x = new Array(n);
  let k = 0;
  for (let i = 0; i < n; i++) {
    const t = t0 + i / fs;
    while (k < good.length - 2 && good[k + 1].t < t) k++;
    const a = good[k], b = good[k + 1];
    x[i] = a.rr + (b.rr - a.rr) * clamp((t - a.t) / (b.t - a.t), 0, 1);
  }
  // lineaire trend eruit, Hann-venster
  const mi = (n - 1) / 2, mx = mean(x);
  let sxy = 0, sxx = 0;
  for (let i = 0; i < n; i++) { sxy += (i - mi) * (x[i] - mx); sxx += (i - mi) ** 2; }
  const slope = sxy / sxx;
  for (let i = 0; i < n; i++) x[i] = (x[i] - mx - slope * (i - mi)) * (0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (n - 1)));
  let best = 0, bestF = NaN, total = 0;
  for (let f = 0.15; f <= 0.5 + 1e-9; f += 0.005) {
    let re = 0, im = 0;
    for (let i = 0; i < n; i++) { const w = (2 * Math.PI * f * i) / fs; re += x[i] * Math.cos(w); im -= x[i] * Math.sin(w); }
    const p = re * re + im * im; total += p;
    if (p > best) { best = p; bestF = f; }
  }
  return best / total > 0.03 ? bestF * 60 : NaN;
}

// ---------- epochs (60 s) ----------
function quatAngle(a, b) {
  const na = Math.hypot(...a), nb = Math.hypot(...b);
  if (!na || !nb) return 0;
  const d = Math.abs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]) / (na * nb);
  return 2 * Math.acos(Math.min(1, d)) + Math.abs(nb - 1);
}

export function epochs(samples, epochSec = 60) {
  if (!samples.length) return [];
  const t0 = samples[0].t, eps = [];
  let prevQ = null;
  for (const s of samples) {
    const i = Math.floor((s.t - t0) / epochSec);
    while (eps.length <= i) eps.push({ t: t0 + eps.length * epochSec, hrs: [], move: 0, temps: [], n: 0 });
    const e = eps[i];
    e.n++;
    if (s.hr > 0) e.hrs.push(s.hr);
    if (Number.isFinite(s.skinTemp)) e.temps.push(s.skinTemp);
    if (s.q) { if (prevQ) e.move += quatAngle(prevQ, s.q); prevQ = s.q; }
  }
  return eps.map((e) => ({ t: e.t, hr: e.hrs.length ? mean(e.hrs) : NaN, hrSd: sd(e.hrs), move: e.move, skinTemp: e.temps.length ? mean(e.temps) : NaN, n: e.n }));
}

// ---------- slaapdetectie en -fases ----------
/** Zoekt slaapperiodes: weinig beweging én hartslag dicht bij rust. Geeft [{startIdx, endIdx}] (endIdx exclusief). */
export function detectSleep(eps, cal = DEFAULT_CALIBRATION) {
  const c = cal.sleep;
  const moveS = movingMedian(eps.map((e) => e.move), 7); // mediaan: een omdraaimoment maakt je niet wakker
  const moveThr = c.moveThreshold > 0 ? c.moveThreshold : Math.max(1e-3, 3 * percentile(moveS.filter((_, i) => eps[i].n > 0), 0.1)); // gaten (n = 0) tellen niet mee
  // rustreferentie: gekalibreerde rust-HR, of hoger als de nacht zelf hoger ligt (alcohol, ziekte, warmte)
  const rhr = Math.max(cal.profile.restingHr, percentile(eps.map((e) => e.hr), 0.05) || 0);
  const cand = eps.map((e, i) => moveS[i] < moveThr && (!Number.isFinite(e.hr) || e.hr < rhr + c.hrAboveRest) && e.n > 0);
  const runs = [];
  for (let i = 0; i < cand.length; i++) {
    if (!cand[i]) continue;
    let j = i; while (j < cand.length && cand[j]) j++;
    const last = runs[runs.length - 1];
    if (last && i - last.endIdx <= c.maxGapMin) last.endIdx = j; else runs.push({ startIdx: i, endIdx: j });
    i = j;
  }
  // los staartje aan het eind van een blok (na >= 5 min wakker) weghalen
  const edge = c.edgeRunMin ?? 20;
  for (const r of runs) {
    for (;;) {
      let e = r.endIdx; while (e > r.startIdx && !cand[e - 1]) e--;
      let s = e; while (s > r.startIdx && cand[s - 1]) s--;
      let g = s; while (g > r.startIdx && !cand[g - 1]) g--;
      if (g > r.startIdx && e - s < edge && s - g >= 5) r.endIdx = g; else { r.endIdx = e; break; }
    }
  }
  return { periods: runs.filter((r) => r.endIdx - r.startIdx >= c.minPeriodMin), moveThr, candidate: cand };
}

/** Lokaal uur (0–24) van een tijdstip. */
const localHour = (t, tzOffsetMin) => ((((t / 60 + tzOffsetMin) % 1440) + 1440) % 1440) / 60;
const inNight = (t, c, tz) => { const h = localHour(t, tz), a = c.nightStartHour ?? 22, b = c.nightEndHour ?? 8; return a > b ? h >= a || h < b : h >= a && h < b; };

/**
 * Hoofdslaap kiezen: het langste blok; ligt dat in de nacht, dan horen alle nachtblokken binnen
 * nightMergeGapMin erbij (de tussentijd telt als wakker). De rest zijn dutjes.
 */
export function mainSleep(eps, periods, cal = DEFAULT_CALIBRATION, tzOffsetMin = defaultTz()) {
  const c = cal.sleep;
  if (!periods.length) return null;
  const night = (p) => { for (let i = p.startIdx; i < p.endIdx; i += 5) if (inNight(eps[i].t, c, tzOffsetMin)) return true; return inNight(eps[p.endIdx - 1].t, c, tzOffsetMin); };
  // Voorkeur voor het langste blok in het nachtvenster; zonder nachtblok alleen een lang blok (verschoven nacht),
  // kort stilzitten of een dutje overdag is geen nacht.
  const nightBlocks = periods.filter(night);
  const pool = nightBlocks.length ? nightBlocks : periods;
  const longest = pool.reduce((a, b) => (b.endIdx - b.startIdx > a.endIdx - a.startIdx ? b : a));
  if (!nightBlocks.length && longest.endIdx - longest.startIdx < (c.minDayMainMin ?? 180)) return null;
  // uitslaapblok buiten het nachtvenster alleen als het rustig is (HR niet duidelijk hoger dan in de hoofdslaap)
  const meanHr = (p) => { const v = []; for (let i = p.startIdx; i < p.endIdx; i++) if (Number.isFinite(eps[i].hr) && eps[i].hr > 0) v.push(eps[i].hr); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : NaN; };
  const baseHr = meanHr(longest);
  const rise = c.extendMaxHrRise ?? 4;
  const quiet = (p) => { const h = meanHr(p); return !(Number.isFinite(h) && Number.isFinite(baseHr) && h > baseHr + rise); };
  const main = { ...longest };
  const parts = [longest];
  if (night(longest)) {
    const gap = c.nightMergeGapMin ?? 240;
    let grew = true;
    while (grew) {
      grew = false;
      const ext = c.nightExtendGapMin ?? 60;
      for (const p of periods) {
        if (parts.includes(p)) continue;
        const inside = night(p);
        const g = inside ? gap : ext; // nachtblok: ruim samenvoegen; aansluitend blok buiten de nacht: alleen bij korte onderbreking
        if (!inside && !quiet(p)) continue;
        if (p.endIdx <= main.startIdx && main.startIdx - p.endIdx <= g) { main.startIdx = p.startIdx; parts.push(p); grew = true; }
        else if (p.startIdx >= main.endIdx && p.startIdx - main.endIdx <= g) { main.endIdx = p.endIdx; parts.push(p); grew = true; }
      }
    }
  }
  return { main, naps: periods.filter((p) => !parts.includes(p)) };
}
const defaultTz = () => -new Date().getTimezoneOffset();

export const STAGE = { WAKE: 0, LIGHT: 1, DEEP: 2, REM: 3 };

/** Ken per epoch een fase toe. Diep/REM via rangorde, zodat de verdeling de gekalibreerde fracties volgt. */
export function stageSleep(eps, period, candidate, moveThr, cal = DEFAULT_CALIBRATION, rmssdPerEpoch = null) {
  const c = cal.sleep;
  const idx = []; for (let i = period.startIdx; i < period.endIdx; i++) idx.push(i);
  const N = idx.length;
  const wf = c.wakeMoveFactor ?? 0;
  const stages = idx.map((i) => (!candidate[i] || (wf > 0 && eps[i].move > wf * moveThr) ? STAGE.WAKE : STAGE.LIGHT));
  const sl = idx.map((_, k) => k).filter((k) => stages[k] !== STAGE.WAKE);
  if (!sl.length) return stages;
  const zHr = zscores(sl.map((k) => eps[idx[k]].hr));
  const zSd = zscores(sl.map((k) => eps[idx[k]].hrSd));
  const zRm = zscores(sl.map((k) => (rmssdPerEpoch ? rmssdPerEpoch[idx[k]] : NaN)));
  const pos = sl.map((k) => k / Math.max(1, N - 1));
  let deep = sl.map((k, j) => -zHr[j] - zSd[j] + 0.5 * zRm[j] + 0.8 * (1 - pos[j]));
  let rem = sl.map((k, j) => zSd[j] + 0.5 * zHr[j] - 0.3 * zRm[j] + 0.8 * pos[j] - (k < 45 ? 3 : 0));
  deep = movingAvg(deep, 5); rem = movingAvg(rem, 5);
  const nDeep = Math.round(c.deepFrac * sl.length), nRem = Math.round(c.remFrac * sl.length);
  const order = (sc) => sc.map((v, j) => [v, j]).sort((a, b) => b[0] - a[0] || a[1] - b[1]).map((p) => p[1]);
  const taken = new Array(sl.length).fill(false);
  for (const j of order(deep).slice(0, nDeep)) { stages[sl[j]] = STAGE.DEEP; taken[j] = true; }
  let r = 0;
  for (const j of order(rem)) { if (r >= nRem) break; if (taken[j]) continue; stages[sl[j]] = STAGE.REM; r++; }
  return stages;
}

// ---------- nacht ----------
/** Volledige nachtanalyse: slaap, fases, HRV, rust-HR, ademfrequentie, huidtemperatuur. */
export function analyzeNight(samples, cal = DEFAULT_CALIBRATION, baseline = cal.recovery.baseline, tzOffsetMin = defaultTz()) {
  const eps = epochs(samples);
  const { periods, moveThr, candidate } = detectSleep(eps, cal);
  if (!periods.length) return null;
  const ms = mainSleep(eps, periods, cal, tzOffsetMin);
  if (!ms) return null;
  const { main, naps } = ms;
  const bs = beats(samples);
  const t0 = eps[0].t;
  const epochBeats = eps.map(() => []);
  for (const b of bs) { const i = Math.floor((b.t - t0) / 60); if (i >= 0 && i < eps.length) epochBeats[i].push(b); }
  const rmEp = epochBeats.map(rmssd);
  const stages = stageSleep(eps, main, candidate, moveThr, cal, rmEp);
  const at = (k) => main.startIdx + k;

  // 5-minutenvensters voor HRV en rust-HR
  const c0 = cal.sleep;
  const wins = [];
  for (let k = 0; k + 5 <= stages.length; k += 5) {
    const st = stages.slice(k, k + 5);
    if (st.includes(STAGE.WAKE)) continue;
    const wb = [].concat(...epochBeats.slice(at(k), at(k + 5)));
    const v = rmssdStrict(wb);
    if (!Number.isFinite(v)) continue;
    wins.push({ k, rmssd: v, hr: mean(eps.slice(at(k), at(k + 5)).map((e) => e.hr).filter(Number.isFinite)), deep: st.filter((s) => s === STAGE.DEEP).length >= 3 });
  }
  // Zoals Whoop: laatste aaneengesloten diepe blok (hrvFrom 'lastDeep', standaard), anders alle slaapvensters.
  // HRV = mediaan van de vensters (ongevoelig voor een enkel verstoord venster).
  let chosen = (c0.hrvFrom ?? 'lastDeep') === 'lastDeep' ? wins.filter((w) => w.deep) : [];
  if (chosen.length) { // laatste aaneengesloten diepe blok
    const lastBlock = [chosen[chosen.length - 1]];
    for (let i = chosen.length - 2; i >= 0 && chosen[i].k === lastBlock[0].k - 5; i--) lastBlock.unshift(chosen[i]);
    chosen = lastBlock.length >= 2 ? lastBlock : chosen;
  } else chosen = wins;
  const hrv = chosen.length ? median(chosen.map((w) => w.rmssd)) : NaN;
  const rhr = chosen.length ? mean(chosen.map((w) => w.hr)) : NaN;

  // ademfrequentie: mediaan over vensters van 2 min in slaap
  const rates = [];
  for (let k = 0; k + 2 <= stages.length; k += 1) {
    if (stages[k] === STAGE.WAKE || stages[k + 1] === STAGE.WAKE) continue;
    const r = respRateWindow([].concat(...epochBeats.slice(at(k), at(k + 2))));
    if (Number.isFinite(r)) rates.push(r);
  }
  const resp = rates.length ? median(rates) : NaN;
  const temps = stages.map((s, k) => (s !== STAGE.WAKE ? eps[at(k)].skinTemp : NaN)).filter(Number.isFinite);
  const cnt = [0, 0, 0, 0]; stages.forEach((s) => cnt[s]++);
  let disturbances = 0; for (let k = 1; k < stages.length; k++) if (stages[k] === STAGE.WAKE && stages[k - 1] !== STAGE.WAKE) disturbances++;
  const asleep = cnt[1] + cnt[2] + cnt[3];
  // slaapstress per minuut over de hele periode in bed (5-min-venster)
  const st = cal.stress ?? DEFAULT_CALIBRATION.stress;
  const stress = stages.map((_, k) => {
    const lo = Math.max(0, k - 2), hi = Math.min(stages.length, k + 3);
    const hr = mean(eps.slice(at(lo), at(hi)).map((e) => e.hr).filter(Number.isFinite));
    if (!Number.isFinite(hr)) return NaN;
    const rm = rmssd([].concat(...epochBeats.slice(at(lo), at(hi))));
    const v = st.offset + (hr - baseline.rhrMean) / st.hrScale - (rm > 0 ? (Math.log(rm) - baseline.lnHrvMean) / st.hrvScale : 0);
    return clamp(v, 0, 3);
  });
  const stressMin = { low: 0, medium: 0, high: 0 };
  for (const v of stress) if (Number.isFinite(v)) stressMin[v >= 2 ? 'high' : v >= 1 ? 'medium' : 'low']++;
  const stressTotal = stressMin.low + stressMin.medium + stressMin.high;
  const k = cal.corrections || {};
  return {
    onset: eps[main.startIdx].t, wake: eps[main.endIdx - 1].t + 60,
    inBedMin: stages.length, asleepMin: asleep, awakeMin: cnt[0], lightMin: cnt[1], deepMin: cnt[2], remMin: cnt[3],
    efficiency: (100 * asleep) / stages.length, disturbances,
    hrv: correct(hrv, k.hrv), rhr: correct(rhr, k.rhr), resp: correct(resp, k.resp),
    skinTemp: correct(temps.length ? mean(temps) : NaN, k.skinTemp),
    stress, stressMin, highStressPct: stressTotal ? (100 * stressMin.high) / stressTotal : NaN,
    stages, naps: naps.map((p) => ({ onset: eps[p.startIdx].t, minutes: p.endIdx - p.startIdx })),
  };
}

// ---------- slaapbehoefte en -prestatie ----------
/** Opbouw van de slaapbehoefte zoals de Whoop-app hem toont (minuten). */
export function sleepNeedParts({ debtMin = 0, prevDayStrain = 0, napMin = 0 } = {}, cal = DEFAULT_CALIBRATION) {
  const c = cal.sleep;
  const parts = { healthy: c.needBaseMin, strain: c.needPerStrainMin * Math.max(0, prevDayStrain - c.strainRef), debt: c.needPerDebtMin * debtMin, naps: -napMin };
  return { ...parts, total: Math.max(0, parts.healthy + parts.strain + parts.debt + parts.naps) };
}
/** Slaapschuld (min) voor vannacht, uit de schuld en het tekort van de vorige nacht. */
export function sleepDebt({ prevDebtMin = 0, prevNeedMin = NaN, prevAsleepMin = NaN } = {}, cal = DEFAULT_CALIBRATION) {
  const c = { ...DEFAULT_CALIBRATION.sleep, ...cal.sleep };
  const deficit = Number.isFinite(prevNeedMin) && Number.isFinite(prevAsleepMin) ? prevNeedMin - prevAsleepMin : 0;
  return clamp(c.debtCarry * prevDebtMin + c.debtFromDeficit * deficit, 0, c.debtCapMin);
}
export function sleepNeedMin({ debtMin = 0, prevDayStrain = 0, napMin = 0 } = {}, cal = DEFAULT_CALIBRATION) {
  const c = cal.sleep;
  return Math.max(0, c.needBaseMin + c.needPerDebtMin * debtMin + c.needPerStrainMin * Math.max(0, prevDayStrain - c.strainRef) - napMin);
}
/** Toereikendheid: geslapen / behoefte, max 100 %. */
export const sleepSufficiency = (asleepMin, needMin) => (needMin > 0 ? Math.min(100, (100 * asleepMin) / needMin) : NaN);
/** Slaapprestatie zoals Whoop (sinds 2023): toereikendheid, efficiëntie en consistentie samen. */
export function sleepPerformance({ asleepMin, needMin, efficiency, consistency }, cal = DEFAULT_CALIBRATION) {
  const c = cal.sleep, suf = sleepSufficiency(asleepMin, needMin);
  if (!Number.isFinite(suf)) return NaN;
  const eff = Number.isFinite(efficiency) ? efficiency : 85, con = Number.isFinite(consistency) ? consistency : 70;
  return clamp(c.perfIntercept + c.perfSufficiency * suf + c.perfEfficiency * eff + c.perfConsistency * con, 0, 100);
}
/** Consistentie (%): gemiddelde overlap (doorsnede/vereniging op de 24-uursklok) van de laatste slaap met de 3 nachten ervoor.
 *  `nights`: [{onset, wake}] in unix-s, oudste eerst, laatste = vannacht. */
export function sleepConsistency(nights, tzOffsetMin = 0) {
  if (nights.length < 2) return NaN;
  const mask = (n) => {
    const m = new Uint8Array(1440), a = Math.floor(((n.onset / 60 + tzOffsetMin) % 1440 + 1440) % 1440), d = Math.min(1440, Math.floor((n.wake - n.onset) / 60));
    for (let i = 0; i < d; i++) m[(a + i) % 1440] = 1;
    return m;
  };
  const last = mask(nights[nights.length - 1]);
  const prev = nights.slice(-4, -1).map(mask);
  return mean(prev.map((m) => { let and = 0, or = 0; for (let i = 0; i < 1440; i++) { and += m[i] & last[i]; or += m[i] | last[i]; } return or ? (100 * and) / or : 0; }));
}

// ---------- strain ----------
export function hrZone(hr, profile) {
  const { maxHr, restingHr, zoneMode } = profile;
  const x = zoneMode === 'max' ? hr / maxHr : (hr - restingHr) / (maxHr - restingHr);
  if (x < 0.5) return 0;
  return Math.min(5, 1 + Math.floor((x - 0.5) * 10 + 1e-9));
}
export function strainFromLoad(T, cal = DEFAULT_CALIBRATION) {
  const { a, b } = cal.strain;
  return T > 0 ? Math.min(21, a * Math.log(1 + T / b)) : 0;
}
/** Gewogen zonebelasting T (min) uit minuten per zone [z0..z5]. */
export function loadFromZoneMinutes(zoneMin, cal = DEFAULT_CALIBRATION) {
  return zoneMin.reduce((s, m, z) => s + m * cal.strain.zoneWeights[z], 0);
}
/** Strain over een reeks samples (workout of hele cyclus). */
export function strain(samples, cal = DEFAULT_CALIBRATION) {
  const p = cal.profile, zoneMin = [0, 0, 0, 0, 0, 0];
  for (let i = 0; i < samples.length; i++) {
    const s = samples[i];
    if (!(s.hr > 0)) continue;
    const dt = i + 1 < samples.length ? Math.min(5, samples[i + 1].t - s.t) : 1;
    const z = hrZone(s.hr, p);
    if (z === 0) {
      const x = p.zoneMode === 'max' ? s.hr / p.maxHr : (s.hr - p.restingHr) / (p.maxHr - p.restingHr);
      if (x < cal.strain.zone0Floor) continue;
    }
    zoneMin[z] += dt / 60;
  }
  const load = loadFromZoneMinutes(zoneMin, cal);
  return { strain: strainFromLoad(load, cal), load, zoneMin };
}

// ---------- calorieën ----------
/** Energieverbruik (kcal) over samples: rustmetabolisme (Mifflin-St Jeor) plus activiteit (Keytel, boven rust-HR + 20). */
export function calories(samples, cal = DEFAULT_CALIBRATION) {
  const p = { ...DEFAULT_CALIBRATION.profile, ...cal.profile };
  const bmrPerMin = (10 * p.weightKg + 6.25 * p.heightCm - 5 * p.age + (p.male ? 5 : -161)) / 1440;
  let kcal = 0;
  for (let i = 0; i < samples.length; i++) {
    const s = samples[i];
    const dt = (i + 1 < samples.length ? Math.min(5, samples[i + 1].t - s.t) : 1) / 60;
    let perMin = bmrPerMin;
    if (s.hr > p.restingHr + 20) {
      const k = p.male ? (-55.0969 + 0.6309 * s.hr + 0.1988 * p.weightKg + 0.2017 * p.age) / 4.184
        : (-20.4022 + 0.4472 * s.hr - 0.1263 * p.weightKg + 0.074 * p.age) / 4.184;
      perMin = Math.max(bmrPerMin, k);
    }
    kcal += perMin * dt;
  }
  return kcal * p.kcalScale;
}

// ---------- recovery ----------
const FLOORS = { lnHrvSd: 0.05, rhrSd: 1, respSd: 0.3, tempSd: 0.1 };
/** Basislijn uit eerdere nachten [{hrv, rhr, resp, skinTemp}], laatste `windowDays`. */
/**
 * Basislijn uit de laatste `windowDays` nachten. Met minder dan `minHistory` nachten: de gekalibreerde
 * basislijn als die persoonlijk is (`baselinePersonal`, uit je eigen Whoop-export), anders het gemiddelde
 * van je eigen nachten tot nu toe (inclusief `night`) met de standaardspreiding. Een populatiebasislijn
 * (HRV 60 ms) gaf bij iemand met HRV ~30 ms een herstel van 1–2 %.
 */
export function baselineFrom(history, cal = DEFAULT_CALIBRATION, night = null) {
  const r = cal.recovery, h = history.slice(-r.windowDays);
  const col = (f) => h.map(f).filter(Number.isFinite);
  const lh = col((n) => (n.hrv > 0 ? Math.log(n.hrv) : NaN));
  if (lh.length < r.minHistory) {
    if (r.baselinePersonal || !night) return r.baseline;
    const own = [...h, night];
    const m = (f, fb) => { const v = own.map(f).filter(Number.isFinite); return v.length ? mean(v) : fb; };
    const b = r.baseline;
    return { ...b, lnHrvMean: m((n) => (n.hrv > 0 ? Math.log(n.hrv) : NaN), b.lnHrvMean), rhrMean: m((n) => n.rhr, b.rhrMean),
      respMean: m((n) => n.resp, b.respMean), tempMean: m((n) => n.skinTemp, b.tempMean) };
  }
  const pick = (vals, m, s) => (vals.length >= r.minHistory ? [mean(vals), sd(vals)] : [r.baseline[m], r.baseline[s]]);
  const [lnHrvMean, lnHrvSd] = pick(lh, 'lnHrvMean', 'lnHrvSd');
  const [rhrMean, rhrSd] = pick(col((n) => n.rhr), 'rhrMean', 'rhrSd');
  const [respMean, respSd] = pick(col((n) => n.resp), 'respMean', 'respSd');
  const [tempMean, tempSd] = pick(col((n) => n.skinTemp), 'tempMean', 'tempSd');
  return { lnHrvMean, lnHrvSd, rhrMean, rhrSd, respMean, respSd, tempMean, tempSd };
}
/** Ontwerpvector voor het Recovery-model (zelfde volgorde als RECOVERY_WEIGHTS).
 *  Ontbrekende slaapdelen tellen als hun referentiewaarde, dus zonder bijdrage. */
export function recoveryDesign(n, b, r) {
  const z = (v, m, s, fl) => (Number.isFinite(v) ? (v - m) / Math.max(s, fl) : 0);
  const frac = (v, ref) => (Number.isFinite(v) ? v / 100 : ref);
  const zH = n.hrv > 0 ? z(Math.log(n.hrv), b.lnHrvMean, b.lnHrvSd, FLOORS.lnHrvSd) : 0;
  const sp = frac(n.sleepPerf, r.sleepRef);
  return [
    1, zH,
    z(n.rhr, b.rhrMean, b.rhrSd, FLOORS.rhrSd),
    z(n.resp, b.respMean, b.respSd, FLOORS.respSd),
    sp - r.sleepRef,
    z(n.skinTemp, b.tempMean, b.tempSd, FLOORS.tempSd),
    zH * sp, // HRV telt zwaarder na een goede nacht (gevonden in Sams export)
    frac(n.sufficiency, r.sufRef) - r.sufRef,
    frac(n.efficiency, r.effRef) - r.effRef,
    frac(n.consistency, r.consRef) - r.consRef,
  ];
}
export const RECOVERY_WEIGHTS = ['intercept', 'wHrv', 'wRhr', 'wResp', 'wSleep', 'wTemp', 'wHrvSleep', 'wSuf', 'wEff', 'wCons'];

/** Recovery 1–99 %. `night`: {hrv, rhr, resp, skinTemp, sleepPerf, sufficiency, efficiency, consistency} (slaap in %);
 *  `history`: eerdere nachten [{hrv, rhr, resp, skinTemp}]. */
export function recovery(night, history = [], cal = DEFAULT_CALIBRATION) {
  const r = cal.recovery, d = recoveryDesign(night, baselineFrom(history, cal, night), r);
  const x = RECOVERY_WEIGHTS.reduce((s, k, i) => s + (r[k] ?? 0) * d[i], 0);
  return clamp(Math.round(100 * sigmoid(x)), 1, 99);
}

// ---------- SpO₂ (voorlopig) ----------
/** Ratio-of-ratios; pas bruikbaar als de ruwe optische (rood/IR) data gedecodeerd is. */
export const spo2FromRatio = (R, A = 110, B = 25) => clamp(A - B * R, 70, 100);
