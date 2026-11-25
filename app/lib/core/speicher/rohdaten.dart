import '../modell/aufgabe.dart';
import '../modell/bestand.dart';
import '../modell/finanzen.dart';
import '../modell/konflikt.dart';
import '../modell/notiz.dart';
import '../modell/termin.dart';
import '../raeume/raum.dart';
import 'backup.dart';
import 'schema.dart';

Rohdaten rohdatenVon(Bestand b) => {
      'termine': [for (final t in b.termine.values) t.toJson()],
      'aufgaben': [for (final a in b.aufgaben.values) a.toJson()],
      'notizen': [for (final n in b.notizen.values) n.toJson()],
      'konten': [for (final k in b.konten.values) k.toJson()],
      'buchungen': [for (final x in b.buchungen.values) x.toJson()],
      'plaene': [for (final p in b.plaene.values) p.toJson()],
      'konflikte': [for (final k in b.konflikte.values) k.toJson()],
      'raeume': [for (final r in b.raeume.values) r.toJson()],
      'einstellungen': [b.einstellungen.toJson()],
    };

/// Baut aus Rohdaten einen Bestand; wirft bei unlesbaren Datensätzen und
/// bei Buchungen ohne vorhandenes Konto, statt halbe Daten zu übernehmen.
Bestand bestandAus(Rohdaten d) {
  T lies<T>(String bereich, Map<String, dynamic> j, T Function(Map<String, dynamic>) f) {
    try {
      return f(j);
    } catch (_) {
      throw BackupFehler('Ein Datensatz in „$bereich“ ist beschädigt (${j['id'] ?? 'ohne ID'}).');
    }
  }

  Map<String, T> bereich<T>(String name, T Function(Map<String, dynamic>) f, String Function(T) id) => {
        for (final j in d[name] ?? const <Map<String, dynamic>>[])
          for (final x in [lies(name, j, f)]) id(x): x,
      };

  final konten = bereich('konten', Konto.fromJson, (k) => k.id);
  final buchungen = bereich('buchungen', Buchung.fromJson, (b) => b.id);
  final plaene = bereich('plaene', Plan.fromJson, (p) => p.id);
  for (final b in [...buchungen.values.map((b) => b.kontoId), ...plaene.values.map((p) => p.kontoId)]) {
    if (!konten.containsKey(b)) throw BackupFehler('Eine Buchung verweist auf ein fehlendes Konto.');
  }
  final einst = d['einstellungen'] ?? const [];
  return Bestand(
    termine: bereich('termine', Termin.fromJson, (t) => t.id),
    aufgaben: bereich('aufgaben', Aufgabe.fromJson, (a) => a.id),
    notizen: bereich('notizen', Notiz.fromJson, (n) => n.id),
    konten: konten,
    buchungen: buchungen,
    plaene: plaene,
    konflikte: bereich('konflikte', Konflikt.fromJson, (k) => k.id),
    raeume: bereich('raeume', Raum.fromJson, (r) => r.id),
    einstellungen: einst.isEmpty ? const Einstellungen() : lies('einstellungen', einst.first, Einstellungen.fromJson),
  );
}
