// BLE-protocol: frames bouwen, CRC's, samenvoegen van fragmenten en herstel na fouten.
// De fixtures in testdata/ble zijn echte notificaties uit Sams opnames; de Swift-tests (ios/AppTests) gebruiken dezelfde.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import * as B from '../ble-frames.js';

const load = (n) => JSON.parse(fs.readFileSync(new URL(`../../testdata/ble/${n}.json`, import.meta.url)));
const FIXTURES = ['sync-sessie', 'nacht-download', 'live-rr'];
const chunks = (fx) => fx.notifications.filter((n) => n.c.startsWith('FD4B')).map((n) => ({ c: n.c, b: [...Buffer.from(n.h, 'hex')] }));
const run = (list, opts) => { const p = new B.WhoopParser(opts); for (const n of list) p.handleChunk(n.b, n.c); return p; };
const sig = (p) => JSON.stringify({ r: p.records, t: p.trims, s: p.responses, l: p.live, c: p.complete, i: p.imuFrames });

// Commando's die de app echt naar de band schreef (uit de ruwe opnames): seq, cmd, body → frame.
const WRITES = [
  [1, 0x91, [0x01], 'aa 01 08 00 00 01 e6 71 23 01 91 01 36 3e 5c 8d'],
  [1, 0x16, [0x00], 'aa 01 08 00 00 01 e6 71 23 01 16 00 2c 00 99 8e'],
  [1, 0x03, [0x01], 'aa 01 08 00 00 01 e6 71 23 01 03 01 ae d6 2b ce'],
  [1, 0x51, [0x01], 'aa 01 08 00 00 01 e6 71 23 01 51 01 78 e9 a6 46'],
  [2, 0x16, [0x00], 'aa 01 08 00 00 01 e6 71 23 02 16 00 75 be df 8c'],
  [2, 0x03, [0x01], 'aa 01 08 00 00 01 e6 71 23 02 03 01 f7 68 6d cc'],
  [2, 0x6a, [0x01, 0x01], 'aa 01 0c 00 00 01 e7 41 23 02 6a 01 01 00 00 00 1c c9 f7 a9'],
  [3, 0x16, [0x00], 'aa 01 08 00 00 01 e6 71 23 03 16 00 42 d4 1d 8d'],
  [4, 0x6a, [0x01, 0x01], 'aa 01 0c 00 00 01 e7 41 23 04 6a 01 01 00 00 00 26 fc 27 ca'],
  [6, 0x03, [0x01], 'aa 01 08 00 00 01 e6 71 23 06 03 01 2b c0 64 cb'],
  [7, 0x91, [0x01], 'aa 01 08 00 00 01 e6 71 23 07 91 01 84 42 d1 89'],
];

test('BLE-01 commandoframes zijn byte-voor-byte gelijk aan wat de band accepteerde', () => {
  for (const [seq, cmd, body, want] of WRITES) assert.equal(B.hex(B.frame(seq, cmd, body)), want, `seq ${seq} cmd ${cmd}`);
});

test('BLE-02 CRC16-Modbus en CRC32 (bekende waarden)', () => {
  assert.equal(B.crc16Modbus([0xaa, 0x01, 0x08, 0x00, 0x00, 0x01]), 0x71e6);
  assert.equal(B.crc32([...Buffer.from('123456789')]), 0xcbf43926);   // standaard-controlewaarde zlib
});

test('BLE-03 elk frame in de echte opnames heeft een geldige CRC32-trailer', () => {
  for (const n of FIXTURES) { const p = run(chunks(load(n))); assert.equal(p.badFrames, 0, n); assert.ok(p.frames > 50, n); }
});

test('BLE-04 fixture-uitkomst is stabiel (referentie voor de Swift-tests)', () => {
  for (const n of FIXTURES) { const fx = load(n); assert.deepEqual(JSON.parse(JSON.stringify(B.summarize(fx.notifications))), fx.expected, n); }
});

test('BLE-05 inhoud van de sync-sessie: records, bursts, acks, live en COMPLETE', () => {
  const e = load('sync-sessie').expected;
  assert.equal(e.records.length, 616);
  assert.equal(e.bursts, 18); assert.equal(e.trims.length, 18);
  assert.equal(e.complete, 1);
  assert.ok(e.responses.some(([c, r]) => c === 23 && r === 1), 'ack-antwoord van de band');
  assert.ok(e.live.length > 0);
  for (const r of e.records) {
    assert.ok(r.hr >= 30 && r.hr <= 220, `hr ${r.hr}`);
    assert.ok(r.rr.length <= 4);
    for (const x of r.rr) assert.ok(x >= 250 && x <= 2500, `rr ${x}`);
    assert.ok(r.skinTemp === null || (r.skinTemp > 20 && r.skinTemp < 40));
  }
  for (const l of e.live) for (const x of l.rr) assert.ok(x >= 250 && x <= 2500, `live rr ${x}`);
  // tijden oplopend binnen een burst; nooit dubbel
  assert.equal(new Set(e.records.map((r) => r.time)).size, e.records.length);
});

test('BLE-06 fragmentatie maakt niet uit: byte voor byte voeden geeft hetzelfde', () => {
  for (const n of FIXTURES) {
    const list = chunks(load(n));
    const bytes = list.flatMap((x) => x.b.map((b) => ({ c: x.c, b: [b] })));
    assert.equal(sig(run(bytes)), sig(run(list)), n);
  }
});

test('BLE-07 rommel tussen frames: parser vindt alle frames terug', () => {
  const list = chunks(load('sync-sessie'));
  const noisy = list.flatMap((x, i) => [{ c: x.c, b: i % 3 ? [0x00, 0xaa, 0x02, 0xaa] : [0xaa] }, x]);
  const a = run(list), b = run(noisy);
  assert.equal(b.records.length, a.records.length);
  assert.equal(b.bursts, a.bursts);
});

test('BLE-08 weggevallen notificatie: geen verkeerde records, en met CRC32-controle minder verlies', () => {
  const list = chunks(load('nacht-download'));
  const good = new Map(run(list).records.map((r) => [r.time, JSON.stringify(r)]));
  let withCrc = 0, without = 0;
  for (let k = 0; k < list.length; k += 7) {
    const dropped = list.filter((_, i) => i !== k);
    const p = run(dropped), q = run(dropped, { checkCrc32: false });
    for (const r of p.records) assert.equal(JSON.stringify(r), good.get(r.time), `record ${r.time} na wegvallen #${k}`);
    withCrc += p.records.length; without += q.records.length;
  }
  assert.ok(withCrc >= without, `${withCrc} < ${without}`);
});

test('BLE-09 kapotte CRC16 of CRC32 → frame overgeslagen, volgende frame wel gelezen', () => {
  const list = chunks(load('sync-sessie'));
  const one = run(list).records.length;
  // zoek een notificatie met precies één R18-record en verander er een databyte in
  const idx = list.findIndex((x) => x.b.length === 124 && x.b[8] === 0x2f && x.b[9] === 0x12);
  const bad = list.map((x, i) => (i === idx ? { c: x.c, b: x.b.map((v, j) => (j === 22 ? v ^ 0xff : v)) } : x));
  const p = run(bad);
  assert.equal(p.records.length, one - 1);
  assert.ok(p.badFrames >= 1);
});

test('BLE-10 onvolledig frame + nieuwe verbinding: oude halve data telt niet mee', () => {
  const list = chunks(load('sync-sessie'));
  const full = list.find((x) => x.b.length === 124 && x.b[8] === 0x2f);
  const p = new B.WhoopParser();
  p.handleChunk(full.b.slice(0, 60), full.c);
  p.resetBuffers();
  p.handleChunk(full.b, full.c);
  assert.equal(p.records.length, 1);
  assert.equal(p.badFrames, 0);
});

test('BLE-11 buffer groeit nooit onbeperkt (lengte in header te groot of geen einde)', () => {
  const p = new B.WhoopParser();
  for (let i = 0; i < 100; i++) p.handleChunk(new Array(244).fill(0x55), 'FD4B0005');
  assert.ok((p.buffers.FD4B0005?.length ?? 0) <= 8192);
});

test('BLE-12 records met onmogelijke tijd worden genegeerd', () => {
  assert.equal(B.plausibleTime(0), false);
  assert.equal(B.plausibleTime(1_500_000_000), false);
  assert.equal(B.plausibleTime(1_795_000_000, 1_795_000_000), true);
  assert.equal(B.plausibleTime(1_795_000_000 + 2 * 86400, 1_795_000_000), false);
});

test('BLE-13 live 0x28: RR in 1/1024 s wordt omgerekend naar ms (mediaan past bij de hartslag)', () => {
  // Live-RR bevat veel artefacten (gemiste en gesplitste slagen, ook op 2A37), dus alleen de mediaan vergelijken.
  const e = load('live-rr').expected;
  const rr = e.live.flatMap((l) => l.rr).sort((a, b) => a - b);
  const hr = e.live.map((l) => l.hr).sort((a, b) => a - b);
  assert.ok(rr.length >= 20, `${rr.length} RR-waarden`);
  const bpm = 60000 / rr[rr.length >> 1], med = hr[hr.length >> 1];
  assert.ok(Math.abs(bpm - med) / med < 0.1, `${bpm.toFixed(1)} bpm uit RR vs ${med} bpm`);
});
