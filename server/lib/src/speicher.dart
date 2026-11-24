import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// Schemaversion der Server-Datenbank. Migrationen laufen beim Start in
/// einer Transaktion; eine neuere Datenbank lehnt der Server ab.
///
/// - 1: Konten, Geräte, Objekte, Kopplungen (M3)
/// - 2: Blöcke für Dateiinhalte des Vault-Syncs (M4)
const dbSchema = 2;

final _zufall = Random.secure();

Uint8List zufall(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) _zufall.nextInt(256)]);

String hexVon(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

String neueId() => hexVon(zufall(16));

/// Hash eines hochentropischen Geheimnisses (Gerätetoken, Recovery-Anmeldung).
/// Ein einfacher SHA-256 genügt, weil die Eingaben 256 Bit Zufall sind.
String geheimHash(List<int> geheim) => sha256.convert(geheim).toString();

class SpeicherFehler implements Exception {
  SpeicherFehler(this.meldung);
  final String meldung;
  @override
  String toString() => meldung;
}

typedef Geraet = ({String id, String konto});

/// Ergebnis einer einzelnen Änderung beim Hochladen.
typedef Ergebnis = ({String id, bool ok, int seq, String? daten});

/// Datenhaltung des Sync-Servers (SQLite). Gespeichert werden nur
/// Geheimtexte der Clients und die für Anmeldung und Abgleich nötigen
/// Metadaten: Konto-, Geräte- und Objekt-IDs (zufällig bzw. gehasht),
/// Revisionen, Zeitstempel und Größen. Gerätenamen verschlüsseln die
/// Clients selbst.
class Speicher {
  Speicher._(this.db);

  final Database db;

  static Speicher oeffnen(String pfad) => Speicher._(_sqlite.open(pfad)).._einrichten();
  static Speicher imSpeicher() => Speicher._(_sqlite.openInMemory()).._einrichten();

  /// Schlanke Systeme (z. B. Debian-slim) haben nur `libsqlite3.so.0`
  /// ohne die Entwickler-Verknüpfung `libsqlite3.so`.
  static Sqlite3 get _sqlite {
    if (Platform.isLinux) _bibliothekSetzen();
    return sqlite3;
  }

  static void _bibliothekSetzen() {
    open.overrideFor(OperatingSystem.linux, () {
      try {
        return DynamicLibrary.open('libsqlite3.so');
      } on ArgumentError {
        return DynamicLibrary.open('libsqlite3.so.0');
      }
    });
  }

  void _einrichten() {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA busy_timeout = 5000');
    final v = db.select('PRAGMA user_version').first.values.first as int;
    if (v > dbSchema) {
      throw SpeicherFehler('Die Datenbank stammt aus einer neueren Server-Version (Schema $v).');
    }
    transaktion(() {
      for (var s = v; s < dbSchema; s++) {
        _migrationen[s]!(db);
      }
      db.execute('PRAGMA user_version = $dbSchema');
    });
    if (meta('instanz') == null) setzeMeta('instanz', neueId());
  }

  static final Map<int, void Function(Database)> _migrationen = {
    0: (db) => db.execute('''
      CREATE TABLE meta (schluessel TEXT PRIMARY KEY, wert TEXT NOT NULL);
      CREATE TABLE konten (
        id TEXT PRIMARY KEY,
        recovery_hash TEXT NOT NULL UNIQUE,
        recovery_huelle TEXT NOT NULL,
        schluessel_paket TEXT NOT NULL,
        seq INTEGER NOT NULL DEFAULT 0,
        erstellt INTEGER NOT NULL
      );
      CREATE TABLE geraete (
        id TEXT PRIMARY KEY,
        konto TEXT NOT NULL REFERENCES konten(id) ON DELETE CASCADE,
        token_hash TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        erstellt INTEGER NOT NULL,
        zuletzt INTEGER NOT NULL
      );
      CREATE TABLE objekte (
        konto TEXT NOT NULL REFERENCES konten(id) ON DELETE CASCADE,
        id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        aenderung TEXT NOT NULL,
        daten TEXT NOT NULL,
        PRIMARY KEY (konto, id)
      );
      CREATE INDEX objekte_seq ON objekte (konto, seq);
      CREATE TABLE kopplungen (
        slot TEXT PRIMARY KEY,
        konto TEXT NOT NULL REFERENCES konten(id) ON DELETE CASCADE,
        paket TEXT NOT NULL,
        ablauf INTEGER NOT NULL
      );
    '''),
    1: (db) => db.execute('''
      CREATE TABLE bloecke (
        konto TEXT NOT NULL REFERENCES konten(id) ON DELETE CASCADE,
        id TEXT NOT NULL,
        daten BLOB NOT NULL,
        erstellt INTEGER NOT NULL,
        PRIMARY KEY (konto, id)
      );
    '''),
  };

  int get _jetzt => DateTime.now().toUtc().millisecondsSinceEpoch;

  T transaktion<T>(T Function() f) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final r = f();
      db.execute('COMMIT');
      return r;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  String? meta(String k) => db.select('SELECT wert FROM meta WHERE schluessel = ?', [k]).firstOrNull?['wert'] as String?;
  void setzeMeta(String k, String w) => db.execute('INSERT OR REPLACE INTO meta VALUES (?, ?)', [k, w]);

  String get instanz => meta('instanz')!;

  // -------------------------------------------------------------------
  // Konten und Geräte

  /// Legt ein Konto mit erstem Gerät an; liefert Konto, Gerät und Token.
  ({String konto, String geraet, String token}) kontoAnlegen({
    required List<int> recoveryAuth,
    required String recoveryHuelle,
    required String schluesselPaket,
    required String geraetName,
  }) =>
      transaktion(() {
        final hash = geheimHash(recoveryAuth);
        if (db.select('SELECT 1 FROM konten WHERE recovery_hash = ?', [hash]).isNotEmpty) {
          throw SpeicherFehler('Für diesen Recovery-Schlüssel gibt es schon ein Konto.');
        }
        final konto = neueId();
        db.execute(
          'INSERT INTO konten (id, recovery_hash, recovery_huelle, schluessel_paket, erstellt) VALUES (?, ?, ?, ?, ?)',
          [konto, hash, recoveryHuelle, schluesselPaket, _jetzt],
        );
        final (:geraet, :token) = _geraetAnlegen(konto, geraetName);
        return (konto: konto, geraet: geraet, token: token);
      });

  ({String geraet, String token}) _geraetAnlegen(String konto, String name) {
    final token = zufall(32);
    final id = neueId();
    db.execute(
      'INSERT INTO geraete (id, konto, token_hash, name, erstellt, zuletzt) VALUES (?, ?, ?, ?, ?, ?)',
      [id, konto, geheimHash(token), name, _jetzt, _jetzt],
    );
    return (geraet: id, token: base64Url.encode(token));
  }

  /// Anmeldung mit dem aus dem Recovery-Schlüssel abgeleiteten Geheimnis:
  /// registriert ein neues Gerät. `null`, wenn kein Konto passt.
  ({String konto, String geraet, String token, String recoveryHuelle})? recoveryAnmelden(List<int> recoveryAuth, String geraetName) =>
      transaktion(() {
        final k = db.select('SELECT id, recovery_huelle FROM konten WHERE recovery_hash = ?', [geheimHash(recoveryAuth)]).firstOrNull;
        if (k == null) return null;
        final (:geraet, :token) = _geraetAnlegen(k['id'] as String, geraetName);
        return (konto: k['id'] as String, geraet: geraet, token: token, recoveryHuelle: k['recovery_huelle'] as String);
      });

  /// Gerät zum Token oder `null` (unbekannt oder widerrufen).
  Geraet? geraetZuToken(String token) {
    final List<int> roh;
    try {
      roh = base64Url.decode(token);
    } on FormatException {
      return null;
    }
    final r = db.select('SELECT id, konto, zuletzt FROM geraete WHERE token_hash = ?', [geheimHash(roh)]).firstOrNull;
    if (r == null) return null;
    // Grob (einmal pro Minute) vermerken, wann das Gerät zuletzt da war.
    if (_jetzt - (r['zuletzt'] as int) > 60000) {
      db.execute('UPDATE geraete SET zuletzt = ? WHERE id = ?', [_jetzt, r['id']]);
    }
    return (id: r['id'] as String, konto: r['konto'] as String);
  }

  Map<String, Object?> kontoInfo(String konto) {
    final k = db.select('SELECT seq, recovery_huelle, schluessel_paket, erstellt FROM konten WHERE id = ?', [konto]).first;
    final o = db.select('SELECT count(*) n, coalesce(sum(length(daten)), 0) b FROM objekte WHERE konto = ?', [konto]).first;
    final b = db.select('SELECT count(*) n, coalesce(sum(length(daten)), 0) b FROM bloecke WHERE konto = ?', [konto]).first;
    return {
      'konto': konto,
      'seq': k['seq'],
      'objekte': o['n'],
      'bloecke': b['n'],
      'belegt': (o['b'] as int) + (b['b'] as int),
      'recoveryHuelle': k['recovery_huelle'],
      'schluesselPaket': k['schluessel_paket'],
      'erstellt': _iso(k['erstellt'] as int),
    };
  }

  List<Map<String, Object?>> geraete(String konto) => [
        for (final r in db.select('SELECT id, name, erstellt, zuletzt FROM geraete WHERE konto = ? ORDER BY erstellt', [konto]))
          {'id': r['id'], 'name': r['name'], 'erstellt': _iso(r['erstellt'] as int), 'zuletzt': _iso(r['zuletzt'] as int)},
      ];

  bool geraetEntfernen(String konto, String id) {
    db.execute('DELETE FROM geraete WHERE konto = ? AND id = ?', [konto, id]);
    return db.updatedRows > 0;
  }

  void geraetUmbenennen(String id, String name) => db.execute('UPDATE geraete SET name = ? WHERE id = ?', [name, id]);

  /// Neuer Recovery-Schlüssel: alte Anmeldung gilt danach nicht mehr.
  void recoveryErsetzen(String konto, {required List<int> recoveryAuth, required String recoveryHuelle, required String schluesselPaket}) =>
      transaktion(() {
        final hash = geheimHash(recoveryAuth);
        if (db.select('SELECT 1 FROM konten WHERE recovery_hash = ? AND id != ?', [hash, konto]).isNotEmpty) {
          throw SpeicherFehler('Dieser Recovery-Schlüssel gehört schon zu einem anderen Konto.');
        }
        db.execute(
          'UPDATE konten SET recovery_hash = ?, recovery_huelle = ?, schluessel_paket = ? WHERE id = ?',
          [hash, recoveryHuelle, schluesselPaket, konto],
        );
      });

  void kontoLoeschen(String konto) => db.execute('DELETE FROM konten WHERE id = ?', [konto]);

  // -------------------------------------------------------------------
  // Kopplung neuer Geräte

  static const kopplungenProKonto = 5;

  void kopplungAnlegen(String konto, String slot, String paket, Duration gueltig) => transaktion(() {
        _kopplungenAufraeumen();
        final n = db.select('SELECT count(*) n FROM kopplungen WHERE konto = ?', [konto]).first['n'] as int;
        if (n >= kopplungenProKonto) throw SpeicherFehler('Zu viele offene Kopplungen. Bitte etwas warten.');
        db.execute('INSERT OR REPLACE INTO kopplungen VALUES (?, ?, ?, ?)', [slot, konto, paket, _jetzt + gueltig.inMilliseconds]);
      });

  /// Löst eine Kopplung genau einmal ein und registriert das neue Gerät.
  ({String konto, String paket, String geraet, String token})? kopplungEinloesen(String slot, String geraetName) => transaktion(() {
        _kopplungenAufraeumen();
        final k = db.select('SELECT konto, paket FROM kopplungen WHERE slot = ?', [slot]).firstOrNull;
        if (k == null) return null;
        db.execute('DELETE FROM kopplungen WHERE slot = ?', [slot]);
        final konto = k['konto'] as String;
        final (:geraet, :token) = _geraetAnlegen(konto, geraetName);
        return (konto: konto, paket: k['paket'] as String, geraet: geraet, token: token);
      });

  void _kopplungenAufraeumen() => db.execute('DELETE FROM kopplungen WHERE ablauf < ?', [_jetzt]);

  // -------------------------------------------------------------------
  // Objekte

  /// Objekte mit `seq > seit`, aufsteigend; [bis] ist der Stand, ab dem der
  /// nächste Abruf weitermacht.
  ({List<Map<String, Object?>> objekte, int bis, bool mehr}) abrufen(String konto, int seit, int max) {
    final rows = db.select(
      'SELECT id, seq, daten FROM objekte WHERE konto = ? AND seq > ? ORDER BY seq LIMIT ?',
      [konto, seit, max + 1],
    );
    final mehr = rows.length > max;
    final liste = [for (final r in rows.take(max)) {'id': r['id'], 'seq': r['seq'], 'daten': r['daten']}];
    final bis = liste.isNotEmpty
        ? liste.last['seq'] as int
        : db.select('SELECT seq FROM konten WHERE id = ?', [konto]).first['seq'] as int;
    // Ohne neue Objekte ist [bis] der Kontostand. Liegt er unter [seit],
    // wurde der Server zurückgesetzt (z. B. aus einer älteren Sicherung).
    return (objekte: liste, bis: bis, mehr: mehr);
  }

  /// Schreibt Änderungen in einer Transaktion. Je Objekt gilt: passt die
  /// [basis] des Clients zur Serverrevision (oder ist das Objekt neu),
  /// wird geschrieben; sonst gibt es einen Konflikt mit der Serverfassung.
  /// Dieselbe Änderungs-ID zweimal (Wiederholung nach Abbruch) ist kein
  /// Konflikt, sondern liefert das frühere Ergebnis.
  List<Ergebnis> schreiben(String konto, List<({String id, int basis, String aenderung, String daten})> aenderungen) =>
      transaktion(() {
        var seq = db.select('SELECT seq FROM konten WHERE id = ?', [konto]).first['seq'] as int;
        final ergebnisse = <Ergebnis>[];
        for (final a in aenderungen) {
          final cur = db.select('SELECT seq, aenderung, daten FROM objekte WHERE konto = ? AND id = ?', [konto, a.id]).firstOrNull;
          if (cur != null && cur['aenderung'] == a.aenderung) {
            ergebnisse.add((id: a.id, ok: true, seq: cur['seq'] as int, daten: null));
            continue;
          }
          if (cur != null && cur['seq'] != a.basis) {
            ergebnisse.add((id: a.id, ok: false, seq: cur['seq'] as int, daten: cur['daten'] as String));
            continue;
          }
          seq++;
          db.execute(
            'INSERT OR REPLACE INTO objekte (konto, id, seq, aenderung, daten) VALUES (?, ?, ?, ?, ?)',
            [konto, a.id, seq, a.aenderung, a.daten],
          );
          ergebnisse.add((id: a.id, ok: true, seq: seq, daten: null));
        }
        db.execute('UPDATE konten SET seq = ? WHERE id = ?', [seq, konto]);
        return ergebnisse;
      });

  // -------------------------------------------------------------------
  // Blöcke (Dateiinhalte des Vault-Syncs)
  //
  // Die Clients verschlüsseln Dateien in Blöcken; die Block-ID ist ein
  // HMAC über den Inhalt unter einem Kontoschlüssel. Welche Datei welche
  // Blöcke nutzt, steht nur in den verschlüsselten Objekten.

  /// Belegter Platz eines Kontos (Objekte und Blöcke) in Byte.
  int belegt(String konto) =>
      (db.select('SELECT coalesce(sum(length(daten)), 0) b FROM objekte WHERE konto = ?', [konto]).first['b'] as int) +
      (db.select('SELECT coalesce(sum(length(daten)), 0) b FROM bloecke WHERE konto = ?', [konto]).first['b'] as int);

  /// Speichert einen Block; gibt es ihn schon, bleibt er unverändert.
  /// [maxKonto] > 0 begrenzt den Platz je Konto.
  void blockSchreiben(String konto, String id, Uint8List daten, {int maxKonto = 0}) => transaktion(() {
        if (db.select('SELECT 1 FROM bloecke WHERE konto = ? AND id = ?', [konto, id]).isNotEmpty) return;
        if (maxKonto > 0 && belegt(konto) + daten.length > maxKonto) {
          throw SpeicherFehler('Der Speicherplatz dieses Kontos ist aufgebraucht.');
        }
        db.execute('INSERT INTO bloecke (konto, id, daten, erstellt) VALUES (?, ?, ?, ?)', [konto, id, daten, _jetzt]);
      });

  Uint8List? blockLesen(String konto, String id) =>
      db.select('SELECT daten FROM bloecke WHERE konto = ? AND id = ?', [konto, id]).firstOrNull?['daten'] as Uint8List?;

  /// Welche der [ids] fehlen.
  List<String> bloeckeFehlend(String konto, List<String> ids) {
    final da = <String>{};
    for (var i = 0; i < ids.length; i += 500) {
      final teil = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      final rows = db.select(
        'SELECT id FROM bloecke WHERE konto = ? AND id IN (${List.filled(teil.length, '?').join(',')})',
        [konto, ...teil],
      );
      da.addAll(rows.map((r) => r['id'] as String));
    }
    return [for (final id in ids) if (!da.contains(id)) id];
  }

  /// Entfernt Blöcke, die keines der Objekte mehr braucht. Nur die
  /// Clients wissen das; sie nennen alle noch benutzten Blöcke. Jüngere
  /// Blöcke als [schonfrist] bleiben, weil ein anderes Gerät sie gerade
  /// hochladen könnte, bevor sein Objekt beim Server ist.
  int bloeckeAufraeumen(String konto, Set<String> behalten, {Duration schonfrist = const Duration(hours: 24)}) => transaktion(() {
        final grenze = _jetzt - schonfrist.inMilliseconds;
        final alt = [
          for (final r in db.select('SELECT id FROM bloecke WHERE konto = ? AND erstellt < ?', [konto, grenze]))
            if (!behalten.contains(r['id'])) r['id'] as String,
        ];
        for (final id in alt) {
          db.execute('DELETE FROM bloecke WHERE konto = ? AND id = ?', [konto, id]);
        }
        return alt.length;
      });

  static String _iso(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

  /// Konsistente Kopie der Datenbank (läuft auch neben dem Server).
  void sichern(String ziel) {
    if (File(ziel).existsSync()) throw SpeicherFehler('$ziel existiert schon.');
    db.execute('VACUUM INTO ?', [ziel]);
  }

  void schliessen() => db.dispose();
}
