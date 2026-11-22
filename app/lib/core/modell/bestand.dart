import 'finanzen.dart';
import 'notiz.dart';
import 'termin.dart';

/// Entschlüsselter Datenbestand im Speicher (nur solange entsperrt).
class Bestand {
  const Bestand({
    this.termine = const {},
    this.notizen = const {},
    this.konten = const {},
    this.buchungen = const {},
    this.plaene = const {},
    this.einstellungen = const Einstellungen(),
  });

  final Map<String, Termin> termine;
  final Map<String, Notiz> notizen;
  final Map<String, Konto> konten;
  final Map<String, Buchung> buchungen;
  final Map<String, Plan> plaene;
  final Einstellungen einstellungen;

  Bestand kopie({
    Map<String, Termin>? termine,
    Map<String, Notiz>? notizen,
    Map<String, Konto>? konten,
    Map<String, Buchung>? buchungen,
    Map<String, Plan>? plaene,
    Einstellungen? einstellungen,
  }) =>
      Bestand(
        termine: termine ?? this.termine,
        notizen: notizen ?? this.notizen,
        konten: konten ?? this.konten,
        buchungen: buchungen ?? this.buchungen,
        plaene: plaene ?? this.plaene,
        einstellungen: einstellungen ?? this.einstellungen,
      );

  /// Kontostand: Anfangssaldo plus alle gebuchten Buchungen (inklusive
  /// Umbuchungen). Geplantes zählt nicht.
  int saldoCent(String kontoId) {
    var s = konten[kontoId]?.anfangssaldoCent ?? 0;
    for (final b in buchungen.values) {
      if (b.kontoId == kontoId && b.gebucht) s += b.betragCent;
    }
    return s;
  }

  /// Die Gegenbuchung einer Umbuchung.
  Buchung? gegenbuchung(Buchung b) => b.umbuchungId == null
      ? null
      : buchungen.values.where((x) => x.umbuchungId == b.umbuchungId && x.id != b.id).firstOrNull;

  List<Notiz> get notizenNeuesteZuerst => notizen.values.toList()..sort((a, b) => b.geaendert.compareTo(a.geaendert));

  List<Konto> get kontenSortiert => konten.values.toList()
    ..sort((a, b) {
      if (a.archiviert != b.archiviert) return a.archiviert ? 1 : -1;
      final art = a.art.index.compareTo(b.art.index);
      return art != 0 ? art : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  int get anzahlDatensaetze => termine.length + notizen.length + konten.length + buchungen.length + plaene.length;
}
