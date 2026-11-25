import 'dart:convert';

import 'regionen.g.dart';

/// Feste Regionen (Landkreise und kreisfreie Städte, amtlicher
/// Kreisschlüssel) und Ketten für den Preiskatalog (M10). Damit meinen
/// „NWM“, „Nordwestmecklenburg“ und „Nord-West Mecklenburg“ dieselbe
/// Region. Daten: `protokoll/regionen-de.json`, `protokoll/ketten-de.json`.
/// Dieselben Regeln gelten in der App (`app/lib/core/regionen/`); beide
/// prüfen `protokoll/regionen-testfaelle.json`.

/// Vergleichsform: klein, Umlaute ausgeschrieben, Abkürzungen des
/// Gemeindeverzeichnisses aufgelöst, nur Buchstaben und Ziffern.
String kompakt(String s) {
  for (final (a, b) in const [('a.d.', 'an der '), ('a.', 'am '), ('i.d.', 'in der '), ('i.', 'im '), ('OPf.', 'Oberpfalz')]) {
    s = s.replaceAll(a, b);
  }
  s = s.toLowerCase().replaceAll('ß', 'ss').replaceAll('ä', 'ae').replaceAll('ö', 'oe').replaceAll('ü', 'ue');
  return s.replaceAll(RegExp(r'[^a-z0-9]'), '');
}

class Kreis {
  const Kreis(this.schluessel, this.name, this.art, this.kfz);
  final String schluessel, name, art;
  final List<String> kfz;
  bool get istStadt => art == 'Kreisfreie Stadt' || art == 'Stadtkreis';
}

class Kette {
  const Kette(this.schluessel, this.name, this.alias);
  final String schluessel, name;
  final List<String> alias;
}

class Regionen {
  Regionen._(this.kreise, this.ketten) {
    for (final k in kreise.values) {
      final roh = k.name.replaceFirst(RegExp(r',.*$'), '');
      final basen = {roh, roh.replaceAll(RegExp(r'\s*\([^)]*\)'), '')};
      final namen = {k.name, k.schluessel, ...basen, ...k.kfz};
      if (k.name.contains(',')) namen.add('${k.name.split(',')[1]} $roh');
      for (final b in basen) {
        namen.addAll(k.istStadt ? ['Stadt $b', 'kreisfreie Stadt $b'] : ['Landkreis $b', 'Kreis $b', 'LK $b']);
      }
      for (final n in namen) {
        (_kreisIndex[kompakt(n)] ??= {}).add(k.schluessel);
      }
    }
    for (final k in ketten.values) {
      for (final n in {k.schluessel, k.name, ...k.alias}) {
        (_ketteIndex[kompakt(n)] ??= {}).add(k.schluessel);
      }
    }
  }

  static final Regionen de = Regionen.ausJson(kreiseJson, kettenJson);

  factory Regionen.ausJson(String kreiseText, String kettenText) => Regionen._(
        {
          for (final k in (jsonDecode(kreiseText) as Map)['kreise'] as List)
            k['s'] as String: Kreis(k['s'] as String, k['n'] as String, k['a'] as String, (k['k'] as List).cast<String>()),
        },
        {
          for (final k in (jsonDecode(kettenText) as Map)['ketten'] as List)
            k['s'] as String: Kette(k['s'] as String, k['n'] as String, (k['alias'] as List).cast<String>()),
        },
      );

  final Map<String, Kreis> kreise;
  final Map<String, Kette> ketten;
  final _kreisIndex = <String, Set<String>>{};
  final _ketteIndex = <String, Set<String>>{};
  final _cache = <String, String?>{};

  /// Kreisschlüssel zu einer freien Eingabe, nur wenn eindeutig.
  String? kreisZu(String? text) => text == null ? null : _cache.putIfAbsent('k|$text', () => _eindeutig(_kreisIndex[kompakt(text)]));

  /// Kettenschlüssel zu einer freien Eingabe, nur wenn eindeutig.
  String? ketteZu(String? text) => text == null ? null : _cache.putIfAbsent('c|$text', () => _eindeutig(_ketteIndex[kompakt(text)]));

  static String? _eindeutig(Set<String>? s) => s != null && s.length == 1 ? s.first : null;
}

/// GTIN/EAN-8, UPC-A (12), EAN-13 oder GTIN-14 mit gültiger Prüfziffer.
bool gtinGueltig(String s) {
  if (!RegExp(r'^(\d{8}|\d{12,14})$').hasMatch(s)) return false;
  var summe = 0;
  for (var i = 0; i < s.length - 1; i++) {
    final ziffer = s.codeUnitAt(s.length - 2 - i) - 48;
    summe += i.isEven ? ziffer * 3 : ziffer;
  }
  return (10 - summe % 10) % 10 == s.codeUnitAt(s.length - 1) - 48;
}
