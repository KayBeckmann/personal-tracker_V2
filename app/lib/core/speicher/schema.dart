/// Schemaversion der Klartext-Datensätze. Bei jeder Änderung am
/// Datenformat erhöhen und eine Migration ergänzen; ältere Backups und
/// lokale Bestände werden damit beim Öffnen bzw. Einlesen angehoben.
///
/// - 1: M1 (Termine, Notizen, Haushaltsbuch)
/// - 2: M2 (zusätzlich Aufgaben)
const aktuellesSchema = 2;

/// Rohdaten: Bereich → Datensätze (Klartext-JSON).
typedef Rohdaten = Map<String, List<Map<String, dynamic>>>;

/// Migration von Version `n` auf `n + 1`.
typedef Migration = Rohdaten Function(Rohdaten daten);

const Map<int, Migration> migrationen = {1: _v1zuV2};

/// Schema 2 ergänzt nur den Bereich „aufgaben“; vorhandene Datensätze
/// bleiben unverändert. Die Versionsnummer steigt trotzdem, damit eine
/// M1-App eine M2-Sicherung ablehnt, statt Aufgaben still zu verlieren.
Rohdaten _v1zuV2(Rohdaten d) => {...d, 'aufgaben': d['aufgaben'] ?? []};

class SchemaFehler implements Exception {
  SchemaFehler(this.meldung);
  final String meldung;
  @override
  String toString() => meldung;
}

/// Hebt [daten] von [von] auf [aktuellesSchema]. Neuere Stände werden
/// abgelehnt, statt sie mit einer alten App zu verfälschen.
Rohdaten migrieren(Rohdaten daten, int von, {Map<int, Migration> schritte = migrationen, int ziel = aktuellesSchema}) {
  if (von > ziel) {
    throw SchemaFehler('Die Daten stammen aus einer neueren App-Version (Schema $von). Bitte die App aktualisieren.');
  }
  var d = daten;
  for (var v = von; v < ziel; v++) {
    final schritt = schritte[v];
    if (schritt == null) throw SchemaFehler('Keine Migration von Schema $v auf ${v + 1} vorhanden.');
    d = schritt(d);
  }
  return d;
}
