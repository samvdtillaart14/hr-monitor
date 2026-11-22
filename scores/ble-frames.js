// Referentie-implementatie van ios/HRMonitor/WhoopParser.swift (zelfde regels, zelfde offsets).
// Gebruikt door de tests om echte BLE-opnames te ontleden en de verwachte uitkomst voor de Swift-tests vast te leggen.

export function crc16Modbus(b) {
  let c = 0xffff;
  for (const x of b) { c ^= x; for (let i = 0; i < 8; i++) c = c & 1 ? (c >>> 1) ^ 0xa001 : c >>> 1; }
  return c;
}

export function crc32(b) {
  let c = 0xffffffff;
  for (const x of b) { c ^= x; for (let i = 0; i < 8; i++) c = c & 1 ? (c >>> 1) ^ 0xedb88320 : c >>> 1; }
  return ~c >>> 0;
}

const u16 = (b, i) => b[i] | (b[i + 1] << 8);
const u32 = (b, i) => (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) >>> 0;
const f32 = (b, i) => new DataView(Uint8Array.from(b.slice(i, i + 4)).buffer).getFloat32(0, true);

export const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join(' ');
export const unhex = (s) => s.trim().split(/\s+/).filter(Boolean).map((h) => parseInt(h, 16));

/** Commandoframe (type 0x23) zoals WhoopParser.frame(cmd:body:). */
export function frame(seq, cmd, body) {
  const payload = [0x23, seq & 0xff, cmd, ...body];
  while (payload.length % 4) payload.push(0);
  const len = payload.length + 4;
  const f = [0xaa, 0x01, len & 0xff, len >> 8, 0x00, 0x01];
  const c16 = crc16Modbus(f);
  f.push(c16 & 0xff, c16 >> 8, ...payload);
  const c32 = crc32(payload);
  f.push(c32 & 0xff, (c32 >>> 8) & 0xff, (c32 >>> 16) & 0xff, c32 >>> 24);
  return f;
}

/** Zelfde grenzen als WhoopParser.plausibleTime: 2020-01-01 tot morgen. */
export const plausibleTime = (t, now = Date.now() / 1000) => t >= 1577836800 && t <= now + 86400;

/** CRC32-trailer klopt (over byte 8 tot de laatste 4). */
export function trailerOk(f) { return crc32(f.slice(8, f.length - 4)) === u32(f, f.length - 4); }

/** Parser met dezelfde toestand en uitkomsten als de Swift-versie. `checkCrc32`: ook de trailer controleren. */
export class WhoopParser {
  constructor({ checkCrc32 = true } = {}) {
    this.checkCrc32 = checkCrc32;
    this.frames = 0; this.badFrames = 0; this.typeCounts = {}; this.records = []; this.bursts = 0;
    this.trims = []; this.responses = []; this.complete = 0; this.liveHR = null; this.liveRR = []; this.live = [];
    this.logLines = 0; this.imuFrames = 0; this.seen = new Set(); this.buffers = {};
  }
  resetBuffers() { this.buffers = {}; }
  handleChunk(bytes, channel) {
    let buf = (this.buffers[channel] ?? []).concat(Array.from(bytes));
    let i = 0;
    while (i < buf.length) {
      if (buf[i] !== 0xaa || (i + 1 < buf.length && buf[i + 1] !== 0x01)) { i++; continue; }
      if (buf.length - i < 8) break;
      if (crc16Modbus(buf.slice(i, i + 6)) !== u16(buf, i + 6)) { i++; continue; }
      const total = u16(buf, i + 2) + 8;
      if (total < 12 || total > 4096) { i++; this.badFrames++; continue; }
      if (buf.length - i < total) break;
      const f = buf.slice(i, i + total);
      if (this.checkCrc32 && !trailerOk(f)) { i++; this.badFrames++; continue; }
      this.handleFrame(f);
      i += total;
    }
    buf = buf.slice(i);
    if (buf.length > 8192) buf = [];
    this.buffers[channel] = buf;
  }
  handleFrame(b) {
    if (!(b.length >= 12 && b[0] === 0xaa && b[1] === 0x01 && u16(b, 2) + 8 === b.length && crc16Modbus(b.slice(0, 6)) === u16(b, 6))) { this.badFrames++; return; }
    this.frames++;
    const type = b[8];
    this.typeCounts[type] = (this.typeCounts[type] ?? 0) + 1;
    if (type === 0x2f && b[9] === 0x12 && b.length >= 124) {
      const t = u32(b, 15);
      if (!plausibleTime(t)) return;
      const raw = u16(b, 73) / 100, n = Math.min(b[23], 4);
      const rec = {
        time: t, hr: b[22], skinTemp: raw >= 5 && raw <= 45 ? raw : null,
        rr: Array.from({ length: n }, (_, k) => u16(b, 24 + 2 * k)),
        motion: [0, 1, 2, 3].map((k) => f32(b, 41 + 4 * k)),
        temp2: u16(b, 69) / 10, temp3: u16(b, 71) / 10,
      };
      if (!this.seen.has(t)) { this.seen.add(t); this.records.push(rec); }
    } else if ((type === 0x2b && b.length >= 1244) || (type === 0x2f && b[9] === 0x15 && b.length >= 1244)) {
      this.imuFrames++;
    } else if (type === 0x31 && b.length >= 15) {
      if (b[10] === 2 && b.length >= 33) { this.bursts++; this.trims.push(b.slice(21, 29)); }
      else if (b[10] === 3) this.complete++;
    } else if (type === 0x28 && b.length >= 18) {
      this.liveHR = b[16];
      const n = Math.min(b[17], Math.floor((b.length - 22) / 2));
      this.liveRR = Array.from({ length: Math.max(0, n) }, (_, k) => Math.floor((u16(b, 18 + 2 * k) * 1000 + 512) / 1024));
      this.live.push({ time: u32(b, 10), hr: b[16], rr: this.liveRR });
    } else if (type === 0x32 && b.length > 25) {
      this.logLines++;
    } else if (type === 0x24 && b.length >= 13) {
      this.responses.push([b[10], b[12]]);
    }
  }
}

/** Leest een RUW-ALLES-opname (CSV met ;) en geeft de notificaties: {char, kind, bytes}. */
export function readRawCapture(text) {
  const out = [];
  for (const line of text.split('\n').slice(1)) {
    const p = line.split(';');
    if (p.length < 6) continue;
    out.push({ time: p[0], kind: p[1], service: p[2], char: p[3], bytes: unhex(p[5]) });
  }
  return out;
}

/** Uitkomst van de parser voor een lijst notificaties {c: characteristic, h: hex}; dit staat als `expected` in de fixtures. */
export function summarize(notifications) {
  const p = new WhoopParser();
  for (const n of notifications) if (n.c.startsWith('FD4B')) p.handleChunk(unhex(n.h.replace(/(..)/g, '$1 ')), n.c);
  return {
    frames: p.frames, badFrames: p.badFrames, typeCounts: p.typeCounts, bursts: p.bursts, complete: p.complete, imuFrames: p.imuFrames,
    trims: p.trims.map((t) => hex(t).replace(/ /g, '')), responses: p.responses, live: p.live, records: p.records,
  };
}
