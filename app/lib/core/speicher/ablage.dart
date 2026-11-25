import 'dart:convert';
import 'dart:typed_data';

import 'package:sembast/sembast.dart';

import '../krypto/krypto.dart';
import 'datenbank_io.dart' if (dart.library.js_interop) 'datenbank_web.dart';

/// Lokaler Speicher. Fachdaten liegen ausschließlich als AES-GCM-
/// Geheimtext je Datensatz vor (AAD = Bereich/ID). Unverschlüsselt sind
/// nur Metadaten: Schlüsselbund, Schemaversion und das Farbschema.
class Ablage {
  Ablage(this.db);

  final Database db;

  static const dateiname = 'personal_tracker_v2.db';
  static const bereiche = ['termine', 'aufgaben', 'notizen', 'konten', 'buchungen', 'plaene', 'konflikte', 'raeume', 'einstellungen'];

  /// Zustand des Syncs (Verbindung, Revisionen, ausstehende Änderungen);
  /// ebenfalls verschlüsselt, aber nicht Teil von Sicherungen.
  static const syncBereiche = ['sync', 'sync_ausgang'];

  /// Vault-Dateien aus dem Sync (M4) und der Zwischenspeicher ihrer
  /// Blöcke; nicht Teil des Bestands und nicht in Sicherungen (der Vault
  /// hat sein eigenes Original im Obsidian-Ordner).
  static const vaultBereiche = ['vault', 'vault_bloecke'];

  static final _meta = StoreRef<String, Object?>('meta');

  static Future<Ablage> oeffnen({DatabaseFactory? factory, String name = dateiname}) async {
    // Eigene Fabrik (Tests): Name direkt, sonst Plattformpfad.
    if (factory != null) return Ablage(await factory.openDatabase(name));
    return Ablage(await datenbankFabrik().openDatabase(await datenbankPfad(name)));
  }

  Future<Object?> meta(String schluessel) => _meta.record(schluessel).get(db);
  Future<void> setzeMeta(String schluessel, Object? wert, {DatabaseClient? tx}) =>
      wert == null ? _meta.record(schluessel).delete(tx ?? db) : _meta.record(schluessel).put(tx ?? db, wert);

  StoreRef<String, Map<String, Object?>> _bereich(String name) => StoreRef<String, Map<String, Object?>>(name);

  /// Alle Datensätze eines Bereichs entschlüsselt. Nicht lesbare Datensätze
  /// (falscher Schlüssel/beschädigt) landen in [defekt], statt still zu
  /// verschwinden.
  Future<List<Map<String, dynamic>>> lesen(Uint8List dek, String bereich, {List<String>? defekt, DatabaseClient? tx}) async {
    final ergebnis = <Map<String, dynamic>>[];
    for (final r in await _bereich(bereich).find(tx ?? db)) {
      final g = Geheimtext.fromJson(r.value);
      final klar = g == null ? null : AesGcm.entschluesseln(dek, g, aad: '$bereich/${r.key}');
      if (klar == null) {
        defekt?.add('$bereich/${r.key}');
        continue;
      }
      ergebnis.add((jsonDecode(utf8.decode(klar)) as Map).cast<String, dynamic>());
    }
    return ergebnis;
  }

  /// Ein Datensatz entschlüsselt; `null`, wenn es ihn nicht gibt oder er
  /// nicht lesbar ist.
  Future<Map<String, dynamic>?> lesenEinzeln(Uint8List dek, String bereich, String id, {DatabaseClient? tx}) async {
    final g = Geheimtext.fromJson(await _bereich(bereich).record(id).get(tx ?? db));
    final klar = g == null ? null : AesGcm.entschluesseln(dek, g, aad: '$bereich/$id');
    return klar == null ? null : (jsonDecode(utf8.decode(klar)) as Map).cast<String, dynamic>();
  }

  /// Schlüssel aller Datensätze eines Bereichs (ohne Entschlüsseln).
  Future<List<String>> schluessel(String bereich, {DatabaseClient? tx}) => _bereich(bereich).findKeys(tx ?? db);

  Future<void> schreiben(Uint8List dek, String bereich, String id, Map<String, dynamic> daten, {DatabaseClient? tx}) {
    final g = AesGcm.verschluesseln(dek, Uint8List.fromList(utf8.encode(jsonEncode(daten))), aad: '$bereich/$id');
    return _bereich(bereich).record(id).put(tx ?? db, g.toJson());
  }

  Future<void> loeschen(String bereich, String id, {DatabaseClient? tx}) => _bereich(bereich).record(id).delete(tx ?? db);

  Future<void> leeren(String bereich, {DatabaseClient? tx}) => _bereich(bereich).delete(tx ?? db);

  Future<T> transaktion<T>(Future<T> Function(Transaction tx) aktion) => db.transaction(aktion);

  Future<void> schliessen() => db.close();
}
