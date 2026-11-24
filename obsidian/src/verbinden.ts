// Verbinden per Kopplungscode aus der App (Einstellungen → Sync → Gerät
// hinzufügen). Der Code bleibt beim Nutzer; der Server sieht nur den
// daraus abgeleiteten Slot und kann das Paket nicht öffnen.

import { SyncApi, SyncFehler, serverAdresse, type Transport } from './api.ts';
import { base64 } from './krypto.ts';
import { Kopplungscode } from './protokoll.ts';
import type { Verbindung } from './abgleich.ts';

export async function koppeln(server: string, codeText: string, name: string, transport: Transport): Promise<Verbindung> {
  const code = Kopplungscode.lesen(codeText);
  if (!code) throw new SyncFehler('daten', 'Der Kopplungscode hat 20 Zeichen (Buchstaben und Ziffern).');
  const basis = serverAdresse(server);
  const api = new SyncApi(basis, transport);
  await api.info();
  let e;
  try {
    e = await api.kopplungEinloesen(await code.slot(), '');
  } catch (f) {
    if (f instanceof SyncFehler && f.art === 'nichtGefunden') {
      throw new SyncFehler('nichtGefunden', 'Kopplungscode unbekannt oder abgelaufen. Bitte in der App einen neuen erzeugen.');
    }
    throw f;
  }
  const p = await code.paketOeffnen(e.paket);
  if (!p) throw new SyncFehler('daten', 'Das Kopplungspaket ließ sich nicht öffnen.');
  const mitToken = api.mitToken(e.token);
  const konto = await mitToken.konto();
  if (!(await p.schluessel.passtZuPaket(konto.schluesselPaket))) {
    throw new SyncFehler('daten', 'Der Schlüssel aus dem Kopplungscode passt nicht zum Konto.');
  }
  await mitToken.geraetUmbenennen(e.geraet, await p.schluessel.geraetName(name));
  return { server: basis, konto: e.konto, geraet: e.geraet, token: e.token, schluessel: base64(p.schluessel.bytes), name, seq: 0, bekannt: 0 };
}
