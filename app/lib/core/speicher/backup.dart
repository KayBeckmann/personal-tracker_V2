import 'dart:convert';
import 'dart:typed_data';

import '../krypto/krypto.dart';
import '../krypto/recovery_schluessel.dart';
import 'schema.dart';

class BackupFehler implements Exception {
  BackupFehler(this.meldung);
  final String meldung;
  @override
  String toString() => meldung;
}

/// Verschlüsselte Komplettsicherung aller Tracker-Daten.
///
/// Datei (JSON): sichtbarer Kopf mit Format, Version, Erstellzeit und
/// Recovery-Kennung; Inhalt AES-256-GCM-verschlüsselt mit dem aus dem
/// Recovery-Schlüssel abgeleiteten Backup-Schlüssel. Der Kopf ist als
/// AAD gebunden — eine Änderung daran macht die Datei unlesbar.
class Backup {
  const Backup._();

  static const format = 'personal-tracker-v2-backup';
  static const version = 1;
  static const dateiendung = 'ptbackup';

  static Uint8List erstellen({
    required Rohdaten daten,
    required Uint8List backupSchluessel,
    required String recoveryKennung,
    DateTime? zeitpunkt,
  }) {
    final erstellt = (zeitpunkt ?? DateTime.now()).toUtc().toIso8601String();
    final inhalt = utf8.encode(jsonEncode({'schema': aktuellesSchema, 'daten': daten}));
    final g = AesGcm.verschluesseln(
      backupSchluessel,
      Uint8List.fromList(inhalt),
      aad: _aad(version, recoveryKennung, erstellt),
    );
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'format': format,
      'version': version,
      'erstellt': erstellt,
      'recoveryKennung': recoveryKennung,
      ...g.toJson(),
    })));
  }

  /// Liest den Kopf ohne Schlüssel (für die Vorschau „von wann?“).
  static BackupKopf kopfLesen(Uint8List datei) {
    final Map<String, dynamic> j;
    try {
      j = (jsonDecode(utf8.decode(datei)) as Map).cast<String, dynamic>();
    } catch (_) {
      throw BackupFehler('Das ist keine Sicherungsdatei des Personal Trackers.');
    }
    if (j['format'] != format) throw BackupFehler('Das ist keine Sicherungsdatei des Personal Trackers.');
    final v = j['version'];
    if (v is! int) throw BackupFehler('Die Sicherungsdatei ist beschädigt.');
    if (v > version) throw BackupFehler('Die Sicherung stammt aus einer neueren App-Version. Bitte die App aktualisieren.');
    final erstellt = DateTime.tryParse('${j['erstellt']}');
    final kennung = j['recoveryKennung'];
    final g = Geheimtext.fromJson(j);
    if (erstellt == null || kennung is! String || g == null) throw BackupFehler('Die Sicherungsdatei ist beschädigt.');
    return BackupKopf(version: v, erstellt: erstellt, recoveryKennung: kennung, rohErstellt: '${j['erstellt']}', inhalt: g);
  }

  /// Entschlüsselt und migriert auf das aktuelle Schema.
  static BackupInhalt lesen(Uint8List datei, RecoverySchluessel recovery) {
    final kopf = kopfLesen(datei);
    if (kopf.recoveryKennung != recovery.kennung) {
      throw BackupFehler('Dieser Recovery-Schlüssel gehört nicht zu dieser Sicherung.');
    }
    return mitSchluessel(kopf, recovery.backupSchluessel);
  }

  static BackupInhalt mitSchluessel(BackupKopf kopf, Uint8List backupSchluessel) {
    final klar = AesGcm.entschluesseln(
      backupSchluessel,
      kopf.inhalt,
      aad: _aad(kopf.version, kopf.recoveryKennung, kopf.rohErstellt),
    );
    if (klar == null) throw BackupFehler('Die Sicherung lässt sich nicht entschlüsseln — Datei beschädigt oder verändert.');
    final Map<String, dynamic> j;
    try {
      j = (jsonDecode(utf8.decode(klar)) as Map).cast<String, dynamic>();
    } catch (_) {
      throw BackupFehler('Die Sicherung ist beschädigt.');
    }
    final schema = j['schema'];
    final rohDaten = j['daten'];
    if (schema is! int || rohDaten is! Map) throw BackupFehler('Die Sicherung ist beschädigt.');
    final Rohdaten daten = {
      for (final e in rohDaten.entries)
        '${e.key}': [for (final d in (e.value as List)) (d as Map).cast<String, dynamic>()],
    };
    try {
      return BackupInhalt(kopf: kopf, schema: schema, daten: migrieren(daten, schema));
    } on SchemaFehler catch (e) {
      throw BackupFehler(e.meldung);
    }
  }

  static String _aad(int v, String kennung, String erstellt) => '$format|$v|$kennung|$erstellt';

  static String dateiname(DateTime t) =>
      'personal-tracker_${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}'
      '_${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}.$dateiendung';
}

class BackupKopf {
  const BackupKopf({
    required this.version,
    required this.erstellt,
    required this.recoveryKennung,
    required this.rohErstellt,
    required this.inhalt,
  });

  final int version;
  final DateTime erstellt;
  final String recoveryKennung;
  final String rohErstellt;
  final Geheimtext inhalt;
}

class BackupInhalt {
  const BackupInhalt({required this.kopf, required this.schema, required this.daten});

  final BackupKopf kopf;
  final int schema;
  final Rohdaten daten;

  int anzahl(String bereich) => daten[bereich]?.length ?? 0;
}
