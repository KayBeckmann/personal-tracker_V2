import 'datum.dart';

enum KontoArt {
  bargeld('Bargeld'),
  bank('Bank'),
  depot('Depot'),
  sonstiges('Sonstiges');

  const KontoArt(this.bezeichnung);
  final String bezeichnung;
}

/// Konto im Haushaltsbuch. Beträge in Cent (nur EUR in M1). Ein Depot
/// ist ein normales Konto ohne Kurswerte: sein Saldo ergibt sich nur aus
/// Buchungen.
class Konto {
  const Konto({
    required this.id,
    required this.name,
    required this.art,
    this.anfangssaldoCent = 0,
    this.archiviert = false,
    required this.geaendert,
  });

  final String id;
  final String name;
  final KontoArt art;
  final int anfangssaldoCent;
  final bool archiviert;
  final DateTime geaendert;

  Konto kopie({String? name, KontoArt? art, int? anfangssaldoCent, bool? archiviert, DateTime? geaendert}) => Konto(
        id: id,
        name: name ?? this.name,
        art: art ?? this.art,
        anfangssaldoCent: anfangssaldoCent ?? this.anfangssaldoCent,
        archiviert: archiviert ?? this.archiviert,
        geaendert: geaendert ?? this.geaendert,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'art': art.name,
        'anfangssaldoCent': anfangssaldoCent,
        'archiviert': archiviert,
        'geaendert': geaendert.toUtc().toIso8601String(),
      };

  static Konto fromJson(Map<String, dynamic> j) => Konto(
        id: j['id'] as String,
        name: j['name'] as String,
        art: KontoArt.values.byName(j['art'] as String),
        anfangssaldoCent: (j['anfangssaldoCent'] as int?) ?? 0,
        archiviert: j['archiviert'] == true,
        geaendert: DateTime.parse(j['geaendert'] as String),
      );
}

enum BuchungsStatus {
  gebucht('gebucht'),
  geplant('geplant');

  const BuchungsStatus(this.bezeichnung);
  final String bezeichnung;
}

/// Buchung: genau ein Konto. Negativ = Ausgabe, positiv = Einnahme.
/// Eine Umbuchung besteht aus zwei Buchungen mit derselben
/// [umbuchungId] (Abgang negativ, Zugang positiv) und zählt nie als
/// Einnahme oder Ausgabe.
class Buchung {
  const Buchung({
    required this.id,
    required this.kontoId,
    required this.datum,
    required this.empfaenger,
    required this.betragCent,
    required this.status,
    this.bemerkung,
    this.umbuchungId,
    this.planId,
    this.planMonat,
    this.ausPlanung = false,
    required this.geaendert,
  });

  final String id;
  final String kontoId;
  final DateTime datum;
  final String empfaenger;
  final int betragCent;
  final BuchungsStatus status;
  final String? bemerkung;
  final String? umbuchungId;

  /// Gebuchtes Vorkommen eines wiederkehrenden [Plan]s.
  final String? planId;
  final Monat? planMonat;

  /// War als einmalig geplanter Posten erfasst und wurde dann gebucht —
  /// zählt nicht zu den variablen Ausgaben.
  final bool ausPlanung;
  final DateTime geaendert;

  bool get istUmbuchung => umbuchungId != null;
  bool get gebucht => status == BuchungsStatus.gebucht;

  /// Weder geplant noch aus einem Plan: Grundlage der Durchschnittsschätzung.
  bool get variabel => !istUmbuchung && planId == null && !ausPlanung;

  Buchung kopie({
    String? kontoId,
    DateTime? datum,
    String? empfaenger,
    int? betragCent,
    BuchungsStatus? status,
    String? Function()? bemerkung,
    bool? ausPlanung,
    DateTime? geaendert,
  }) =>
      Buchung(
        id: id,
        kontoId: kontoId ?? this.kontoId,
        datum: datum ?? this.datum,
        empfaenger: empfaenger ?? this.empfaenger,
        betragCent: betragCent ?? this.betragCent,
        status: status ?? this.status,
        bemerkung: bemerkung != null ? bemerkung() : this.bemerkung,
        umbuchungId: umbuchungId,
        planId: planId,
        planMonat: planMonat,
        ausPlanung: ausPlanung ?? this.ausPlanung,
        geaendert: geaendert ?? this.geaendert,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kontoId': kontoId,
        'datum': tagIso(datum),
        'empfaenger': empfaenger,
        'betragCent': betragCent,
        'status': status.name,
        if (bemerkung != null) 'bemerkung': bemerkung,
        if (umbuchungId != null) 'umbuchungId': umbuchungId,
        if (planId != null) 'planId': planId,
        if (planMonat != null) 'planMonat': monatIso(planMonat!),
        if (ausPlanung) 'ausPlanung': true,
        'geaendert': geaendert.toUtc().toIso8601String(),
      };

  static Buchung fromJson(Map<String, dynamic> j) => Buchung(
        id: j['id'] as String,
        kontoId: j['kontoId'] as String,
        datum: tagAusIso(j['datum'] as String),
        empfaenger: (j['empfaenger'] as String?) ?? '',
        betragCent: j['betragCent'] as int,
        status: BuchungsStatus.values.byName(j['status'] as String),
        bemerkung: j['bemerkung'] as String?,
        umbuchungId: j['umbuchungId'] as String?,
        planId: j['planId'] as String?,
        planMonat: j['planMonat'] == null ? null : monatAusIso(j['planMonat'] as String),
        ausPlanung: j['ausPlanung'] == true,
        geaendert: DateTime.parse(j['geaendert'] as String),
      );
}

/// Monatlich wiederkehrender geplanter Posten (z. B. Miete). Ein
/// Vorkommen gilt als erledigt, sobald eine Buchung mit [id] und dem
/// Monat existiert.
class Plan {
  const Plan({
    required this.id,
    required this.kontoId,
    required this.empfaenger,
    required this.betragCent,
    required this.tag,
    required this.ab,
    this.bis,
    this.bemerkung,
    required this.geaendert,
  });

  final String id;
  final String kontoId;
  final String empfaenger;
  final int betragCent;

  /// Tag im Monat (1–31); in kürzeren Monaten der letzte Tag.
  final int tag;
  final Monat ab;
  final Monat? bis;
  final String? bemerkung;
  final DateTime geaendert;

  bool giltIm(Monat m) => m >= ab && (bis == null || m <= bis!);

  DateTime faelligIm(Monat m) {
    final t = tag > tageImMonat(m) ? tageImMonat(m) : tag;
    return DateTime(monatJahr(m), monatNummer(m), t);
  }

  Plan kopie({
    String? kontoId,
    String? empfaenger,
    int? betragCent,
    int? tag,
    Monat? ab,
    Monat? Function()? bis,
    String? Function()? bemerkung,
    DateTime? geaendert,
  }) =>
      Plan(
        id: id,
        kontoId: kontoId ?? this.kontoId,
        empfaenger: empfaenger ?? this.empfaenger,
        betragCent: betragCent ?? this.betragCent,
        tag: tag ?? this.tag,
        ab: ab ?? this.ab,
        bis: bis != null ? bis() : this.bis,
        bemerkung: bemerkung != null ? bemerkung() : this.bemerkung,
        geaendert: geaendert ?? this.geaendert,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kontoId': kontoId,
        'empfaenger': empfaenger,
        'betragCent': betragCent,
        'tag': tag,
        'ab': monatIso(ab),
        if (bis != null) 'bis': monatIso(bis!),
        if (bemerkung != null) 'bemerkung': bemerkung,
        'geaendert': geaendert.toUtc().toIso8601String(),
      };

  static Plan fromJson(Map<String, dynamic> j) => Plan(
        id: j['id'] as String,
        kontoId: j['kontoId'] as String,
        empfaenger: (j['empfaenger'] as String?) ?? '',
        betragCent: j['betragCent'] as int,
        tag: j['tag'] as int,
        ab: monatAusIso(j['ab'] as String),
        bis: j['bis'] == null ? null : monatAusIso(j['bis'] as String),
        bemerkung: j['bemerkung'] as String?,
        geaendert: DateTime.parse(j['geaendert'] as String),
      );
}

/// Persönliche Einstellungen (verschlüsselt gespeichert).
class Einstellungen {
  const Einstellungen({this.ausgabenrahmenCent, this.erinnerungMitTitel = false, this.letzteSicherung, this.vaultMaxMiB = 100});

  /// Selbst gesetzter monatlicher Ausgabenrahmen — getrennt von der
  /// berechneten Prognose.
  final int? ausgabenrahmenCent;

  /// Termin- und Aufgabentitel in Benachrichtigungen zeigen (Standard: nein, damit
  /// nichts im Sperrbildschirm oder im Planungsspeicher des Systems steht).
  final bool erinnerungMitTitel;
  final DateTime? letzteSicherung;

  /// Größte Vault-Datei, die diese App hochlädt (MiB). Größere bleiben
  /// lokal und werden als „zu groß“ angezeigt.
  final int vaultMaxMiB;

  Einstellungen kopie({int? Function()? ausgabenrahmenCent, bool? erinnerungMitTitel, DateTime? letzteSicherung, int? vaultMaxMiB}) =>
      Einstellungen(
        ausgabenrahmenCent: ausgabenrahmenCent != null ? ausgabenrahmenCent() : this.ausgabenrahmenCent,
        erinnerungMitTitel: erinnerungMitTitel ?? this.erinnerungMitTitel,
        letzteSicherung: letzteSicherung ?? this.letzteSicherung,
        vaultMaxMiB: vaultMaxMiB ?? this.vaultMaxMiB,
      );

  Map<String, dynamic> toJson() => {
        'id': 'app',
        if (ausgabenrahmenCent != null) 'ausgabenrahmenCent': ausgabenrahmenCent,
        'erinnerungMitTitel': erinnerungMitTitel,
        if (letzteSicherung != null) 'letzteSicherung': letzteSicherung!.toUtc().toIso8601String(),
        if (vaultMaxMiB != 100) 'vaultMaxMiB': vaultMaxMiB,
      };

  static Einstellungen fromJson(Map<String, dynamic> j) => Einstellungen(
        ausgabenrahmenCent: j['ausgabenrahmenCent'] as int?,
        erinnerungMitTitel: j['erinnerungMitTitel'] == true,
        letzteSicherung: j['letzteSicherung'] == null ? null : DateTime.parse(j['letzteSicherung'] as String),
        vaultMaxMiB: (j['vaultMaxMiB'] as int?) ?? 100,
      );
}
