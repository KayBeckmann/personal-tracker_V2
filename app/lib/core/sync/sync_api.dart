import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Unterstützte Version des Sync-Vertrags.
const syncApiVersion = 1;

enum SyncFehlerArt {
  /// Server nicht erreichbar (offline, falsche Adresse, Zeitüberschreitung).
  netz,

  /// Gerät nicht (mehr) angemeldet: entfernt oder Konto gelöscht.
  anmeldung,

  /// Etwas gibt es nicht (Kopplungscode, Konto zum Recovery-Schlüssel).
  nichtGefunden,

  /// Serverversion oder Daten eines anderen Geräts passen nicht zur App.
  version,

  /// Daten ließen sich nicht entschlüsseln oder sind widersprüchlich.
  daten,

  /// Gibt es schon (z. B. Konto zu diesem Recovery-Schlüssel).
  vorhanden,

  /// Recht fehlt (z. B. Schreiben in einer Freigabe mit Leserecht).
  verboten,

  /// Neues Konto nur mit Einladungscode des Betreibers (oder gar nicht).
  einladung,
  server,
}

class SyncFehler implements Exception {
  SyncFehler(this.art, this.meldung);
  final SyncFehlerArt art;
  final String meldung;
  @override
  String toString() => meldung;
}

/// Prüft eine Serveradresse: HTTPS Pflicht, HTTP nur für dieses Gerät
/// (`localhost`, Tests und Tunnel). Liefert die normalisierte Basis-URL.
Uri serverAdresse(String eingabe) {
  var t = eingabe.trim();
  if (t.isEmpty) throw SyncFehler(SyncFehlerArt.netz, 'Bitte eine Serveradresse eingeben.');
  if (!t.contains('://')) t = 'https://$t';
  final u = Uri.tryParse(t);
  if (u == null || u.host.isEmpty || !(u.scheme == 'https' || u.scheme == 'http')) {
    throw SyncFehler(SyncFehlerArt.netz, 'Das ist keine gültige Serveradresse.');
  }
  const lokal = {'localhost', '127.0.0.1', '::1'};
  if (u.scheme == 'http' && !lokal.contains(u.host)) {
    throw SyncFehler(SyncFehlerArt.netz, 'Bitte eine HTTPS-Adresse verwenden. Unverschlüsselt (http) geht nur auf diesem Gerät (localhost).');
  }
  final pfad = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
  return u.replace(path: pfad, query: null, fragment: null);
}

/// Client für den Sync-Vertrag v1 (siehe `server/API.md`).
class SyncApi {
  SyncApi(this.basis, {http.Client? client, this.token, this.zeitlimit = const Duration(seconds: 30)})
      : _client = client ?? http.Client();

  final Uri basis;
  final http.Client _client;
  final String? token;
  final Duration zeitlimit;

  SyncApi mitToken(String token) => SyncApi(basis, client: _client, token: token, zeitlimit: zeitlimit);

  Uri _uri(String pfad, [Map<String, String>? query]) =>
      basis.replace(path: '${basis.path}$pfad', queryParameters: query);

  Future<Map<String, dynamic>> _anfrage(String methode, String pfad, {Object? body, Map<String, String>? query}) async {
    final req = http.Request(methode, _uri(pfad, query));
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response antwort;
    try {
      antwort = await http.Response.fromStream(await _client.send(req).timeout(zeitlimit));
    } on TimeoutException {
      throw SyncFehler(SyncFehlerArt.netz, 'Der Server antwortet nicht.');
    } catch (e) {
      throw SyncFehler(SyncFehlerArt.netz, 'Server nicht erreichbar. Bist du online und stimmt die Adresse?');
    }
    Map<String, dynamic> j;
    try {
      j = antwort.body.isEmpty ? {} : (jsonDecode(antwort.body) as Map).cast<String, dynamic>();
    } catch (_) {
      throw SyncFehler(SyncFehlerArt.server, 'Unerwartete Antwort (${antwort.statusCode}). Ist das ein Personal-Tracker-Server?');
    }
    if (antwort.statusCode >= 200 && antwort.statusCode < 300) return j;
    final meldung = j['meldung'] as String? ?? 'Serverfehler ${antwort.statusCode}.';
    throw SyncFehler(
      switch (antwort.statusCode) {
        401 => SyncFehlerArt.anmeldung,
        403 => SyncFehlerArt.verboten,
        404 => SyncFehlerArt.nichtGefunden,
        409 => SyncFehlerArt.vorhanden,
        _ => SyncFehlerArt.server,
      },
      antwort.statusCode == 401 ? 'Dieses Gerät ist beim Server nicht mehr angemeldet.' : meldung,
    );
  }

  Future<http.Response> _binaer(String methode, String pfad, {Uint8List? body}) async {
    final req = http.Request(methode, _uri(pfad));
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/octet-stream';
      req.bodyBytes = body;
    }
    final http.Response antwort;
    try {
      antwort = await http.Response.fromStream(await _client.send(req).timeout(zeitlimit * 2));
    } on TimeoutException {
      throw SyncFehler(SyncFehlerArt.netz, 'Der Server antwortet nicht.');
    } catch (e) {
      throw SyncFehler(SyncFehlerArt.netz, 'Server nicht erreichbar. Bist du online und stimmt die Adresse?');
    }
    if (antwort.statusCode >= 200 && antwort.statusCode < 300) return antwort;
    String? meldung;
    try {
      meldung = (jsonDecode(antwort.body) as Map)['meldung'] as String?;
    } catch (_) {}
    throw SyncFehler(
      switch (antwort.statusCode) {
        401 => SyncFehlerArt.anmeldung,
        404 => SyncFehlerArt.nichtGefunden,
        _ => SyncFehlerArt.server,
      },
      meldung ?? 'Serverfehler ${antwort.statusCode}.',
    );
  }

  /// Prüft, ob unter der Adresse ein passender Server läuft.
  Future<Map<String, dynamic>> info() async {
    final j = await _anfrage('GET', '/v1/info');
    if (j['dienst'] != 'personal-tracker-sync') {
      throw SyncFehler(SyncFehlerArt.server, 'Unter dieser Adresse läuft kein Personal-Tracker-Server.');
    }
    if (j['api'] != syncApiVersion) {
      throw SyncFehler(SyncFehlerArt.version, 'Der Server spricht API-Version ${j['api']}, die App Version $syncApiVersion.');
    }
    return j;
  }

  Future<({String konto, String geraet, String token})> kontoAnlegen({
    required Uint8List recoveryAnmeldung,
    required String recoveryHuelle,
    required String schluesselPaket,
    required String geraetName,
    String? einladung,
  }) async {
    final Map<String, dynamic> j;
    try {
      j = await _anfrage('POST', '/v1/konten', body: {
        'recoveryAuth': base64Url.encode(recoveryAnmeldung),
        'recoveryHuelle': recoveryHuelle,
        'schluesselPaket': schluesselPaket,
        'geraetName': geraetName,
        'einladung': ?einladung,
      });
    } on SyncFehler catch (e) {
      if (e.art == SyncFehlerArt.verboten) throw SyncFehler(SyncFehlerArt.einladung, e.meldung);
      rethrow;
    }
    return (konto: j['konto'] as String, geraet: j['geraet'] as String, token: j['token'] as String);
  }

  Future<({String konto, String geraet, String token, String recoveryHuelle})> recoveryAnmelden(
    Uint8List recoveryAnmeldung,
    String geraetName,
  ) async {
    final j = await _anfrage('POST', '/v1/anmelden/recovery', body: {
      'recoveryAuth': base64Url.encode(recoveryAnmeldung),
      'geraetName': geraetName,
    });
    return (
      konto: j['konto'] as String,
      geraet: j['geraet'] as String,
      token: j['token'] as String,
      recoveryHuelle: j['recoveryHuelle'] as String,
    );
  }

  Future<Map<String, dynamic>> konto() => _anfrage('GET', '/v1/konto');

  Future<void> recoveryErsetzen({required Uint8List recoveryAnmeldung, required String recoveryHuelle, required String schluesselPaket}) =>
      _anfrage('PUT', '/v1/konto/recovery', body: {
        'recoveryAuth': base64Url.encode(recoveryAnmeldung),
        'recoveryHuelle': recoveryHuelle,
        'schluesselPaket': schluesselPaket,
      });

  Future<void> kontoLoeschen() => _anfrage('DELETE', '/v1/konto');

  Future<void> geraetUmbenennen(String id, String name) => _anfrage('PUT', '/v1/geraete/$id', body: {'name': name});

  Future<void> geraetEntfernen(String id) => _anfrage('DELETE', '/v1/geraete/$id');

  Future<void> kopplungAnlegen(String slot, String paket, Duration gueltig, {bool agent = false, int? ablaufTage}) => _anfrage('POST', '/v1/kopplungen', body: {
        'slot': slot,
        'paket': paket,
        'gueltigSekunden': gueltig.inSeconds,
        if (agent) 'art': 'agent',
        'geraetAblaufTage': ?ablaufTage,
      });

  Future<({String konto, String paket, String geraet, String token})> kopplungEinloesen(String slot, String geraetName) async {
    final j = await _anfrage('POST', '/v1/kopplungen/$slot/einloesen', body: {'geraetName': geraetName});
    return (konto: j['konto'] as String, paket: j['paket'] as String, geraet: j['geraet'] as String, token: j['token'] as String);
  }

  Future<({List<({String id, int seq, String daten})> objekte, int bis, bool mehr})> abrufen(int seit, {int? max, String? raum}) async {
    final j = await _anfrage('GET', '${_ort(raum)}/objekte', query: {'seit': '$seit', if (max != null) 'max': '$max'});
    return (
      objekte: [
        for (final o in (j['objekte'] as List).cast<Map<String, dynamic>>())
          (id: o['id'] as String, seq: o['seq'] as int, daten: o['daten'] as String),
      ],
      bis: j['bis'] as int,
      mehr: j['mehr'] as bool,
    );
  }

  /// Bei einem Konflikt liefert der Server seine Fassung mit ([daten]).
  Future<List<({String id, bool ok, int seq, String? daten})>> schreiben(List<({String id, int basis, String aenderung, String daten})> aenderungen, {String? raum}) async {
    final j = await _anfrage('POST', '${_ort(raum)}/objekte', body: {
      'aenderungen': [
        for (final a in aenderungen) {'id': a.id, 'basis': a.basis, 'aenderung': a.aenderung, 'daten': a.daten},
      ],
    });
    return [
      for (final e in (j['ergebnisse'] as List).cast<Map<String, dynamic>>())
        (id: e['id'] as String, ok: e['status'] == 'ok', seq: e['seq'] as int, daten: e['daten'] as String?),
    ];
  }

  // Blöcke des Vault-Syncs (Server ab 1.1.0)

  Future<void> blockSchreiben(String id, Uint8List daten, {String? raum}) => _binaer('PUT', '${_ort(raum)}/bloecke/$id', body: daten);

  Future<Uint8List> blockLesen(String id, {String? raum}) async => (await _binaer('GET', '${_ort(raum)}/bloecke/$id')).bodyBytes;

  Future<List<String>> bloeckeFehlend(List<String> ids, {String? raum}) async {
    final fehlend = <String>[];
    for (var i = 0; i < ids.length; i += 5000) {
      final j = await _anfrage('POST', '${_ort(raum)}/bloecke/fehlend', body: {'ids': ids.sublist(i, i + 5000 > ids.length ? ids.length : i + 5000)});
      fehlend.addAll((j['fehlend'] as List).cast<String>());
    }
    return fehlend;
  }

  Future<int> bloeckeAufraeumen(List<String> behalten, {String? raum}) async =>
      (await _anfrage('POST', '${_ort(raum)}/bloecke/aufraeumen', body: {'behalten': behalten}))['geloescht'] as int;

  /// Pfad der Objekte und Blöcke: eigenes Konto oder geteilter Raum.
  static String _ort(String? raum) => raum == null ? '/v1' : '/v1/raeume/$raum';

  // Geteilte Räume (Server ab 1.2.0)

  Future<List<Map<String, dynamic>>> raeume() async => ((await _anfrage('GET', '/v1/raeume'))['raeume'] as List).cast<Map<String, dynamic>>();

  Future<void> raumAnlegen(String id) => _anfrage('POST', '/v1/raeume', body: {'id': id});

  /// Eigentümer: Raum löschen; Mitglied: austreten.
  Future<void> raumVerlassen(String id) => _anfrage('DELETE', '/v1/raeume/$id');

  Future<void> einladungAnlegen(String raum, {required String slot, required String recht, required String paket, required String mitgliedPaket, required Duration gueltig}) =>
      _anfrage('POST', '/v1/raeume/$raum/einladungen', body: {
        'slot': slot,
        'recht': recht,
        'paket': paket,
        'mitgliedPaket': mitgliedPaket,
        'gueltigSekunden': gueltig.inSeconds,
      });

  Future<({String raum, String recht, String paket})> einladungAnnehmen(String slot, String antwort) async {
    final j = await _anfrage('POST', '/v1/einladungen/$slot/annehmen', body: {'antwort': antwort});
    return (raum: j['raum'] as String, recht: j['recht'] as String, paket: j['paket'] as String);
  }

  Future<void> mitgliedAendern(String raum, String konto, {String? recht, String? paket}) =>
      _anfrage('PUT', '/v1/raeume/$raum/mitglieder/$konto', body: {'recht': ?recht, 'paket': ?paket});

  Future<void> mitgliedEntfernen(String raum, String konto) => _anfrage('DELETE', '/v1/raeume/$raum/mitglieder/$konto');

  // Öffentlicher Preiskatalog (Server ab 1.3.0)

  Future<Map<String, dynamic>> katalogIch() => _anfrage('GET', '/v1/katalog/ich');

  Future<Map<String, dynamic>> katalogBeitrag(Map<String, dynamic> beitrag) => _anfrage('POST', '/v1/katalog/beitraege', body: beitrag);

  Future<List<Map<String, dynamic>>> katalogPreise({String? artikel, String? ean, String? kette, String? region}) async =>
      ((await _anfrage('GET', '/v1/katalog/preise', query: {'artikel': ?artikel, 'ean': ?ean, 'kette': ?kette, 'region': ?region}))['preise'] as List)
          .cast<Map<String, dynamic>>();

  Future<List<Map<String, dynamic>>> katalogMeine() async => ((await _anfrage('GET', '/v1/katalog/meine'))['beitraege'] as List).cast<Map<String, dynamic>>();
}
