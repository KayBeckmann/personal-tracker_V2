// Sync-Protokoll wie in der App (siehe protokoll/VAULT.md und
// server/SICHERHEIT.md): Objekt-IDs, Umschläge, Blöcke, Kopplungscode.

import { base64, entschluesseln, hex, hkdf, hmac, sha256, utf8, verschluesseln, vonBase64, vonUtf8, zufall } from './krypto.ts';

export const VAULT_BEREICH = 'vault';
/** Schemaversion der App (Umschlag `s`); muss zu `protokoll/testvektoren.json` passen. */
export const SCHEMA = 6;
export const INLINE_GRENZE = 64 * 1024;
export const BLOCK_GROESSE = 1024 * 1024;
const BLOCK_RASTER = 4096;

export interface BlockRef {
  id: string;
  groesse: number;
}

export interface VaultDatei {
  id: string;
  pfad: string;
  groesse: number;
  sha256: string;
  inhalt?: string; // base64
  bloecke?: BlockRef[];
  geaendert: string;
}

export interface Umschlag {
  bereich: string;
  id: string;
  schema: number;
  daten: Record<string, unknown> | null;
}

type Bytes = Uint8Array<ArrayBuffer>;

function geheimtextJson(g: { nonce: Bytes; daten: Bytes }): string {
  return JSON.stringify({ n: base64(g.nonce), c: base64(g.daten) });
}

function ausGeheimtextJson(text: string): { nonce: Bytes; daten: Bytes } | null {
  try {
    const j = JSON.parse(text);
    if (typeof j?.n !== 'string' || typeof j?.c !== 'string') return null;
    return { nonce: vonBase64(j.n), daten: vonBase64(j.c) };
  } catch {
    return null;
  }
}

async function verpacken(schluessel: Bytes, inhalt: unknown, aad: string): Promise<string> {
  return geheimtextJson(await verschluesseln(schluessel, utf8(JSON.stringify(inhalt)), aad));
}

async function entpacken(schluessel: Bytes, text: string, aad: string): Promise<Record<string, unknown> | null> {
  const g = ausGeheimtextJson(text);
  if (!g) return null;
  const klar = await entschluesseln(schluessel, g.nonce, g.daten, aad);
  if (!klar) return null;
  try {
    return JSON.parse(vonUtf8(klar));
  } catch {
    return null;
  }
}

export class Kontoschluessel {
  private idSchluessel?: Promise<Bytes>;
  private blockIdSchluessel?: Promise<Bytes>;

  readonly bytes: Bytes;
  constructor(bytes: Bytes) {
    this.bytes = bytes;
  }

  static ausBase64(s: string): Kontoschluessel {
    return new Kontoschluessel(vonBase64(s));
  }

  /** Serverseitige ID eines Datensatzes (128 Bit HMAC, hex). */
  async objektId(bereich: string, id: string): Promise<string> {
    this.idSchluessel ??= hkdf(this.bytes, 'ptv2-sync-objekt-id-v1');
    return hex((await hmac(await this.idSchluessel, utf8(`${bereich}/${id}`))).subarray(0, 16));
  }

  /** Umschlag verschlüsseln; auf 256 Byte aufgefüllt wie in der App. */
  async verschluesseln(u: Umschlag): Promise<string> {
    const roh = utf8(JSON.stringify({ b: u.bereich, i: u.id, s: u.schema, d: u.daten }));
    const fuell = (256 - ((roh.length + 1) % 256)) % 256;
    const klar = new Uint8Array(roh.length + 1 + fuell);
    klar.set(roh);
    klar[roh.length] = 0x0a;
    const oid = await this.objektId(u.bereich, u.id);
    return geheimtextJson(await verschluesseln(this.bytes, klar, `ptv2-sync-objekt|${oid}`));
  }

  /** `null`, wenn der Geheimtext nicht zu Schlüssel und ID passt. */
  async entschluesseln(objektId: string, daten: string): Promise<Umschlag | null> {
    const g = ausGeheimtextJson(daten);
    if (!g) return null;
    const klar = await entschluesseln(this.bytes, g.nonce, g.daten, `ptv2-sync-objekt|${objektId}`);
    if (!klar) return null;
    try {
      const ende = klar.indexOf(0x0a);
      const j = JSON.parse(vonUtf8(ende < 0 ? klar : klar.subarray(0, ende)));
      const u: Umschlag = { bereich: j.b, id: j.i, schema: j.s, daten: j.d ?? null };
      if (typeof u.bereich !== 'string' || typeof u.id !== 'string' || typeof u.schema !== 'number') return null;
      return (await this.objektId(u.bereich, u.id)) === objektId ? u : null;
    } catch {
      return null;
    }
  }

  async geraetName(name: string): Promise<string> {
    return verpacken(this.bytes, { n: name }, 'ptv2-sync-geraetename-v1');
  }

  async geraetNameAus(text: string): Promise<string | null> {
    const j = await entpacken(this.bytes, text, 'ptv2-sync-geraetename-v1');
    return typeof j?.n === 'string' ? j.n : null;
  }

  /** Prüft, ob das Schlüsselpaket des Kontos zu diesem Schlüssel passt. */
  async passtZuPaket(paket: string): Promise<boolean> {
    return (await entpacken(this.bytes, paket, 'ptv2-sync-schluesselpaket-v1')) !== null;
  }

  async blockId(klar: Bytes): Promise<string> {
    this.blockIdSchluessel ??= hkdf(this.bytes, 'ptv2-vault-block-id-v1');
    return hex((await hmac(await this.blockIdSchluessel, klar)).subarray(0, 16));
  }

  async blockVerschluesseln(id: string, klar: Bytes): Promise<Bytes> {
    const laenge = Math.max(BLOCK_RASTER, Math.ceil(klar.length / BLOCK_RASTER) * BLOCK_RASTER);
    const gefuellt = new Uint8Array(laenge);
    gefuellt.set(klar);
    const g = await verschluesseln(this.bytes, gefuellt, `ptv2-vault-block|${id}`);
    const out = new Uint8Array(12 + g.daten.length);
    out.set(g.nonce);
    out.set(g.daten, 12);
    return out;
  }

  async blockEntschluesseln(id: string, daten: Bytes, groesse: number): Promise<Bytes | null> {
    if (daten.length < 28) return null;
    const klar = await entschluesseln(this.bytes, daten.slice(0, 12), daten.slice(12), `ptv2-vault-block|${id}`);
    if (!klar || klar.length < groesse) return null;
    const inhalt = klar.slice(0, groesse);
    return (await this.blockId(inhalt)) === id ? inhalt : null;
  }

  /** Datensatz einer Datei; große Inhalte als Blöcke (Klartext in [neueBloecke]). */
  /** [blockId] des Orts (Konto oder Raum); Standard: Konto. */
  async vaultDatei(
    id: string,
    pfad: string,
    inhalt: Bytes,
    geaendert: Date,
    neueBloecke?: Map<string, Bytes>,
    blockId: (k: Bytes) => Promise<string> = (k) => this.blockId(k),
  ): Promise<VaultDatei> {
    const basis = { id, pfad, groesse: inhalt.length, sha256: await sha256(inhalt), geaendert: geaendert.toISOString() };
    if (inhalt.length <= INLINE_GRENZE) return { ...basis, inhalt: base64(inhalt) };
    const bloecke: BlockRef[] = [];
    for (let i = 0; i < inhalt.length; i += BLOCK_GROESSE) {
      const teil = inhalt.slice(i, Math.min(i + BLOCK_GROESSE, inhalt.length));
      const bid = await blockId(teil);
      bloecke.push({ id: bid, groesse: teil.length });
      neueBloecke?.set(bid, teil);
    }
    return { ...basis, bloecke };
  }
}

/** Prüft einen Pfad vom Server; wirft bei allem, was aus dem Vault führt. */
export function vaultPfad(pfad: string): string {
  const p = pfad.replace(/\\/g, '/');
  const teile = p.split('/');
  if (
    p === '' ||
    p.startsWith('/') ||
    teile.some((t) => t === '' || t === '.' || t === '..') ||
    /[\x00-\x1f]/.test(p) ||
    /^[A-Za-z]:/.test(p)
  ) {
    throw new Error(`Ungültiger Vault-Pfad: ${pfad}`);
  }
  return p;
}

/** „Notiz (Konflikt 2026-11-24 1403 Handy).md“, bei Bedarf mit Zahl. */
export function konfliktPfad(pfad: string, zeit: Date, geraet: string, vergeben: (p: string) => boolean): string {
  const i = pfad.lastIndexOf('/');
  const ordner = i < 0 ? '' : pfad.slice(0, i + 1);
  const name = pfad.slice(i + 1);
  const p = name.lastIndexOf('.');
  const basis = p > 0 ? name.slice(0, p) : name;
  const endung = p > 0 ? name.slice(p) : '';
  const zwei = (n: number) => String(n).padStart(2, '0');
  const stempel = `${zeit.getFullYear()}-${zwei(zeit.getMonth() + 1)}-${zwei(zeit.getDate())} ${zwei(zeit.getHours())}${zwei(zeit.getMinutes())}`;
  const g = geraet.replace(/[\\/:*?"<>|\x00-\x1f]/g, '').trim();
  const kern = `${basis} (Konflikt ${stempel}${g ? ' ' + g : ''}`;
  let kandidat = `${ordner}${kern})${endung}`;
  for (let n = 2; vergeben(kandidat); n++) kandidat = `${ordner}${kern} ${n})${endung}`;
  return kandidat;
}

/** Pfade, die nicht synchronisiert werden (in der Vorschau sichtbar). */
export const AUSNAHMEN: { muster: RegExp; grund: string }[] = [
  { muster: /^\.stfolder(\/|$)|^\.stversions(\/|$)|^\.stignore$|^\.stfolder\.removed-/, grund: 'Syncthing-Verwaltung' },
  { muster: /^\.git(\/|$)/, grund: 'Git-Verwaltung' },
  { muster: /^\.trash(\/|$)/, grund: 'Obsidian-Papierkorb' },
  { muster: /^\.obsidian\/workspace(-mobile)?\.json$/, grund: 'Fensteranordnung je Gerät' },
  { muster: /^\.ptv2-sicherung(\/|$)/, grund: 'Sicherungen dieses Plugins' },
];

export function ausnahme(pfad: string): string | null {
  return AUSNAHMEN.find((a) => a.muster.test(pfad))?.grund ?? null;
}

const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/** Einmaliger Kopplungscode aus der App (20 Zeichen Crockford-Base32). */
export class Kopplungscode {
  readonly text: string;
  private constructor(text: string) {
    this.text = text;
  }

  static lesen(eingabe: string): Kopplungscode | null {
    const s = eingabe.toUpperCase().replace(/[\s\-_.]/g, '').replace(/O/g, '0').replace(/[IL]/g, '1');
    if (s.length !== 20 || [...s].some((c) => !ALPHABET.includes(c))) return null;
    return new Kopplungscode(s);
  }

  async slot(): Promise<string> {
    return hex(await hkdf(utf8(this.text), 'ptv2-kopplung-slot-v1'));
  }

  /** Öffnet das Kopplungspaket; [agent] enthält bei Agenten-Codes Name und Rechte. */
  async paketOeffnen(paket: string): Promise<{ konto: string; schluessel: Kontoschluessel; agent?: Record<string, unknown> } | null> {
    const k = await hkdf(utf8(this.text), 'ptv2-kopplung-paket-v1');
    const j = await entpacken(k, paket, `ptv2-kopplung|${await this.slot()}`);
    if (typeof j?.konto !== 'string' || typeof j?.k !== 'string') return null;
    return { konto: j.konto, schluessel: Kontoschluessel.ausBase64(j.k), agent: typeof j.agent === 'object' && j.agent ? (j.agent as Record<string, unknown>) : undefined };
  }
}

export function neueId(): string {
  const b = zufall(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = hex(b);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
