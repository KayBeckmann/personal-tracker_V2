import 'dart:convert';
import 'dart:io';

import 'package:personal_tracker_sync/src/regionen.dart';
import 'package:personal_tracker_sync/src/regionen.g.dart';
import 'package:test/test.dart';

void main() {
  final faelle = jsonDecode(File('../protokoll/regionen-testfaelle.json').readAsStringSync()) as Map;

  test('regionen.g.dart entspricht protokoll/ (sonst kopieren.py ausführen)', () {
    final regionen = jsonDecode(File('../protokoll/regionen-de.json').readAsStringSync()) as Map;
    expect(jsonDecode(kreiseJson), {'stand': regionen['stand'], 'kreise': regionen['kreise']});
    expect(kettenJson, File('../protokoll/ketten-de.json').readAsStringSync());
  });

  test('Freie Eingaben werden nur eindeutig einem Kreis bzw. einer Kette zugeordnet', () {
    for (final e in (faelle['regionen'] as Map).entries) {
      expect(Regionen.de.kreisZu(e.key as String), e.value, reason: 'Region „${e.key}“');
    }
    for (final e in (faelle['ketten'] as Map).entries) {
      expect(Regionen.de.ketteZu(e.key as String), e.value, reason: 'Kette „${e.key}“');
    }
  });

  test('Alle Kreise haben Name, Art und mindestens ein Kfz-Kennzeichen', () {
    expect(Regionen.de.kreise.length, greaterThan(390));
    for (final k in Regionen.de.kreise.values) {
      expect(k.schluessel, matches(RegExp(r'^\d{5}$')));
      expect(k.kfz, isNotEmpty, reason: k.name);
    }
  });

  test('GTIN-Prüfziffer', () {
    for (final gut in ['4006381333931', '96385074', '036000291452', '10012345678902']) {
      expect(gtinGueltig(gut), isTrue, reason: gut);
    }
    for (final schlecht in ['4006381333932', '400638133393', '12345', 'abcdefghijklm', '']) {
      expect(gtinGueltig(schlecht), isFalse, reason: schlecht);
    }
  });
}
