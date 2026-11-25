import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'katalog.dart';
import 'speicher.dart';

/// Version des Sync-Vertrags (Pfadpräfix `/v1`). Innerhalb einer Version
/// kommen nur Felder hinzu; Clients ignorieren unbekannte Felder.
const apiVersion = 1;
const serverVersion = '1.5.0';

class Konfiguration {
  const Konfiguration({
    this.ursprung = '*',
    this.maxAnfrage = 8 * 1024 * 1024,
    this.maxObjekt = 1024 * 1024,
    this.maxProSchreiben = 200,
    this.maxProAbruf = 500,
    this.maxBlock = 1024 * 1024 + 64 * 1024,
    this.maxKonto = 0,
    this.anmeldungenProFenster = 20,
    this.fenster = const Duration(minutes: 10),
    this.hinterProxy = false,
    this.protokoll,
    this.instanz = 'lokal',
    this.registrierung = 'offen',
  });

  /// Erlaubter Ursprung für die Web-App (CORS). `*` ist vertretbar, weil
  /// die Anmeldung per Bearer-Token läuft, nicht per Cookie.
  final String ursprung;
  final int maxAnfrage;
  final int maxObjekt;
  final int maxProSchreiben;
  final int maxProAbruf;

  /// Größte Blockgröße (Geheimtext). Die Clients teilen Dateien in Blöcke
  /// zu 1 MiB; der Rest ist Platz für Nonce, Tag und Auffüllung.
  final int maxBlock;

  /// Speicherplatz je Konto in Byte (Objekte und Blöcke); 0 = unbegrenzt.
  final int maxKonto;

  /// Begrenzung für Anmeldung, Kontoanlage und Kopplung je IP-Adresse.
  final int anmeldungenProFenster;
  final Duration fenster;

  /// Hinter einem Reverse-Proxy die Client-IP aus `X-Forwarded-For` lesen.
  final bool hinterProxy;

  /// Betriebsprotokoll; bekommt nie Inhalte oder Token.
  final void Function(String zeile)? protokoll;

  /// Öffentliche Adresse für den föderierten Katalog (`https://…`);
  /// `lokal` = Katalog nur auf dieser Instanz.
  final String instanz;

  /// Neue Konten: `offen`, `einladung` (Einmal-Code vom Betreiber) oder `zu`.
  final String registrierung;
}

class _Fehler implements Exception {
  _Fehler(this.status, this.code, this.meldung);
  final int status;
  final String code;
  final String meldung;
}

Response _json(Object? daten, {int status = 200}) =>
    Response(status, body: jsonEncode(daten), headers: {'content-type': 'application/json; charset=utf-8'});

/// Der komplette Server als shelf-Handler (auch für Tests im Speicher).
Handler syncHandler(Speicher s, {Konfiguration k = const Konfiguration()}) {
  final versuche = <String, List<DateTime>>{};
  final katalog = Katalog(s, instanz: k.instanz);
  final hex64 = RegExp(r'^[0-9a-f]{64}$');
  final hex32 = RegExp(r'^[0-9a-f]{32}$');
  final objektId = RegExp(r'^[0-9a-f]{32,64}$');

  void begrenzen(Request r, {int? fenster, String art = 'anmelden'}) {
    var ip = (r.context['shelf.io.connection_info'] as HttpConnectionInfo?)?.remoteAddress.address ?? 'lokal';
    if (k.hinterProxy) ip = r.headers['x-forwarded-for']?.split(',').first.trim() ?? ip;
    final jetzt = DateTime.now();
    final schluessel = '$art:$ip';
    final liste = (versuche[schluessel] ?? [])..removeWhere((t) => jetzt.difference(t) > k.fenster);
    if (liste.length >= (fenster ?? k.anmeldungenProFenster)) {
      throw _Fehler(429, 'zu-viele', 'Zu viele Versuche. Bitte später erneut.');
    }
    versuche[schluessel] = liste..add(jetzt);
  }

  Future<Map<String, dynamic>> lies(Request r) async {
    final puffer = BytesBuilder(copy: false);
    await for (final teil in r.read()) {
      puffer.add(teil);
      if (puffer.length > k.maxAnfrage) throw _Fehler(413, 'zu-gross', 'Anfrage zu groß.');
    }
    try {
      return (jsonDecode(utf8.decode(puffer.takeBytes())) as Map).cast<String, dynamic>();
    } catch (_) {
      throw _Fehler(400, 'ungueltig', 'Kein gültiges JSON.');
    }
  }

  Future<Uint8List> roh(Request r, int max) async {
    final puffer = BytesBuilder(copy: false);
    await for (final teil in r.read()) {
      puffer.add(teil);
      if (puffer.length > max) throw _Fehler(413, 'zu-gross', 'Block zu groß.');
    }
    return puffer.takeBytes();
  }

  List<String> idListe(Map<String, dynamic> j, String name, {int max = 5000}) {
    final v = j[name];
    if (v is! List || v.length > max || v.any((x) => x is! String || !objektId.hasMatch(x))) {
      throw _Fehler(400, 'ungueltig', '„$name“ muss eine Liste von höchstens $max Block-IDs sein.');
    }
    return v.cast<String>();
  }

  T feld<T>(Map<String, dynamic> j, String name, {int maxLaenge = 65536}) {
    final v = j[name];
    if (v is! T) throw _Fehler(400, 'ungueltig', 'Feld „$name“ fehlt oder hat den falschen Typ.');
    if (v is String && v.length > maxLaenge) throw _Fehler(413, 'zu-gross', 'Feld „$name“ ist zu groß.');
    return v;
  }

  List<int> geheimnis(Map<String, dynamic> j, String name) {
    try {
      final b = base64Url.decode(feld<String>(j, name, maxLaenge: 100));
      if (b.length != 32) throw const FormatException();
      return b;
    } on FormatException {
      throw _Fehler(400, 'ungueltig', 'Feld „$name“ muss 32 Byte (Base64url) haben.');
    }
  }

  Geraet angemeldet(Request r) {
    final h = r.headers['authorization'] ?? '';
    final g = h.startsWith('Bearer ') ? s.geraetZuToken(h.substring(7).trim()) : null;
    if (g == null) throw _Fehler(401, 'nicht-angemeldet', 'Gerät nicht angemeldet, entfernt oder abgelaufen.');
    return g;
  }

  /// Verwaltung (Geräte, Recovery, Konto, Teilen, Katalog) nur für echte
  /// Geräte, nie für eine Agenten-Brücke.
  Geraet verwaltend(Request r) {
    final g = angemeldet(r);
    if (g.art == 'agent') throw _Fehler(403, 'verboten', 'Ein Agenten-Zugang darf das nicht.');
    return g;
  }


  /// Wo gelesen oder geschrieben wird, mit Rechteprüfung. Fremde Räume
  /// sehen aus wie nicht vorhandene (kein Hinweis, dass es sie gibt).
  ({Ort ort, String zahler}) zugriff(Request r, String? raum, {bool schreiben = false, bool nurEigentuemer = false}) {
    final g = angemeldet(r);
    if (raum == null) return (ort: Ort.konto(g.konto), zahler: g.konto);
    final recht = s.recht(g.konto, raum);
    if (recht == null) throw _Fehler(404, 'nicht-gefunden', 'Freigabe nicht gefunden.');
    if (nurEigentuemer && recht != 'eigentuemer') throw _Fehler(403, 'verboten', 'Nur der Eigentümer darf das.');
    if (schreiben && recht == 'lesen') throw _Fehler(403, 'verboten', 'Für diese Freigabe hast du nur Leserechte.');
    return (ort: Ort.raum(raum), zahler: s.db.select('SELECT eigentuemer FROM raeume WHERE id = ?', [raum]).first['eigentuemer'] as String);
  }

  Response abrufen(Request r, String? raum) {
    final o = zugriff(r, raum).ort;
    final seit = int.tryParse(r.url.queryParameters['seit'] ?? '0') ?? 0;
    final max = (int.tryParse(r.url.queryParameters['max'] ?? '') ?? k.maxProAbruf).clamp(1, k.maxProAbruf);
    final e = s.abrufen(o, seit, max);
    return _json({'objekte': e.objekte, 'bis': e.bis, 'mehr': e.mehr});
  }

  Future<Response> schreiben(Request r, String? raum) async {
    final (:ort, :zahler) = zugriff(r, raum, schreiben: true);
    final liste = (await lies(r))['aenderungen'];
    if (liste is! List || liste.length > k.maxProSchreiben) {
      throw _Fehler(400, 'ungueltig', '„aenderungen“ fehlt oder enthält mehr als ${k.maxProSchreiben} Einträge.');
    }
    final aenderungen = [
      for (final x in liste)
        if (x is Map<String, dynamic>)
          (
            id: feld<String>(x, 'id', maxLaenge: 64),
            basis: feld<int>(x, 'basis'),
            aenderung: feld<String>(x, 'aenderung', maxLaenge: 64),
            daten: feld<String>(x, 'daten', maxLaenge: k.maxObjekt),
          )
        else
          throw _Fehler(400, 'ungueltig', 'Ungültige Änderung.'),
    ];
    for (final a in aenderungen) {
      if (!objektId.hasMatch(a.id)) throw _Fehler(400, 'ungueltig', 'Ungültige Objekt-ID.');
    }
    final max = s.kontingent(zahler, k.maxKonto);
    if (max > 0 && s.belegt(zahler) + aenderungen.fold(0, (n, a) => n + a.daten.length) > max) {
      throw _Fehler(413, 'kontingent', 'Der Speicherplatz dieses Kontos ist aufgebraucht.');
    }
    final e = s.schreiben(ort, aenderungen);
    return _json({
      'ergebnisse': [
        for (final x in e) {'id': x.id, 'status': x.ok ? 'ok' : 'konflikt', 'seq': x.seq, if (x.daten != null) 'daten': x.daten},
      ],
    });
  }

  Future<Response> blockSchreiben(Request r, String? raum, String id) async {
    final (:ort, :zahler) = zugriff(r, raum, schreiben: true);
    if (!objektId.hasMatch(id)) throw _Fehler(400, 'ungueltig', 'Ungültige Block-ID.');
    final daten = await roh(r, k.maxBlock);
    if (daten.isEmpty) throw _Fehler(400, 'ungueltig', 'Leerer Block.');
    try {
      s.blockSchreiben(ort, id, daten, maxKonto: s.kontingent(zahler, k.maxKonto), zahler: zahler);
    } on SpeicherFehler catch (e) {
      throw _Fehler(413, 'kontingent', e.meldung);
    }
    return _json({'ok': true});
  }

  Response blockLesen(Request r, String? raum, String id) {
    final o = zugriff(r, raum).ort;
    final daten = objektId.hasMatch(id) ? s.blockLesen(o, id) : null;
    if (daten == null) throw _Fehler(404, 'nicht-gefunden', 'Block nicht gefunden.');
    return Response.ok(daten, headers: {'content-type': 'application/octet-stream'});
  }

  Future<Response> bloeckeFehlend(Request r, String? raum) async {
    final o = zugriff(r, raum).ort;
    return _json({'fehlend': s.bloeckeFehlend(o, idListe(await lies(r), 'ids'))});
  }

  Future<Response> bloeckeAufraeumen(Request r, String? raum) async {
    // In Räumen räumt nur der Eigentümer auf (er sieht alle Dateien).
    final o = zugriff(r, raum, nurEigentuemer: raum != null).ort;
    final behalten = idListe(await lies(r), 'behalten', max: 200000).toSet();
    return _json({'geloescht': s.bloeckeAufraeumen(o, behalten)});
  }

  void eigentuemer(Geraet g, String raum) {
    final recht = s.recht(g.konto, raum);
    if (recht == null) throw _Fehler(404, 'nicht-gefunden', 'Freigabe nicht gefunden.');
    if (recht != 'eigentuemer') throw _Fehler(403, 'verboten', 'Nur der Eigentümer darf das.');
  }

  final app = Router()
    ..get('/v1/info', (Request r) => _json({
          'dienst': 'personal-tracker-sync',
          'api': apiVersion,
          'version': serverVersion,
          'instanz': s.instanz,
          'registrierung': k.registrierung,
          if (k.maxKonto > 0) 'kontingent': k.maxKonto,
        }))
    ..get('/v1/gesund', (Request r) {
      // Für die Überwachung: Datenbank antwortet. Keine Kennzahlen nach außen.
      try {
        s.db.select('SELECT 1');
        return _json({'ok': true, 'version': serverVersion});
      } catch (_) {
        return _json({'ok': false}, status: 503);
      }
    })
    ..post('/v1/konten', (Request r) async {
      begrenzen(r);
      if (k.registrierung == 'zu') throw _Fehler(403, 'registrierung-zu', 'Auf diesem Server lassen sich keine neuen Konten anlegen.');
      final j = await lies(r);
      final einladung = j['einladung'];
      if (k.registrierung == 'einladung' && (einladung is! String || einladung.isEmpty || einladung.length > 64)) {
        throw _Fehler(403, 'einladung-noetig', 'Für ein Konto auf diesem Server ist ein Einladungscode des Betreibers nötig.');
      }
      try {
        final e = s.kontoAnlegen(
          recoveryAuth: geheimnis(j, 'recoveryAuth'),
          recoveryHuelle: feld<String>(j, 'recoveryHuelle'),
          schluesselPaket: feld<String>(j, 'schluesselPaket'),
          geraetName: feld<String>(j, 'geraetName', maxLaenge: 2048),
          einladung: k.registrierung == 'einladung' ? einladung as String : null,
        );
        return _json({'konto': e.konto, 'geraet': e.geraet, 'token': e.token}, status: 201);
      } on EinladungFehler catch (e) {
        throw _Fehler(403, 'einladung-ungueltig', e.meldung);
      } on SpeicherFehler catch (e) {
        throw _Fehler(409, 'vorhanden', e.meldung);
      }
    })
    ..post('/v1/anmelden/recovery', (Request r) async {
      begrenzen(r);
      final j = await lies(r);
      final e = s.recoveryAnmelden(geheimnis(j, 'recoveryAuth'), feld<String>(j, 'geraetName', maxLaenge: 2048));
      if (e == null) throw _Fehler(404, 'nicht-gefunden', 'Zu diesem Recovery-Schlüssel gibt es auf diesem Server kein Konto.');
      return _json({'konto': e.konto, 'geraet': e.geraet, 'token': e.token, 'recoveryHuelle': e.recoveryHuelle});
    })
    ..get('/v1/konto', (Request r) {
      final g = angemeldet(r);
      final max = s.kontingent(g.konto, k.maxKonto);
      return _json({
        ...s.kontoInfo(g.konto),
        'geraet': g.id,
        'geraete': s.geraete(g.konto),
        'belegtGesamt': s.belegt(g.konto),
        if (max > 0) 'kontingent': max,
      });
    })
    ..put('/v1/konto/recovery', (Request r) async {
      final g = verwaltend(r);
      final j = await lies(r);
      try {
        s.recoveryErsetzen(
          g.konto,
          recoveryAuth: geheimnis(j, 'recoveryAuth'),
          recoveryHuelle: feld<String>(j, 'recoveryHuelle'),
          schluesselPaket: feld<String>(j, 'schluesselPaket'),
        );
      } on SpeicherFehler catch (e) {
        throw _Fehler(409, 'vorhanden', e.meldung);
      }
      return _json({'ok': true});
    })
    ..delete('/v1/konto', (Request r) {
      final g = verwaltend(r);
      // Öffentliche Katalogbeiträge zurückziehen, dann alles löschen.
      s.transaktion(() => katalog.kontoEntfernen(g.konto));
      s.kontoLoeschen(g.konto);
      return _json({'ok': true});
    })
    ..put('/v1/geraete/<id>', (Request r, String id) async {
      final g = angemeldet(r);
      if (id != g.id) throw _Fehler(403, 'verboten', 'Nur das eigene Gerät lässt sich umbenennen.');
      s.geraetUmbenennen(id, feld<String>(await lies(r), 'name', maxLaenge: 2048));
      return _json({'ok': true});
    })
    ..delete('/v1/geraete/<id>', (Request r, String id) {
      final g = angemeldet(r);
      // Ein Agent darf nur sich selbst abmelden.
      if (g.art == 'agent' && id != g.id) throw _Fehler(403, 'verboten', 'Ein Agenten-Zugang darf das nicht.');
      if (!s.geraetEntfernen(g.konto, id)) throw _Fehler(404, 'nicht-gefunden', 'Gerät nicht gefunden.');
      return _json({'ok': true});
    })
    ..post('/v1/kopplungen', (Request r) async {
      final g = verwaltend(r);
      final j = await lies(r);
      final slot = feld<String>(j, 'slot', maxLaenge: 64);
      if (!hex64.hasMatch(slot)) throw _Fehler(400, 'ungueltig', 'Ungültiger Kopplungs-Slot.');
      final sek = feld<int>(j, 'gueltigSekunden');
      if (sek < 30 || sek > 900) throw _Fehler(400, 'ungueltig', 'Gültigkeit zwischen 30 und 900 Sekunden.');
      final art = j['art'] ?? 'geraet';
      if (art != 'geraet' && art != 'agent') throw _Fehler(400, 'ungueltig', 'Art muss „geraet“ oder „agent“ sein.');
      final tage = j['geraetAblaufTage'];
      if (tage != null && (tage is! int || tage < 1 || tage > 3650)) throw _Fehler(400, 'ungueltig', 'Ablauf zwischen 1 und 3650 Tagen.');
      try {
        s.kopplungAnlegen(g.konto, slot, feld<String>(j, 'paket'), Duration(seconds: sek),
            art: art as String, geraetAblauf: tage == null ? null : DateTime.now().add(Duration(days: tage as int)));
      } on SpeicherFehler catch (e) {
        throw _Fehler(429, 'zu-viele', e.meldung);
      }
      return _json({'ok': true}, status: 201);
    })
    ..post('/v1/kopplungen/<slot>/einloesen', (Request r, String slot) async {
      begrenzen(r);
      if (!hex64.hasMatch(slot)) throw _Fehler(404, 'nicht-gefunden', 'Kopplungscode unbekannt oder abgelaufen.');
      final j = await lies(r);
      final e = s.kopplungEinloesen(slot, feld<String>(j, 'geraetName', maxLaenge: 2048));
      if (e == null) throw _Fehler(404, 'nicht-gefunden', 'Kopplungscode unbekannt oder abgelaufen.');
      return _json({'konto': e.konto, 'paket': e.paket, 'geraet': e.geraet, 'token': e.token});
    })
    ..get('/v1/objekte', (Request r) => abrufen(r, null))
    ..post('/v1/objekte', (Request r) => schreiben(r, null))
    ..put('/v1/bloecke/<id>', (Request r, String id) => blockSchreiben(r, null, id))
    ..get('/v1/bloecke/<id>', (Request r, String id) => blockLesen(r, null, id))
    ..post('/v1/bloecke/fehlend', (Request r) => bloeckeFehlend(r, null))
    ..post('/v1/bloecke/aufraeumen', (Request r) => bloeckeAufraeumen(r, null))
    // Föderierter Katalog (M7): Konten dieser Instanz …
    ..get('/v1/katalog/ich', (Request r) {
      final g = angemeldet(r);
      final x = katalog.konto(g.konto);
      return _json({'pseudonym': x.pseudonym, 'instanz': katalog.instanz, 'gesperrt': x.gesperrt, 'foederiert': katalog.foederiert});
    })
    ..post('/v1/katalog/beitraege', (Request r) async {
      final g = verwaltend(r);
      final j = await lies(r);
      try {
        return _json(katalog.beitragen(g.konto, j), status: 201);
      } on KatalogFehler catch (e) {
        throw _Fehler(e.status, switch (e.status) { 403 => 'verboten', 404 => 'nicht-gefunden', 429 => 'zu-viele', _ => 'ungueltig' }, e.meldung);
      }
    })
    ..get('/v1/katalog/preise', (Request r) {
      final g = angemeldet(r);
      final q = r.url.queryParameters;
      return _json({'preise': katalog.suchen(konto: g.konto, artikel: q['artikel'], kette: q['kette'], region: q['region'])});
    })
    ..get('/v1/katalog/meine', (Request r) {
      final g = angemeldet(r);
      return _json({'beitraege': katalog.meine(g.konto)});
    })
    // … und für andere Instanzen (öffentlich, ohne Anmeldung).
    ..get('/k1/info', (Request r) {
      if (!katalog.foederiert) throw _Fehler(404, 'nicht-gefunden', 'Diese Instanz nimmt nicht am föderierten Katalog teil.');
      return _json({'dienst': 'personal-tracker-katalog', 'api': 1, 'instanz': katalog.instanz, 'version': serverVersion});
    })
    ..get('/k1/feed', (Request r) {
      if (!katalog.foederiert) throw _Fehler(404, 'nicht-gefunden', 'Diese Instanz nimmt nicht am föderierten Katalog teil.');
      begrenzen(r, fenster: k.anmeldungenProFenster * 10, art: 'feed');
      final seit = int.tryParse(r.url.queryParameters['seit'] ?? '0') ?? 0;
      final max = (int.tryParse(r.url.queryParameters['max'] ?? '') ?? 500).clamp(1, 500);
      final f = katalog.feed(seit, max);
      return _json({'eintraege': f.eintraege, 'bis': f.bis, 'mehr': f.mehr, 'peers': katalog.bekannte()});
    })
    // Geteilte Räume (M5)
    ..get('/v1/raeume', (Request r) {
      final g = angemeldet(r);
      return _json({'raeume': s.raeume(g.konto)});
    })
    ..post('/v1/raeume', (Request r) async {
      final g = verwaltend(r);
      final id = feld<String>(await lies(r), 'id', maxLaenge: 64);
      if (!hex32.hasMatch(id)) throw _Fehler(400, 'ungueltig', 'Ungültige Raum-ID.');
      try {
        s.raumAnlegen(g.konto, id);
      } on SpeicherFehler catch (e) {
        throw _Fehler(409, 'vorhanden', e.meldung);
      }
      return _json({'ok': true}, status: 201);
    })
    ..delete('/v1/raeume/<raum>', (Request r, String raum) {
      final g = verwaltend(r);
      final recht = s.recht(g.konto, raum);
      if (recht == null) throw _Fehler(404, 'nicht-gefunden', 'Freigabe nicht gefunden.');
      // Eigentümer löschen den Raum, Mitglieder treten aus.
      if (recht == 'eigentuemer') {
        s.raumLoeschen(raum);
      } else {
        s.mitgliedEntfernen(raum, g.konto);
      }
      return _json({'ok': true});
    })
    ..post('/v1/raeume/<raum>/einladungen', (Request r, String raum) async {
      final g = verwaltend(r);
      eigentuemer(g, raum);
      final j = await lies(r);
      final slot = feld<String>(j, 'slot', maxLaenge: 64);
      if (!hex64.hasMatch(slot)) throw _Fehler(400, 'ungueltig', 'Ungültiger Einladungs-Slot.');
      final recht = feld<String>(j, 'recht', maxLaenge: 20);
      if (!Speicher.rechte.contains(recht)) throw _Fehler(400, 'ungueltig', 'Recht muss „lesen“ oder „schreiben“ sein.');
      final sek = feld<int>(j, 'gueltigSekunden');
      if (sek < 30 || sek > 7 * 24 * 3600) throw _Fehler(400, 'ungueltig', 'Gültigkeit zwischen 30 Sekunden und 7 Tagen.');
      try {
        s.einladungAnlegen(raum, slot,
            recht: recht, paket: feld<String>(j, 'paket'), mitgliedPaket: feld<String>(j, 'mitgliedPaket'), gueltig: Duration(seconds: sek));
      } on SpeicherFehler catch (e) {
        throw _Fehler(429, 'zu-viele', e.meldung);
      }
      return _json({'ok': true}, status: 201);
    })
    ..post('/v1/einladungen/<slot>/annehmen', (Request r, String slot) async {
      begrenzen(r);
      final g = verwaltend(r);
      if (!hex64.hasMatch(slot)) throw _Fehler(404, 'nicht-gefunden', 'Einladung unbekannt oder abgelaufen.');
      final antwort = feld<String>(await lies(r), 'antwort', maxLaenge: 4096);
      try {
        final e = s.einladungAnnehmen(slot, g.konto, antwort);
        if (e == null) throw _Fehler(404, 'nicht-gefunden', 'Einladung unbekannt oder abgelaufen.');
        return _json({'raum': e.raum, 'recht': e.recht, 'paket': e.paket});
      } on SpeicherFehler catch (e) {
        throw _Fehler(409, 'vorhanden', e.meldung);
      }
    })
    ..put('/v1/raeume/<raum>/mitglieder/<konto>', (Request r, String raum, String konto) async {
      final g = verwaltend(r);
      eigentuemer(g, raum);
      final j = await lies(r);
      final recht = j['recht'];
      if (recht != null && !Speicher.rechte.contains(recht)) throw _Fehler(400, 'ungueltig', 'Recht muss „lesen“ oder „schreiben“ sein.');
      final paket = j['paket'];
      if (paket != null && (paket is! String || paket.length > 65536)) throw _Fehler(400, 'ungueltig', 'Ungültiges Paket.');
      if (!s.mitgliedAendern(raum, konto, recht: recht as String?, paket: paket as String?)) {
        throw _Fehler(404, 'nicht-gefunden', 'Mitglied nicht gefunden.');
      }
      return _json({'ok': true});
    })
    ..delete('/v1/raeume/<raum>/mitglieder/<konto>', (Request r, String raum, String konto) {
      final g = verwaltend(r);
      eigentuemer(g, raum);
      if (!s.mitgliedEntfernen(raum, konto)) throw _Fehler(404, 'nicht-gefunden', 'Mitglied nicht gefunden.');
      return _json({'ok': true});
    })
    ..get('/v1/raeume/<raum>/objekte', (Request r, String raum) => abrufen(r, raum))
    ..post('/v1/raeume/<raum>/objekte', (Request r, String raum) => schreiben(r, raum))
    ..put('/v1/raeume/<raum>/bloecke/<id>', (Request r, String raum, String id) => blockSchreiben(r, raum, id))
    ..get('/v1/raeume/<raum>/bloecke/<id>', (Request r, String raum, String id) => blockLesen(r, raum, id))
    ..post('/v1/raeume/<raum>/bloecke/fehlend', (Request r, String raum) => bloeckeFehlend(r, raum))
    ..post('/v1/raeume/<raum>/bloecke/aufraeumen', (Request r, String raum) => bloeckeAufraeumen(r, raum));

  Handler fehlerBehandeln(Handler inner) => (r) async {
        try {
          return await inner(r);
        } on _Fehler catch (e) {
          return _json({'fehler': e.code, 'meldung': e.meldung}, status: e.status);
        }
      };

  Handler cors(Handler inner) => (r) async {
        final h = {
          'access-control-allow-origin': k.ursprung,
          'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
          'access-control-allow-headers': 'authorization, content-type',
          'access-control-max-age': '600',
          'cache-control': 'no-store',
          'x-content-type-options': 'nosniff',
        };
        if (r.method == 'OPTIONS') return Response(204, headers: h);
        return (await inner(r)).change(headers: h);
      };

  // Protokoll ohne Inhalte; lange Hex-IDs (Slots, Geräte) werden gekürzt.
  final idMuster = RegExp(r'[0-9a-f]{16,}');
  Handler protokoll(Handler inner) => (r) async {
        final start = DateTime.now();
        final antwort = await inner(r);
        k.protokoll?.call('${start.toUtc().toIso8601String()} ${r.method} /${r.url.path.replaceAll(idMuster, '…')} '
            '${antwort.statusCode} ${DateTime.now().difference(start).inMilliseconds}ms');
        return antwort;
      };

  return const Pipeline()
      .addMiddleware(protokoll)
      .addMiddleware(cors)
      .addMiddleware(fehlerBehandeln)
      .addHandler(app.call);
}
