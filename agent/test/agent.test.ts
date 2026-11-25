import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';

import { fetchTransport } from '../../obsidian/src/api.ts';
import { base64, hex, hkdf, utf8, verschluesseln, zufall } from '../../obsidian/src/krypto.ts';
import { neueId } from '../../obsidian/src/protokoll.ts';
import { appKontoMitToken, TestServer, vaultRaum, type AppKonto } from '../../obsidian/test/hilfen.ts';
import { koppeln, mcpServer } from '../src/main.ts';
import { laden, speichern, type Zugang } from '../src/zugang.ts';

const server = new TestServer();
before(() => server.starten());
after(() => server.stoppen());

async function verpacken(k: Uint8Array<ArrayBuffer>, inhalt: unknown, aad: string): Promise<string> {
  const g = await verschluesseln(k, utf8(JSON.stringify(inhalt)), aad);
  return JSON.stringify({ n: base64(g.nonce), c: base64(g.daten) });
}

/** Wie die App: Agenten-Kopplungscode mit Name und Rechten im Paket. */
async function agentCode(app: AppKonto, rechte: Record<string, string>, tage?: number): Promise<string> {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  const text = [...zufall(20)].map((b) => alphabet[b & 31]).join('');
  const slot = hex(await hkdf(utf8(text), 'ptv2-kopplung-slot-v1'));
  const paket = await verpacken(
    await hkdf(utf8(text), 'ptv2-kopplung-paket-v1'),
    { konto: app.konto, k: base64(app.ks.bytes), agent: { id: neueId(), name: 'Claude', rechte } },
    `ptv2-kopplung|${slot}`,
  );
  const r = await fetch(`${server.adresse}/v1/kopplungen`, {
    method: 'POST',
    headers: { authorization: `Bearer ${app.token}` },
    body: JSON.stringify({ slot, paket, gueltigSekunden: 600, art: 'agent', ...(tage ? { geraetAblaufTage: tage } : {}) }),
  });
  assert.equal(r.status, 201);
  return text;
}

async function objekt(app: AppKonto, bereich: string, daten: Record<string, unknown>): Promise<void> {
  const id = daten.id as string;
  const r = await fetch(`${server.adresse}/v1/objekte`, {
    method: 'POST',
    headers: { authorization: `Bearer ${app.token}` },
    body: JSON.stringify({
      aenderungen: [{ id: await app.ks.objektId(bereich, id), basis: 0, aenderung: neueId(), daten: await app.ks.verschluesseln({ bereich, id, schema: 7, daten }) }],
    }),
  });
  assert.equal((await r.json()).ergebnisse[0].status, 'ok');
}

/** Alle Objekte des Kontos entschlüsselt (wie die App sie sähe). */
async function kontoInhalt(app: AppKonto): Promise<{ bereich: string; daten: any }[]> {
  const r = await (await fetch(`${server.adresse}/v1/objekte?seit=0`, { headers: { authorization: `Bearer ${app.token}` } })).json();
  const out = [];
  for (const o of r.objekte) {
    const u = await app.ks.entschluesseln(o.id, o.daten);
    if (u?.daten) out.push({ bereich: u.bereich, daten: u.daten });
  }
  return out;
}

async function verbunden(z: Zugang): Promise<Client> {
  const { server: s } = await mcpServer(z);
  const [a, b] = InMemoryTransport.createLinkedPair();
  const c = new Client({ name: 'test', version: '1' });
  await Promise.all([s.connect(a), c.connect(b)]);
  return c;
}

const text = (r: any) => r.content[0].text as string;

test('Nur Agenten-Codes; ein normaler Geräte-Code wird abgelehnt und sofort abgemeldet', async () => {
  const app = await appKontoMitToken(server.adresse);
  await assert.rejects(koppeln(server.adresse, await app.code(), fetchTransport), /kein Agenten-Code/);
  const k = await (await fetch(`${server.adresse}/v1/konto`, { headers: { authorization: `Bearer ${app.token}` } })).json();
  assert.equal(k.geraete.length, 1, 'das eingelöste Gerät wurde wieder entfernt');
});

test('Rechte bestimmen die Werkzeuge; Lesen, Schreiben, Vorschläge und Protokoll ohne Inhalte', async () => {
  const app = await appKontoMitToken(server.adresse);
  await objekt(app, 'notizen', { id: 'n1', titel: 'Garten', text: '# Ideen\n- Hochbeet bauen', erstellt: '2026-11-01T10:00:00Z', geaendert: '2026-11-01T10:00:00Z' });
  await objekt(app, 'konten', { id: 'giro', name: 'Giro', art: 'bank', anfangssaldoCent: 100000, archiviert: false, geaendert: '2026-11-01T10:00:00Z' });
  await objekt(app, 'buchungen', { id: 'b1', kontoId: 'giro', datum: '2026-11-20', empfaenger: 'Bäckerei', betragCent: -450, status: 'gebucht', geaendert: '2026-11-20T10:00:00Z' });
  const z = await koppeln(server.adresse, await agentCode(app, { notizen: 'lesen', termine: 'schreiben', haushaltsbuch: 'lesen' }), fetchTransport);
  const c = await verbunden(z);
  const namen = (await c.listTools()).tools.map((t) => t.name).sort();
  assert.deepEqual(namen, ['buchungen_suchen', 'konten_auflisten', 'notiz_lesen', 'notizen_suchen', 'termin_aendern', 'termin_anlegen', 'termin_loeschen', 'termine_suchen']);

  // Lesen.
  const n = JSON.parse(text(await c.callTool({ name: 'notizen_suchen', arguments: { text: 'hochbeet' } })));
  assert.equal(n[0].titel, 'Garten');
  const k = JSON.parse(text(await c.callTool({ name: 'konten_auflisten', arguments: {} })));
  assert.equal(k[0].standCent, 100000 - 450);
  // Ohne Recht gibt es das Werkzeug nicht.
  const verboten = await c.callTool({ name: 'notiz_anlegen', arguments: { titel: 'x', text: 'y' } }).catch((e) => e);
  assert.ok(verboten instanceof Error || (verboten as any).isError);

  // Schreiben: Termin wie in der App lesbar.
  const t = JSON.parse(text(await c.callTool({ name: 'termin_anlegen', arguments: { titel: 'Zahnarzt', beginn: '2026-12-03T09:30', ende: '2026-12-03T10:00' } })));
  let inhalt = await kontoInhalt(app);
  const termin = inhalt.find((x) => x.bereich === 'termine')!.daten;
  assert.deepEqual({ titel: termin.titel, beginn: termin.beginn, ende: termin.ende, ganztaegig: termin.ganztaegig }, { titel: 'Zahnarzt', beginn: '2026-12-03T09:30', ende: '2026-12-03T10:00', ganztaegig: false });
  // Ungültige Eingabe wird abgewiesen.
  const falsch = await c.callTool({ name: 'termin_anlegen', arguments: { titel: 'x', beginn: 'morgen' } }).catch((e) => e);
  assert.ok(falsch instanceof Error || (falsch as any).isError);

  // Löschen ist nur ein Vorschlag.
  assert.match(text(await c.callTool({ name: 'termin_loeschen', arguments: { id: t.angelegt.id } })), /Vorschlag angelegt/);
  inhalt = await kontoInhalt(app);
  assert.ok(inhalt.some((x) => x.bereich === 'termine' && x.daten.id === t.angelegt.id), 'der Termin bleibt');
  const v = inhalt.find((x) => x.bereich === 'agent_vorschlaege')!.daten;
  assert.equal(v.art, 'loeschen');
  assert.equal(v.zielId, t.angelegt.id);
  assert.equal(v.status, 'offen');

  // Protokoll: jede Nutzung, ohne Inhalte.
  const p = inhalt.filter((x) => x.bereich === 'agent_protokoll').map((x) => x.daten);
  assert.deepEqual(p.map((x) => x.werkzeug).sort(), ['konten_auflisten', 'notizen_suchen', 'termin_anlegen', 'termine_loeschen'].sort());
  assert.ok(!JSON.stringify(p).includes('Hochbeet') && !JSON.stringify(p).includes('Zahnarzt'));
});

test('Vault: Secrets werden nicht geschrieben; geteilte Dateien nur lesbar', async () => {
  const app = await appKontoMitToken(server.adresse);
  const lena = await appKontoMitToken(server.adresse);
  const z = await koppeln(server.adresse, await agentCode(app, { vault: 'schreiben' }), fetchTransport);
  const c = await verbunden(z);
  const s = await c.callTool({ name: 'vault_schreiben', arguments: { pfad: 'Zugang.md', inhalt: 'Passwort: Pferd-Batterie-77' } });
  assert.ok((s as any).isError);
  assert.match(text(s), /Passwort- oder Token-Zuweisung/);
  assert.ok(!text(s).includes('Pferd'));
  assert.equal(text(await c.callTool({ name: 'vault_schreiben', arguments: { pfad: 'Ideen/Neu.md', inhalt: '# Neu\nvom Agenten' } })), 'Angelegt.');
  assert.equal(text(await c.callTool({ name: 'vault_lesen', arguments: { pfad: 'Ideen/Neu.md' } })), '# Neu\nvom Agenten');
  // Lena teilt einen Ordner mit Kay (Schreibrecht); der Agent liest, schreibt aber nicht hinein.
  const raum = await vaultRaum(server.adresse, lena, 'Familie', [{ konto: app, recht: 'schreiben', ordner: 'Geteilt/Familie' }]);
  const rr = await fetch(`${server.adresse}/v1/raeume/${raum.id}/objekte`, {
    method: 'POST',
    headers: { authorization: `Bearer ${lena.token}` },
    body: JSON.stringify({ aenderungen: [] }),
  });
  assert.equal(rr.status, 200);
  const c2 = await verbunden(z);
  const treffer = JSON.parse(text(await c2.callTool({ name: 'vault_suchen', arguments: {} })));
  assert.deepEqual(treffer.map((x: any) => x.pfad), ['Ideen/Neu.md']);
});

test('Widerruf und Ablauf: danach scheitert jeder Aufruf', async () => {
  const app = await appKontoMitToken(server.adresse);
  const z = await koppeln(server.adresse, await agentCode(app, { aufgaben: 'schreiben' }, 30), fetchTransport);
  const c = await verbunden(z);
  assert.equal((await c.callTool({ name: 'aufgabe_anlegen', arguments: { titel: 'Test' } }) as any).isError, undefined);
  // Die App entfernt das Agenten-Gerät.
  await fetch(`${server.adresse}/v1/geraete/${z.geraet}`, { method: 'DELETE', headers: { authorization: `Bearer ${app.token}` } });
  const r = await c.callTool({ name: 'aufgaben_suchen', arguments: {} });
  assert.ok((r as any).isError);
  assert.match(text(r), /nicht mehr angemeldet/);
});

test('Zugangsdatei: verschlüsselt, falsche Passphrase scheitert; echter MCP-Client über stdio', async () => {
  const app = await appKontoMitToken(server.adresse);
  await objekt(app, 'aufgaben', { id: 'a1', titel: 'Mülltonne raus', prioritaet: 'hoch', geaendert: '2026-11-20T10:00:00Z' });
  const z = await koppeln(server.adresse, await agentCode(app, { aufgaben: 'lesen' }), fetchTransport);
  const ordner = mkdtempSync(join(tmpdir(), 'pt-agent-'));
  const datei = join(ordner, 'zugang.json');
  try {
    speichern(z, 'eine gute passphrase', datei);
    const roh = readFileSync(datei, 'utf8');
    assert.ok(!roh.includes(z.token) && !roh.includes(z.schluessel) && !roh.includes('Claude'));
    assert.throws(() => laden('falsch falsch', datei), /Falsche Passphrase/);
    assert.equal(laden('eine gute passphrase', datei).token, z.token);

    // Gebaute Brücke als eigener Prozess, gesprochen wird reines MCP über stdio.
    const transport = new StdioClientTransport({
      command: process.execPath,
      args: [new URL('../dist/pt-agent.mjs', import.meta.url).pathname, 'mcp'],
      env: { ...process.env, PT_AGENT_DATEI: datei, PT_AGENT_PASSPHRASE: 'eine gute passphrase' } as Record<string, string>,
      stderr: 'pipe',
    });
    const c = new Client({ name: 'stdio-test', version: '1' });
    await c.connect(transport);
    assert.deepEqual((await c.listTools()).tools.map((t) => t.name), ['aufgaben_suchen']);
    const a = JSON.parse(text(await c.callTool({ name: 'aufgaben_suchen', arguments: {} })));
    assert.equal(a[0].titel, 'Mülltonne raus');
    await c.close();
  } finally {
    rmSync(ordner, { recursive: true, force: true });
  }
});
