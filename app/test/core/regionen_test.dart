import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/einkauf/schaetzung.dart';
import 'package:personal_tracker/core/modell/einkauf.dart';
import 'package:personal_tracker/core/regionen/regionen.dart';

final t0 = DateTime.utc(2026, 11, 25);

void main() {
  final r = Regionen.ausJson(File('assets/regionen-de.json').readAsStringSync(), File('assets/ketten-de.json').readAsStringSync());

  test('Assets entsprechen protokoll/ (sonst protokoll/regionen/kopieren.py ausführen)', () {
    for (final name in ['regionen-de.json', 'ketten-de.json']) {
      expect(File('assets/$name').readAsStringSync(), File('../protokoll/$name').readAsStringSync(), reason: name);
    }
  });

  test('Freie Eingaben wie auf dem Server: nur eindeutige Zuordnung', () {
    final faelle = jsonDecode(File('../protokoll/regionen-testfaelle.json').readAsStringSync()) as Map;
    for (final e in (faelle['regionen'] as Map).entries) {
      expect(r.kreisZu(e.key as String), e.value, reason: 'Region „${e.key}“');
    }
    for (final e in (faelle['ketten'] as Map).entries) {
      expect(r.ketteZu(e.key as String), e.value, reason: 'Kette „${e.key}“');
    }
  });

  test('Suche nach Kfz-Kennzeichen, Name, Postleitzahl und Ort', () {
    expect(r.suchen('NWM').first.schluessel, '13074');
    expect(r.suchen('nordwest').first.schluessel, '13074');
    expect(r.suchen('23966').map((k) => k.schluessel), ['13074']);
    expect(r.suchen('239').map((k) => k.schluessel), contains('13074'));
    expect(r.suchen('Wismar').map((k) => k.schluessel), contains('13074'));
    expect(r.orteIn('13074', 'Wism'), contains('Wismar'));
    // Mehrdeutiges Kürzel: Stadt und Landkreis München zur Auswahl.
    expect(r.suchen('M').map((k) => k.schluessel), containsAll(['09162', '09184']));
    expect(r.suchen(''), isEmpty);
    expect(r.kreise['13003']!.beschreibung, 'Rostock (Kreisfreie Stadt, Mecklenburg-Vorpommern)');
  });

  test('Kreis aus der Position ohne Netz', () {
    expect(r.kreisBei(53.892, 11.465)?.schluessel, '13074', reason: 'Wismar');
    expect(r.kreisBei(48.137, 11.575)?.schluessel, '09162', reason: 'München Marienplatz');
    expect(r.kreisBei(40.0, -3.7), isNull, reason: 'außerhalb Deutschlands');
  });

  test('Kettensuche', () {
    expect(r.kettenSuchen('ald').map((k) => k.schluessel), ['aldi-nord', 'aldi-sued']);
    expect(r.kettenSuchen('').length, r.ketten.length);
  });

  test('GTIN-Prüfziffer', () {
    expect(gtinGueltig('4006381333931'), isTrue);
    expect(gtinGueltig('96385074'), isTrue);
    expect(gtinGueltig('4006381333932'), isFalse);
    expect(gtinGueltig('123'), isFalse);
  });

  test('Schätzung: gleiche EAN vor gleichem Namen; Region über den Kreisschlüssel', () {
    Filiale f(String id, {String? region, String? schluessel}) =>
        Filiale(id: id, kette: 'Lidl', name: id, region: region, regionSchluessel: schluessel, geaendert: t0);
    Preis p(String id, String artikel, String filiale, int cent, {String? ean, DateTime? datum}) => Preis(
        id: id, artikel: artikel, ean: ean, filialeId: filiale, packungsPreisCent: cent, packungsMenge: 1, packungsEinheit: Einheit.stueck,
        datum: datum ?? DateTime(2026, 11, 20), geaendert: t0);
    final filialen = {
      'hier': f('hier', region: 'Nordwestmecklenburg', schluessel: '13074'),
      'nachbar': f('nachbar', region: 'NWM (alt eingetippt)', schluessel: '13074'),
      'fern': f('fern', region: 'Rostock', schluessel: '13003'),
    };
    final preise = [
      p('a', 'Hafermilch', 'hier', 199, datum: DateTime(2026, 11, 24)),
      p('b', 'Haferdrink Barista', 'hier', 249, ean: '4006381333931', datum: DateTime(2026, 11, 1)),
      p('c', 'Butter', 'nachbar', 229),
      p('d', 'Butter', 'fern', 199),
    ];
    Posten posten(String name, {String? ean}) => Posten(id: name, listeId: 'l', name: name, ean: ean, geaendert: t0);
    // Mit EAN: der genaue Artikel, auch wenn er anders heißt und älter ist.
    expect(bewerten(posten('Hafermilch', ean: '4006381333931'), preise, filialen, 'hier').kostenCent, 249);
    // Ohne passende EAN: wie bisher über den Namen.
    expect(bewerten(posten('Hafermilch', ean: '96385074'), preise, filialen, 'hier').kostenCent, 199);
    // Region über den Schlüssel, auch wenn der Text verschieden ist; Rostock zählt nicht.
    final butter = bewerten(posten('Butter'), preise, filialen, 'hier');
    expect([butter.kostenCent, butter.herkunft], [229, PreisHerkunft.region]);
  });
}
