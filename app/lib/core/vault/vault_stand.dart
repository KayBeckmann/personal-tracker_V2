import 'dart:convert';
import 'dart:typed_data';

import 'package:sembast/sembast.dart';

import '../speicher/ablage.dart';
import 'vault_datei.dart';

/// Lokaler Stand des Vaults in der App (alles verschlüsselt mit dem DEK):
///
/// - Bereich `vault` – die Datei-Datensätze (kleine Inhalte direkt darin)
/// - Bereich `vault_bloecke` – Zwischenspeicher für Blöcke großer Dateien:
///   geladene und hier neu entstandene (bis sie beim Server sind)
/// - `sync/vault_basis` – je Datei Pfad und Hash beim letzten Abgleich
///   (Grundlage für das Zusammenführen)
/// - `sync/vault_freigaben` – Dateien, die trotz Secret-Treffer hochgeladen
///   werden dürfen, gebunden an den Hash ihres Inhalts
class VaultStand {
  VaultStand(this.ablage, this.dek);

  final Ablage ablage;
  final Uint8List dek;

  static const bloeckeBereich = 'vault_bloecke';

  Future<List<VaultDatei>> alle({DatabaseClient? tx}) async =>
      [for (final j in await ablage.lesen(dek, vaultBereich, tx: tx)) VaultDatei.fromJson(j)];

  Future<VaultDatei?> datei(String id, {DatabaseClient? tx}) async {
    final j = await ablage.lesenEinzeln(dek, vaultBereich, id, tx: tx);
    return j == null ? null : VaultDatei.fromJson(j);
  }

  Future<void> schreiben(VaultDatei d, {DatabaseClient? tx}) => ablage.schreiben(dek, vaultBereich, d.id, d.toJson(), tx: tx);

  Future<void> loeschen(String id, {DatabaseClient? tx}) => ablage.loeschen(vaultBereich, id, tx: tx);

  Future<Uint8List?> block(String id) async {
    final j = await ablage.lesenEinzeln(dek, bloeckeBereich, id);
    return j == null ? null : base64Decode(j['b'] as String);
  }

  Future<void> blockSpeichern(String id, Uint8List klar, {DatabaseClient? tx}) =>
      ablage.schreiben(dek, bloeckeBereich, id, {'id': id, 'b': base64Encode(klar)}, tx: tx);

  Future<Map<String, ({String pfad, String sha})>> basis({DatabaseClient? tx}) async {
    final j = await ablage.lesenEinzeln(dek, 'sync', 'vault_basis', tx: tx);
    return {
      for (final e in ((j?['dateien'] as Map?) ?? const {}).entries)
        '${e.key}': (pfad: (e.value as Map)['p'] as String, sha: (e.value as Map)['h'] as String),
    };
  }

  Future<void> setzeBasis(Map<String, ({String pfad, String sha})> b, {DatabaseClient? tx}) => ablage.schreiben(
        dek,
        'sync',
        'vault_basis',
        {
          'id': 'vault_basis',
          'dateien': {for (final e in b.entries) e.key: {'p': e.value.pfad, 'h': e.value.sha}},
        },
        tx: tx,
      );

  /// Datei-ID → freigegebener Inhalts-Hash.
  Future<Map<String, String>> freigaben({DatabaseClient? tx}) async {
    final j = await ablage.lesenEinzeln(dek, 'sync', 'vault_freigaben', tx: tx);
    return ((j?['dateien'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', v as String));
  }

  Future<void> freigeben(String id, String sha) async {
    final f = await freigaben();
    f[id] = sha;
    await ablage.schreiben(dek, 'sync', 'vault_freigaben', {'id': 'vault_freigaben', 'dateien': f});
  }

  Future<DateTime?> aufgeraeumt() async {
    final j = await ablage.lesenEinzeln(dek, 'sync', 'vault_aufgeraeumt');
    return j == null ? null : DateTime.parse(j['zeit'] as String);
  }

  Future<void> setzeAufgeraeumt(DateTime t) =>
      ablage.schreiben(dek, 'sync', 'vault_aufgeraeumt', {'id': 'vault_aufgeraeumt', 'zeit': t.toUtc().toIso8601String()});
}
