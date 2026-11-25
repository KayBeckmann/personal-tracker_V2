import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../modell/einkauf.dart' show entfernungMeter;

/// Feste Regionen (Landkreise und kreisfreie Städte mit amtlichem
/// Kreisschlüssel) und Ketten für Filialen und Preiskatalog (M10). Daten:
/// `assets/regionen-de.json` und `assets/ketten-de.json`, Kopien aus
/// `protokoll/` (siehe `protokoll/REGIONEN.md`). Die Zuordnung freier Texte
/// folgt denselben Regeln wie der Server (`server/lib/src/regionen.dart`);
/// beide prüfen `protokoll/regionen-testfaelle.json`.
final regionenProvider = FutureProvider<Regionen>((ref) async => Regionen.ausJson(
      await rootBundle.loadString('assets/regionen-de.json'),
      await rootBundle.loadString('assets/ketten-de.json'),
    ));

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
  const Kreis(this.schluessel, this.name, this.art, this.land, this.kfz);
  final String schluessel, name, art, land;
  final List<String> kfz;
  bool get istStadt => art == 'Kreisfreie Stadt' || art == 'Stadtkreis';

  /// z. B. „Nordwestmecklenburg (Landkreis, Mecklenburg-Vorpommern)“.
  String get beschreibung => '$name ($art, $land)';
}

class Kette {
  const Kette(this.schluessel, this.name, this.alias);
  final String schluessel, name;
  final List<String> alias;
}

class Regionen {
  Regionen._(this.kreise, this.ketten, this._plz, this._orte) {
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
      _kreisNamen[k.schluessel] = {for (final n in namen) kompakt(n)};
    }
    for (final k in ketten.values) {
      for (final n in {k.schluessel, k.name, ...k.alias}) {
        (_ketteIndex[kompakt(n)] ??= {}).add(k.schluessel);
      }
    }
  }

  factory Regionen.ausJson(String regionenText, String kettenText) {
    final r = jsonDecode(regionenText) as Map<String, dynamic>;
    return Regionen._(
      {
        for (final k in r['kreise'] as List)
          k['s'] as String: Kreis(k['s'] as String, k['n'] as String, k['a'] as String, k['l'] as String, (k['k'] as List).cast<String>()),
      },
      {
        for (final k in (jsonDecode(kettenText) as Map)['ketten'] as List)
          k['s'] as String: Kette(k['s'] as String, k['n'] as String, (k['alias'] as List).cast<String>()),
      },
      {for (final e in (r['plz'] as Map).entries) e.key as String: (e.value as List).cast<String>()},
      [for (final o in r['orte'] as List) (name: o[0] as String, breite: (o[1] as num).toDouble(), laenge: (o[2] as num).toDouble(), kreis: o[3] as String)],
    );
  }

  final Map<String, Kreis> kreise;
  final Map<String, Kette> ketten;
  final Map<String, List<String>> _plz;
  final List<({String name, double breite, double laenge, String kreis})> _orte;
  final _kreisIndex = <String, Set<String>>{};
  final _kreisNamen = <String, Set<String>>{};
  final _ketteIndex = <String, Set<String>>{};

  /// Kreisschlüssel zu einer freien Eingabe, nur wenn eindeutig.
  String? kreisZu(String? text) => text == null ? null : _eindeutig(_kreisIndex[kompakt(text)]);

  /// Kettenschlüssel zu einer freien Eingabe, nur wenn eindeutig.
  String? ketteZu(String? text) => text == null ? null : _eindeutig(_ketteIndex[kompakt(text)]);

  static String? _eindeutig(Set<String>? s) => s != null && s.length == 1 ? s.first : null;

  /// Kreise zu einer Suche nach Name, Kfz-Kennzeichen, Postleitzahl oder
  /// Ort; genaue Treffer zuerst.
  List<Kreis> suchen(String text, {int max = 20}) {
    final t = kompakt(text);
    if (t.isEmpty) return const [];
    final treffer = <String>{};
    if (RegExp(r'^\d+$').hasMatch(t)) {
      if (kreise.containsKey(t)) treffer.add(t);
      if (t.length >= 3) {
        for (final e in _plz.entries) {
          if (e.key.startsWith(t)) treffer.addAll(e.value);
        }
      }
    } else {
      treffer.addAll(_kreisIndex[t] ?? const {});
      for (final e in _kreisNamen.entries) {
        if (e.value.any((n) => n.startsWith(t))) treffer.add(e.key);
      }
      if (t.length >= 3) {
        for (final o in _orte) {
          if (kompakt(o.name).startsWith(t)) treffer.add(o.kreis);
          if (treffer.length >= max * 2) break;
        }
      }
    }
    return [for (final s in treffer.take(max)) kreise[s]!];
  }

  /// Orte (Gemeinden) eines Kreises, die zur Suche passen — zur Anzeige,
  /// warum ein Kreis gefunden wurde.
  List<String> orteIn(String kreis, String text, {int max = 3}) {
    final t = kompakt(text);
    if (t.length < 3) return const [];
    return [for (final o in _orte) if (o.kreis == kreis && kompakt(o.name).startsWith(t)) o.name].take(max).toList();
  }

  /// Kreis des nächstgelegenen Gemeindemittelpunkts (ohne Netz).
  Kreis? kreisBei(double breite, double laenge) {
    String? beste;
    var abstand = double.infinity;
    for (final o in _orte) {
      final d = entfernungMeter(breite, laenge, o.breite, o.laenge);
      if (d < abstand) {
        abstand = d;
        beste = o.kreis;
      }
    }
    return beste == null || abstand > 50000 ? null : kreise[beste];
  }

  /// Ketten zu einer Suche (Name oder Schreibweise beginnt mit der Eingabe).
  List<Kette> kettenSuchen(String text) {
    final t = kompakt(text);
    return [
      for (final k in ketten.values)
        if (t.isEmpty || {k.name, ...k.alias}.any((n) => kompakt(n).startsWith(t))) k,
    ];
  }
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
