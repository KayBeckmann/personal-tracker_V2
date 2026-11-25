import 'dart:math' as math;

import 'datum.dart';

/// Mengeneinheiten für Posten und Packungen. Gramm/Kilogramm und
/// Milliliter/Liter lassen sich ineinander umrechnen, Stück nur mit Stück.
enum Einheit {
  stueck('Stück', 'Stück', 1),
  packung('Packung', 'Packung', 1),
  g('g', 'g', 1),
  kg('kg', 'g', 1000),
  ml('ml', 'ml', 1),
  l('l', 'ml', 1000);

  const Einheit(this.kurz, this.basis, this.faktor);
  final String kurz;

  /// Basiseinheit für Vergleiche (g, ml, Stück).
  final String basis;
  final int faktor;

  /// Einheit des Grundpreises (je kg, je l, je Stück).
  String get grundpreisEinheit => switch (basis) {
        'g' => 'kg',
        'ml' => 'l',
        _ => 'Stück',
      };

  int get grundpreisFaktor => basis == 'Stück' ? 1 : 1000;
}

/// Eine konkrete Filiale; zwei Filialen derselben Kette bleiben getrennt.
class Filiale {
  const Filiale({
    required this.id,
    required this.kette,
    required this.name,
    this.region,
    this.breite,
    this.laenge,
    required this.geaendert,
    this.raum,
  });

  final String id;

  /// z. B. „Aldi Süd“.
  final String kette;

  /// z. B. „Hauptstraße, Musterstadt“.
  final String name;

  /// Optional: Preisregion, z. B. „Musterstadt“.
  final String? region;

  /// Kartenposition (WGS84), nur auf ausdrücklichen Wunsch erfasst.
  final double? breite;
  final double? laenge;
  final DateTime geaendert;

  /// Geteilt mit einer Einkaufsliste (Raum-ID); `null` = privat.
  final String? raum;

  String get anzeige => '$kette · $name';
  bool get hatPosition => breite != null && laenge != null;

  Filiale kopie({String? kette, String? name, String? Function()? region, double? Function()? breite, double? Function()? laenge, DateTime? geaendert, String? Function()? raum}) =>
      Filiale(
        id: id,
        kette: kette ?? this.kette,
        name: name ?? this.name,
        region: region != null ? region() : this.region,
        breite: breite != null ? breite() : this.breite,
        laenge: laenge != null ? laenge() : this.laenge,
        geaendert: geaendert ?? this.geaendert,
        raum: raum != null ? raum() : this.raum,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kette': kette,
        'name': name,
        if (region != null) 'region': region,
        if (breite != null) 'breite': breite,
        if (laenge != null) 'laenge': laenge,
        'geaendert': geaendert.toUtc().toIso8601String(),
        if (raum != null) 'raum': raum,
      };

  static Filiale fromJson(Map<String, dynamic> j) => Filiale(
        id: j['id'] as String,
        kette: j['kette'] as String,
        name: j['name'] as String,
        region: j['region'] as String?,
        breite: (j['breite'] as num?)?.toDouble(),
        laenge: (j['laenge'] as num?)?.toDouble(),
        geaendert: DateTime.parse(j['geaendert'] as String),
        raum: j['raum'] as String?,
      );
}

/// Entfernung in Metern (Haversine).
double entfernungMeter(double b1, double l1, double b2, double l2) {
  const r = 6371000.0;
  double rad(double g) => g * math.pi / 180;
  final db = rad(b2 - b1), dl = rad(l2 - l1);
  final a = math.sin(db / 2) * math.sin(db / 2) + math.cos(rad(b1)) * math.cos(rad(b2)) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// Normalisierter Artikelname (für Preise und Posten).
String artikelSchluessel(String name, [String? variante]) {
  final n = name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  final v = variante?.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ') ?? '';
  return v.isEmpty ? n : '$n|$v';
}

/// Ein beobachteter Preis: konkrete Packung in einer Filiale zu einem Tag.
class Preis {
  const Preis({
    required this.id,
    required this.artikel,
    this.variante,
    required this.filialeId,
    required this.packungsPreisCent,
    required this.packungsMenge,
    required this.packungsEinheit,
    required this.datum,
    this.quelle = 'selbst',
    required this.geaendert,
    this.raum,
  });

  final String id;

  /// Artikelname wie eingegeben (z. B. „Hafermilch“).
  final String artikel;
  final String? variante;
  final String filialeId;
  final int packungsPreisCent;

  /// Inhalt einer Packung, z. B. 1 (l) oder 500 (g).
  final double packungsMenge;
  final Einheit packungsEinheit;

  /// Tag der Beobachtung.
  final DateTime datum;

  /// Woher der Preis stammt (`selbst`, `kassenbon`).
  final String quelle;
  final DateTime geaendert;
  final String? raum;

  String get schluessel => artikelSchluessel(artikel, variante);

  /// Preis je kg, je l oder je Stück in Cent (gerundet).
  int? get grundpreisCent {
    if (packungsEinheit == Einheit.packung || packungsMenge <= 0) return null;
    final basisMenge = packungsMenge * packungsEinheit.faktor;
    return (packungsPreisCent * packungsEinheit.grundpreisFaktor / basisMenge).round();
  }

  Preis kopie({DateTime? geaendert, String? Function()? raum}) => Preis(
        id: id,
        artikel: artikel,
        variante: variante,
        filialeId: filialeId,
        packungsPreisCent: packungsPreisCent,
        packungsMenge: packungsMenge,
        packungsEinheit: packungsEinheit,
        datum: datum,
        quelle: quelle,
        geaendert: geaendert ?? this.geaendert,
        raum: raum != null ? raum() : this.raum,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'artikel': artikel,
        if (variante != null) 'variante': variante,
        'filialeId': filialeId,
        'packungsPreisCent': packungsPreisCent,
        'packungsMenge': packungsMenge,
        'packungsEinheit': packungsEinheit.name,
        'datum': tagIso(datum),
        'quelle': quelle,
        'geaendert': geaendert.toUtc().toIso8601String(),
        if (raum != null) 'raum': raum,
      };

  static Preis fromJson(Map<String, dynamic> j) => Preis(
        id: j['id'] as String,
        artikel: j['artikel'] as String,
        variante: j['variante'] as String?,
        filialeId: j['filialeId'] as String,
        packungsPreisCent: j['packungsPreisCent'] as int,
        packungsMenge: (j['packungsMenge'] as num).toDouble(),
        packungsEinheit: Einheit.values.byName(j['packungsEinheit'] as String),
        datum: tagAusIso(j['datum'] as String),
        quelle: (j['quelle'] as String?) ?? 'selbst',
        geaendert: DateTime.parse(j['geaendert'] as String),
        raum: j['raum'] as String?,
      );
}

class Einkaufsliste {
  const Einkaufsliste({required this.id, required this.name, this.filialeId, required this.geaendert, this.raum});

  final String id;
  final String name;

  /// Filiale, für die geschätzt wird (und in der eingekauft wird).
  final String? filialeId;
  final DateTime geaendert;
  final String? raum;

  Einkaufsliste kopie({String? name, String? Function()? filialeId, DateTime? geaendert, String? Function()? raum}) => Einkaufsliste(
        id: id,
        name: name ?? this.name,
        filialeId: filialeId != null ? filialeId() : this.filialeId,
        geaendert: geaendert ?? this.geaendert,
        raum: raum != null ? raum() : this.raum,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (filialeId != null) 'filialeId': filialeId,
        'geaendert': geaendert.toUtc().toIso8601String(),
        if (raum != null) 'raum': raum,
      };

  static Einkaufsliste fromJson(Map<String, dynamic> j) => Einkaufsliste(
        id: j['id'] as String,
        name: j['name'] as String,
        filialeId: j['filialeId'] as String?,
        geaendert: DateTime.parse(j['geaendert'] as String),
        raum: j['raum'] as String?,
      );
}

/// Ein Posten auf einer Liste.
class Posten {
  const Posten({
    required this.id,
    required this.listeId,
    required this.name,
    this.variante,
    this.menge = 1,
    this.einheit = Einheit.stueck,
    this.notiz,
    this.abgehakt = false,
    this.einkaufId,
    required this.geaendert,
    this.raum,
  });

  final String id;
  final String listeId;
  final String name;
  final String? variante;
  final double menge;
  final Einheit einheit;
  final String? notiz;

  /// Im Wagen (vor dem Abschließen).
  final bool abgehakt;

  /// Gekauft mit diesem Einkauf; danach nicht mehr auf der Liste.
  final String? einkaufId;
  final DateTime geaendert;
  final String? raum;

  bool get offen => einkaufId == null;
  String get schluessel => artikelSchluessel(name, variante);

  Posten kopie({
    String? name,
    String? Function()? variante,
    double? menge,
    Einheit? einheit,
    String? Function()? notiz,
    bool? abgehakt,
    String? Function()? einkaufId,
    DateTime? geaendert,
    String? Function()? raum,
  }) =>
      Posten(
        id: id,
        listeId: listeId,
        name: name ?? this.name,
        variante: variante != null ? variante() : this.variante,
        menge: menge ?? this.menge,
        einheit: einheit ?? this.einheit,
        notiz: notiz != null ? notiz() : this.notiz,
        abgehakt: abgehakt ?? this.abgehakt,
        einkaufId: einkaufId != null ? einkaufId() : this.einkaufId,
        geaendert: geaendert ?? this.geaendert,
        raum: raum != null ? raum() : this.raum,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'listeId': listeId,
        'name': name,
        if (variante != null) 'variante': variante,
        'menge': menge,
        'einheit': einheit.name,
        if (notiz != null) 'notiz': notiz,
        if (abgehakt) 'abgehakt': true,
        if (einkaufId != null) 'einkaufId': einkaufId,
        'geaendert': geaendert.toUtc().toIso8601String(),
        if (raum != null) 'raum': raum,
      };

  static Posten fromJson(Map<String, dynamic> j) => Posten(
        id: j['id'] as String,
        listeId: j['listeId'] as String,
        name: j['name'] as String,
        variante: j['variante'] as String?,
        menge: (j['menge'] as num?)?.toDouble() ?? 1,
        einheit: Einheit.values.byName((j['einheit'] as String?) ?? 'stueck'),
        notiz: j['notiz'] as String?,
        abgehakt: j['abgehakt'] == true,
        einkaufId: j['einkaufId'] as String?,
        geaendert: DateTime.parse(j['geaendert'] as String),
        raum: j['raum'] as String?,
      );
}

/// Ein abgeschlossener Einkauf: genau eine Buchung im eigenen
/// Haushaltsbuch (immer privat, auch bei geteilten Listen).
class Einkauf {
  const Einkauf({
    required this.id,
    required this.listeId,
    this.filialeId,
    required this.datum,
    this.geschaetztCent,
    required this.betragCent,
    required this.kontoId,
    required this.buchungId,
    required this.postenIds,
    required this.geaendert,
  });

  final String id;
  final String listeId;
  final String? filialeId;
  final DateTime datum;

  /// Schätzung aus den Preisen der abgehakten Posten (falls alle bekannt).
  final int? geschaetztCent;

  /// Tatsächlich bezahlt (vom Kassenbon), positiv.
  final int betragCent;
  final String kontoId;
  final String buchungId;
  final List<String> postenIds;
  final DateTime geaendert;

  Map<String, dynamic> toJson() => {
        'id': id,
        'listeId': listeId,
        if (filialeId != null) 'filialeId': filialeId,
        'datum': tagIso(datum),
        if (geschaetztCent != null) 'geschaetztCent': geschaetztCent,
        'betragCent': betragCent,
        'kontoId': kontoId,
        'buchungId': buchungId,
        'postenIds': postenIds,
        'geaendert': geaendert.toUtc().toIso8601String(),
      };

  static Einkauf fromJson(Map<String, dynamic> j) => Einkauf(
        id: j['id'] as String,
        listeId: j['listeId'] as String,
        filialeId: j['filialeId'] as String?,
        datum: tagAusIso(j['datum'] as String),
        geschaetztCent: j['geschaetztCent'] as int?,
        betragCent: j['betragCent'] as int,
        kontoId: j['kontoId'] as String,
        buchungId: j['buchungId'] as String,
        postenIds: (j['postenIds'] as List).cast<String>(),
        geaendert: DateTime.parse(j['geaendert'] as String),
      );
}
