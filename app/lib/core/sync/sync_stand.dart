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
    this.name = 'Gerät',
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

  /// Name dieses Geräts (für Konfliktkopien im Vault).
  final String name;

  Verbindung mit({int? seq, int? bekannt}) => Verbindung(
        server: server,
        konto: konto,
        geraet: geraet,
        token: token,
        schluessel: schluessel,
        seq: seq ?? this.seq,
        bekannt: bekannt ?? this.bekannt,
        name: name,
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
        'name': name,
      };

  static Verbindung fromJson(Map<String, dynamic> j) => Verbindung(
        server: j['server'] as String,
        konto: j['konto'] as String,
        geraet: j['geraet'] as String,
        token: j['token'] as String,
        schluessel: Kontoschluessel(base64Decode(j['schluessel'] as String)),
        seq: j['seq'] as int,
        bekannt: (j['bekannt'] as int?) ?? 0,
        name: (j['name'] as String?) ?? 'Gerät',
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

  /// Datensätze, die in einem geteilten Raum liegen: Schlüssel → Raum-ID.
  /// Fehlt ein Schlüssel, liegt der Datensatz (falls schon gesendet) im
  /// eigenen Konto. [basis] gilt jeweils für diesen Ort.
  Future<Map<String, String>> orte({DatabaseClient? tx}) async {
    final j = await ablage.lesenEinzeln(dek, 'sync', 'orte', tx: tx);
    return ((j?['orte'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', v as String));
  }

  Future<void> setzeOrte(Map<String, String> o, {DatabaseClient? tx}) => ablage.schreiben(dek, 'sync', 'orte', {'id': 'orte', 'orte': o}, tx: tx);

  /// Abrufstand je Raum (wie [Verbindung.seq]/[Verbindung.bekannt]).
  Future<Map<String, ({int seq, int bekannt, int info})>> raumStaende({DatabaseClient? tx}) async {
    final j = await ablage.lesenEinzeln(dek, 'sync', 'raum_staende', tx: tx);
    return {
      for (final e in ((j?['raeume'] as Map?) ?? const {}).entries)
        '${e.key}': (seq: (e.value as Map)['seq'] as int, bekannt: (e.value as Map)['bekannt'] as int, info: ((e.value as Map)['info'] as int?) ?? 0),
    };
  }

  Future<void> setzeRaumStaende(Map<String, ({int seq, int bekannt, int info})> m, {DatabaseClient? tx}) => ablage.schreiben(
        dek,
        'sync',
        'raum_staende',
        {
          'id': 'raum_staende',
          'raeume': {for (final e in m.entries) e.key: {'seq': e.value.seq, 'bekannt': e.value.bekannt, 'info': e.value.info}},
        },
        tx: tx,
      );

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
    for (final b in [...Ablage.bereiche, 'vault']) {
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
  Future<void>? _aktiv;

  Future<T> exklusiv<T>(Future<T> Function() aktion) async {
    // Im Leerlauf beginnt die Aktion sofort (ohne an eine frühere Future
    // anzuhängen).
    while (_aktiv != null) {
      await _aktiv;
    }
    final fertig = Completer<void>();
    _aktiv = fertig.future;
    try {
      return await aktion();
    } finally {
      _aktiv = null;
      fertig.complete();
    }
  }
}
