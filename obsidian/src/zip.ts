// Minimaler ZIP-Schreiber (ohne Kompression) für die Sicherung vor der
// Einrichtung. Lesbar mit jedem Entpacker.

type Bytes = Uint8Array<ArrayBuffer>;

const crcTabelle = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

export function crc32(b: Uint8Array): number {
  let c = 0xffffffff;
  for (const x of b) c = crcTabelle[(c ^ x) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export function zip(dateien: { pfad: string; daten: Bytes }[], zeit = new Date()): Bytes {
  const enc = new TextEncoder();
  const dosZeit = ((zeit.getHours() << 11) | (zeit.getMinutes() << 5) | (zeit.getSeconds() >> 1)) & 0xffff;
  const dosDatum = (((zeit.getFullYear() - 1980) << 9) | ((zeit.getMonth() + 1) << 5) | zeit.getDate()) & 0xffff;
  const teile: Uint8Array[] = [];
  const zentral: Uint8Array[] = [];
  let versatz = 0;
  for (const d of dateien) {
    const name = enc.encode(d.pfad);
    const crc = crc32(d.daten);
    const kopf = new DataView(new ArrayBuffer(30));
    kopf.setUint32(0, 0x04034b50, true);
    kopf.setUint16(4, 20, true);
    kopf.setUint16(6, 0x0800, true); // UTF-8-Namen
    kopf.setUint16(10, dosZeit, true);
    kopf.setUint16(12, dosDatum, true);
    kopf.setUint32(14, crc, true);
    kopf.setUint32(18, d.daten.length, true);
    kopf.setUint32(22, d.daten.length, true);
    kopf.setUint16(26, name.length, true);
    teile.push(new Uint8Array(kopf.buffer), name, d.daten);
    const z = new DataView(new ArrayBuffer(46));
    z.setUint32(0, 0x02014b50, true);
    z.setUint16(4, 20, true);
    z.setUint16(6, 20, true);
    z.setUint16(8, 0x0800, true);
    z.setUint16(12, dosZeit, true);
    z.setUint16(14, dosDatum, true);
    z.setUint32(16, crc, true);
    z.setUint32(20, d.daten.length, true);
    z.setUint32(24, d.daten.length, true);
    z.setUint16(28, name.length, true);
    z.setUint32(42, versatz, true);
    zentral.push(new Uint8Array(z.buffer), name);
    versatz += 30 + name.length + d.daten.length;
  }
  const zentralGroesse = zentral.reduce((n, t) => n + t.length, 0);
  const ende = new DataView(new ArrayBuffer(22));
  ende.setUint32(0, 0x06054b50, true);
  ende.setUint16(8, dateien.length, true);
  ende.setUint16(10, dateien.length, true);
  ende.setUint32(12, zentralGroesse, true);
  ende.setUint32(16, versatz, true);
  const alle = [...teile, ...zentral, new Uint8Array(ende.buffer)];
  const out = new Uint8Array(alle.reduce((n, t) => n + t.length, 0));
  let o = 0;
  for (const t of alle) {
    out.set(t, o);
    o += t.length;
  }
  return out;
}
