import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';

import { fetchTransport, SyncApi } from '../src/api.ts';
import { leererZustand, VaultAbgleich } from '../src/abgleich.ts';
import { zufall } from '../src/krypto.ts';
import { koppeln } from '../src/verbinden.ts';
import { appKontoMitToken, SpeicherFs, TestServer, vaultRaum, type AppKonto } from './hilfen.ts';

const server = new TestServer();
before(() => server.starten());
after(() => server.stoppen());

class Plugin {
  fs = new SpeicherFs();
  z = leererZustand();
  uhr = new Date(2026, 10, 25, 9, 0);
  a = new VaultAbgleich(this.fs, this.z, (v) => new SyncApi(v.server, fetchTransport, v.token), () => ({ maxBytes: 100 * 1024 * 1024 }), () => this.uhr);
  static async fuer(k: AppKonto, name: string): Promise<Plugin> {
    const p = new Plugin();
    p.z.verbindung = await koppeln(server.adresse, await k.code(), name, fetchTransport);
    p.z.eingerichtet = true;
    return p;
  }
  async sync() {
    const b = await this.a.abgleichen();
    assert.equal(b.defekt, 0);
    return b;
  }
}

test('Geteilter Ordner: Eigentümer, Schreib- und Lese-Mitglied, Verschieben, Beenden', async () => {
  const kay = await appKontoMitToken(server.adresse);
  const lena = await appKontoMitToken(server.adresse);
  const tim = await appKontoMitToken(server.adresse);
  const pk = await Plugin.fuer(kay, 'Kay-Laptop');
  pk.fs.setze('Familie/Plan.md', '# Plan');
  pk.fs.setze('Familie/Fotos/gross.bin', zufall(1500 * 1024));
  pk.fs.setze('Privat/geheim.md', 'nur für mich');
  await pk.sync();

  const raum = await vaultRaum(server.adresse, kay, 'Familie', [
    { konto: lena, recht: 'schreiben', ordner: 'Geteilt/Familie' },
    { konto: tim, recht: 'lesen', ordner: 'Familie von Kay' },
  ]);
  await pk.sync(); // Kay holt den Raum und verschiebt den Ordner dorthin.
  const pl = await Plugin.fuer(lena, 'Lena-Handy');
  const pt = await Plugin.fuer(tim, 'Tim-PC');
  await pl.sync();
  await pt.sync();
  assert.deepEqual(pl.fs.pfade(), ['Geteilt/Familie/Fotos/gross.bin', 'Geteilt/Familie/Plan.md']);
  assert.deepEqual(pt.fs.pfade(), ['Familie von Kay/Fotos/gross.bin', 'Familie von Kay/Plan.md']);
  assert.deepEqual(await pl.fs.lesen('Geteilt/Familie/Fotos/gross.bin'), await pk.fs.lesen('Familie/Fotos/gross.bin'));

  // Lena schreibt, Kay und Tim bekommen es.
  pl.fs.setze('Geteilt/Familie/Plan.md', '# Plan\n- Lena');
  pl.fs.setze('Geteilt/Familie/Neu.md', 'von Lena');
  await pl.sync();
  await pk.sync();
  await pt.sync();
  assert.equal(pk.fs.text('Familie/Plan.md'), '# Plan\n- Lena');
  assert.equal(pk.fs.text('Familie/Neu.md'), 'von Lena');
  assert.equal(pt.fs.text('Familie von Kay/Neu.md'), 'von Lena');

  // Tim (nur lesen) ändert lokal: seine Fassung wird beiseitegelegt, die geteilte kommt zurück.
  pt.fs.setze('Familie von Kay/Plan.md', 'Tims Version');
  const bt = await pt.sync();
  await pt.sync();
  assert.deepEqual(bt.nurLesen, ['Eigene Änderungen/Familie/Plan.md']);
  assert.equal(pt.fs.text('Familie von Kay/Plan.md'), '# Plan\n- Lena');
  assert.equal(pt.fs.text('Eigene Änderungen/Familie/Plan.md'), 'Tims Version');
  await pk.sync();
  assert.equal(pk.fs.text('Familie/Plan.md'), '# Plan\n- Lena');
  assert.equal(pk.fs.text('Eigene Änderungen/Familie/Plan.md'), undefined, 'Tims Kopie bleibt privat bei Tim');

  // Privat → geteilt → privat.
  await pk.fs.verschieben('Privat/geheim.md', 'Familie/geheim.md');
  pk.a.umbenannt.set('Privat/geheim.md', 'Familie/geheim.md');
  await pk.sync();
  await pl.sync();
  assert.equal(pl.fs.text('Geteilt/Familie/geheim.md'), 'nur für mich');
  await pk.fs.verschieben('Familie/geheim.md', 'Privat/geheim.md');
  pk.a.umbenannt.set('Familie/geheim.md', 'Privat/geheim.md');
  await pk.sync();
  await pl.sync();
  assert.equal(pl.fs.text('Geteilt/Familie/geheim.md'), undefined);
  assert.ok(pl.fs.papierkorbInhalt.has('Geteilt/Familie/geheim.md'));

  // Tim wird entfernt: seine Kopien gehen in den Papierkorb, Lena bleibt.
  await raum.entfernen(tim);
  const bt2 = await pt.sync();
  assert.deepEqual(bt2.raeumeEntfernt, ['Familie']);
  assert.deepEqual(pt.fs.pfade(), ['Eigene Änderungen/Familie/Plan.md']);

  // Kay beendet die Freigabe: Lena verliert alles, Kay behält es (wieder privat).
  await raum.beenden();
  await pk.sync();
  await pl.sync();
  assert.deepEqual(pl.fs.pfade(), []);
  assert.ok(pk.fs.pfade().includes('Familie/Plan.md'));
  assert.equal(pk.a.ausstehend, 0);
  const pk2 = await Plugin.fuer(kay, 'Kay-Zweitgeraet');
  await pk2.sync();
  assert.equal(pk2.fs.text('Familie/Plan.md'), '# Plan\n- Lena', 'nach dem Beenden wieder im eigenen Konto');
});
