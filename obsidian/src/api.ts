// Client für den Sync-Vertrag v1 (server/API.md), nur was das Plugin
// braucht. Der Transport ist austauschbar: in Obsidian `requestUrl`
// (ohne CORS-Grenzen, auch mobil), in Tests `fetch`.

export interface Antwort {
  status: number;
  text: string;
  bytes: Uint8Array<ArrayBuffer>;
}

export type Transport = (anfrage: {
  url: string;
  methode: string;
  kopf: Record<string, string>;
  body?: string | Uint8Array<ArrayBuffer>;
}) => Promise<Antwort>;

export const fetchTransport: Transport = async ({ url, methode, kopf, body }) => {
  const r = await fetch(url, { method: methode, headers: kopf, body });
  const bytes = new Uint8Array(await r.arrayBuffer());
  return { status: r.status, bytes, text: new TextDecoder().decode(bytes) };
};

export type FehlerArt = 'netz' | 'anmeldung' | 'nichtGefunden' | 'version' | 'daten' | 'server' | 'kontingent';

export class SyncFehler extends Error {
  readonly art: FehlerArt;
  constructor(art: FehlerArt, meldung: string) {
    super(meldung);
    this.art = art;
  }
}

/** HTTPS Pflicht, HTTP nur für localhost (wie in der App). */
export function serverAdresse(eingabe: string): string {
  let t = eingabe.trim();
  if (!t) throw new SyncFehler('netz', 'Bitte eine Serveradresse eingeben.');
  if (!t.includes('://')) t = `https://${t}`;
  let u: URL;
  try {
    u = new URL(t);
  } catch {
    throw new SyncFehler('netz', 'Das ist keine gültige Serveradresse.');
  }
  if (!['https:', 'http:'].includes(u.protocol) || !u.hostname) throw new SyncFehler('netz', 'Das ist keine gültige Serveradresse.');
  if (u.protocol === 'http:' && !['localhost', '127.0.0.1', '[::1]'].includes(u.hostname)) {
    throw new SyncFehler('netz', 'Bitte eine HTTPS-Adresse verwenden. Unverschlüsselt (http) geht nur auf diesem Gerät (localhost).');
  }
  return `${u.protocol}//${u.host}${u.pathname.replace(/\/$/, '')}`;
}

export interface Objekt {
  id: string;
  seq: number;
  daten: string;
}

export class SyncApi {
  readonly basis: string;
  readonly token?: string;
  private readonly transport: Transport;

  constructor(basis: string, transport: Transport, token?: string) {
    this.basis = basis;
    this.transport = transport;
    this.token = token;
  }

  mitToken(token: string): SyncApi {
    return new SyncApi(this.basis, this.transport, token);
  }

  private async roh(methode: string, pfad: string, body?: string | Uint8Array<ArrayBuffer>, typ?: string): Promise<Antwort> {
    const kopf: Record<string, string> = {};
    if (this.token) kopf['authorization'] = `Bearer ${this.token}`;
    if (typ) kopf['content-type'] = typ;
    let a: Antwort;
    try {
      a = await this.transport({ url: this.basis + pfad, methode, kopf, body });
    } catch {
      throw new SyncFehler('netz', 'Server nicht erreichbar. Bist du online und stimmt die Adresse?');
    }
    if (a.status >= 200 && a.status < 300) return a;
    let meldung = `Serverfehler ${a.status}.`;
    let code = '';
    try {
      const j = JSON.parse(a.text);
      meldung = j.meldung ?? meldung;
      code = j.fehler ?? '';
    } catch {
      // keine JSON-Antwort
    }
    const art: FehlerArt =
      a.status === 401 ? 'anmeldung' : a.status === 404 ? 'nichtGefunden' : code === 'kontingent' ? 'kontingent' : 'server';
    throw new SyncFehler(art, a.status === 401 ? 'Dieses Gerät ist beim Server nicht mehr angemeldet.' : meldung);
  }

  private async json(methode: string, pfad: string, body?: unknown): Promise<any> {
    const a = await this.roh(methode, pfad, body === undefined ? undefined : JSON.stringify(body), body === undefined ? undefined : 'application/json');
    try {
      return a.text ? JSON.parse(a.text) : {};
    } catch {
      throw new SyncFehler('server', 'Unerwartete Antwort. Ist das ein Personal-Tracker-Server?');
    }
  }

  async info(): Promise<{ version: string }> {
    const j = await this.json('GET', '/v1/info');
    if (j.dienst !== 'personal-tracker-sync') throw new SyncFehler('server', 'Unter dieser Adresse läuft kein Personal-Tracker-Server.');
    if (j.api !== 1) throw new SyncFehler('version', `Der Server spricht API-Version ${j.api}, das Plugin Version 1.`);
    const [major, minor] = String(j.version).split('.').map(Number);
    if (major < 1 || (major === 1 && minor < 1)) {
      throw new SyncFehler('version', `Der Server (${j.version}) kann noch keine Dateien speichern. Bitte auf Version 1.1 oder neuer aktualisieren.`);
    }
    return j;
  }

  kopplungEinloesen(slot: string, geraetName: string): Promise<{ konto: string; paket: string; geraet: string; token: string }> {
    return this.json('POST', `/v1/kopplungen/${slot}/einloesen`, { geraetName });
  }

  konto(): Promise<any> {
    return this.json('GET', '/v1/konto');
  }

  async geraetUmbenennen(id: string, name: string): Promise<void> {
    await this.json('PUT', `/v1/geraete/${id}`, { name });
  }

  async geraetEntfernen(id: string): Promise<void> {
    await this.json('DELETE', `/v1/geraete/${id}`);
  }

  /** Pfad der Objekte und Blöcke: eigenes Konto oder geteilter Raum. */
  private ort(raum?: string): string {
    return raum ? `/v1/raeume/${raum}` : '/v1';
  }

  abrufen(seit: number, max?: number, raum?: string): Promise<{ objekte: Objekt[]; bis: number; mehr: boolean }> {
    return this.json('GET', `${this.ort(raum)}/objekte?seit=${seit}${max ? `&max=${max}` : ''}`);
  }

  /** Bei einem Konflikt liefert der Server seine Fassung mit (`daten`). */
  async schreiben(
    aenderungen: { id: string; basis: number; aenderung: string; daten: string }[],
    raum?: string,
  ): Promise<{ id: string; ok: boolean; seq: number; daten?: string }[]> {
    const j = await this.json('POST', `${this.ort(raum)}/objekte`, { aenderungen });
    return j.ergebnisse.map((e: any) => ({ id: e.id, ok: e.status === 'ok', seq: e.seq, daten: e.daten }));
  }

  async blockSchreiben(id: string, daten: Uint8Array<ArrayBuffer>, raum?: string): Promise<void> {
    await this.roh('PUT', `${this.ort(raum)}/bloecke/${id}`, daten, 'application/octet-stream');
  }

  async blockLesen(id: string, raum?: string): Promise<Uint8Array<ArrayBuffer>> {
    return (await this.roh('GET', `${this.ort(raum)}/bloecke/${id}`)).bytes;
  }

  async bloeckeFehlend(ids: string[], raum?: string): Promise<string[]> {
    const fehlend: string[] = [];
    for (let i = 0; i < ids.length; i += 5000) fehlend.push(...(await this.json('POST', `${this.ort(raum)}/bloecke/fehlend`, { ids: ids.slice(i, i + 5000) })).fehlend);
    return fehlend;
  }

  async bloeckeAufraeumen(behalten: string[], raum?: string): Promise<number> {
    return (await this.json('POST', `${this.ort(raum)}/bloecke/aufraeumen`, { behalten })).geloescht;
  }

  /** Eigene und geteilte Räume (Server ab 1.2.0). */
  async raeume(): Promise<{ id: string; recht: string; paket?: string }[]> {
    return (await this.json('GET', '/v1/raeume')).raeume;
  }
}
