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
        404 => SyncFehlerArt.nichtGefunden,
        409 => SyncFehlerArt.vorhanden,
        _ => SyncFehlerArt.server,
      },
      antwort.statusCode == 401 ? 'Dieses Gerät ist beim Server nicht mehr angemeldet.' : meldung,
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
  }) async {
    final j = await _anfrage('POST', '/v1/konten', body: {
      'recoveryAuth': base64Url.encode(recoveryAnmeldung),
      'recoveryHuelle': recoveryHuelle,
      'schluesselPaket': schluesselPaket,
      'geraetName': geraetName,
    });
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

  Future<void> kopplungAnlegen(String slot, String paket, Duration gueltig) =>
      _anfrage('POST', '/v1/kopplungen', body: {'slot': slot, 'paket': paket, 'gueltigSekunden': gueltig.inSeconds});

  Future<({String konto, String paket, String geraet, String token})> kopplungEinloesen(String slot, String geraetName) async {
    final j = await _anfrage('POST', '/v1/kopplungen/$slot/einloesen', body: {'geraetName': geraetName});
    return (konto: j['konto'] as String, paket: j['paket'] as String, geraet: j['geraet'] as String, token: j['token'] as String);
  }

  Future<({List<({String id, int seq, String daten})> objekte, int bis, bool mehr})> abrufen(int seit, {int? max}) async {
    final j = await _anfrage('GET', '/v1/objekte', query: {'seit': '$seit', if (max != null) 'max': '$max'});
    return (
      objekte: [
        for (final o in (j['objekte'] as List).cast<Map<String, dynamic>>())
          (id: o['id'] as String, seq: o['seq'] as int, daten: o['daten'] as String),
      ],
      bis: j['bis'] as int,
      mehr: j['mehr'] as bool,
    );
  }

  Future<List<({String id, bool ok, int seq})>> schreiben(List<({String id, int basis, String aenderung, String daten})> aenderungen) async {
    final j = await _anfrage('POST', '/v1/objekte', body: {
      'aenderungen': [
        for (final a in aenderungen) {'id': a.id, 'basis': a.basis, 'aenderung': a.aenderung, 'daten': a.daten},
      ],
    });
    return [
      for (final e in (j['ergebnisse'] as List).cast<Map<String, dynamic>>())
        (id: e['id'] as String, ok: e['status'] == 'ok', seq: e['seq'] as int),
    ];
  }
}
