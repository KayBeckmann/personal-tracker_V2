// Test-Hilfen: echter Sync-Server (Dart) auf einem freien Port, ein
// Vault-Ordner im Speicher und ein Konto wie von der App angelegt.

import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:net';

import { fetchTransport, SyncApi } from '../src/api.ts';
import type { DateiInfo, Dateisystem } from '../src/abgleich.ts';
import { base64, base64Url, hex, hkdf, utf8, verschluesseln, zufall } from '../src/krypto.ts';
import { Kontoschluessel } from '../src/protokoll.ts';

type Bytes = Uint8Array<ArrayBuffer>;

async function freierPort(): Promise<number> {
  return new Promise((ok) => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => {
      const p = (s.address() as { port: number }).port;
      s.close(() => ok(p));
    });
  });
}

export class TestServer {
  prozess?: ChildProcess;
  ordner = mkdtempSync(join(tmpdir(), 'ptv2-plugin-'));
  adresse = '';

  async starten(): Promise<void> {
    const port = await freierPort();
    this.adresse = `http://127.0.0.1:${port}`;
    this.prozess = spawn('dart', ['run', 'bin/server.dart'], {
      cwd: new URL('../../server', import.meta.url).pathname,
      env: { ...process.env, PT_PORT: String(port), PT_DB: join(this.ordner, 'sync.db') },
      stdio: ['ignore', 'pipe', 'inherit'],
    });
    for (let i = 0; i < 200; i++) {
      try {
        if ((await fetch(`${this.adresse}/v1/info`)).ok) return;
      } catch {
        // startet noch
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error('Server startet nicht');
  }

  stoppen(): void {
    this.prozess?.kill('SIGTERM');
    rmSync(this.ordner, { recursive: true, force: true });
  }
}

async function verpacken(schluessel: Bytes, inhalt: unknown, aad: string): Promise<string> {
  const g = await verschluesseln(schluessel, utf8(JSON.stringify(inhalt)), aad);
  return JSON.stringify({ n: base64(g.nonce), c: base64(g.daten) });
}

/** Konto wie von der App angelegt; liefert eine Funktion für Kopplungscodes. */
export async function appKonto(adresse: string): Promise<{ ks: Kontoschluessel; api: SyncApi; code: () => Promise<string> }> {
  const ks = new Kontoschluessel(zufall(32));
  const api = new SyncApi(adresse, fetchTransport);
  const r = await fetch(`${adresse}/v1/konten`, {
    method: 'POST',
    body: JSON.stringify({
      recoveryAuth: base64Url(zufall(32)),
      recoveryHuelle: 'H',
      schluesselPaket: await verpacken(ks.bytes, { huelle: '', backup: '', kennung: 'x' }, 'ptv2-sync-schluesselpaket-v1'),
      geraetName: await ks.geraetName('App'),
    }),
  });
  const j = await r.json();
  const mit = api.mitToken(j.token);
  const code = async () => {
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    const text = [...zufall(20)].map((b) => alphabet[b & 31]).join('');
    const slot = hex(await hkdf(utf8(text), 'ptv2-kopplung-slot-v1'));
    const paket = await verpacken(await hkdf(utf8(text), 'ptv2-kopplung-paket-v1'), { konto: j.konto, k: base64(ks.bytes) }, `ptv2-kopplung|${slot}`);
    await fetch(`${adresse}/v1/kopplungen`, {
      method: 'POST',
      headers: { authorization: `Bearer ${j.token}` },
      body: JSON.stringify({ slot, paket, gueltigSekunden: 600 }),
    });
    return text;
  };
  return { ks, api: mit, code };
}

/** Vault-Ordner im Speicher mit Papierkorb; Zeitstempel zählen hoch. */
export class SpeicherFs implements Dateisystem {
  dateien = new Map<string, { daten: Bytes; mtime: number }>();
  papierkorbInhalt = new Map<string, Bytes>();
  private uhr = 1000;

  setze(pfad: string, text: string | Bytes): void {
    this.dateien.set(pfad, { daten: typeof text === 'string' ? utf8(text) : text, mtime: ++this.uhr });
  }

  text(pfad: string): string | undefined {
    const d = this.dateien.get(pfad);
    return d && new TextDecoder().decode(d.daten);
  }

  pfade(): string[] {
    return [...this.dateien.keys()].sort();
  }

  async liste(): Promise<DateiInfo[]> {
    return [...this.dateien].map(([pfad, d]) => ({ pfad, groesse: d.daten.length, mtime: d.mtime }));
  }
  async stat(pfad: string): Promise<DateiInfo | null> {
    const d = this.dateien.get(pfad);
    return d ? { pfad, groesse: d.daten.length, mtime: d.mtime } : null;
  }
  async lesen(pfad: string): Promise<Bytes> {
    const d = this.dateien.get(pfad);
    if (!d) throw new Error(`fehlt: ${pfad}`);
    return d.daten;
  }
  async schreiben(pfad: string, daten: Bytes): Promise<DateiInfo> {
    this.setze(pfad, daten);
    return (await this.stat(pfad))!;
  }
  async verschieben(alt: string, neu: string): Promise<DateiInfo> {
    const d = this.dateien.get(alt)!;
    this.dateien.delete(alt);
    this.dateien.set(neu, d);
    return (await this.stat(neu))!;
  }
  async papierkorb(pfad: string): Promise<void> {
    this.papierkorbInhalt.set(pfad, this.dateien.get(pfad)!.daten);
    this.dateien.delete(pfad);
  }
}

// ---------------------------------------------------------------------
// Räume wie von der App angelegt (protokoll/RAEUME.md), für Plugin-Tests.

async function kontoObjekt(adresse: string, token: string, ks: Kontoschluessel, bereich: string, id: string, daten: unknown, basis = 0): Promise<void> {
  const r = await fetch(`${adresse}/v1/objekte`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}` },
    body: JSON.stringify({
      aenderungen: [
        {
          id: await ks.objektId(bereich, id),
          basis,
          aenderung: base64(zufall(8)),
          daten: await ks.verschluesseln({ bereich, id, schema: 5, daten: daten as Record<string, unknown> | null }),
        },
      ],
    }),
  });
  const j = await r.json();
  if (j.ergebnisse[0].status !== 'ok') throw new Error('Objekt nicht geschrieben');
}

export interface AppKonto {
  ks: Kontoschluessel;
  token: string;
  konto: string;
  code: () => Promise<string>;
}

/** Konto mit Token (für Räume), wie `appKonto`. */
export async function appKontoMitToken(adresse: string): Promise<AppKonto> {
  const ks = new Kontoschluessel(zufall(32));
  const r = await fetch(`${adresse}/v1/konten`, {
    method: 'POST',
    body: JSON.stringify({
      recoveryAuth: base64Url(zufall(32)),
      recoveryHuelle: 'H',
      schluesselPaket: await verpacken(ks.bytes, { huelle: '', backup: '', kennung: 'x' }, 'ptv2-sync-schluesselpaket-v1'),
      geraetName: await ks.geraetName('App'),
    }),
  });
  const j = await r.json();
  const code = async () => {
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    const text = [...zufall(20)].map((b) => alphabet[b & 31]).join('');
    const slot = hex(await hkdf(utf8(text), 'ptv2-kopplung-slot-v1'));
    const paket = await verpacken(await hkdf(utf8(text), 'ptv2-kopplung-paket-v1'), { konto: j.konto, k: base64(ks.bytes) }, `ptv2-kopplung|${slot}`);
    await fetch(`${adresse}/v1/kopplungen`, { method: 'POST', headers: { authorization: `Bearer ${j.token}` }, body: JSON.stringify({ slot, paket, gueltigSekunden: 600 }) });
    return text;
  };
  return { ks, token: j.token, konto: j.konto, code };
}

/** Eigentümer legt einen geteilten Vault-Ordner an und lädt [mitglieder] ein. */
export async function vaultRaum(
  adresse: string,
  eig: AppKonto,
  ordner: string,
  mitglieder: { konto: AppKonto; recht: 'lesen' | 'schreiben'; ordner: string }[],
): Promise<{ id: string; json: Record<string, unknown>; beenden: () => Promise<void>; entfernen: (m: AppKonto) => Promise<void> }> {
  const id = hex(zufall(16));
  const json: Record<string, unknown> = {
    id,
    art: 'vault',
    name: 'Familie',
    recht: 'eigentuemer',
    von: 'Kay',
    idSchluessel: base64(zufall(32)),
    schluessel: { '1': base64(zufall(32)) },
    epoche: 1,
    ordner,
  };
  await fetch(`${adresse}/v1/raeume`, { method: 'POST', headers: { authorization: `Bearer ${eig.token}` }, body: JSON.stringify({ id }) });
  await kontoObjekt(adresse, eig.token, eig.ks, 'raeume', id, json);
  for (const m of mitglieder) {
    const paar = zufall(32);
    const slot = hex(zufall(32));
    const mitgliedPaket = await verpacken(paar, { epoche: 1, schluessel: json.schluessel }, `ptv2-raum-mitglied|${id}`);
    await fetch(`${adresse}/v1/raeume/${id}/einladungen`, {
      method: 'POST',
      headers: { authorization: `Bearer ${eig.token}` },
      body: JSON.stringify({ slot, recht: m.recht, paket: 'p', mitgliedPaket, gueltigSekunden: 600 }),
    });
    await fetch(`${adresse}/v1/einladungen/${slot}/annehmen`, { method: 'POST', headers: { authorization: `Bearer ${m.konto.token}` }, body: JSON.stringify({ antwort: 'a' }) });
    await kontoObjekt(adresse, m.konto.token, m.konto.ks, 'raeume', id, { ...json, recht: m.recht, paar: base64(paar), ordner: m.ordner });
  }
  return {
    id,
    json,
    beenden: async () => {
      await fetch(`${adresse}/v1/raeume/${id}`, { method: 'DELETE', headers: { authorization: `Bearer ${eig.token}` } });
    },
    entfernen: async (m: AppKonto) => {
      await fetch(`${adresse}/v1/raeume/${id}/mitglieder/${m.konto}`, { method: 'DELETE', headers: { authorization: `Bearer ${eig.token}` } });
    },
  };
}
