import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/einkauf/schaetzung.dart';
import 'package:personal_tracker/core/katalog/katalog_dienst.dart' as kat;
import 'package:personal_tracker/core/modell/einkauf.dart';

import '../sync_hilfen.dart';
import 'sitzung_test.dart' show einrichtenMitDaten;
import 'sync_test.dart' show Geraet;

final t0 = DateTime.utc(2026, 11, 25);

void main() {
  late TestServer server;
  setUp(() => server = TestServer());
  tearDown(() => server.speicher.schliessen());

  Future<Geraet> person(String name) async {
    final g = await Geraet(server, name).start();
    final r = await einrichtenMitDaten(g.s);
    await g.sync.verbinden(server: TestServer.adresse, recovery: r, geraetName: name);
    await g.ruhig();
    return g;
  }

  test('Katalog: nur mit Opt-in, ohne Position; Bestätigung durch eine zweite Person; Übernehmen; Zurückziehen', () async {
    final kay = await person('Kay');
    final lena = await person('Lena');
    final heute = DateTime.now();
    final f = Filiale(id: 'f1', kette: 'Aldi Süd', name: 'Hauptstraße', region: 'Musterstadt', breite: 52.52, laenge: 13.40, geaendert: t0);
    await kay.s.speichereFiliale(f);
    final p = Preis(
      id: 'p1', artikel: 'Butter', filialeId: 'f1', packungsPreisCent: 229, packungsMenge: 250, packungsEinheit: Einheit.g,
      datum: DateTime(heute.year, heute.month, heute.day), geaendert: t0);
    await kay.s.speicherePreis(p);

    // Ohne Opt-in geht nichts.
    final k = kay.c.read(kat.katalogProvider);
    await expectLater(k.veroeffentlichen(p, f), throwsA(isA<kat.KatalogFehler>()));
    expect(server.speicher.db.select('SELECT count(*) n FROM katalog').first['n'], 0);
    // Was veröffentlicht würde: keine Position, kein Name.
    final b = kat.KatalogDienst.beitragFuer(p, f);
    expect(b.keys.toSet(), {'typ', 'artikel', 'packungsMenge', 'packungsEinheit', 'kette', 'filiale', 'region', 'preisCent', 'waehrung', 'tag'});
    expect(() => kat.KatalogDienst.beitragFuer(p, f.kopie(region: () => null)), throwsA(isA<kat.KatalogFehler>()));

    await kay.s.speichereEinstellungen(kay.b.einstellungen.kopie(katalogBeitragen: true));
    await k.veroeffentlichen(p, f);
    final daten = server.speicher.db.select('SELECT daten FROM katalog').single['daten'] as String;
    expect(daten, isNot(contains('52.52')));
    expect(daten, isNot(contains('Kay')));

    // Lena liest (nach Opt-in): unbestätigt, nicht übernehmbar.
    final kl = lena.c.read(kat.katalogProvider);
    await expectLater(kl.suchen('Butter'), throwsA(isA<kat.KatalogFehler>()));
    await lena.s.speichereEinstellungen(lena.b.einstellungen.kopie(katalogLesen: true, katalogBeitragen: true));
    var treffer = await kl.suchen('butter');
    expect(treffer.single.bestaetigt, isFalse);
    expect(treffer.single.eigen, isFalse);
    await expectLater(kl.uebernehmen(treffer.single), throwsA(isA<kat.KatalogFehler>()));
    // Kay kann sich nicht selbst bestätigen (Server lehnt ab).
    await kay.s.speichereEinstellungen(kay.b.einstellungen.kopie(katalogLesen: true));
    final eigener = (await k.suchen('Butter')).single;
    expect(eigener.eigen, isTrue);
    await expectLater(k.bestaetigen(eigener), throwsA(anything));

    await kl.bestaetigen(treffer.single);
    treffer = await kl.suchen('butter');
    expect(treffer.single.bestaetigt, isTrue);
    expect(treffer.single.vonMir, isTrue);
    final uebernommen = await kl.uebernehmen(treffer.single);
    expect(uebernommen.quelle, 'katalog');
    final lf = lena.b.filialen[uebernommen.filialeId]!;
    expect('${lf.kette}|${lf.name}|${lf.region}', 'Aldi Süd|Hauptstraße|Musterstadt');
    expect(lf.hatPosition, isFalse);
    final s = ListenSchaetzung(
        [Posten(id: 'x', listeId: 'l', name: 'Butter', menge: 1, einheit: Einheit.packung, geaendert: t0)], lena.b.preise.values, lena.b.filialen, lf.id);
    expect(s.summeCent, 229);

    // Zurückziehen.
    final meine = await k.meine();
    await k.zurueckziehen(eigener.instanz, meine.firstWhere((x) => x['typ'] == 'preis')['id'] as String);
    expect(await kl.suchen('butter'), isEmpty);
    // Lenas übernommener Preis bleibt ihr eigener.
    expect(lena.b.preise[uebernommen.id], isNotNull);
  });
}
