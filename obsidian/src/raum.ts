// Geteilte Räume (protokoll/RAEUME.md), soweit das Plugin sie braucht:
// geteilte Vault-Ordner lesen und schreiben. Verwaltet (anlegen,
// einladen, annehmen) werden Räume in der Tracker-App; das Plugin liest
// ihre Daten aus dem eigenen Konto (Datensätze `raeume/<id>`).

import { base64, entschluesseln, hex, hkdf, hmac, utf8, verschluesseln, vonBase64, vonUtf8 } from './krypto.ts';
import type { Umschlag } from './protokoll.ts';

type Bytes = Uint8Array<ArrayBuffer>;

/** Raum-Datensatz wie in der App (`Raum.toJson`). */
export interface RaumJson {
  id: string;
  art: 'vault' | 'kalender' | 'aufgaben';
  name: string;
  recht: 'eigentuemer' | 'schreiben' | 'lesen';
  von?: string;
  idSchluessel: string;
  schluessel: Record<string, string>;
  epoche: number;
  paar?: string;
  ordner?: string;
}

export class Raum {
  readonly j: RaumJson;
  private readonly idSchluessel: Bytes;
  private readonly schluessel: Map<number, Bytes>;
  private blockIdSchluessel?: Promise<Bytes>;

  constructor(j: RaumJson) {
    this.j = j;
    this.idSchluessel = vonBase64(j.idSchluessel);
    this.schluessel = new Map(Object.entries(j.schluessel).map(([e, k]) => [Number(e), vonBase64(k)]));
  }

  get id(): string {
    return this.j.id;
  }
  get ordner(): string | undefined {
    return this.j.ordner;
  }
  get schreibbar(): boolean {
    return this.j.recht !== 'lesen';
  }
  get eigen(): boolean {
    return this.j.recht === 'eigentuemer';
  }

  /** Mit neuen Schlüsseln und Recht (aus dem Mitglieds-Paket des Servers). */
  mit(recht: RaumJson['recht'], epoche: number, schluessel: Record<string, string>): Raum {
    return new Raum({ ...this.j, recht, epoche, schluessel });
  }

  async objektId(bereich: string, id: string): Promise<string> {
    return hex((await hmac(this.idSchluessel, utf8(`${bereich}/${id}`))).subarray(0, 16));
  }

  private aad(oid: string): string {
    return `ptv2-raum-objekt|${this.j.id}|${oid}`;
  }

  async verschluesseln(u: Umschlag): Promise<string> {
    const roh = utf8(JSON.stringify({ b: u.bereich, i: u.id, s: u.schema, d: u.daten }));
    const fuell = (256 - ((roh.length + 1) % 256)) % 256;
    const klar = new Uint8Array(roh.length + 1 + fuell);
    klar.set(roh);
    klar[roh.length] = 0x0a;
    const g = await verschluesseln(this.schluessel.get(this.j.epoche)!, klar, this.aad(await this.objektId(u.bereich, u.id)));
    return JSON.stringify({ e: this.j.epoche, n: base64(g.nonce), c: base64(g.daten) });
  }

  async entschluesseln(oid: string, daten: string): Promise<Umschlag | null> {
    try {
      const j = JSON.parse(daten);
      const k = this.schluessel.get(j.e);
      if (!k || typeof j.n !== 'string' || typeof j.c !== 'string') return null;
      const klar = await entschluesseln(k, vonBase64(j.n), vonBase64(j.c), this.aad(oid));
      if (!klar) return null;
      const ende = klar.indexOf(0x0a);
      const u = JSON.parse(vonUtf8(ende < 0 ? klar : klar.subarray(0, ende)));
      const r: Umschlag = { bereich: u.b, id: u.i, schema: u.s, daten: u.d ?? null };
      return (await this.objektId(r.bereich, r.id)) === oid ? r : null;
    } catch {
      return null;
    }
  }

  async blockId(klar: Bytes): Promise<string> {
    this.blockIdSchluessel ??= hkdf(this.idSchluessel, 'ptv2-raum-block-id-v1');
    return hex((await hmac(await this.blockIdSchluessel, klar)).subarray(0, 16));
  }

  async blockVerschluesseln(bid: string, klar: Bytes): Promise<Bytes> {
    const laenge = Math.max(4096, Math.ceil(klar.length / 4096) * 4096);
    const gefuellt = new Uint8Array(laenge);
    gefuellt.set(klar);
    const g = await verschluesseln(this.schluessel.get(this.j.epoche)!, gefuellt, `ptv2-raum-block|${this.j.id}|${bid}`);
    const out = new Uint8Array(4 + 12 + g.daten.length);
    new DataView(out.buffer).setUint32(0, this.j.epoche);
    out.set(g.nonce, 4);
    out.set(g.daten, 16);
    return out;
  }

  async blockEntschluesseln(bid: string, daten: Bytes, groesse: number): Promise<Bytes | null> {
    if (daten.length < 32) return null;
    const k = this.schluessel.get(new DataView(daten.buffer, daten.byteOffset).getUint32(0));
    if (!k) return null;
    const klar = await entschluesseln(k, daten.slice(4, 16), daten.slice(16), `ptv2-raum-block|${this.j.id}|${bid}`);
    if (!klar || klar.length < groesse) return null;
    const inhalt = klar.slice(0, groesse);
    return (await this.blockId(inhalt)) === bid ? inhalt : null;
  }

  /** Raumschlüssel aus dem Mitglieds-Paket (Server: `GET /v1/raeume`). */
  static async mitgliedPaketOeffnen(raum: string, paar: Bytes, paket: string): Promise<{ epoche: number; schluessel: Record<string, string> } | null> {
    try {
      const g = JSON.parse(paket);
      const klar = await entschluesseln(paar, vonBase64(g.n), vonBase64(g.c), `ptv2-raum-mitglied|${raum}`);
      if (!klar) return null;
      const j = JSON.parse(vonUtf8(klar));
      return { epoche: j.epoche, schluessel: j.schluessel };
    } catch {
      return null;
    }
  }
}
