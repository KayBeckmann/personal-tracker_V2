import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/einkauf/schaetzung.dart';
import 'package:personal_tracker/core/modell/einkauf.dart';
import 'package:personal_tracker/core/raeume/raum.dart';
import 'package:personal_tracker/core/raeume/raum_dienst.dart';
import 'package:personal_tracker/core/sitzung.dart';
import 'package:personal_tracker/core/speicher/rohdaten.dart';

import '../sync_hilfen.dart';
import 'sitzung_test.dart' show einrichtenMitDaten;
import 'sync_test.dart' show Geraet;

final t0 = DateTime.utc(2026, 11, 25);

Filiale filiale(String id, String kette, String name, {String? region}) =>
    Filiale(id: id, kette: kette, name: name, region: region, geaendert: t0);

Preis preis(String id, String artikel, String filialeId, int cent, double menge, Einheit e, {DateTime? datum}) => Preis(
      id: id,
      artikel: artikel,
      filialeId: filialeId,
      packungsPreisCent: cent,
      packungsMenge: menge,
      packungsEinheit: e,
      datum: datum ?? DateTime(2026, 11, 20),
      geaendert: t0,
    );

Posten posten(String id, String name, {double menge = 1, Einheit einheit = Einheit.stueck, bool abgehakt = false, String listeId = 'l1'}) =>
    Posten(id: id, listeId: listeId, name: name, menge: menge, einheit: einheit, abgehakt: abgehakt, geaendert: t0);

void main() {
  group('Preise und Umrechnung', () {
    test('Grundpreis und Kosten je Menge', () {
      final mehl = preis('p', 'Mehl', 'f', 149, 500, Einheit.g);
      expect(mehl.grundpreisCent, 298);
      expect(kostenCent(mehl, 1, Einheit.kg), 298);
      expect(kostenCent(mehl, 250, Einheit.g), 75);
      expect(kostenCent(mehl, 2, Einheit.packung), 298);
      expect(kostenCent(mehl, 1, Einheit.l), isNull, reason: 'g und l sind nicht vergleichbar');
      expect(kostenCent(mehl, 3, Einheit.stueck), isNull);
      final milch = preis('m', 'Milch', 'f', 109, 1, Einheit.l);
      expect(milch.grundpreisCent, 109);
      expect(kostenCent(milch, 1500, Einheit.ml), 164);
      final eier = preis('e', 'Eier', 'f', 239, 10, Einheit.stueck);
      expect(eier.grundpreisCent, 24);
      expect(kostenCent(eier, 6, Einheit.stueck), 143);
    });

    test('Zwei Aldi-Filialen bleiben getrennt; Region nur als Schätzung; unbekannt ist nicht 0 €', () {
      final filialen = {
        'a1': filiale('a1', 'Aldi Süd', 'Hauptstraße', region: 'Musterstadt'),
        'a2': filiale('a2', 'Aldi Süd', 'Bahnhof', region: 'Musterstadt'),
        'a3': filiale('a3', 'Aldi Süd', 'Nachbarort', region: 'Nachbarort'),
      };
      final preise = [
        preis('p1', 'Butter', 'a1', 229, 250, Einheit.g),
        preis('p2', 'Butter', 'a2', 199, 250, Einheit.g),
        preis('p3', 'Butter', 'a2', 249, 250, Einheit.g, datum: DateTime(2026, 11, 1)),
        preis('p4', 'Kaffee', 'a2', 699, 500, Einheit.g),
      ];
      final liste = [posten('x1', 'Butter'), posten('x2', 'Kaffee', menge: 1, einheit: Einheit.packung), posten('x3', 'Safran')];
      // In a1: Butter aus a1, Kaffee nur aus a2 (gleiche Region → Schätzung), Safran unbekannt.
      final s1 = ListenSchaetzung(liste.map((p) => p.kopie(einheit: p.name == 'Butter' ? Einheit.packung : null)), preise, filialen, 'a1');
      expect(s1.werte['x1']!.kostenCent, 229);
      expect(s1.werte['x1']!.herkunft, PreisHerkunft.filiale);
      expect(s1.werte['x2']!.herkunft, PreisHerkunft.region);
      expect(s1.werte['x3']!.herkunft, PreisHerkunft.unbekannt);
      expect(s1.summeCent, 229 + 699);
      expect(s1.ohnePreis, 1);
      expect(s1.geschaetzt, 1);
      expect(s1.vollstaendig, isFalse);
      // In a2: jüngster Butterpreis von a2 (1,99 €, nicht der ältere 2,49 €).
      final s2 = ListenSchaetzung([posten('x1', 'Butter', einheit: Einheit.packung)], preise, filialen, 'a2');
      expect(s2.summeCent, 199);
      // Andere Region: kein Preis von a1/a2.
      final s3 = ListenSchaetzung([posten('x1', 'Butter', einheit: Einheit.packung)], preise, filialen, 'a3');
      expect(s3.summeCent, 0);
      expect(s3.ohnePreis, 1);
    });

    test('Entfernung (Haversine) für die nächste Filiale', () {
      // Berlin Hbf – Brandenburger Tor: etwa 1,6 km.
      final d = entfernungMeter(52.5251, 13.3694, 52.5163, 13.3777);
      expect(d, inInclusiveRange(1000, 1300));
      expect(entfernungMeter(50, 8, 50, 8), 0);
    });
  });

  group('Einkauf in der Sitzung', () {
    late TestServer server;
    setUp(() => server = TestServer());
    tearDown(() => server.speicher.schliessen());

    test('Abschließen ergibt genau eine Buchung; gekaufte Posten verschwinden von der Liste', () async {
      final g = await Geraet(server, 'a').start();
      await einrichtenMitDaten(g.s);
      final s = g.s;
      await s.speichereFiliale(filiale('a1', 'Aldi Süd', 'Hauptstraße'));
      final l = await s.speichereListe(Einkaufsliste(id: 'l1', name: 'Wocheneinkauf', filialeId: 'a1', geaendert: t0));
      await s.speicherePosten(posten('x1', 'Butter', abgehakt: true));
      await s.speicherePosten(posten('x2', 'Milch', abgehakt: true));
      await s.speicherePosten(posten('x3', 'Safran'));
      final saldo = g.b.saldoCent('giro');
      final e = await s.einkaufAbschliessen(listeId: l.id, betragCent: 1234, kontoId: 'giro', datum: DateTime(2026, 11, 25));
      expect(g.b.saldoCent('giro'), saldo - 1234);
      expect(g.b.buchungen[e.buchungId]!.empfaenger, 'Aldi Süd · Hauptstraße');
      expect(g.b.postenVon('l1').map((p) => p.name), ['Safran']);
      expect(g.b.posten['x1']!.einkaufId, e.id);
      // Nichts mehr abgehakt: kein zweites Abschließen, keine doppelte Buchung.
      await expectLater(s.einkaufAbschliessen(listeId: 'l1', betragCent: 1234, kontoId: 'giro', datum: DateTime(2026, 11, 25)), throwsStateError);
      expect(g.b.buchungen.values.where((b) => b.betragCent == -1234), hasLength(1));
      // Alles steckt in der Sicherung.
      final roh = rohdatenVon(g.b);
      expect(roh['einkaeufe'], hasLength(1));
      expect(roh['posten'], hasLength(3));
      expect(roh['filialen'], hasLength(1));
    });

    test('Geteilte Einkaufsliste: Posten, Preise und Filiale beim Mitglied; die Buchung bleibt privat', () async {
      Future<Geraet> person(String name) async {
        final g = await Geraet(server, name).start();
        final r = await einrichtenMitDaten(g.s);
        await g.s.speichereEinstellungen(g.b.einstellungen.kopie(anzeigeName: name));
        await g.sync.verbinden(server: TestServer.adresse, recovery: r, geraetName: name);
        await g.ruhig();
        return g;
      }

      final kay = await person('Kay');
      final lena = await person('Lena');
      await kay.s.speichereFiliale(filiale('a1', 'Aldi Süd', 'Hauptstraße', region: 'Musterstadt'));
      await kay.s.speicherePreis(preis('p-privat', 'Butter', 'a1', 229, 250, Einheit.g));
      final raum = await kay.c.read(raumDienstProvider).anlegen(art: RaumArt.einkauf, name: 'Haushalt');
      final liste = await kay.s.speichereListe(Einkaufsliste(id: 'liste-1', name: 'Haushalt', filialeId: 'a1', geaendert: t0, raum: raum.id));
      // Die private Filiale wurde für den Raum kopiert.
      final geteilteFiliale = kay.b.filialen[liste.filialeId]!;
      expect(geteilteFiliale.raum, raum.id);
      expect(kay.b.filialen['a1']!.raum, isNull);
      await kay.s.speicherePosten(posten('x1', 'Butter', einheit: Einheit.packung, listeId: 'liste-1'));
      await kay.s.speicherePreis(Preis(
          id: 'p-geteilt', artikel: 'Butter', filialeId: geteilteFiliale.id, packungsPreisCent: 219, packungsMenge: 250, packungsEinheit: Einheit.g,
          datum: DateTime(2026, 11, 24), geaendert: t0, raum: raum.id));
      final (:code, bis: _) = await kay.c.read(raumDienstProvider).einladen(kay.b.raeume[raum.id]!, 'schreiben');
      await lena.c.read(raumDienstProvider).annehmen(code.text);
      await kay.abgleichen();
      await lena.abgleichen();
      expect(lena.b.einkaufslisten['liste-1']!.name, 'Haushalt');
      expect(lena.b.postenVon('liste-1').map((p) => p.name), ['Butter']);
      expect(lena.b.preise.keys, contains('p-geteilt'));
      expect(lena.b.preise.keys, isNot(contains('p-privat')), reason: 'private Preise bleiben privat');
      expect(lena.b.filialen.keys, isNot(contains('a1')));
      final s = ListenSchaetzung(lena.b.postenVon('liste-1'), lena.b.preise.values, lena.b.filialen, lena.b.einkaufslisten['liste-1']!.filialeId);
      expect(s.summeCent, 219);

      // Lena kauft ein: Buchung in ihrem Haushaltsbuch, Kay sieht nur, dass gekauft ist.
      await lena.s.speicherePosten(lena.b.posten['x1']!.kopie(abgehakt: true));
      final e = await lena.s.einkaufAbschliessen(listeId: 'liste-1', betragCent: 219, kontoId: 'giro', datum: DateTime(2026, 11, 25));
      await lena.abgleichen();
      await kay.abgleichen();
      expect(kay.b.postenVon('liste-1'), isEmpty);
      expect(kay.b.buchungen.containsKey(e.buchungId), isFalse);
      expect(kay.b.einkaeufe, isEmpty);
      expect(lena.b.buchungen[e.buchungId]!.betragCent, -219);
      expect(server.dump(), isNot(contains('Hauptstraße')));
    });
  });

  test('Sitzung: Leserecht sperrt auch Einkaufsdaten', () async {
    final server = TestServer();
    addTearDown(server.speicher.schliessen);
    final g = await Geraet(server, 'x').start();
    await einrichtenMitDaten(g.s);
    // Raum mit Leserecht von Hand eintragen.
    await g.s.raumSpeichern(Raum(
      id: 'r1', art: RaumArt.einkauf, name: 'Fremd', recht: 'lesen', idSchluessel: Uint8List(32), schluessel: {1: Uint8List(32)}, epoche: 1));
    await expectLater(g.s.speichereListe(Einkaufsliste(id: 'l', name: 'x', geaendert: t0, raum: 'r1')), throwsStateError);
    expect(g.c.read(bestandProvider).einkaufslisten, isEmpty);
  });
}
