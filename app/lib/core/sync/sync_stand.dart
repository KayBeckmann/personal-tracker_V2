import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sembast/sembast.dart';
import 'package:uuid/uuid.dart';

import '../speicher/ablage.dart';
import 'sync_krypto.dart';

/// Verbindung dieses Geräts zu einem Sync-Konto. Liegt verschlüsselt in
/// der lokalen Ablage (Token und Kontoschlüssel nie im Klartext).
class Verbindung {
  const Verbindung({
    required this.server,
    required this.konto,
    required this.geraet,
    required this.token,
    required this.schluessel,
    this.seq = 0,
    this.bekannt = 0,
  });

  final String server;
  final String konto;
  final String geraet;
  final String token;
  final Kontoschluessel schluessel;

  /// Bis zu dieser Serverrevision ist alles abgeholt.
  final int seq;

  /// Höchste Serverrevision, die dieses Gerät kennt (auch aus eigenen
  /// Sendungen). Meldet der Server weniger, wurde er zurückgesetzt.
  final int bekannt;

  Verbindung mit({int? seq, int? bekannt}) => Verbindung(
        server: server,
        konto: konto,
        geraet: geraet,
        token: token,
        schluessel: schluessel,
        seq: seq ?? this.seq,
        bekannt: bekannt ?? this.bekannt,
      );

  Map<String, dynamic> toJson() => {
        'id': 'verbindung',
        'server': server,
        'konto': konto,
        'geraet': geraet,
        'token': token,
        'schluessel': base64Encode(schluessel.bytes),
        'seq': seq,
        'bekannt': bekannt,
      };

  static Verbindung fromJson(Map<String, dynamic> j) => Verbindung(
        server: j['server'] as String,
        konto: j['konto'] as String,
        geraet: j['geraet'] as String,
        token: j['token'] as String,
        schluessel: Kontoschluessel(base64Decode(j['schluessel'] as String)),
        seq: j['seq'] as int,
        bekannt: (j['bekannt'] as int?) ?? 0,
      );
}

/// Lokaler Sync-Zustand in der Ablage:
///
/// - `sync/verbindung` – [Verbindung]
/// - `sync/basis` – je Datensatz (`bereich|id`) die zuletzt bekannte
///   Serverrevision
/// - `sync_ausgang/<bereich|id>` – ausstehende Änderung mit Änderungs-ID;
///   Inhalt wird erst beim Senden aus dem aktuellen Datensatz gebildet,
///   mehrere Änderungen fallen so zu einer zusammen.
class SyncStand {
  SyncStand(this.ablage, this.dek);

  final Ablage ablage;
  final Uint8List dek;
  static const _uuid = Uuid();

  static String schluessel(String bereich, String id) => '$bereich|$id';
  static (String, String) teile(String schluessel) {
    final i = schluessel.indexOf('|');
    return (schluessel.substring(0, i), schluessel.substring(i + 1));
  }

  Future<Verbindung?> verbindung({DatabaseClient? tx}) async {
    final j = await ablage.lesenEinzeln(dek, 'sync', 'verbindung', tx: tx);
    return j == null ? null : Verbindung.fromJson(j);
  }

  Future<void> setzeVerbindung(Verbindung v, {DatabaseClient? tx}) => ablage.schreiben(dek, 'sync', 'verbindung', v.toJson(), tx: tx);

  Future<Map<String, int>> basis({DatabaseClient? tx}) async {
    final j = await ablage.lesenEinzeln(dek, 'sync', 'basis', tx: tx);
    return {for (final e in ((j?['revisionen'] as Map?) ?? const {}).entries) '${e.key}': e.value as int};
  }

  Future<void> setzeBasis(Map<String, int> b, {DatabaseClient? tx}) =>
      ablage.schreiben(dek, 'sync', 'basis', {'id': 'basis', 'revisionen': b}, tx: tx);

  /// Ausstehende Änderungen: Schlüssel → Änderungs-ID.
  Future<Map<String, String>> ausgang({DatabaseClient? tx}) async => {
        for (final j in await ablage.lesen(dek, 'sync_ausgang', tx: tx)) j['id'] as String: j['aenderung'] as String,
      };

  Future<int> anzahlAusstehend() async => (await ablage.schluessel('sync_ausgang')).length;

  /// Merkt einen geänderten oder gelöschten Datensatz zum Senden vor.
  Future<void> vormerken(String bereich, String id, {DatabaseClient? tx}) {
    final k = schluessel(bereich, id);
    return ablage.schreiben(dek, 'sync_ausgang', k, {'id': k, 'aenderung': _uuid.v4()}, tx: tx);
  }

  Future<void> erledigt(String schluessel, {DatabaseClient? tx}) => ablage.loeschen('sync_ausgang', schluessel, tx: tx);

  /// Alle lokalen Datensätze vormerken (Erstverbindung, Neuaufbau).
  Future<int> allesVormerken({DatabaseClient? tx}) async {
    var n = 0;
    for (final b in Ablage.bereiche) {
      for (final id in await ablage.schluessel(b, tx: tx)) {
        await vormerken(b, id, tx: tx);
        n++;
      }
    }
    return n;
  }

  /// Entfernt Verbindung und Sync-Zustand (Daten bleiben).
  Future<void> loeschen({DatabaseClient? tx}) async {
    for (final b in Ablage.syncBereiche) {
      await ablage.leeren(b, tx: tx);
    }
  }
}

/// Einfache Sperre: lokale Änderungen und das Einspielen vom Server
/// laufen nacheinander, damit keine Änderung die andere überschreibt.
class Sperre {
  Future<void> _letzte = Future.value();

  Future<T> exklusiv<T>(Future<T> Function() aktion) {
    final ergebnis = _letzte.then((_) => aktion());
    _letzte = ergebnis.then((_) {}, onError: (_) {});
    return ergebnis;
  }
}
