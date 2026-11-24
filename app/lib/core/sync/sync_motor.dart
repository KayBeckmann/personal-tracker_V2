import 'dart:convert';
import 'dart:typed_data';

import 'package:sembast/sembast.dart';
import 'package:uuid/uuid.dart';

import '../speicher/ablage.dart';
import '../speicher/schema.dart';
import 'sync_api.dart';
import 'sync_krypto.dart';
import 'sync_stand.dart';

class SyncBericht {
  SyncBericht();

  int geholt = 0;
  int gesendet = 0;

  /// Neu entstandene Konflikt-Fassungen.
  int konflikte = 0;

  /// Objekte, die sich nicht entschlüsseln ließen (übersprungen).
  int defekt = 0;

  /// Der Server war hinter dem lokalen Stand zurück (z. B. aus einer
  /// Sicherung wiederhergestellt); alles wurde neu abgeglichen.
  bool neuAufgebaut = false;

  /// Lokale Daten haben sich durch den Abgleich geändert.
  bool get lokalGeaendert => geholt > 0 || konflikte > 0;

  /// Antwort von `GET /v1/konto` (Recovery-Paket, Geräte).
  Map<String, dynamic>? konto;
}

/// Abgleich mit dem Server. Ablauf: alles Neue holen und in einer
/// Transaktion einspielen, dann Ausstehendes senden; meldet der Server
/// einen Konflikt (anderes Gerät war schneller), wiederholen.
///
/// Regeln beim Einspielen eines Objekts, das hier ebenfalls geändert wurde:
/// - beide gleich → nichts zu tun
/// - dort gelöscht, hier geändert → die Änderung bleibt (und wird gesendet)
/// - dort geändert, hier gelöscht → die Änderung kommt zurück
/// - beide verschieden geändert → die Serverfassung gilt, die eigene bleibt
///   als [Konflikt]-Fassung erhalten
/// - Einstellungen: die Serverfassung gilt ohne Konflikt; „letzte
///   Sicherung“ bleibt je Gerät.
class SyncMotor {
  SyncMotor({
    required this.ablage,
    required this.dek,
    required this.api,
    required this.sperre,
    this.seite = 500,
    this.proSenden = 200,
    DateTime Function()? uhr,
  }) : _uhr = uhr ?? DateTime.now;

  final Ablage ablage;
  final Uint8List dek;
  final SyncApi api;
  final Sperre sperre;
  final int seite;
  final int proSenden;
  final DateTime Function() _uhr;
  static const _uuid = Uuid();

  late final stand = SyncStand(ablage, dek);

  Future<SyncBericht> abgleichen() async {
    final b = SyncBericht();
    for (var runde = 0; runde < 4; runde++) {
      await _holen(b);
      if (!await _senden(b)) break;
    }
    b.konto = await api.konto();
    return b;
  }

  // ---------------------------------------------------------------------
  // Holen

  Future<void> _holen(SyncBericht bericht) async {
    var v = (await stand.verbindung())!;
    final objekte = <({String id, int seq, String daten})>[];
    var seit = v.seq;
    while (true) {
      final r = await api.abrufen(seit, max: seite);
      if (r.objekte.isEmpty && objekte.isEmpty && r.bis < (seit > v.bekannt ? seit : v.bekannt)) {
        await _neuAufbauen(bericht);
        return _holen(bericht);
      }
      objekte.addAll(r.objekte);
      seit = r.bis;
      if (!r.mehr) break;
    }

    // Entschlüsseln außerhalb der Sperre.
    final umschlaege = <({int seq, Umschlag u})>[];
    for (final o in objekte) {
      final u = v.schluessel.entschluesseln(o.id, o.daten);
      if (u == null) {
        bericht.defekt++;
        continue;
      }
      if (u.schema > aktuellesSchema || !Ablage.bereiche.contains(u.bereich)) {
        throw SyncFehler(SyncFehlerArt.version, 'Ein anderes Gerät nutzt eine neuere App-Version. Bitte diese App aktualisieren.');
      }
      umschlaege.add((seq: o.seq, u: u));
    }

    await sperre.exklusiv(() => ablage.transaktion((tx) async {
          final basis = await stand.basis(tx: tx);
          final ausgang = await stand.ausgang(tx: tx);
          final geloeschteKonten = <String, Map<String, dynamic>>{};
          for (final (:seq, :u) in umschlaege) {
            final k = SyncStand.schluessel(u.bereich, u.id);
            if ((basis[k] ?? 0) >= seq) continue;
            await _einspielen(u, ausgang.containsKey(k), tx, bericht, geloeschteKonten);
            basis[k] = seq;
          }
          await _kontenSichern(geloeschteKonten, tx);
          await stand.setzeBasis(basis, tx: tx);
          v = (await stand.verbindung(tx: tx))!;
          await stand.setzeVerbindung(v.mit(seq: seit, bekannt: seit > v.bekannt ? seit : v.bekannt), tx: tx);
        }));
  }

  Future<void> _einspielen(
    Umschlag u,
    bool ausstehend,
    DatabaseClient tx,
    SyncBericht bericht,
    Map<String, Map<String, dynamic>> geloeschteKonten,
  ) async {
    final k = SyncStand.schluessel(u.bereich, u.id);
    var dort = u.daten;
    if (dort != null && u.schema < aktuellesSchema) {
      dort = migrieren({u.bereich: [dort]}, u.schema)[u.bereich]!.first;
    }
    final hier = await ablage.lesenEinzeln(dek, u.bereich, u.id, tx: tx);

    Future<void> uebernehmen() async {
      bericht.geholt++;
      if (dort == null) {
        if (hier != null && u.bereich == 'konten') geloeschteKonten[u.id] = hier;
        await ablage.loeschen(u.bereich, u.id, tx: tx);
      } else {
        await ablage.schreiben(dek, u.bereich, u.id, dort, tx: tx);
      }
    }

    if (u.bereich == 'einstellungen') {
      if (dort != null) {
        dort = {...dort, if (hier?['letzteSicherung'] != null) 'letzteSicherung': hier!['letzteSicherung']};
      }
      await uebernehmen();
      if (ausstehend) await stand.erledigt(k, tx: tx);
      return;
    }
    if (!ausstehend) return uebernehmen();

    if (dort == null) {
      // Dort gelöscht: eine Änderung hier gewinnt; sonst ist es erledigt.
      if (hier == null) await stand.erledigt(k, tx: tx);
      return;
    }
    if (hier == null || _gleich(hier, dort)) {
      // Hier gelöscht, dort geändert: die Änderung kommt zurück.
      await stand.erledigt(k, tx: tx);
      return uebernehmen();
    }
    // Echter Konflikt: Serverfassung gilt, die eigene bleibt erhalten.
    final id = _uuid.v4();
    await ablage.schreiben(
      dek,
      'konflikte',
      id,
      {'id': id, 'bereich': u.bereich, 'originalId': u.id, 'daten': hier, 'entstanden': _uhr().toUtc().toIso8601String()},
      tx: tx,
    );
    await stand.vormerken('konflikte', id, tx: tx);
    await stand.erledigt(k, tx: tx);
    bericht.konflikte++;
    await uebernehmen();
  }

  /// Wurde ein Konto gelöscht, auf das hier noch Buchungen oder Pläne
  /// zeigen (auf diesem Gerät offline angelegt), bleibt es erhalten und
  /// wird erneut gesendet — sonst entstünden verwaiste Buchungen.
  Future<void> _kontenSichern(Map<String, Map<String, dynamic>> geloescht, DatabaseClient tx) async {
    final vorhanden = (await ablage.schluessel('konten', tx: tx)).toSet();
    final benutzt = {
      for (final b in ['buchungen', 'plaene'])
        for (final d in await ablage.lesen(dek, b, tx: tx)) d['kontoId'] as String,
    };
    for (final id in benutzt.difference(vorhanden)) {
      final daten = geloescht[id];
      if (daten == null) {
        throw SyncFehler(SyncFehlerArt.daten, 'Vom Server kam eine Buchung ohne zugehöriges Konto. Abgleich abgebrochen, lokal ist nichts verändert.');
      }
      await ablage.schreiben(dek, 'konten', id, daten, tx: tx);
      await stand.vormerken('konten', id, tx: tx);
    }
  }

  /// Der Server kennt weniger als dieses Gerät (aus älterer Sicherung
  /// wiederhergestellt oder ausgetauscht): alles neu holen und alles
  /// Lokale erneut senden. Abweichungen werden zu Konflikt-Fassungen.
  Future<void> _neuAufbauen(SyncBericht bericht) => sperre.exklusiv(() => ablage.transaktion((tx) async {
        bericht.neuAufgebaut = true;
        await stand.setzeBasis({}, tx: tx);
        await stand.allesVormerken(tx: tx);
        final v = (await stand.verbindung(tx: tx))!;
        await stand.setzeVerbindung(v.mit(seq: 0, bekannt: 0), tx: tx);
      }));

  // ---------------------------------------------------------------------
  // Senden

  /// Sendet Ausstehendes; `true`, wenn der Server Konflikte gemeldet hat.
  Future<bool> _senden(SyncBericht bericht) async {
    final v = (await stand.verbindung())!;
    var konflikt = false;
    final alle = (await stand.ausgang()).entries.toList();
    for (var i = 0; i < alle.length; i += proSenden) {
      final teil = alle.sublist(i, i + proSenden > alle.length ? alle.length : i + proSenden);
      final aenderungen = <({String id, int basis, String aenderung, String daten})>[];
      final zuordnung = <String, MapEntry<String, String>>{};
      await sperre.exklusiv(() async {
        final basis = await stand.basis();
        for (final e in teil) {
          final (bereich, id) = SyncStand.teile(e.key);
          var daten = await ablage.lesenEinzeln(dek, bereich, id);
          if (daten == null && basis[e.key] == null) {
            // Nie gesendet und schon wieder gelöscht: nichts zu tun.
            await stand.erledigt(e.key);
            continue;
          }
          if (bereich == 'einstellungen' && daten != null) daten = {...daten}..remove('letzteSicherung');
          final oid = v.schluessel.objektId(bereich, id);
          zuordnung[oid] = e;
          aenderungen.add((
            id: oid,
            basis: basis[e.key] ?? 0,
            aenderung: e.value,
            daten: v.schluessel.verschluesseln(Umschlag(bereich: bereich, id: id, schema: aktuellesSchema, daten: daten)),
          ));
        }
      });
      if (aenderungen.isEmpty) continue;
      final ergebnisse = await api.schreiben(aenderungen);
      await sperre.exklusiv(() => ablage.transaktion((tx) async {
            final basis = await stand.basis(tx: tx);
            final ausgang = await stand.ausgang(tx: tx);
            for (final r in ergebnisse) {
              final e = zuordnung[r.id];
              if (e == null) continue;
              if (!r.ok) {
                konflikt = true;
                continue;
              }
              bericht.gesendet++;
              basis[e.key] = r.seq;
              // Nur erledigt, wenn hier inzwischen nichts Neues dazukam.
              if (ausgang[e.key] == e.value) await stand.erledigt(e.key, tx: tx);
            }
            await stand.setzeBasis(basis, tx: tx);
            final hoechste = ergebnisse.where((r) => r.ok).fold(0, (m, r) => r.seq > m ? r.seq : m);
            final jetzt = (await stand.verbindung(tx: tx))!;
            if (hoechste > jetzt.bekannt) await stand.setzeVerbindung(jetzt.mit(bekannt: hoechste), tx: tx);
          }));
    }
    return konflikt;
  }

  /// Inhaltlich gleich; der Änderungszeitpunkt zählt nicht mit.
  static bool _gleich(Map<String, dynamic> a, Map<String, dynamic> b) =>
      jsonEncode(_sortiert({...a}..remove('geaendert'))) == jsonEncode(_sortiert({...b}..remove('geaendert')));

  static Object? _sortiert(Object? x) => switch (x) {
        Map() => {for (final k in (x.keys.map((k) => '$k').toList()..sort())) k: _sortiert(x[k])},
        List() => [for (final e in x) _sortiert(e)],
        _ => x,
      };
}
