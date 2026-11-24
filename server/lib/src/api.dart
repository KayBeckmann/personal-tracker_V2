import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'speicher.dart';

/// Version des Sync-Vertrags (Pfadpräfix `/v1`). Innerhalb einer Version
/// kommen nur Felder hinzu; Clients ignorieren unbekannte Felder.
const apiVersion = 1;
const serverVersion = '1.1.0';

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
  final hex64 = RegExp(r'^[0-9a-f]{64}$');
  final objektId = RegExp(r'^[0-9a-f]{32,64}$');

  void begrenzen(Request r) {
    var ip = (r.context['shelf.io.connection_info'] as HttpConnectionInfo?)?.remoteAddress.address ?? 'lokal';
    if (k.hinterProxy) ip = r.headers['x-forwarded-for']?.split(',').first.trim() ?? ip;
    final jetzt = DateTime.now();
    final liste = (versuche[ip] ?? [])..removeWhere((t) => jetzt.difference(t) > k.fenster);
    if (liste.length >= k.anmeldungenProFenster) {
      throw _Fehler(429, 'zu-viele', 'Zu viele Versuche. Bitte später erneut.');
    }
    versuche[ip] = liste..add(jetzt);
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
    if (g == null) throw _Fehler(401, 'nicht-angemeldet', 'Gerät nicht angemeldet oder entfernt.');
    return g;
  }


  final app = Router()
    ..get('/v1/info', (Request r) => _json({'dienst': 'personal-tracker-sync', 'api': apiVersion, 'version': serverVersion, 'instanz': s.instanz}))
    ..post('/v1/konten', (Request r) async {
      begrenzen(r);
      final j = await lies(r);
      try {
        final e = s.kontoAnlegen(
          recoveryAuth: geheimnis(j, 'recoveryAuth'),
          recoveryHuelle: feld<String>(j, 'recoveryHuelle'),
          schluesselPaket: feld<String>(j, 'schluesselPaket'),
          geraetName: feld<String>(j, 'geraetName', maxLaenge: 2048),
        );
        return _json({'konto': e.konto, 'geraet': e.geraet, 'token': e.token}, status: 201);
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
      return _json({...s.kontoInfo(g.konto), 'geraet': g.id, 'geraete': s.geraete(g.konto)});
    })
    ..put('/v1/konto/recovery', (Request r) async {
      final g = angemeldet(r);
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
      final g = angemeldet(r);
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
      if (!s.geraetEntfernen(g.konto, id)) throw _Fehler(404, 'nicht-gefunden', 'Gerät nicht gefunden.');
      return _json({'ok': true});
    })
    ..post('/v1/kopplungen', (Request r) async {
      final g = angemeldet(r);
      final j = await lies(r);
      final slot = feld<String>(j, 'slot', maxLaenge: 64);
      if (!hex64.hasMatch(slot)) throw _Fehler(400, 'ungueltig', 'Ungültiger Kopplungs-Slot.');
      final sek = feld<int>(j, 'gueltigSekunden');
      if (sek < 30 || sek > 900) throw _Fehler(400, 'ungueltig', 'Gültigkeit zwischen 30 und 900 Sekunden.');
      try {
        s.kopplungAnlegen(g.konto, slot, feld<String>(j, 'paket'), Duration(seconds: sek));
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
    ..get('/v1/objekte', (Request r) {
      final g = angemeldet(r);
      final seit = int.tryParse(r.url.queryParameters['seit'] ?? '0') ?? 0;
      final max = (int.tryParse(r.url.queryParameters['max'] ?? '') ?? k.maxProAbruf).clamp(1, k.maxProAbruf);
      final e = s.abrufen(g.konto, seit, max);
      return _json({'objekte': e.objekte, 'bis': e.bis, 'mehr': e.mehr});
    })
    ..post('/v1/objekte', (Request r) async {
      final g = angemeldet(r);
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
      if (k.maxKonto > 0 && s.belegt(g.konto) + aenderungen.fold(0, (n, a) => n + a.daten.length) > k.maxKonto) {
        throw _Fehler(413, 'kontingent', 'Der Speicherplatz dieses Kontos ist aufgebraucht.');
      }
      final e = s.schreiben(g.konto, aenderungen);
      return _json({
        'ergebnisse': [
          for (final x in e) {'id': x.id, 'status': x.ok ? 'ok' : 'konflikt', 'seq': x.seq, if (x.daten != null) 'daten': x.daten},
        ],
      });
    })
    ..put('/v1/bloecke/<id>', (Request r, String id) async {
      final g = angemeldet(r);
      if (!objektId.hasMatch(id)) throw _Fehler(400, 'ungueltig', 'Ungültige Block-ID.');
      final daten = await roh(r, k.maxBlock);
      if (daten.isEmpty) throw _Fehler(400, 'ungueltig', 'Leerer Block.');
      try {
        s.blockSchreiben(g.konto, id, daten, maxKonto: k.maxKonto);
      } on SpeicherFehler catch (e) {
        throw _Fehler(413, 'kontingent', e.meldung);
      }
      return _json({'ok': true});
    })
    ..get('/v1/bloecke/<id>', (Request r, String id) {
      final g = angemeldet(r);
      final daten = objektId.hasMatch(id) ? s.blockLesen(g.konto, id) : null;
      if (daten == null) throw _Fehler(404, 'nicht-gefunden', 'Block nicht gefunden.');
      return Response.ok(daten, headers: {'content-type': 'application/octet-stream'});
    })
    ..post('/v1/bloecke/fehlend', (Request r) async {
      final g = angemeldet(r);
      return _json({'fehlend': s.bloeckeFehlend(g.konto, idListe(await lies(r), 'ids'))});
    })
    ..post('/v1/bloecke/aufraeumen', (Request r) async {
      final g = angemeldet(r);
      final behalten = idListe(await lies(r), 'behalten', max: 200000).toSet();
      return _json({'geloescht': s.bloeckeAufraeumen(g.konto, behalten)});
    });

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
