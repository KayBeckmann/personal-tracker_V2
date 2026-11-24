import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';

import { fetchTransport, SyncApi } from '../src/api.ts';
import { leererZustand, VaultAbgleich } from '../src/abgleich.ts';
import { zufall } from '../src/krypto.ts';
import { koppeln } from '../src/verbinden.ts';
import { appKonto, SpeicherFs, TestServer } from './hilfen.ts';

const server = new TestServer();
before(() => server.starten());
after(() => server.stoppen());

class Geraet {
  fs = new SpeicherFs();
  z = leererZustand();
  uhr = new Date(2026, 10, 24, 14, 3);
  maxBytes = 100 * 1024 * 1024;
  a = new VaultAbgleich(this.fs, this.z, (v) => new SyncApi(v.server, fetchTransport, v.token), () => ({ maxBytes: this.maxBytes }), () => this.uhr);

  async verbinden(code: string, name: string): Promise<void> {
    this.z.verbindung = await koppeln(server.adresse, code, name, fetchTransport);
  }
  async einrichten(): Promise<void> {
    this.z.eingerichtet = true;
    await this.sync();
  }
  async sync() {
    const b = await this.a.abgleichen();
    assert.equal(b.defekt, 0);
    return b;
  }
}

async function zwei(): Promise<{ p1: Geraet; p2: Geraet; app: Awaited<ReturnType<typeof appKonto>> }> {
  const app = await appKonto(server.adresse);
  const p1 = new Geraet();
  const p2 = new Geraet();
  await p1.verbinden(await app.code(), 'Laptop');
  await p2.verbinden(await app.code(), 'Handy');
  return { p1, p2, app };
}

test('Kopplungscode: falsch, verbraucht, richtig', async () => {
  const app = await appKonto(server.adresse);
  const g = new Geraet();
  await assert.rejects(g.verbinden('kurz', 'x'), /20 Zeichen/);
  const code = await app.code();
  await g.verbinden(code, 'Laptop');
  await assert.rejects(new Geraet().verbinden(code, 'y'), /unbekannt oder abgelaufen/);
  const k = await app.api.konto();
  assert.equal(k.geraete.length, 2);
});

test('Vorschau ändert nichts; nach dem Einrichten ist alles beim anderen Gerät', async () => {
  const { p1, p2 } = await zwei();
  p1.fs.setze('Start.md', '# Start\n[[Projekte/Plan]]');
  p1.fs.setze('Projekte/Plan.md', 'Plan');
  p1.fs.setze('.obsidian/app.json', '{"livePreview":true}');
  p1.fs.setze('.obsidian/workspace.json', '{}');
  p1.fs.setze('.git/HEAD', 'ref: refs/heads/main');
  p1.fs.setze('Zugang.md', 'Passwort: Pferd-Batterie-77');
  p1.fs.setze('bild.png', zufall(200 * 1024));
  p1.maxBytes = 100 * 1024;

  const v = await p1.a.vorschau();
  assert.deepEqual(v.hochladen, ['.obsidian/app.json', 'Projekte/Plan.md', 'Start.md']);
  assert.deepEqual(v.gesperrt.map((x) => [x.pfad, x.treffer[0].zeile]), [['Zugang.md', 1]]);
  assert.deepEqual(v.zuGross, ['bild.png']);
  assert.deepEqual(v.ausgenommen.map((x) => x.pfad), ['.git/HEAD', '.obsidian/workspace.json']);
  assert.equal((await p1.a.vorschau()).hochladen.length, 3);
  // Nichts hochgeladen, solange nicht eingerichtet.
  await assert.rejects(p1.a.abgleichen(), /nicht eingerichtet/);

  const b = await (async () => {
    p1.z.eingerichtet = true;
    return p1.sync();
  })();
  assert.equal(b.gesendet, 3);
  assert.equal(b.gesperrt.size, 1);
  assert.deepEqual(b.zuGross, ['bild.png']);

  // Zweites Gerät mit teils gleichen, teils anderen Dateien.
  p2.fs.setze('Projekte/Plan.md', 'Plan');
  p2.fs.setze('Start.md', 'anderer Start');
  p2.fs.setze('Nur-hier.md', 'nur auf dem Handy');
  const v2 = await p2.a.vorschau();
  assert.deepEqual(v2.gleich, ['Projekte/Plan.md']);
  assert.deepEqual(v2.konflikte, ['Start.md']);
  assert.deepEqual(v2.herunterladen, ['.obsidian/app.json']);
  await p2.einrichten();
  assert.deepEqual(p2.fs.pfade(), ['.obsidian/app.json', 'Nur-hier.md', 'Projekte/Plan.md', 'Start (Konflikt 2026-11-24 1403 Handy).md', 'Start.md']);
  assert.equal(p2.fs.text('Start.md'), '# Start\n[[Projekte/Plan]]');
  assert.equal(p2.fs.text('Start (Konflikt 2026-11-24 1403 Handy).md'), 'anderer Start');
  await p1.sync();
  assert.deepEqual(p1.fs.pfade(), ['.git/HEAD', '.obsidian/app.json', '.obsidian/workspace.json', 'Nur-hier.md', 'Projekte/Plan.md', 'Start (Konflikt 2026-11-24 1403 Handy).md', 'Start.md', 'Zugang.md', 'bild.png']);
  assert.equal(p2.a.ausstehend, 0);
});

test('Verschieben, Ändern, Löschen und Konflikte zwischen zwei Plugins', async () => {
  const { p1, p2 } = await zwei();
  p1.fs.setze('Notiz.md', 'eins');
  p1.fs.setze('Weg.md', 'weg');
  p1.fs.setze('Bleibt.md', 'alt');
  await p1.einrichten();
  await p2.einrichten();
  assert.deepEqual(p2.fs.pfade(), ['Bleibt.md', 'Notiz.md', 'Weg.md']);

  // Verschieben hier, Ändern dort: beides gilt.
  await p1.fs.verschieben('Notiz.md', 'Archiv/Notiz.md');
  p1.a.umbenannt.set('Notiz.md', 'Archiv/Notiz.md');
  p2.fs.setze('Notiz.md', 'zwei');
  // Löschen hier, Ändern dort: Änderung bleibt. Löschen ohne Gegenänderung: weg.
  await p1.fs.papierkorb('Bleibt.md');
  p2.fs.setze('Bleibt.md', 'neu');
  await p2.fs.papierkorb('Weg.md');
  await p1.sync();
  await p2.sync();
  await p1.sync();
  for (const p of [p1, p2]) {
    assert.deepEqual(p.fs.pfade(), ['Archiv/Notiz.md', 'Bleibt.md']);
    assert.equal(p.fs.text('Archiv/Notiz.md'), 'zwei');
    assert.equal(p.fs.text('Bleibt.md'), 'neu');
  }
  assert.ok(p1.fs.papierkorbInhalt.has('Weg.md'), 'gelöschte Datei liegt im Papierkorb');

  // Gleichzeitig verschieden geändert: Serverfassung gilt, die andere als Kopie.
  p1.fs.setze('Bleibt.md', 'Fassung Laptop');
  p2.fs.setze('Bleibt.md', 'Fassung Handy');
  await p1.sync();
  const b = await p2.sync();
  assert.deepEqual(b.konflikte, ['Bleibt (Konflikt 2026-11-24 1403 Handy).md']);
  await p1.sync();
  for (const p of [p1, p2]) {
    assert.equal(p.fs.text('Bleibt.md'), 'Fassung Laptop');
    assert.equal(p.fs.text('Bleibt (Konflikt 2026-11-24 1403 Handy).md'), 'Fassung Handy');
  }
});

test('Große Dateien in Blöcken, byte-genau; Secret-Freigabe gilt nur für den Inhalt', async () => {
  const { p1, p2 } = await zwei();
  const gross = zufall(2 * 1024 * 1024 + 123);
  p1.fs.setze('Anhang/video.bin', gross);
  p1.fs.setze('Zugang.md', 'token: abcdefgh12345678');
  await p1.einrichten();
  await p2.einrichten();
  assert.deepEqual(await p2.fs.lesen('Anhang/video.bin'), gross);
  assert.equal(p2.fs.text('Zugang.md'), undefined);

  p1.a.freigeben('Zugang.md');
  await p1.sync();
  await p2.sync();
  assert.equal(p2.fs.text('Zugang.md'), 'token: abcdefgh12345678');

  p1.fs.setze('Zugang.md', 'token: andererwert99');
  const b = await p1.sync();
  assert.equal(b.gesperrt.size, 1);
  assert.equal(JSON.stringify([...b.gesperrt.values()]).includes('andererwert'), false);
  await p2.sync();
  assert.equal(p2.fs.text('Zugang.md'), 'token: abcdefgh12345678');
});

test('Dateien, die während des Abgleichs geändert werden, werden nicht überschrieben', async () => {
  const { p1, p2 } = await zwei();
  p1.fs.setze('a.md', 'eins');
  await p1.einrichten();
  await p2.einrichten();
  p1.fs.setze('a.md', 'zwei');
  await p1.sync();
  // p2 sieht durch, dann tippt der Nutzer, bevor eingespielt wird.
  const echt = p2.fs.liste.bind(p2.fs);
  p2.fs.liste = async () => {
    const l = await echt();
    p2.fs.setze('a.md', 'getippt');
    return l;
  };
  const b = await p2.sync();
  p2.fs.liste = echt;
  assert.equal(b.uebersprungen > 0, true);
  assert.equal(p2.fs.text('a.md'), 'getippt');
  await p2.sync();
  await p1.sync();
  // Danach normaler Konflikt: nichts geht verloren.
  const alle = [...p1.fs.pfade()].map((p) => p1.fs.text(p));
  assert.deepEqual(alle.sort(), ['getippt', 'zwei']);
});
