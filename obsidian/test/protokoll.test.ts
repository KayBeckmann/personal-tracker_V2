import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { hex, hkdf, vonBase64 } from '../src/krypto.ts';
import { Kontoschluessel, Kopplungscode, konfliktPfad, vaultPfad, ausnahme, SCHEMA } from '../src/protokoll.ts';
import { pruefeText, pruefen } from '../src/secrets.ts';
import { Raum } from '../src/raum.ts';

const v = JSON.parse(readFileSync(new URL('../../protokoll/testvektoren.json', import.meta.url), 'utf8'));
const beispiele = JSON.parse(readFileSync(new URL('../../protokoll/secret-beispiele.json', import.meta.url), 'utf8'));

test('Plugin kennt die Schemaversion der App', () => {
  assert.equal(SCHEMA, v.schema, 'App-Schema geändert: SCHEMA in src/protokoll.ts anpassen');
});

test('Testvektoren der App: HKDF, Objekt-ID, Umschlag, Block, Gerätename, Kopplung', async () => {
  const ks = Kontoschluessel.ausBase64(v.kontoschluessel);
  assert.equal(hex(await hkdf(vonBase64(v.hkdf.material), v.hkdf.info)), v.hkdf.ergebnis);
  assert.equal(await ks.objektId('vault', 'datei-1'), v.objektId.ergebnis);
  const u = await ks.entschluesseln(v.umschlag.objektId, v.umschlag.daten);
  assert.equal((u?.daten as { pfad: string }).pfad, 'Ordner/Ä.md');
  assert.equal(await ks.entschluesseln('00' + v.umschlag.objektId.slice(2), v.umschlag.daten), null);
  const klar = vonBase64(v.block.klar);
  assert.equal(await ks.blockId(klar), v.block.id);
  assert.deepEqual(await ks.blockEntschluesseln(v.block.id, vonBase64(v.block.daten), klar.length), klar);
  assert.equal(await ks.geraetNameAus(v.geraetName.daten), 'Laptop');
  const c = Kopplungscode.lesen(v.kopplung.code)!;
  assert.equal(await c.slot(), v.kopplung.slot);
  assert.equal((await c.paketOeffnen(v.kopplung.paket))?.konto, 'konto-1');
  // Eigene Verschlüsselung ist für denselben Schlüssel wieder lesbar.
  const neu = await ks.verschluesseln({ bereich: 'vault', id: 'x', schema: 4, daten: { a: 1 } });
  assert.deepEqual((await ks.entschluesseln(await ks.objektId('vault', 'x'), neu))?.daten, { a: 1 });
  const geheim = await ks.blockVerschluesseln(v.block.id, klar);
  assert.equal(geheim.length, 12 + 4096 + 16);
});

test('Secret-Beispiele wie in der App', () => {
  for (const f of beispiele.faelle) {
    assert.deepEqual(new Set(pruefeText(f.text).map((t) => t.regel)), new Set(f.regeln), f.text);
  }
  assert.equal(pruefen(new Uint8Array([1, 0, 2])), null);
  assert.equal(JSON.stringify(pruefeText('Passwort: Pferd-Batterie-77')).includes('Pferd'), false);
});

test('Pfade, Konfliktnamen, Ausnahmen', () => {
  for (const p of ['../x', '/a', 'a//b', 'C:/x', '']) assert.throws(() => vaultPfad(p), p);
  assert.equal(vaultPfad('a\\b.md'), 'a/b.md');
  const t = new Date(2026, 10, 24, 14, 3);
  assert.equal(konfliktPfad('O/Notiz.md', t, 'Handy', () => false), 'O/Notiz (Konflikt 2026-11-24 1403 Handy).md');
  const belegt = new Set(['Notiz (Konflikt 2026-11-24 1403 Handy).md']);
  assert.equal(konfliktPfad('Notiz.md', t, 'Handy', (p) => belegt.has(p)), 'Notiz (Konflikt 2026-11-24 1403 Handy 2).md');
  assert.equal(ausnahme('.git/HEAD'), 'Git-Verwaltung');
  assert.equal(ausnahme('.obsidian/workspace.json'), 'Fensteranordnung je Gerät');
  assert.equal(ausnahme('.obsidian/app.json'), null);
  assert.equal(ausnahme('.stfolder'), 'Syncthing-Verwaltung');
});

test('Testvektoren der App: Raum (Objekt-ID, Umschlag mit Epoche, Block, Mitglieds-Paket)', async () => {
  const rv = v.raum;
  const r = new Raum(rv.json);
  assert.equal(await r.objektId('vault', 'datei-1'), rv.objektId);
  assert.deepEqual((await r.entschluesseln(rv.objektId, rv.umschlag))?.daten, { pfad: 'Plan.md' });
  const klar = vonBase64(v.block.klar);
  assert.equal(await r.blockId(klar), rv.blockId);
  assert.deepEqual(await r.blockEntschluesseln(rv.blockId, vonBase64(rv.block), klar.length), klar);
  assert.equal((await Raum.mitgliedPaketOeffnen(r.id, vonBase64(rv.mitgliedPaar), rv.mitgliedPaket))?.epoche, 2);
  // Eigene Verschlüsselung (Epoche 2) wieder lesbar, andere Raum-ID nicht.
  const neu = await r.verschluesseln({ bereich: 'vault', id: 'x', schema: 5, daten: { a: 1 } });
  assert.deepEqual((await r.entschluesseln(await r.objektId('vault', 'x'), neu))?.daten, { a: 1 });
  const fremd = new Raum({ ...rv.json, id: 'ffffffffffffffffffffffffffffffff' });
  assert.equal(await fremd.entschluesseln(await r.objektId('vault', 'x'), neu), null);
});
