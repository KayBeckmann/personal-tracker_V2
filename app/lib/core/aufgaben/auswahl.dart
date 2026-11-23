import '../modell/aufgabe.dart';
import '../modell/datum.dart';

/// Gruppen der Aufgabenliste, in dieser Reihenfolge.
enum Gruppe {
  ueberfaellig('Überfällig'),
  heute('Heute'),
  woche('Nächste 7 Tage'),
  spaeter('Später'),
  ohneDatum('Ohne Datum');

  const Gruppe(this.titel);
  final String titel;
}

Gruppe gruppeVon(Aufgabe a, DateTime heute) {
  final f = a.faellig;
  if (f == null) return Gruppe.ohneDatum;
  final t = tagVon(heute);
  if (f.isBefore(t)) return Gruppe.ueberfaellig;
  if (gleicherTag(f, t)) return Gruppe.heute;
  if (!f.isAfter(DateTime(t.year, t.month, t.day + 7))) return Gruppe.woche;
  return Gruppe.spaeter;
}

/// Wichtigere zuerst, dann früher fällig, dann ohne Datum, dann Titel.
int vergleichen(Aufgabe a, Aufgabe b) {
  final p = b.prioritaet.index.compareTo(a.prioritaet.index);
  if (p != 0) return p;
  final fa = a.faellig, fb = b.faellig;
  if (fa != null && fb != null && fa != fb) return fa.compareTo(fb);
  if ((fa == null) != (fb == null)) return fa == null ? 1 : -1;
  return a.titel.toLowerCase().compareTo(b.titel.toLowerCase());
}

/// Offene Aufgaben nach [Gruppe], innerhalb sortiert nach [vergleichen].
Map<Gruppe, List<Aufgabe>> gruppieren(Iterable<Aufgabe> aufgaben, DateTime heute) {
  final g = {for (final x in Gruppe.values) x: <Aufgabe>[]};
  for (final a in aufgaben) {
    if (a.offen) g[gruppeVon(a, heute)]!.add(a);
  }
  for (final l in g.values) {
    l.sort(vergleichen);
  }
  return g;
}

/// Auswahl für die Übersicht. Jede Aufgabe erscheint höchstens einmal:
///
/// - **Überfällig:** alle offenen mit Fälligkeit vor heute (eigener Block).
/// - **Heute:** bis zu [proBlock] heute fällige, wichtigste zuerst.
/// - **Diese Woche:** bis zu [proBlock] in den nächsten 7 Tagen fällige
///   mit Priorität normal oder hoch, dazu hohe ohne Datum; hohe zuerst.
///   Niedrige erscheinen nur in der Aufgabenliste.
class TagesAuswahl {
  TagesAuswahl(Iterable<Aufgabe> aufgaben, DateTime heute, {this.proBlock = 2}) {
    final g = gruppieren(aufgaben, heute);
    ueberfaellig = g[Gruppe.ueberfaellig]!;
    final h = g[Gruppe.heute]!;
    this.heute = h.take(proBlock).toList();
    heuteWeitere = h.length - this.heute.length;
    final w = [
      ...g[Gruppe.woche]!.where((a) => a.prioritaet != Prioritaet.niedrig),
      ...g[Gruppe.ohneDatum]!.where((a) => a.prioritaet == Prioritaet.hoch),
    ]..sort(vergleichen);
    woche = w.take(proBlock).toList();
    wocheWeitere = w.length - woche.length;
  }

  final int proBlock;
  late final List<Aufgabe> ueberfaellig;
  late final List<Aufgabe> heute;
  late final int heuteWeitere;
  late final List<Aufgabe> woche;
  late final int wocheWeitere;
}
