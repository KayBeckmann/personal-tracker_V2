import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'speicher.dart';

/// Föderierter, freiwilliger Produkt- und Preiskatalog (M7).
///
/// Anders als alles andere auf diesem Server ist der Katalog **öffentlich**:
/// Beiträge sind Klartext, damit andere sie lesen können. Jede Instanz
/// veröffentlicht nur die Beiträge ihrer eigenen Konten (`GET /k1/feed`);
/// andere Instanzen holen sie per HTTPS ab. Die Herkunft ist damit die
/// abrufende Adresse. Eine Person erscheint als `Pseudonym@Instanz`, nie mit
/// Namen oder Konto-ID.
///
/// Ein Preis gilt als **bestätigt**, sobald mindestens eine andere Identität
/// ihn bestätigt hat (ausdrücklich oder mit demselben Preis für dieselbe
/// Packung in derselben Filiale innerhalb von 14 Tagen). Eine Instanz kann
/// beliebig viele Identitäten erfinden; das ist der bewusste Preis der
/// offenen Föderation (siehe `protokoll/KATALOG.md`).
class Katalog {
  Katalog(this.s, {required this.instanz});

  final Speicher s;

  /// Öffentliche Adresse dieser Instanz (`https://…`), oder `lokal`, wenn
  /// keine eingestellt ist (dann ohne Föderation).
  final String instanz;

  Database get db => s.db;

  bool get foederiert => instanz != 'lokal';

  static const typen = {'preis', 'bestaetigung', 'rueckzug'};
  static final _pseudonym = RegExp(r'^p-[0-9a-f]{12}$');
  static final _id = RegExp(r'^[0-9a-zA-Z\-]{8,64}$');
  static const einheiten = {'stueck', 'g', 'kg', 'ml', 'l'};

  int get _jetzt => DateTime.now().toUtc().millisecondsSinceEpoch;

  // -------------------------------------------------------------------
  // Konten

  /// Pseudonym eines Kontos (beim ersten Gebrauch angelegt).
  ({String pseudonym, bool gesperrt}) konto(String konto) {
    final r = db.select('SELECT pseudonym, gesperrt FROM katalog_konten WHERE konto = ?', [konto]).firstOrNull;
    if (r != null) return (pseudonym: r['pseudonym'] as String, gesperrt: r['gesperrt'] == 1);
    final p = 'p-${hexVon(zufall(6))}';
    db.execute('INSERT INTO katalog_konten (konto, pseudonym, gesperrt) VALUES (?, ?, 0)', [konto, p]);
    return (pseudonym: p, gesperrt: false);
  }

  /// Betreiber: Konto sperren. Seine Beiträge werden zurückgezogen (auch
  /// bei anderen Instanzen), neue sind nicht mehr möglich.
  int kontoSperren(String pseudonym) => s.transaktion(() {
        db.execute('UPDATE katalog_konten SET gesperrt = 1 WHERE pseudonym = ?', [pseudonym]);
        if (db.updatedRows == 0) throw SpeicherFehler('Pseudonym $pseudonym gibt es auf dieser Instanz nicht.');
        return _alleZurueckziehen(pseudonym);
      });

  /// Beim Löschen eines Kontos: seine Beiträge zurückziehen.
  void kontoEntfernen(String konto) {
    final r = db.select('SELECT pseudonym FROM katalog_konten WHERE konto = ?', [konto]).firstOrNull;
    if (r != null) _alleZurueckziehen(r['pseudonym'] as String);
  }

  int _alleZurueckziehen(String pseudonym) {
    final ids = [
      for (final r in db.select(
        "SELECT id FROM katalog WHERE instanz = ? AND autor = ? AND typ != 'rueckzug' AND id NOT IN (SELECT json_extract(daten, '\$.ziel.id') FROM katalog WHERE instanz = ? AND typ = 'rueckzug')",
        [instanz, pseudonym, instanz],
      ))
        r['id'] as String,
    ];
    for (final id in ids) {
      _eintragen(pseudonym, {'typ': 'rueckzug', 'ziel': {'instanz': instanz, 'id': id}});
    }
    return ids.length;
  }

  /// Betreiber: eine Instanz nicht mehr abrufen und ihre Beiträge ausblenden.
  void instanzSperren(String url, {bool gesperrt = true}) {
    db.execute('INSERT INTO katalog_peers (url, seit, gesperrt, entdeckt) VALUES (?, 0, ?, ?) ON CONFLICT(url) DO UPDATE SET gesperrt = excluded.gesperrt',
        [url, gesperrt ? 1 : 0, _jetzt]);
  }

  // -------------------------------------------------------------------
  // Eigene Beiträge

  /// Prüft einen Beitrag (eigener oder von einer anderen Instanz). Liefert
  /// die bereinigten Daten oder `null`.
  static Map<String, Object?>? pruefen(Map<String, dynamic> j) {
    String? text(String k, int max, {bool pflicht = true}) {
      final v = j[k];
      if (v == null && !pflicht) return null;
      if (v is! String) return null;
      final t = v.trim();
      if ((pflicht && t.isEmpty) || t.length > max || RegExp(r'[\x00-\x1f]').hasMatch(t)) return null;
      return t;
    }

    final typ = j['typ'];
    if (typ is! String || !typen.contains(typ)) return null;
    if (typ == 'preis') {
      final artikel = text('artikel', 100), kette = text('kette', 60), filiale = text('filiale', 100), region = text('region', 60);
      final variante = text('variante', 60, pflicht: false);
      final menge = j['packungsMenge'], einheit = j['packungsEinheit'], cent = j['preisCent'], tag = j['tag'];
      if (artikel == null || kette == null || filiale == null || region == null) return null;
      if (j['variante'] != null && variante == null) return null;
      if (menge is! num || menge <= 0 || menge > 100000 || einheit is! String || !einheiten.contains(einheit)) return null;
      if (cent is! int || cent <= 0 || cent > 10000000) return null;
      if (j['waehrung'] != 'EUR') return null;
      if (tag is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(tag)) return null;
      final t = DateTime.tryParse(tag);
      final heute = DateTime.now().toUtc();
      if (t == null || t.isAfter(heute.add(const Duration(days: 2))) || t.isBefore(heute.subtract(const Duration(days: 800)))) return null;
      return {
        'typ': 'preis',
        'artikel': artikel,
        'variante': ?variante,
        'packungsMenge': menge,
        'packungsEinheit': einheit,
        'kette': kette,
        'filiale': filiale,
        'region': region,
        'preisCent': cent,
        'waehrung': 'EUR',
        'tag': tag,
      };
    }
    final ziel = j['ziel'];
    if (ziel is! Map || ziel['instanz'] is! String || ziel['id'] is! String) return null;
    final zi = ziel['instanz'] as String, zid = ziel['id'] as String;
    if (zi.length > 200 || !_id.hasMatch(zid)) return null;
    return {
      'typ': typ,
      'ziel': {'instanz': zi, 'id': zid},
    };
  }

  /// Neuer Beitrag eines Kontos dieser Instanz.
  Map<String, Object?> beitragen(String konto, Map<String, dynamic> j) => s.transaktion(() {
        final k = this.konto(konto);
        if (k.gesperrt) throw KatalogFehler(403, 'Dieses Konto ist für den Katalog gesperrt.');
        final daten = pruefen(j);
        if (daten == null) throw KatalogFehler(400, 'Ungültiger Beitrag.');
        final heute = db.select('SELECT count(*) n FROM katalog WHERE instanz = ? AND autor = ? AND empfangen > ?', [instanz, k.pseudonym, _jetzt - 86400000]);
        if ((heute.first['n'] as int) >= 300) throw KatalogFehler(429, 'Zu viele Beiträge heute.');
        final ziel = daten['ziel'] as Map?;
        if (daten['typ'] == 'rueckzug') {
          final eigen = db.select('SELECT 1 FROM katalog WHERE instanz = ? AND id = ? AND autor = ?', [instanz, ziel?['id'], k.pseudonym]);
          if (ziel?['instanz'] != instanz || eigen.isEmpty) throw KatalogFehler(403, 'Zurückziehen geht nur für eigene Beiträge.');
        }
        if (daten['typ'] == 'bestaetigung') {
          final p = db.select("SELECT autor FROM katalog WHERE instanz = ? AND id = ? AND typ = 'preis'", [ziel?['instanz'], ziel?['id']]).firstOrNull;
          if (p == null) throw KatalogFehler(404, 'Diesen Preis gibt es nicht.');
          if (ziel?['instanz'] == instanz && p['autor'] == k.pseudonym) throw KatalogFehler(403, 'Eigene Preise kann man nicht selbst bestätigen.');
        }
        return _eintragen(k.pseudonym, daten);
      });

  Map<String, Object?> _eintragen(String autor, Map<String, Object?> daten) {
    final seq = (int.tryParse(s.meta('katalog_seq') ?? '0') ?? 0) + 1;
    s.setzeMeta('katalog_seq', '$seq');
    final id = _uuid();
    final zeit = DateTime.now().toUtc().toIso8601String();
    final voll = {...daten, 'id': id, 'autor': autor, 'zeit': zeit};
    db.execute(
      'INSERT INTO katalog (instanz, id, seq, typ, autor, daten, empfangen) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [instanz, id, seq, daten['typ'], autor, jsonEncode(voll), _jetzt],
    );
    return voll;
  }

  static String _uuid() {
    final b = zufall(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = hexVon(b);
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  // -------------------------------------------------------------------
  // Föderation: eigener Feed und Abruf anderer Instanzen

  /// Eigene Beiträge ab [seit] (für andere Instanzen).
  ({List<Map<String, Object?>> eintraege, int bis, bool mehr}) feed(int seit, int max) {
    final rows = db.select('SELECT seq, daten FROM katalog WHERE instanz = ? AND seq > ? ORDER BY seq LIMIT ?', [instanz, seit, max + 1]);
    final liste = [for (final r in rows.take(max)) {'seq': r['seq'], ...(jsonDecode(r['daten'] as String) as Map).cast<String, Object?>()}];
    return (eintraege: liste, bis: liste.isEmpty ? seit : liste.last['seq'] as int, mehr: rows.length > max);
  }

  /// Bekannte, nicht gesperrte Instanzen (für die Weitergabe im Feed).
  List<String> bekannte() => [for (final r in db.select('SELECT url FROM katalog_peers WHERE gesperrt = 0 ORDER BY url LIMIT 200')) r['url'] as String];

  void peerHinzufuegen(String url) {
    final u = normalisieren(url);
    if (u == null || u == instanz) return;
    db.execute('INSERT OR IGNORE INTO katalog_peers (url, seit, gesperrt, entdeckt) VALUES (?, 0, 0, ?)', [u, _jetzt]);
  }

  /// Nur `https://host[:port]` (bzw. `http://localhost` für Tests).
  static String? normalisieren(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || u.host.isEmpty || u.hasQuery || u.hasFragment) return null;
    final lokal = {'localhost', '127.0.0.1'}.contains(u.host);
    if (u.scheme != 'https' && !(u.scheme == 'http' && lokal)) return null;
    return '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}${u.path.replaceAll(RegExp(r'/+$'), '')}';
  }

  /// Holt die Feeds aller bekannten Instanzen. [abruf] liefert Status und
  /// Text einer GET-Anfrage. Ungültige Einträge werden übersprungen und
  /// gezählt, eine ausgefallene Instanz hält die anderen nicht auf.
  Future<({int neu, int ungueltig, Map<String, String> fehler})> abgleichen(Future<(int, String)> Function(Uri) abruf, {int maxSeiten = 20}) async {
    var neu = 0, ungueltig = 0;
    final fehler = <String, String>{};
    for (final p in db.select('SELECT url, seit FROM katalog_peers WHERE gesperrt = 0')) {
      final url = p['url'] as String;
      var seit = p['seit'] as int;
      try {
        final (st, info) = await abruf(Uri.parse('$url/k1/info'));
        final i = st == 200 ? jsonDecode(info) as Map : null;
        if (i == null || i['dienst'] != 'personal-tracker-katalog' || i['api'] != 1 || i['instanz'] != url) {
          throw const FormatException('keine passende Katalog-Instanz');
        }
        for (var seite = 0; seite < maxSeiten; seite++) {
          final (st2, text) = await abruf(Uri.parse('$url/k1/feed?seit=$seit&max=500'));
          if (st2 != 200) throw FormatException('Feed: HTTP $st2');
          final j = jsonDecode(text) as Map;
          final eintraege = j['eintraege'];
          if (eintraege is! List) throw const FormatException('Feed ohne Einträge');
          s.transaktion(() {
            for (final e in eintraege) {
              if (e is! Map || e['seq'] is! int || e['id'] is! String || e['autor'] is! String) {
                ungueltig++;
                continue;
              }
              final daten = pruefen(e.cast<String, dynamic>());
              if (daten == null || !_id.hasMatch(e['id'] as String) || !_pseudonym.hasMatch(e['autor'] as String)) {
                ungueltig++;
                continue;
              }
              // Zurückziehen nur für Beiträge derselben Instanz.
              if (daten['typ'] == 'rueckzug' && (daten['ziel'] as Map)['instanz'] != url) {
                ungueltig++;
                continue;
              }
              final voll = {...daten, 'id': e['id'], 'autor': e['autor'], 'zeit': e['zeit'] is String ? e['zeit'] : null};
              db.execute(
                'INSERT OR IGNORE INTO katalog (instanz, id, seq, typ, autor, daten, empfangen) VALUES (?, ?, ?, ?, ?, ?, ?)',
                [url, e['id'], e['seq'], daten['typ'], e['autor'], jsonEncode(voll), _jetzt],
              );
              neu += db.updatedRows;
            }
            final bis = j['bis'];
            if (bis is int && bis > seit) seit = bis;
            db.execute('UPDATE katalog_peers SET seit = ?, letzter = ?, fehler = NULL WHERE url = ?', [seit, _jetzt, url]);
          });
          // Offene Föderation: weitergegebene Instanzen kennenlernen.
          final peers = j['peers'];
          if (peers is List) {
            for (final x in peers.take(200)) {
              if (x is String) peerHinzufuegen(x);
            }
          }
          if (j['mehr'] != true) break;
        }
      } catch (e) {
        fehler[url] = '$e';
        db.execute('UPDATE katalog_peers SET fehler = ?, letzter = ? WHERE url = ?', ['$e'.substring(0, '$e'.length.clamp(0, 300)), _jetzt, url]);
      }
    }
    return (neu: neu, ungueltig: ungueltig, fehler: fehler);
  }

  // -------------------------------------------------------------------
  // Suche mit Bestätigungsstand

  static String _norm(Object? s) => '${s ?? ''}'.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static String _schluessel(Map d) => [
        _norm(d['artikel']),
        _norm(d['variante']),
        '${d['packungsMenge']}',
        d['packungsEinheit'],
        _norm(d['kette']),
        _norm(d['filiale']),
        _norm(d['region']),
      ].join('|');

  /// Preise passend zur Suche, mit Bestätigungen. Zurückgezogene Beiträge,
  /// gesperrte Konten und gesperrte Instanzen fehlen.
  List<Map<String, Object?>> suchen({required String konto, String? artikel, String? kette, String? region, int max = 200}) {
    final ich = '${this.konto(konto).pseudonym}@$instanz';
    final gesperrtInstanz = {for (final r in db.select('SELECT url FROM katalog_peers WHERE gesperrt = 1')) r['url'] as String};
    final gesperrtKonto = {for (final r in db.select('SELECT pseudonym FROM katalog_konten WHERE gesperrt = 1')) '${r['pseudonym']}@$instanz'};
    final alle = [
      for (final r in db.select('SELECT instanz, typ, autor, daten FROM katalog'))
        if (!gesperrtInstanz.contains(r['instanz']) && !gesperrtKonto.contains('${r['autor']}@${r['instanz']}'))
          (instanz: r['instanz'] as String, typ: r['typ'] as String, autor: '${r['autor']}@${r['instanz']}', d: jsonDecode(r['daten'] as String) as Map),
    ];
    final zurueck = {for (final x in alle) if (x.typ == 'rueckzug') '${(x.d['ziel'] as Map)['instanz']}|${(x.d['ziel'] as Map)['id']}'};
    final preise = [for (final x in alle) if (x.typ == 'preis' && !zurueck.contains('${x.instanz}|${x.d['id']}')) x];
    final bestaetigungen = <String, Set<String>>{};
    for (final x in alle) {
      if (x.typ != 'bestaetigung' || zurueck.contains('${x.instanz}|${x.d['id']}')) continue;
      final z = x.d['ziel'] as Map;
      (bestaetigungen['${z['instanz']}|${z['id']}'] ??= {}).add(x.autor);
    }
    final nachSchluessel = <String, List<({String instanz, String typ, String autor, Map d})>>{};
    for (final p in preise) {
      (nachSchluessel[_schluessel(p.d)] ??= []).add(p);
    }
    final a = _norm(artikel), k = _norm(kette), r = _norm(region);
    final heute = DateTime.now().toUtc();
    final ergebnis = <Map<String, Object?>>[];
    for (final p in preise) {
      if (a.isNotEmpty && !_norm(p.d['artikel']).contains(a)) continue;
      if (k.isNotEmpty && _norm(p.d['kette']) != k) continue;
      if (r.isNotEmpty && _norm(p.d['region']) != r) continue;
      final stimmen = {...?bestaetigungen['${p.instanz}|${p.d['id']}']};
      // Gleicher Preis für dieselbe Packung und Filiale innerhalb von 14 Tagen zählt mit.
      final tag = DateTime.parse(p.d['tag'] as String);
      for (final q in nachSchluessel[_schluessel(p.d)]!) {
        if (q.d['preisCent'] == p.d['preisCent'] && DateTime.parse(q.d['tag'] as String).difference(tag).inDays.abs() <= 14) stimmen.add(q.autor);
      }
      stimmen.remove(p.autor);
      ergebnis.add({
        ...p.d.cast<String, Object?>(),
        'instanz': p.instanz,
        'autor': p.autor,
        'eigen': p.autor == ich,
        'bestaetigungen': stimmen.length,
        'bestaetigt': stimmen.isNotEmpty,
        'vonMir': stimmen.contains(ich),
        'veraltet': heute.difference(tag).inDays > 90,
      });
    }
    ergebnis.sort((x, y) => (y['tag'] as String).compareTo(x['tag'] as String));
    return ergebnis.take(max).toList();
  }

  /// Eigene, nicht zurückgezogene Beiträge eines Kontos.
  List<Map<String, Object?>> meine(String konto) {
    final p = this.konto(konto).pseudonym;
    final zurueck = {
      for (final r in db.select("SELECT json_extract(daten, '\$.ziel.id') z FROM katalog WHERE instanz = ? AND typ = 'rueckzug'", [instanz])) r['z'] as String,
    };
    return [
      for (final r in db.select("SELECT daten FROM katalog WHERE instanz = ? AND autor = ? AND typ != 'rueckzug' ORDER BY seq DESC", [instanz, p]))
        if (!zurueck.contains((jsonDecode(r['daten'] as String) as Map)['id'])) (jsonDecode(r['daten'] as String) as Map).cast<String, Object?>(),
    ];
  }
}

class KatalogFehler implements Exception {
  KatalogFehler(this.status, this.meldung);
  final int status;
  final String meldung;
  @override
  String toString() => meldung;
}
