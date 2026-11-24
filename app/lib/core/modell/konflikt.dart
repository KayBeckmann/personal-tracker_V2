/// Eine Fassung, die beim Abgleich gegen eine gleichzeitige Änderung auf
/// einem anderen Gerät verloren hätte. Sie bleibt als eigener Datensatz
/// erhalten (und wird mitsynchronisiert), bis sie übernommen oder
/// verworfen wird. Bis dahin zählt sie nirgends mit — auch nicht im Saldo.
class Konflikt {
  const Konflikt({
    required this.id,
    required this.bereich,
    required this.originalId,
    required this.daten,
    required this.entstanden,
  });

  final String id;

  /// Bereich und ID des Datensatzes, zu dem diese Fassung gehört.
  final String bereich;
  final String originalId;

  /// Die abweichende Fassung (Klartext-JSON des Datensatzes).
  final Map<String, dynamic> daten;
  final DateTime entstanden;

  Map<String, dynamic> toJson() => {
        'id': id,
        'bereich': bereich,
        'originalId': originalId,
        'daten': daten,
        'entstanden': entstanden.toUtc().toIso8601String(),
      };

  static Konflikt fromJson(Map<String, dynamic> j) => Konflikt(
        id: j['id'] as String,
        bereich: j['bereich'] as String,
        originalId: j['originalId'] as String,
        daten: (j['daten'] as Map).cast<String, dynamic>(),
        entstanden: DateTime.parse(j['entstanden'] as String),
      );
}
