import 'dart:convert';
import 'dart:typed_data';

import 'package:sembast/sembast.dart';
import 'package:uuid/uuid.dart';

import '../raeume/raum.dart';
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
  bool get lokalGeaendert => geholt > 0 || konflikte > 0 || raeumeEntfernt.isNotEmpty || raeumeGeaendert;

  /// Antwort von `GET /v1/konto` (Recovery-Paket, Geräte).
  Map<String, dynamic>? konto;

  /// Vault-Dateien, die nicht gesendet wurden: Secret-Treffer ohne
  /// Freigabe, über der Größengrenze oder mit fehlendem Block.
  final vaultGesperrt = <String>{};
  final vaultZuGross = <String>{};
  final vaultFehlt = <String>{};

  /// Vom Server aufgeräumte, nicht mehr benutzte Blöcke.
  int bloeckeAufgeraeumt = 0;

  /// Räume, zu denen kein Zugang mehr besteht (Name).
  final raeumeEntfernt = <String>[];

  /// Neue Mitglieder in eigenen Räumen („Name (Raum)“).
  final neueMitglieder = <String>[];

  /// Raumdaten (Schlüssel, Rechte, Mitglieder) haben sich geändert.
  bool raeumeGeaendert = false;

  /// Änderungen in Räumen mit Leserecht, die nicht gesendet wurden.
  int nurLesen = 0;
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
      await _raeumeAbgleichen(b);
      for (final r in await _raeume()) {
        await _holen(b, raum: r);
      }
      if (!await _senden(b)) break;
    }
    b.konto = await api.konto();
    await _aufraeumen(b);
    return b;
  }

  Future<List<Raum>> _raeume({DatabaseClient? tx}) async => [for (final j in await ablage.lesen(dek, 'raeume', tx: tx)) Raum.fromJson(j)];

  /// Wo ein Datensatz hingehört: `null` = eigenes Konto, sonst Raum-ID.
  /// Termine und Aufgaben tragen ihren Raum; Vault-Dateien liegen in
  /// einem Raum, wenn ihr Pfad unter dessen Ordner liegt.
  static String? zielVon(String bereich, Map<String, dynamic>? daten, Iterable<Raum> raeume) {
    if (daten == null) return null;
    if (bereich == 'termine' || bereich == 'aufgaben') return daten['raum'] as String?;
    if (bereich == vaultBereich) return raumFuerPfad(daten['pfad'] as String, raeume)?.id;
    return null;
  }

  static String freigabeSchluessel(String id, String? raum) => raum == null ? id : '$id@$raum';

  /// Der Vault-Raum, unter dessen Ordner [pfad] liegt.
  static Raum? raumFuerPfad(String pfad, Iterable<Raum> raeume) {
    for (final r in raeume) {
      final o = r.ordner;
      if (r.art == RaumArt.vault && o != null && pfad.startsWith('$o/')) return r;
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Holen

  /// Holt alles Neue aus dem Konto oder aus [raum] und spielt es ein.
  Future<void> _holen(SyncBericht bericht, {Raum? raum}) async {
    final v = (await stand.verbindung())!;
    final staende = await stand.raumStaende();
    final start = raum == null ? (seq: v.seq, bekannt: v.bekannt) : (seq: staende[raum.id]?.seq ?? 0, bekannt: staende[raum.id]?.bekannt ?? 0);
    final objekte = <({String id, int seq, String daten})>[];
    var seit = start.seq;
    while (true) {
      final r = await api.abrufen(seit, max: seite, raum: raum?.id);
      if (r.objekte.isEmpty && objekte.isEmpty && r.bis < (seit > start.bekannt ? seit : start.bekannt)) {
        await _neuAufbauen(bericht, raum);
        return _holen(bericht, raum: raum);
      }
      objekte.addAll(r.objekte);
      seit = r.bis;
      if (!r.mehr) break;
    }

    if (raum != null) {
      // Zurückgestellte Objekte dieses Raums noch einmal versuchen.
      for (final z in (await stand.zurueckgestellt()).values) {
        if (z.raum == raum.id && !objekte.any((o) => o.id == z.id && o.seq >= z.seq)) objekte.add((id: z.id, seq: z.seq, daten: z.daten));
      }
      objekte.sort((a, b) => a.seq.compareTo(b.seq));
    }

    // Entschlüsseln außerhalb der Sperre.
    final erlaubt = raum == null
        ? {...Ablage.bereiche, vaultBereich}
        : {'raum', switch (raum.art) { RaumArt.kalender => 'termine', RaumArt.aufgaben => 'aufgaben', RaumArt.vault => vaultBereich }};
    final umschlaege = <({int seq, Umschlag u, String oid, String daten})>[];
    for (final o in objekte) {
      final u = raum == null ? v.schluessel.entschluesseln(o.id, o.daten) : raum.entschluesseln(o.id, o.daten);
      if (u == null) {
        bericht.defekt++;
        continue;
      }
      if (u.schema > aktuellesSchema || (raum == null && !erlaubt.contains(u.bereich))) {
        throw SyncFehler(SyncFehlerArt.version, 'Ein anderes Gerät nutzt eine neuere App-Version. Bitte diese App aktualisieren.');
      }
      if (!erlaubt.contains(u.bereich)) {
        bericht.defekt++;
        continue;
      }
      umschlaege.add((seq: o.seq, u: u, oid: o.id, daten: o.daten));
    }

    await sperre.exklusiv(() => ablage.transaktion((tx) async {
          final basis = await stand.basis(tx: tx);
          final ausgang = await stand.ausgang(tx: tx);
          final orte = await stand.orte(tx: tx);
          final zurueck = await stand.zurueckgestellt(tx: tx);
          final geloeschteKonten = <String, Map<String, dynamic>>{};
          _vaultIndex = null;
          final vBasis = await vault.basis(tx: tx);
          final v0 = (await stand.verbindung(tx: tx))!;
          var aktuellerRaum = raum;
          for (final (:seq, :u, :oid, :daten) in umschlaege) {
            if (u.bereich == 'raum') {
              // Raum-Info des Eigentümers: Name und Mitglieder.
              if (raum != null && !raum.eigen && u.daten != null) aktuellerRaum = await _infoUebernehmen(raum.id, u.daten!, tx);
              continue;
            }
            final k = SyncStand.schluessel(u.bereich, u.id);
            if (raum != null && zurueck[k]?.raum == raum.id && zurueck[k]!.seq <= seq) zurueck.remove(k);
            if (orte[k] != raum?.id) {
              // Liegt (für uns) woanders: ein Löschvermerk hier betrifft uns
              // nicht mehr; eine Fassung hier heißt, er ist hierher gewandert.
              if (u.daten == null) continue;
              // Ein Raum darf nichts übernehmen, was hier noch woanders liegt
              // (sonst könnte ein Mitglied einen wieder privaten Eintrag
              // zurückholen). Eigene Verschiebungen löschen zuerst am alten
              // Ort; danach kommt das zurückgestellte Objekt an die Reihe.
              if (raum != null && (ausgang.containsKey(k) || await ablage.lesenEinzeln(dek, u.bereich, u.id, tx: tx) != null)) {
                zurueck[k] = (raum: raum.id, seq: seq, id: oid, daten: daten);
                continue;
              }
              if (raum == null) {
                orte.remove(k);
              } else {
                orte[k] = raum.id;
              }
              basis.remove(k);
            } else if ((basis[k] ?? 0) >= seq) {
              continue;
            }
            var w = u;
            if (raum != null && u.daten != null) w = _ausRaum(u, aktuellerRaum!);
            if (w.bereich == vaultBereich) {
              await _vaultEinspielen(w, ausgang, vBasis, v0.name, tx, bericht);
            } else {
              await _einspielen(w, ausgang.containsKey(k), tx, bericht, geloeschteKonten);
            }
            basis[k] = seq;
          }
          await _kontenSichern(geloeschteKonten, tx);
          await vault.setzeBasis(vBasis, tx: tx);
          await stand.setzeBasis(basis, tx: tx);
          await stand.setzeOrte(orte, tx: tx);
          await stand.setzeZurueckgestellt(zurueck, tx: tx);
          if (raum == null) {
            final jetzt = (await stand.verbindung(tx: tx))!;
            await stand.setzeVerbindung(jetzt.mit(seq: seit, bekannt: seit > jetzt.bekannt ? seit : jetzt.bekannt), tx: tx);
          } else {
            final st = await stand.raumStaende(tx: tx);
            final alt = st[raum.id];
            final bekannt = alt == null || seit > alt.bekannt ? seit : alt.bekannt;
            st[raum.id] = (seq: seit, bekannt: bekannt, info: alt?.info ?? 0);
            await stand.setzeRaumStaende(st, tx: tx);
          }
        }));
  }

  /// Daten aus einem Raum in die lokale Form: Termine und Aufgaben
  /// bekommen den Raum, Vault-Pfade den Ordner, unter dem er hier hängt.
  static Umschlag _ausRaum(Umschlag u, Raum raum) {
    final d = {...u.daten!};
    if (u.bereich == vaultBereich) {
      d['pfad'] = '${raum.ordner}/${vaultPfad(d['pfad'] as String)}';
      d['blockOrt'] = raum.id;
    } else {
      d['raum'] = raum.id;
    }
    return Umschlag(bereich: u.bereich, id: u.id, schema: u.schema, daten: d);
  }

  Future<Raum> _infoUebernehmen(String id, Map<String, dynamic> info, DatabaseClient tx) async {
    final j = await ablage.lesenEinzeln(dek, 'raeume', id, tx: tx);
    final r = Raum.fromJson(j!);
    final neu = r.kopie(
      name: info['name'] as String?,
      von: info['von'] as String?,
      mitgliederNamen: [
        for (final m in ((info['mitglieder'] as List?) ?? const []).cast<Map<String, dynamic>>()) (name: m['name'] as String, recht: m['recht'] as String),
      ],
    );
    if (jsonEncode(neu.toJson()) != jsonEncode(r.toJson())) {
      await ablage.schreiben(dek, 'raeume', id, neu.toJson(), tx: tx);
      await stand.vormerken('raeume', id, tx: tx);
    }
    return neu;
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
      blockOrt: inhaltVon.blockOrt,
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
  /// Für einen Raum gilt das nur für das, was dort liegt.
  Future<void> _neuAufbauen(SyncBericht bericht, Raum? raum) => sperre.exklusiv(() => ablage.transaktion((tx) async {
        bericht.neuAufgebaut = true;
        final orte = await stand.orte(tx: tx);
        final basis = await stand.basis(tx: tx);
        final vBasis = await vault.basis(tx: tx);
        if (raum == null) {
          await stand.allesVormerken(tx: tx);
          basis.removeWhere((k, _) => !orte.containsKey(k));
          final v = (await stand.verbindung(tx: tx))!;
          await stand.setzeVerbindung(v.mit(seq: 0, bekannt: 0), tx: tx);
        } else {
          final st = await stand.raumStaende(tx: tx);
          st[raum.id] = (seq: 0, bekannt: 0, info: 0);
          await stand.setzeRaumStaende(st, tx: tx);
          for (final k in [for (final e in orte.entries) if (e.value == raum.id) e.key]) {
            basis.remove(k);
            if (raum.schreibbar) await stand.vormerken(SyncStand.teile(k).$1, SyncStand.teile(k).$2, tx: tx);
          }
        }
        for (final id in vBasis.keys.toList()) {
          if (!basis.containsKey(SyncStand.schluessel(vaultBereich, id))) vBasis.remove(id);
        }
        await vault.setzeBasis(vBasis, tx: tx);
        await stand.setzeBasis(basis, tx: tx);
      }));

  // ---------------------------------------------------------------------
  // Räume verwalten

  /// Gleicht die Raumliste mit dem Server ab: neue Mitglieder erkennen
  /// (Eigentümer), neue Schlüssel und Rechte übernehmen (Mitglied), und
  /// Räume ohne Zugang mehr aufräumen.
  Future<void> _raeumeAbgleichen(SyncBericht bericht) async {
    final lokal = await _raeume();
    if (lokal.isEmpty) return;
    final server = {for (final r in await api.raeume()) r['id'] as String: r};
    final jetzt = _uhr();
    for (final r in lokal) {
      final s = server[r.id];
      if (s == null) {
        await sperre.exklusiv(() => ablage.transaktion((tx) => _raumEntfernen(r, tx)));
        bericht.raeumeEntfernt.add(r.name);
        continue;
      }
      Raum neu = r;
      if (r.eigen) {
        final bekannt = {for (final m in r.mitglieder) m.konto: m};
        final offen = [...r.einladungen.where((e) => e.bis.isAfter(jetzt))];
        final mitglieder = <Mitglied>[];
        for (final m in (s['mitglieder'] as List).cast<Map<String, dynamic>>()) {
          final konto = m['konto'] as String;
          final alt = bekannt[konto];
          if (alt != null) {
            mitglieder.add(alt.mit(recht: m['recht'] as String));
            continue;
          }
          for (final e in offen) {
            final name = Raum.antwortName(e.slot, e.paar, m['antwort'] as String);
            if (name == null) continue;
            final neues = Mitglied(konto: konto, name: name, recht: m['recht'] as String, paar: e.paar);
            mitglieder.add(neues);
            offen.remove(e);
            // Aktuelle Schlüssel nachreichen (die Einladung kann älter sein
            // als der letzte Schlüsselwechsel).
            await api.mitgliedAendern(r.id, konto, paket: r.mitgliedPaket(e.paar));
            bericht.neueMitglieder.add('$name (${r.name})');
            break;
          }
        }
        neu = r.kopie(mitglieder: mitglieder, einladungen: offen);
      } else {
        final paket = s['paket'] as String?;
        final k = paket == null || r.paar == null ? null : Raum.mitgliedPaketOeffnen(r.id, r.paar!, paket);
        neu = r.kopie(recht: s['recht'] as String, schluessel: k?.schluessel, epoche: k?.epoche);
      }
      if (jsonEncode(neu.toJson()) != jsonEncode(r.toJson())) {
        await sperre.exklusiv(() => ablage.transaktion((tx) async {
              await ablage.schreiben(dek, 'raeume', r.id, neu.toJson(), tx: tx);
              await stand.vormerken('raeume', r.id, tx: tx);
            }));
        bericht.raeumeGeaendert = true;
      }
      if (neu.eigen) await infoSenden(neu);
    }
  }

  /// Schreibt die Raum-Info (Name, Art, Mitglieder), wenn sie sich geändert
  /// hat. Nur der Eigentümer.
  Future<void> infoSenden(Raum r) async {
    final daten = {
      'name': r.name,
      'art': r.art.name,
      'von': r.von,
      'mitglieder': [for (final m in r.mitglieder) {'name': m.name, 'recht': m.recht}],
    };
    final st = await stand.raumStaende();
    final alt = st[r.id];
    final hash = sha256Hex(utf8.encode(jsonEncode(daten)));
    if (await ablage.lesenEinzeln(dek, 'sync', 'raum_info_${r.id}').then((j) => j?['hash']) == hash) return;
    var basis = alt?.info ?? 0;
    for (var versuch = 0; versuch < 2; versuch++) {
      final e = (await api.schreiben([
        (
          id: r.objektId('raum', 'info'),
          basis: basis,
          aenderung: _uuid.v4(),
          daten: r.verschluesseln(Umschlag(bereich: 'raum', id: 'info', schema: aktuellesSchema, daten: daten)),
        ),
      ], raum: r.id))
          .single;
      basis = e.seq;
      if (e.ok) break;
    }
    final neu = await stand.raumStaende();
    final x = neu[r.id];
    neu[r.id] = (seq: x?.seq ?? 0, bekannt: x?.bekannt ?? 0, info: basis);
    await stand.setzeRaumStaende(neu);
    await ablage.schreiben(dek, 'sync', 'raum_info_${r.id}', {'id': 'raum_info_${r.id}', 'hash': hash});
  }

  /// Kein Zugang mehr zu [r] (entfernt, ausgetreten, Raum gelöscht).
  /// Mitglied: was aus dem Raum stammte, verschwindet hier. Eigentümer
  /// (Raum auf einem anderen eigenen Gerät beendet): alles wird wieder
  /// privat und im eigenen Konto abgelegt.
  Future<void> raumEntfernen(Raum r, DatabaseClient tx) => _raumEntfernen(r, tx);

  Future<void> _raumEntfernen(Raum r, DatabaseClient tx) async {
    final orte = await stand.orte(tx: tx);
    final basis = await stand.basis(tx: tx);
    final vBasis = await vault.basis(tx: tx);
    for (final bereich in ['termine', 'aufgaben']) {
      for (final d in await ablage.lesen(dek, bereich, tx: tx)) {
        if (d['raum'] != r.id) continue;
        final k = SyncStand.schluessel(bereich, d['id'] as String);
        if (r.eigen) {
          await ablage.schreiben(dek, bereich, d['id'] as String, {...d}..remove('raum'), tx: tx);
          await stand.vormerken(bereich, d['id'] as String, tx: tx);
        } else {
          await ablage.loeschen(bereich, d['id'] as String, tx: tx);
          await stand.erledigt(k, tx: tx);
        }
      }
    }
    for (final d in await vault.alle(tx: tx)) {
      final drin = d.blockOrt == r.id || (r.ordner != null && d.pfad.startsWith('${r.ordner}/'));
      if (!drin) continue;
      final k = SyncStand.schluessel(vaultBereich, d.id);
      if (r.eigen) {
        await stand.vormerken(vaultBereich, d.id, tx: tx);
      } else {
        await vault.loeschen(d.id, tx: tx);
        await stand.erledigt(k, tx: tx);
        vBasis.remove(d.id);
      }
    }
    for (final k in [for (final e in orte.entries) if (e.value == r.id) e.key]) {
      orte.remove(k);
      basis.remove(k);
      if (SyncStand.teile(k).$1 == vaultBereich) vBasis.remove(SyncStand.teile(k).$2);
    }
    await stand.setzeOrte(orte, tx: tx);
    await stand.setzeBasis(basis, tx: tx);
    await vault.setzeBasis(vBasis, tx: tx);
    final st = await stand.raumStaende(tx: tx)..remove(r.id);
    await stand.setzeRaumStaende(st, tx: tx);
    final z = await stand.zurueckgestellt(tx: tx)..removeWhere((_, x) => x.raum == r.id);
    await stand.setzeZurueckgestellt(z, tx: tx);
    await ablage.loeschen('raeume', r.id, tx: tx);
    await stand.vormerken('raeume', r.id, tx: tx);
  }

  // ---------------------------------------------------------------------
  // Senden

  _Ort _ort(Verbindung v, Raum? r) => _Ort(v.schluessel, r);

  /// Sendet Ausstehendes; `true`, wenn der Server Konflikte gemeldet hat.
  /// Wechselt ein Datensatz den Ort (privat ↔ geteilt), wird er am alten
  /// Ort gelöscht und am neuen angelegt.
  Future<bool> _senden(SyncBericht bericht) async {
    final v = (await stand.verbindung())!;
    final raeume = {for (final r in await _raeume()) r.id: r};
    final zurueck = await _vaultVorbereiten(v, bericht, raeume);
    final eintraege = (await stand.ausgang()).entries.where((e) => !zurueck.contains(e.key)).toList();
    final weg = <String?, List<_Sendung>>{};
    final hin = <String?, List<_Sendung>>{};
    await sperre.exklusiv(() async {
      final basis = await stand.basis();
      final orte = await stand.orte();
      for (final e in eintraege) {
        final (bereich, id) = SyncStand.teile(e.key);
        var daten = await ablage.lesenEinzeln(dek, bereich, id);
        final hatBasis = basis[e.key] != null;
        if (daten == null && !hatBasis) {
          // Nie gesendet und schon wieder gelöscht: nichts zu tun.
          await stand.erledigt(e.key);
          continue;
        }
        final alt = hatBasis ? orte[e.key] : null;
        final ziel = daten == null ? alt : zielVon(bereich, daten, raeume.values);
        final zr = ziel == null ? null : raeume[ziel];
        if (ziel != null && (zr == null || !zr.schreibbar)) {
          // Raum weg oder nur lesbar: nicht senden.
          if (zr != null) bericht.nurLesen++;
          await stand.erledigt(e.key);
          continue;
        }
        if (bereich == 'einstellungen' && daten != null) daten = {...daten}..remove('letzteSicherung');
        VaultDatei? vd;
        if (daten != null && bereich == vaultBereich) {
          vd = VaultDatei.fromJson(daten);
          daten = vd.zumSenden(wurzel: zr?.ordner);
        } else if (daten != null && (bereich == 'termine' || bereich == 'aufgaben')) {
          daten = {...daten}..remove('raum');
        }
        if (hatBasis && alt != ziel) {
          final ar = alt == null ? null : raeume[alt];
          if (alt == null || (ar != null && ar.schreibbar)) {
            (weg[alt] ??= []).add(_Sendung(e.key, basis[e.key]!, e.value, null, null, alt));
          }
        }
        (hin[ziel] ??= []).add(_Sendung(e.key, hatBasis && alt == ziel ? basis[e.key]! : 0, e.value, daten, vd, ziel));
      }
    });

    var konflikt = false;
    final gescheitert = <String>{};
    for (final g in weg.entries) {
      for (final (s, r) in await _schicken(v, raeume[g.key], g.value)) {
        if (!r.ok) {
          konflikt = true;
          gescheitert.add(s.key);
        }
      }
    }
    for (final g in hin.entries) {
      final liste = g.value.where((s) => !gescheitert.contains(s.key)).toList();
      for (var i = 0; i < liste.length; i += proSenden) {
        final teil = liste.sublist(i, i + proSenden > liste.length ? liste.length : i + proSenden);
        final ergebnisse = await _schicken(v, raeume[g.key], teil);
        await sperre.exklusiv(() => ablage.transaktion((tx) async {
              final basis = await stand.basis(tx: tx);
              final orte = await stand.orte(tx: tx);
              final ausgang = await stand.ausgang(tx: tx);
              final vBasis = await vault.basis(tx: tx);
              var hoechste = 0;
              for (final (s, r) in ergebnisse) {
                if (!r.ok) {
                  konflikt = true;
                  continue;
                }
                bericht.gesendet++;
                basis[s.key] = r.seq;
                if (r.seq > hoechste) hoechste = r.seq;
                if (s.ort == null) {
                  orte.remove(s.key);
                } else {
                  orte[s.key] = s.ort!;
                }
                final (b, id) = SyncStand.teile(s.key);
                if (b == vaultBereich) {
                  if (s.vault == null) {
                    vBasis.remove(id);
                  } else {
                    vBasis[id] = (pfad: s.vault!.pfad, sha: s.vault!.sha256);
                  }
                }
                // Nur erledigt, wenn hier inzwischen nichts Neues dazukam.
                if (ausgang[s.key] == s.aenderung) await stand.erledigt(s.key, tx: tx);
              }
              await stand.setzeBasis(basis, tx: tx);
              await stand.setzeOrte(orte, tx: tx);
              await vault.setzeBasis(vBasis, tx: tx);
              if (g.key == null) {
                final jetzt = (await stand.verbindung(tx: tx))!;
                if (hoechste > jetzt.bekannt) await stand.setzeVerbindung(jetzt.mit(bekannt: hoechste), tx: tx);
              } else {
                final st = await stand.raumStaende(tx: tx);
                final x = st[g.key!];
                if (hoechste > (x?.bekannt ?? 0)) {
                  st[g.key!] = (seq: x?.seq ?? 0, bekannt: hoechste, info: x?.info ?? 0);
                  await stand.setzeRaumStaende(st, tx: tx);
                }
              }
            }));
      }
    }
    return konflikt;
  }

  Future<List<(_Sendung, ({String id, bool ok, int seq, String? daten}))>> _schicken(Verbindung v, Raum? raum, List<_Sendung> liste) async {
    if (liste.isEmpty) return const [];
    final ort = _ort(v, raum);
    final zuordnung = <String, _Sendung>{};
    final aenderungen = <({String id, int basis, String aenderung, String daten})>[];
    for (final s in liste) {
      final (bereich, id) = SyncStand.teile(s.key);
      final oid = ort.objektId(bereich, id);
      zuordnung[oid] = s;
      aenderungen.add((
        id: oid,
        basis: s.basis,
        aenderung: s.aenderung,
        daten: ort.verschluesseln(Umschlag(bereich: bereich, id: id, schema: aktuellesSchema, daten: s.daten)),
      ));
    }
    final ergebnisse = [for (final r in await api.schreiben(aenderungen, raum: raum?.id)) if (zuordnung[r.id] != null) (zuordnung[r.id]!, r)];
    // Kommt ein Datensatz an einen Ort zurück, an dem nur noch sein
    // Löschvermerk liegt (z. B. geteilt und wieder privat), gilt dieser
    // als Basis.
    final nochmal = <_Sendung>[];
    for (final (s, r) in ergebnisse) {
      if (r.ok || s.basis != 0 || r.daten == null) continue;
      final dort = ort.entschluesseln(r.id, r.daten!);
      if (dort != null && dort.daten == null) nochmal.add(_Sendung(s.key, r.seq, s.aenderung, s.daten, s.vault, s.ort));
    }
    if (nochmal.isEmpty) return ergebnisse;
    final zweite = {for (final (s, r) in await _schicken(v, raum, nochmal)) s.key: (s, r)};
    return [for (final (s, r) in ergebnisse) zweite[s.key] ?? (s, r)];
  }

  /// Prüft ausstehende Vault-Dateien vor dem Senden und lädt fehlende
  /// Blöcke an ihren Ort hoch. Liefert die Schlüssel, die diesmal nicht
  /// gesendet werden (Secret ohne Freigabe, zu groß, Block fehlt).
  ///
  /// Geprüft wird ein Inhalt, den der Server noch nicht kennt, und alles,
  /// was neu in einen geteilten Raum kommt (dort sehen es andere). Eine
  /// reine Umbenennung ändert nichts an dem, was schon dort liegt.
  Future<Set<String>> _vaultVorbereiten(Verbindung v, SyncBericht bericht, Map<String, Raum> raeume) async {
    final zurueck = <String>{};
    final ausgang = await stand.ausgang();
    final keys = ausgang.keys.where((k) => SyncStand.teile(k).$1 == vaultBereich).toList();
    if (keys.isEmpty) return zurueck;
    final vBasis = await vault.basis();
    final freigaben = await vault.freigaben();
    final basis = await stand.basis();
    final orte = await stand.orte();
    final brauchtBloecke = <String?, Map<String, String>>{};
    for (final k in keys) {
      final id = SyncStand.teile(k).$2;
      var d = await vault.datei(id);
      if (d == null) continue;
      final zr = raumFuerPfad(d.pfad, raeume.values);
      if (zr != null && !zr.schreibbar) continue;
      final ziel = zr?.id;
      final neuHier = basis[k] == null || orte[k] != ziel;
      final inhaltNeu = vBasis[id]?.sha != d.sha256;
      if (!inhaltNeu && !neuHier && d.blockOrt == ziel) continue;
      if (d.groesse > vaultMaxBytes) {
        bericht.vaultZuGross.add(id);
        zurueck.add(k);
        continue;
      }
      Uint8List? inhalt;
      try {
        inhalt = d.inhalt ?? await _ausCache(d) ?? await _vomServer(v, d, raeume);
      } on SyncFehler {
        inhalt = null;
      }
      if (inhalt == null) {
        bericht.vaultFehlt.add(id);
        zurueck.add(k);
        continue;
      }
      if (inhaltNeu || (neuHier && ziel != null)) {
        final treffer = secrets.pruefen(inhalt);
        // Eine Freigabe gilt für genau diesen Inhalt an genau diesem Ort:
        // Was privat hochgeladen werden durfte, ist nicht automatisch für
        // andere freigegeben.
        if (treffer != null && treffer.isNotEmpty && freigaben[freigabeSchluessel(id, ziel)] != d.sha256) {
          bericht.vaultGesperrt.add(id);
          zurueck.add(k);
          continue;
        }
      }
      if (d.inhalt == null && d.blockOrt != ziel) {
        // Blöcke mit dem Schlüssel des neuen Orts neu bilden.
        final ort = _ort(v, zr);
        final neueBloecke = <String, Uint8List>{};
        final n = vaultDateiAus(
          id: d.id,
          pfad: d.pfad,
          inhalt: inhalt,
          geaendert: d.geaendert,
          blockId: ort.blockId,
          blockOrt: ziel,
          neueBloecke: neueBloecke,
        );
        final alt = d;
        await sperre.exklusiv(() => ablage.transaktion((tx) async {
              final jetzt = await vault.datei(id, tx: tx);
              if (jetzt == null || jetzt.sha256 != alt.sha256 || jetzt.pfad != alt.pfad) return;
              for (final e in neueBloecke.entries) {
                await vault.blockSpeichern(e.key, e.value, tx: tx);
              }
              await vault.schreiben(n, tx: tx);
            }));
        d = n;
      }
      for (final b in d.bloecke) {
        (brauchtBloecke[ziel] ??= {})[b.id] = k;
      }
    }
    for (final g in brauchtBloecke.entries) {
      final ort = _ort(v, g.key == null ? null : raeume[g.key]);
      for (final bid in await api.bloeckeFehlend(g.value.keys.toList(), raum: g.key)) {
        final k = g.value[bid]!;
        if (zurueck.contains(k)) continue;
        final klar = await vault.block(bid);
        if (klar == null) {
          bericht.vaultFehlt.add(SyncStand.teile(k).$2);
          zurueck.add(k);
          continue;
        }
        await api.blockSchreiben(bid, ort.blockVerschluesseln(bid, klar), raum: g.key);
      }
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

  /// Inhalt vom bisherigen Ort holen (z. B. beim Verschieben in einen Raum).
  Future<Uint8List?> _vomServer(Verbindung v, VaultDatei d, Map<String, Raum> raeume) async {
    final r = d.blockOrt == null ? null : raeume[d.blockOrt];
    if (d.blockOrt != null && r == null) return null;
    final ort = _ort(v, r);
    final teile = BytesBuilder(copy: false);
    for (final b in d.bloecke) {
      final klar = ort.blockEntschluesseln(b.id, await api.blockLesen(b.id, raum: r?.id), b.groesse);
      if (klar == null) return null;
      await vault.blockSpeichern(b.id, klar);
      teile.add(klar);
    }
    final alles = teile.takeBytes();
    return sha256Hex(alles) == d.sha256 ? alles : null;
  }

  /// Nicht mehr benutzte Blöcke beim Server entfernen lassen (höchstens
  /// einmal am Tag), im Konto und in eigenen Räumen. Nur nach einem
  /// Abgleich, bei dem alles lesbar war: sonst könnte ein Block noch zu
  /// einer Datei gehören, die hier fehlt.
  Future<void> _aufraeumen(SyncBericht b) async {
    if (b.defekt > 0) return;
    final zuletzt = await vault.aufgeraeumt();
    if (zuletzt != null && _uhr().difference(zuletzt) < aufraeumenAlle) return;
    final dateien = await vault.alle();
    if (dateien.isEmpty && zuletzt == null) return;
    try {
      final behalten = {for (final d in dateien) if (d.blockOrt == null) for (final x in d.bloecke) x.id};
      b.bloeckeAufgeraeumt = await api.bloeckeAufraeumen(behalten.toList());
      for (final r in await _raeume()) {
        if (!r.eigen || r.art != RaumArt.vault) continue;
        final imRaum = {for (final d in dateien) if (d.blockOrt == r.id) for (final x in d.bloecke) x.id};
        b.bloeckeAufgeraeumt += await api.bloeckeAufraeumen(imRaum.toList(), raum: r.id);
      }
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

/// Eine Änderung für einen Ort (`null` = eigenes Konto).
class _Sendung {
  _Sendung(this.key, this.basis, this.aenderung, this.daten, this.vault, this.ort);
  final String key;
  final int basis;
  final String aenderung;

  /// `null` = Löschvermerk.
  final Map<String, dynamic>? daten;
  final VaultDatei? vault;
  final String? ort;
}

/// Schlüssel eines Orts: Kontoschlüssel oder Raum.
class _Ort {
  _Ort(this.ks, this.raum);
  final Kontoschluessel ks;
  final Raum? raum;

  String objektId(String b, String i) => raum?.objektId(b, i) ?? ks.objektId(b, i);
  String verschluesseln(Umschlag u) => raum?.verschluesseln(u) ?? ks.verschluesseln(u);
  Umschlag? entschluesseln(String oid, String daten) => raum != null ? raum!.entschluesseln(oid, daten) : ks.entschluesseln(oid, daten);
  String blockId(Uint8List klar) => raum?.blockId(klar) ?? ks.blockId(klar);
  Uint8List blockVerschluesseln(String id, Uint8List klar) => raum?.blockVerschluesseln(id, klar) ?? ks.blockVerschluesseln(id, klar);
  Uint8List? blockEntschluesseln(String id, Uint8List daten, int groesse) =>
      raum != null ? raum!.blockEntschluesseln(id, daten, groesse) : ks.blockEntschluesseln(id, daten, groesse);
}
