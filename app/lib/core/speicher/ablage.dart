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
  static const bereiche = ['termine', 'notizen', 'konten', 'buchungen', 'plaene', 'einstellungen'];

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
  Future<List<Map<String, dynamic>>> lesen(Uint8List dek, String bereich, {List<String>? defekt}) async {
    final ergebnis = <Map<String, dynamic>>[];
    for (final r in await _bereich(bereich).find(db)) {
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

  Future<void> schreiben(Uint8List dek, String bereich, String id, Map<String, dynamic> daten, {DatabaseClient? tx}) {
    final g = AesGcm.verschluesseln(dek, Uint8List.fromList(utf8.encode(jsonEncode(daten))), aad: '$bereich/$id');
    return _bereich(bereich).record(id).put(tx ?? db, g.toJson());
  }

  Future<void> loeschen(String bereich, String id, {DatabaseClient? tx}) => _bereich(bereich).record(id).delete(tx ?? db);

  Future<void> leeren(String bereich, {DatabaseClient? tx}) => _bereich(bereich).delete(tx ?? db);

  Future<T> transaktion<T>(Future<T> Function(Transaction tx) aktion) => db.transaction(aktion);

  Future<void> schliessen() => db.close();
}
