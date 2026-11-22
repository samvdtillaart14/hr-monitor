// Maakt een BLE-fixture uit een echte RUW-ALLES-opname: een stuk notificaties (zoals ze binnenkwamen, dus met de
// echte fragmentatie) plus de verwachte uitkomst van de referentieparser (ble-frames.js).
// Gebruik: node test/make-ble-fixture.mjs <RUW-ALLES.csv> <uit.json> <van:tot> [<van:tot> …]
import fs from 'node:fs';
import { readRawCapture, hex, summarize as expected } from '../ble-frames.js';

const [src, out, ...ranges] = process.argv.slice(2);
if (!src || !out || !ranges.length) { console.error('gebruik: make-ble-fixture.mjs <csv> <uit.json> <van:tot> …'); process.exit(1); }
const all = readRawCapture(fs.readFileSync(src, 'utf8')).filter((n) => n.kind === 'NOTIFY' && (n.service.startsWith('FD4B') || n.char === '2A37'));
const picked = ranges.flatMap((r) => { const [a, b] = r.split(':').map(Number); return all.slice(a, b); });
const notifications = picked.map((n) => ({ c: n.char.slice(0, 8), h: hex(n.bytes).replace(/ /g, '') }));
fs.writeFileSync(out, JSON.stringify({ notes: `Echte notificaties uit een opname (${ranges.join(', ')}), in volgorde van binnenkomst.`, notifications, expected: expected(notifications) }, null, 0) + '\n');
console.log(`${notifications.length} notificaties → ${out}`);
