import 'dart:convert';
import 'dart:typed_data';

import 'package:sembast/sembast.dart';
import 'package:uuid/uuid.dart';

import '../speicher/ablage.dart';
import '../speicher/schema.dart';
import '../vault/secrets.dart';
import '../vault/vault_datei.dart';
import '../vault/vault_stand.dart';
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

  /// Vault-Dateien, die nicht gesendet wurden: Secret-Treffer ohne
  /// Freigabe, über der Größengrenze oder mit fehlendem Block.
  final vaultGesperrt = <String>{};
  final vaultZuGross = <String>{};
  final vaultFehlt = <String>{};

  /// Vom Server aufgeräumte, nicht mehr benutzte Blöcke.
  int bloeckeAufgeraeumt = 0;
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
    this.vaultMaxBytes = 100 * 1024 * 1024,
    SecretPruefung? secrets,
    DateTime Function()? uhr,
  })  : _uhr = uhr ?? DateTime.now,
        secrets = secrets ?? SecretPruefung.standard();

  final Ablage ablage;
  final Uint8List dek;
  final SyncApi api;
  final Sperre sperre;
  final int seite;
  final int proSenden;

  /// Größte Vault-Datei, die gesendet wird.
  final int vaultMaxBytes;
  final SecretPruefung secrets;
  final DateTime Function() _uhr;
  static const _uuid = Uuid();

  late final stand = SyncStand(ablage, dek);
  late final vault = VaultStand(ablage, dek);

  /// Blöcke werden höchstens einmal am Tag aufgeräumt.
  static const aufraeumenAlle = Duration(hours: 24);

  Future<SyncBericht> abgleichen() async {
    final b = SyncBericht();
    for (var runde = 0; runde < 4; runde++) {
      await _holen(b);
      if (!await _senden(b)) break;
    }
    b.konto = await api.konto();
    await _aufraeumen(b);
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
      if (u.schema > aktuellesSchema || !(Ablage.bereiche.contains(u.bereich) || u.bereich == vaultBereich)) {
        throw SyncFehler(SyncFehlerArt.version, 'Ein anderes Gerät nutzt eine neuere App-Version. Bitte diese App aktualisieren.');
      }
      umschlaege.add((seq: o.seq, u: u));
    }

    await sperre.exklusiv(() => ablage.transaktion((tx) async {
          final basis = await stand.basis(tx: tx);
          final ausgang = await stand.ausgang(tx: tx);
          final geloeschteKonten = <String, Map<String, dynamic>>{};
          _vaultIndex = null;
          final vBasis = await vault.basis(tx: tx);
          final v0 = (await stand.verbindung(tx: tx))!;
          for (final (:seq, :u) in umschlaege) {
            final k = SyncStand.schluessel(u.bereich, u.id);
            if ((basis[k] ?? 0) >= seq) continue;
            if (u.bereich == vaultBereich) {
              await _vaultEinspielen(u, ausgang, vBasis, v0.name, tx, bericht);
            } else {
              await _einspielen(u, ausgang.containsKey(k), tx, bericht, geloeschteKonten);
            }
            basis[k] = seq;
          }
          await _kontenSichern(geloeschteKonten, tx);
          await vault.setzeBasis(vBasis, tx: tx);
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

  /// Eine Vault-Datei vom Server einspielen. Pfad und Inhalt werden
  /// getrennt zusammengeführt (gegen den Stand beim letzten Abgleich):
  /// Hat hier nur der Pfad und dort nur der Inhalt geändert (oder
  /// umgekehrt), gilt beides. Haben beide den Inhalt verschieden geändert,
  /// gilt die Serverfassung und die eigene bleibt als Konfliktkopie
  /// („Notiz (Konflikt 2026-11-24 1403 Handy).md“) erhalten.
  Future<void> _vaultEinspielen(
    Umschlag u,
    Map<String, String> ausgang,
    Map<String, ({String pfad, String sha})> vBasis,
    String geraetName,
    DatabaseClient tx,
    SyncBericht bericht,
  ) async {
    final k = SyncStand.schluessel(u.bereich, u.id);
    final VaultDatei? dort;
    try {
      dort = u.daten == null ? null : VaultDatei.fromJson(u.daten!);
      if (dort != null) vaultPfad(dort.pfad);
    } catch (_) {
      bericht.defekt++;
      return;
    }
    final hier = await vault.datei(u.id, tx: tx);
    final b = vBasis[u.id];
    if (dort == null) {
      vBasis.remove(u.id);
    } else {
      vBasis[u.id] = (pfad: dort.pfad, sha: dort.sha256);
    }

    Future<void> setzen(VaultDatei? d) async {
      if (d == null) {
        await vault.loeschen(u.id, tx: tx);
        (await _index(tx)).remove(u.id);
      } else {
        await _vaultSchreiben(d, ausgang, geraetName, tx);
      }
    }

    if (!ausgang.containsKey(k)) {
      bericht.geholt++;
      return setzen(dort);
    }
    if (dort == null) {
      // Dort gelöscht, hier geändert: die Änderung bleibt.
      if (hier == null) await stand.erledigt(k, tx: tx);
      return;
    }
    if (hier == null) {
      // Hier gelöscht, dort geändert: die Änderung kommt zurück.
      await stand.erledigt(k, tx: tx);
      ausgang.remove(k);
      bericht.geholt++;
      return setzen(dort);
    }
    final hierPfad = b == null || hier.pfad != b.pfad;
    final hierInhalt = b == null || hier.sha256 != b.sha;
    final dortPfad = b == null || dort.pfad != b.pfad;
    final pfad = hierPfad && !dortPfad ? hier.pfad : dort.pfad;
    bericht.geholt++;
    if (hierInhalt && hier.sha256 != dort.sha256 && (b == null || dort.sha256 != b.sha)) {
      // Beide Inhalte geändert: Serverfassung gilt, eigene als Kopie.
      final index = await _index(tx);
      final belegt = {for (final d in index.values) if (d.id != u.id) d.pfad}..add(pfad);
      final kopie = hier.kopie(
        id: _uuid.v4(),
        pfad: konfliktPfad(pfad, _uhr(), geraetName, belegt.contains),
        geaendert: _uhr().toUtc(),
      );
      await _vaultSchreiben(kopie, ausgang, geraetName, tx);
      await stand.vormerken(vaultBereich, kopie.id, tx: tx);
      ausgang[SyncStand.schluessel(vaultBereich, kopie.id)] = '';
      bericht.konflikte++;
      if (pfad == dort.pfad) {
        await stand.erledigt(k, tx: tx);
        ausgang.remove(k);
      }
      return setzen(dort.kopie(pfad: pfad));
    }
    final inhaltVon = hierInhalt && hier.sha256 != dort.sha256 ? hier : dort;
    final ergebnis = VaultDatei(
      id: u.id,
      pfad: pfad,
      groesse: inhaltVon.groesse,
      sha256: inhaltVon.sha256,
      inhalt: inhaltVon.inhalt,
      bloecke: inhaltVon.bloecke,
      geaendert: inhaltVon.geaendert,
    );
    if (ergebnis.pfad == dort.pfad && ergebnis.sha256 == dort.sha256) {
      await stand.erledigt(k, tx: tx);
      ausgang.remove(k);
    }
    await setzen(ergebnis);
  }

  /// Schreibt eine Datei; belegt schon eine andere Datei denselben Pfad,
  /// weicht die hier neu angelegte (gleicher Inhalt: sie entfällt). Sind
  /// beide schon beim Server, behält die kleinere ID den Pfad — auf allen
  /// Geräten gleich, damit sie dasselbe tun.
  Future<void> _vaultSchreiben(VaultDatei d, Map<String, String> ausgang, String geraetName, DatabaseClient tx) async {
    final index = await _index(tx);
    final andere = index.values.where((x) => x.id != d.id && x.pfad == d.pfad).firstOrNull;
    var neu = d;
    final ak = andere == null ? null : SyncStand.schluessel(vaultBereich, andere.id);
    if (andere != null && andere.sha256 == d.sha256 && ausgang.containsKey(ak) && (await stand.basis(tx: tx))[ak] == null) {
      // Hier neu angelegt, dort dieselbe Datei: eine Datei, die vom Server.
      await vault.loeschen(andere.id, tx: tx);
      index.remove(andere.id);
      await stand.erledigt(ak!, tx: tx);
      ausgang.remove(ak);
    } else if (andere != null) {
      final belegt = {for (final x in index.values) x.pfad};
      // Was noch nicht beim Server ist, weicht; sonst die größere ID.
      final andereNeu = (await stand.basis(tx: tx))[ak] == null;
      final weicht = andereNeu || andere.id.compareTo(d.id) > 0 ? andere : d;
      final umbenannt = weicht.kopie(pfad: konfliktPfad(weicht.pfad, _uhr(), geraetName, belegt.contains));
      if (identical(weicht, d)) {
        neu = umbenannt;
      } else {
        await vault.schreiben(umbenannt, tx: tx);
        index[umbenannt.id] = umbenannt;
      }
      await stand.vormerken(vaultBereich, umbenannt.id, tx: tx);
      ausgang[SyncStand.schluessel(vaultBereich, umbenannt.id)] = '';
    }
    await vault.schreiben(neu, tx: tx);
    index[neu.id] = neu;
  }

  /// Alle Vault-Dateien dieses Einspielens (einmal gelesen, dann
  /// mitgeführt), um Pfadkollisionen ohne erneutes Lesen zu finden.
  Map<String, VaultDatei>? _vaultIndex;
  Future<Map<String, VaultDatei>> _index(DatabaseClient tx) async =>
      _vaultIndex ??= {for (final d in await vault.alle(tx: tx)) d.id: d};

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
        await vault.setzeBasis({}, tx: tx);
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
    final zurueck = await _vaultVorbereiten(v, bericht);
    final alle = (await stand.ausgang()).entries.where((e) => !zurueck.contains(e.key)).toList();
    final gesendetVault = <String, VaultDatei>{};
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
          if (bereich == vaultBereich && daten != null) gesendetVault[e.key] = VaultDatei.fromJson(daten);
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
            final vBasis = await vault.basis(tx: tx);
            for (final r in ergebnisse) {
              final e = zuordnung[r.id];
              if (e == null) continue;
              if (!r.ok) {
                konflikt = true;
                continue;
              }
              bericht.gesendet++;
              basis[e.key] = r.seq;
              final (b, id) = SyncStand.teile(e.key);
              if (b == vaultBereich) {
                final d = gesendetVault[e.key];
                if (d == null) {
                  vBasis.remove(id);
                } else {
                  vBasis[id] = (pfad: d.pfad, sha: d.sha256);
                }
              }
              // Nur erledigt, wenn hier inzwischen nichts Neues dazukam.
              if (ausgang[e.key] == e.value) await stand.erledigt(e.key, tx: tx);
            }
            await stand.setzeBasis(basis, tx: tx);
            await vault.setzeBasis(vBasis, tx: tx);
            final hoechste = ergebnisse.where((r) => r.ok).fold(0, (m, r) => r.seq > m ? r.seq : m);
            final jetzt = (await stand.verbindung(tx: tx))!;
            if (hoechste > jetzt.bekannt) await stand.setzeVerbindung(jetzt.mit(bekannt: hoechste), tx: tx);
          }));
    }
    return konflikt;
  }

  /// Prüft ausstehende Vault-Dateien vor dem Senden und lädt fehlende
  /// Blöcke hoch. Liefert die Schlüssel, die diesmal nicht gesendet werden
  /// (Secret ohne Freigabe, zu groß, Block fehlt).
  ///
  /// Geprüft wird nur ein Inhalt, den der Server noch nicht kennt; eine
  /// reine Umbenennung ändert nichts an dem, was schon dort liegt.
  Future<Set<String>> _vaultVorbereiten(Verbindung v, SyncBericht bericht) async {
    final zurueck = <String>{};
    final ausgang = await stand.ausgang();
    final keys = ausgang.keys.where((k) => SyncStand.teile(k).$1 == vaultBereich).toList();
    if (keys.isEmpty) return zurueck;
    final vBasis = await vault.basis();
    final freigaben = await vault.freigaben();
    final brauchtBloecke = <String, String>{};
    for (final k in keys) {
      final id = SyncStand.teile(k).$2;
      final d = await vault.datei(id);
      if (d == null || vBasis[id]?.sha == d.sha256) continue;
      if (d.groesse > vaultMaxBytes) {
        bericht.vaultZuGross.add(id);
        zurueck.add(k);
        continue;
      }
      final inhalt = d.inhalt ?? await _ausCache(d);
      if (inhalt == null) {
        // Inhalt nicht hier: dann war er schon beim Server (oder ist weg).
        for (final b in d.bloecke) {
          brauchtBloecke[b.id] = k;
        }
        continue;
      }
      final treffer = secrets.pruefen(inhalt);
      if (treffer != null && treffer.isNotEmpty && freigaben[id] != d.sha256) {
        bericht.vaultGesperrt.add(id);
        zurueck.add(k);
        continue;
      }
      for (final b in d.bloecke) {
        brauchtBloecke[b.id] = k;
      }
    }
    if (brauchtBloecke.isEmpty) return zurueck;
    for (final bid in await api.bloeckeFehlend(brauchtBloecke.keys.toList())) {
      final k = brauchtBloecke[bid]!;
      if (zurueck.contains(k)) continue;
      final klar = await vault.block(bid);
      if (klar == null) {
        bericht.vaultFehlt.add(SyncStand.teile(k).$2);
        zurueck.add(k);
        continue;
      }
      await api.blockSchreiben(bid, v.schluessel.blockVerschluesseln(bid, klar));
    }
    return zurueck;
  }

  Future<Uint8List?> _ausCache(VaultDatei d) async {
    final teile = BytesBuilder(copy: false);
    for (final b in d.bloecke) {
      final klar = await vault.block(b.id);
      if (klar == null) return null;
      teile.add(klar);
    }
    return teile.takeBytes();
  }

  /// Nicht mehr benutzte Blöcke beim Server entfernen lassen (höchstens
  /// einmal am Tag). Nur nach einem Abgleich, bei dem alles lesbar war:
  /// sonst könnte ein Block noch zu einer Datei gehören, die hier fehlt.
  Future<void> _aufraeumen(SyncBericht b) async {
    if (b.defekt > 0) return;
    final zuletzt = await vault.aufgeraeumt();
    if (zuletzt != null && _uhr().difference(zuletzt) < aufraeumenAlle) return;
    final dateien = await vault.alle();
    if (dateien.isEmpty && zuletzt == null) return;
    final behalten = {for (final d in dateien) for (final x in d.bloecke) x.id};
    try {
      b.bloeckeAufgeraeumt = await api.bloeckeAufraeumen(behalten.toList());
      await vault.setzeAufgeraeumt(_uhr());
    } on SyncFehler {
      // Aufräumen ist Nebensache; der Abgleich selbst war erfolgreich.
    }
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
