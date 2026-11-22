import '../modell/datum.dart';
import '../modell/termin.dart';

/// Alle Vorkommen von [termin], die den Zeitraum [von]–[bis] (Tage,
/// einschließlich) berühren, nach Beginn sortiert.
///
/// Regeln: Wiederholungen behalten die Wanduhrzeit (sommerzeitfest).
/// Monatlich am 31. bzw. jährlich am 29.02. entfällt in Monaten/Jahren
/// ohne diesen Tag (kein Verschieben). Einzeln gelöschte Vorkommen
/// ([Termin.ausnahmen]) fehlen.
List<Vorkommen> vorkommenIm(Termin termin, DateTime von, DateTime bis) {
  final vonTag = tagVon(von), bisTag = tagVon(bis);
  final w = termin.wiederholung;
  final ergebnis = <Vorkommen>[];

  bool beruehrt(Vorkommen v) => !tagVon(v.beginn).isAfter(bisTag) && !v.letzterTag.isBefore(vonTag);

  if (w == null) {
    final v = Vorkommen(termin, termin.beginn);
    if (beruehrt(v)) ergebnis.add(v);
    return ergebnis;
  }

  final b = termin.beginn;
  final grenze = w.bis != null && w.bis!.isBefore(bisTag) ? tagVon(w.bis!) : bisTag;
  // Vorkommen, die vor [von] beginnen, aber hineinreichen, mitnehmen.
  final vorlauf = termin.ganztaegig ? termin.spanneTage : termin.dauer.inDays + 1;
  final startSuche = vonTag.subtract(Duration(days: vorlauf));

  DateTime? nTes(int n) {
    final schritt = n * w.intervall;
    switch (w.rhythmus) {
      case Rhythmus.taeglich:
        return DateTime(b.year, b.month, b.day + schritt, b.hour, b.minute);
      case Rhythmus.woechentlich:
        return DateTime(b.year, b.month, b.day + 7 * schritt, b.hour, b.minute);
      case Rhythmus.monatlich:
        final d = DateTime(b.year, b.month + schritt, b.day, b.hour, b.minute);
        return d.day == b.day ? d : null;
      case Rhythmus.jaehrlich:
        final d = DateTime(b.year + schritt, b.month, b.day, b.hour, b.minute);
        return d.day == b.day && d.month == b.month ? d : null;
    }
  }

  // Erstes relevantes n schätzen, statt eine lange Serie ab Beginn
  // durchzulaufen.
  final abstandTage = DateTime.utc(startSuche.year, startSuche.month, startSuche.day)
      .difference(DateTime.utc(b.year, b.month, b.day))
      .inDays;
  var n = 0;
  if (abstandTage > 0) {
    n = switch (w.rhythmus) {
      Rhythmus.taeglich => abstandTage ~/ w.intervall,
      Rhythmus.woechentlich => abstandTage ~/ (7 * w.intervall),
      Rhythmus.monatlich => ((startSuche.year - b.year) * 12 + startSuche.month - b.month - 1) ~/ w.intervall,
      Rhythmus.jaehrlich => (startSuche.year - b.year - 1) ~/ w.intervall,
    };
    if (n < 0) n = 0;
  }

  for (var sicherung = 0; sicherung < 5000; sicherung++, n++) {
    final start = nTes(n);
    if (start == null) continue;
    if (tagVon(start).isAfter(grenze)) break;
    if (termin.ausnahmen.contains(tagIso(start))) continue;
    final v = Vorkommen(termin, start);
    if (beruehrt(v)) ergebnis.add(v);
  }
  return ergebnis;
}

/// Vorkommen aller Termine im Zeitraum, sortiert (ganztägig zuerst).
List<Vorkommen> alleVorkommen(Iterable<Termin> termine, DateTime von, DateTime bis) {
  final alle = [for (final t in termine) ...vorkommenIm(t, von, bis)];
  alle.sort((a, b) {
    final t = tagVon(a.beginn).compareTo(tagVon(b.beginn));
    if (t != 0) return t;
    if (a.termin.ganztaegig != b.termin.ganztaegig) return a.termin.ganztaegig ? -1 : 1;
    return a.beginn.compareTo(b.beginn);
  });
  return alle;
}
