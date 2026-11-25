import 'datum.dart';
import 'termin.dart';

enum Prioritaet {
  niedrig('Niedrig'),
  normal('Normal'),
  hoch('Hoch');

  const Prioritaet(this.bezeichnung);
  final String bezeichnung;
}

/// Eine abgeschlossene Runde einer wiederkehrenden Aufgabe.
class Runde {
  const Runde(this.faellig, this.erledigt);

  final DateTime faellig;
  final DateTime erledigt;

  Map<String, dynamic> toJson() => {'faellig': tagIso(faellig), 'erledigt': erledigt.toUtc().toIso8601String()};

  static Runde fromJson(Map<String, dynamic> j) =>
      Runde(tagAusIso(j['faellig'] as String), DateTime.parse(j['erledigt'] as String));
}

/// Eine Aufgabe. Fälligkeit ist ein Kalendertag; eine Erinnerung gibt es
/// nur mit Fälligkeit und Uhrzeit. Wiederkehrende Aufgaben bekommen beim
/// Abhaken die nächste Fälligkeit (siehe [naechsteFaelligkeit]) — eine
/// Aufgabe wird nie automatisch zum Termin.
class Aufgabe {
  const Aufgabe({
    required this.id,
    required this.titel,
    this.notiz,
    this.faellig,
    this.erinnerungUm,
    this.prioritaet = Prioritaet.normal,
    this.wiederholung,
    this.serienStart,
    this.erledigt,
    this.verlauf = const [],
    required this.geaendert,
    this.raum,
  });

  /// Höchstens so viele Runden bleiben im Verlauf.
  static const verlaufMax = 50;

  final String id;
  final String titel;
  final String? notiz;
  final DateTime? faellig;

  /// Uhrzeit der Erinnerung am Fälligkeitstag als Minuten seit 0:00.
  final int? erinnerungUm;
  final Prioritaet prioritaet;
  final Wiederholung? wiederholung;

  /// Bezugstag der Serie: hält z. B. „monatlich am 31.“ stabil, auch wenn
  /// eine Runde in einem kürzeren Monat auf den 30. fiel.
  final DateTime? serienStart;

  /// Zeitpunkt des Abschlusses; `null` = offen.
  final DateTime? erledigt;
  final List<Runde> verlauf;
  final DateTime geaendert;

  /// Geteilter Kalender bzw. geteilte Liste (Raum-ID); `null` = privat.
  final String? raum;

  bool get offen => erledigt == null;

  /// Zeitpunkt der Erinnerung oder `null`.
  DateTime? get erinnerung {
    final f = faellig, m = erinnerungUm;
    if (f == null || m == null || !offen) return null;
    return DateTime(f.year, f.month, f.day, m ~/ 60, m % 60);
  }

  Aufgabe kopie({
    String? titel,
    String? Function()? notiz,
    DateTime? Function()? faellig,
    int? Function()? erinnerungUm,
    Prioritaet? prioritaet,
    Wiederholung? Function()? wiederholung,
    DateTime? Function()? serienStart,
    DateTime? Function()? erledigt,
    List<Runde>? verlauf,
    DateTime? geaendert,
    String? Function()? raum,
  }) =>
      Aufgabe(
        id: id,
        titel: titel ?? this.titel,
        notiz: notiz != null ? notiz() : this.notiz,
        faellig: faellig != null ? faellig() : this.faellig,
        erinnerungUm: erinnerungUm != null ? erinnerungUm() : this.erinnerungUm,
        prioritaet: prioritaet ?? this.prioritaet,
        wiederholung: wiederholung != null ? wiederholung() : this.wiederholung,
        serienStart: serienStart != null ? serienStart() : this.serienStart,
        erledigt: erledigt != null ? erledigt() : this.erledigt,
        verlauf: verlauf ?? this.verlauf,
        geaendert: geaendert ?? this.geaendert,
        raum: raum != null ? raum() : this.raum,
      );

  /// Abhaken am [jetzt]. Wiederkehrend: Runde in den Verlauf, nächste
  /// Fälligkeit setzen; endet die Serie, ist die Aufgabe erledigt.
  Aufgabe abschliessen(DateTime jetzt) {
    final f = faellig;
    final w = wiederholung;
    if (w == null || f == null) return kopie(erledigt: () => jetzt.toUtc());
    final runden = [Runde(f, jetzt.toUtc()), ...verlauf].take(verlaufMax).toList();
    final naechste = naechsteFaelligkeit(jetzt);
    if (naechste == null) return kopie(erledigt: () => jetzt.toUtc(), verlauf: runden);
    return kopie(faellig: () => naechste, serienStart: () => serienStart ?? f, verlauf: runden);
  }

  /// Erledigte einmalige Aufgabe wieder öffnen.
  Aufgabe wiedereroeffnen() => kopie(erledigt: () => null);

  /// Nächste Fälligkeit nach dem Abhaken am [jetzt]: der erste Serientag
  /// nach dem späteren von bisheriger Fälligkeit und heute. Verpasste
  /// Runden werden also nicht nachgeholt; wer früher abhakt, überspringt
  /// keine Runde. Monatlich am 31. fällt in kürzeren Monaten auf den
  /// letzten Tag. `null`, wenn das Serienende überschritten ist.
  DateTime? naechsteFaelligkeit(DateTime jetzt) {
    final w = wiederholung, f = faellig;
    if (w == null || f == null) return null;
    final start = tagVon(serienStart ?? f);
    final heute = tagVon(jetzt);
    final nach = f.isAfter(heute) ? tagVon(f) : heute;
    DateTime nTer(int n) {
      final s = n * w.intervall;
      return switch (w.rhythmus) {
        Rhythmus.taeglich => DateTime(start.year, start.month, start.day + s),
        Rhythmus.woechentlich => DateTime(start.year, start.month, start.day + 7 * s),
        Rhythmus.monatlich => _geklemmt(start.year, start.month + s, start.day),
        Rhythmus.jaehrlich => _geklemmt(start.year + s, start.month, start.day),
      };
    }

    // Grob vorspringen, dann exakt suchen.
    final tage = DateTime.utc(nach.year, nach.month, nach.day).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
    var n = switch (w.rhythmus) {
      Rhythmus.taeglich => tage ~/ w.intervall,
      Rhythmus.woechentlich => tage ~/ (7 * w.intervall),
      Rhythmus.monatlich => ((nach.year - start.year) * 12 + nach.month - start.month - 1) ~/ w.intervall,
      Rhythmus.jaehrlich => (nach.year - start.year - 1) ~/ w.intervall,
    };
    if (n < 0) n = 0;
    while (!nTer(n).isAfter(nach)) {
      n++;
    }
    final ergebnis = nTer(n);
    final bis = w.bis;
    return bis != null && ergebnis.isAfter(tagVon(bis)) ? null : ergebnis;
  }

  static DateTime _geklemmt(int jahr, int monat, int tag) {
    final letzter = DateTime(jahr, monat + 1, 0).day;
    return DateTime(jahr, monat, tag > letzter ? letzter : tag);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'titel': titel,
        if (notiz != null) 'notiz': notiz,
        if (faellig != null) 'faellig': tagIso(faellig!),
        if (erinnerungUm != null) 'erinnerungUm': erinnerungUm,
        'prioritaet': prioritaet.name,
        if (wiederholung != null) 'wiederholung': wiederholung!.toJson(),
        if (serienStart != null) 'serienStart': tagIso(serienStart!),
        if (erledigt != null) 'erledigt': erledigt!.toUtc().toIso8601String(),
        if (verlauf.isNotEmpty) 'verlauf': [for (final r in verlauf) r.toJson()],
        'geaendert': geaendert.toUtc().toIso8601String(),
        if (raum != null) 'raum': raum,
      };

  static Aufgabe fromJson(Map<String, dynamic> j) => Aufgabe(
        id: j['id'] as String,
        titel: j['titel'] as String,
        notiz: j['notiz'] as String?,
        faellig: j['faellig'] == null ? null : tagAusIso(j['faellig'] as String),
        erinnerungUm: j['erinnerungUm'] as int?,
        prioritaet: Prioritaet.values.byName((j['prioritaet'] as String?) ?? 'normal'),
        wiederholung: j['wiederholung'] == null
            ? null
            : Wiederholung.fromJson((j['wiederholung'] as Map).cast<String, dynamic>()),
        serienStart: j['serienStart'] == null ? null : tagAusIso(j['serienStart'] as String),
        erledigt: j['erledigt'] == null ? null : DateTime.parse(j['erledigt'] as String),
        verlauf: [for (final r in (j['verlauf'] as List?) ?? const []) Runde.fromJson((r as Map).cast<String, dynamic>())],
        geaendert: DateTime.parse(j['geaendert'] as String),
        raum: j['raum'] as String?,
      );
}
