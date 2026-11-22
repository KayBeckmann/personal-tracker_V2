import 'datum.dart';

enum Rhythmus {
  taeglich('täglich', 'Tag', 'Tage'),
  woechentlich('wöchentlich', 'Woche', 'Wochen'),
  monatlich('monatlich', 'Monat', 'Monate'),
  jaehrlich('jährlich', 'Jahr', 'Jahre');

  const Rhythmus(this.bezeichnung, this.einheit, this.einheiten);
  final String bezeichnung;
  final String einheit;
  final String einheiten;
}

class Wiederholung {
  const Wiederholung(this.rhythmus, {this.intervall = 1, this.bis});

  final Rhythmus rhythmus;
  final int intervall;

  /// Letzter möglicher Tag (einschließlich), `null` = unbegrenzt.
  final DateTime? bis;

  String get beschreibung {
    final basis = intervall == 1 ? rhythmus.bezeichnung : 'alle $intervall ${rhythmus.einheiten}';
    return bis == null ? basis : '$basis bis ${bis!.day}.${bis!.month}.${bis!.year}';
  }

  Map<String, dynamic> toJson() => {
        'rhythmus': rhythmus.name,
        'intervall': intervall,
        if (bis != null) 'bis': tagIso(bis!),
      };

  static Wiederholung fromJson(Map<String, dynamic> j) => Wiederholung(
        Rhythmus.values.byName(j['rhythmus'] as String),
        intervall: (j['intervall'] as int?) ?? 1,
        bis: j['bis'] == null ? null : tagAusIso(j['bis'] as String),
      );
}

/// Ein Termin, ggf. mit Wiederholung. Zeiten sind lokale Wanduhrzeiten.
class Termin {
  const Termin({
    required this.id,
    required this.titel,
    required this.beginn,
    this.ende,
    this.ganztaegig = false,
    this.ort,
    this.notiz,
    this.wiederholung,
    this.ausnahmen = const {},
    this.erinnerungMinuten,
    required this.geaendert,
  });

  final String id;
  final String titel;
  final DateTime beginn;

  /// Ganztägig: letzter Tag (einschließlich); sonst Endzeitpunkt.
  final DateTime? ende;
  final bool ganztaegig;
  final String? ort;
  final String? notiz;
  final Wiederholung? wiederholung;

  /// Einzeln gelöschte Vorkommen einer Serie (Starttage).
  final Set<String> ausnahmen;

  /// Minuten vor Beginn; `null` = keine Erinnerung. Ganztägig: Minuten
  /// vor 09:00 am Tag.
  final int? erinnerungMinuten;
  final DateTime geaendert;

  /// Dauer eines Termins mit Uhrzeit.
  Duration get dauer => ganztaegig || ende == null ? Duration.zero : ende!.difference(beginn);

  /// Zusätzliche Kalendertage eines ganztägigen Termins (0 = ein Tag).
  int get spanneTage {
    final e = ende;
    if (!ganztaegig || e == null) return 0;
    final d = DateTime.utc(e.year, e.month, e.day).difference(DateTime.utc(beginn.year, beginn.month, beginn.day));
    return d.inDays < 0 ? 0 : d.inDays;
  }

  Termin kopie({
    String? titel,
    DateTime? beginn,
    DateTime? Function()? ende,
    bool? ganztaegig,
    String? Function()? ort,
    String? Function()? notiz,
    Wiederholung? Function()? wiederholung,
    Set<String>? ausnahmen,
    int? Function()? erinnerungMinuten,
    DateTime? geaendert,
  }) =>
      Termin(
        id: id,
        titel: titel ?? this.titel,
        beginn: beginn ?? this.beginn,
        ende: ende != null ? ende() : this.ende,
        ganztaegig: ganztaegig ?? this.ganztaegig,
        ort: ort != null ? ort() : this.ort,
        notiz: notiz != null ? notiz() : this.notiz,
        wiederholung: wiederholung != null ? wiederholung() : this.wiederholung,
        ausnahmen: ausnahmen ?? this.ausnahmen,
        erinnerungMinuten: erinnerungMinuten != null ? erinnerungMinuten() : this.erinnerungMinuten,
        geaendert: geaendert ?? this.geaendert,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'titel': titel,
        'beginn': zeitIso(beginn),
        if (ende != null) 'ende': zeitIso(ende!),
        'ganztaegig': ganztaegig,
        if (ort != null) 'ort': ort,
        if (notiz != null) 'notiz': notiz,
        if (wiederholung != null) 'wiederholung': wiederholung!.toJson(),
        if (ausnahmen.isNotEmpty) 'ausnahmen': (ausnahmen.toList()..sort()),
        if (erinnerungMinuten != null) 'erinnerungMinuten': erinnerungMinuten,
        'geaendert': geaendert.toUtc().toIso8601String(),
      };

  static Termin fromJson(Map<String, dynamic> j) => Termin(
        id: j['id'] as String,
        titel: j['titel'] as String,
        beginn: zeitAusIso(j['beginn'] as String),
        ende: j['ende'] == null ? null : zeitAusIso(j['ende'] as String),
        ganztaegig: j['ganztaegig'] == true,
        ort: j['ort'] as String?,
        notiz: j['notiz'] as String?,
        wiederholung: j['wiederholung'] == null
            ? null
            : Wiederholung.fromJson((j['wiederholung'] as Map).cast<String, dynamic>()),
        ausnahmen: {...((j['ausnahmen'] as List?) ?? const []).cast<String>()},
        erinnerungMinuten: j['erinnerungMinuten'] as int?,
        geaendert: DateTime.parse(j['geaendert'] as String),
      );
}

/// Ein konkretes Vorkommen eines (ggf. wiederkehrenden) Termins.
class Vorkommen {
  const Vorkommen(this.termin, this.beginn);

  final Termin termin;
  final DateTime beginn;

  /// Ganztägig: letzter Tag (Kalendertage, sommerzeitfest); sonst Endzeit.
  DateTime get ende => termin.ganztaegig
      ? DateTime(beginn.year, beginn.month, beginn.day + termin.spanneTage)
      : beginn.add(termin.dauer);

  /// Letzter Kalendertag, an dem das Vorkommen stattfindet.
  DateTime get letzterTag {
    if (termin.ganztaegig) return tagVon(ende);
    final e = ende;
    // Ein Termin bis 00:00 endet am Vortag.
    if (e.isAfter(beginn) && e.hour == 0 && e.minute == 0) return tagVon(e.subtract(const Duration(minutes: 1)));
    return tagVon(e);
  }

  /// Zeitpunkt der Erinnerung oder `null`.
  DateTime? get erinnerung {
    final m = termin.erinnerungMinuten;
    if (m == null) return null;
    final basis = termin.ganztaegig ? DateTime(beginn.year, beginn.month, beginn.day, 9) : beginn;
    return basis.subtract(Duration(minutes: m));
  }
}
