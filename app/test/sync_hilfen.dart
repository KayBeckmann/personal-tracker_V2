import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_tracker_sync/personal_tracker_sync.dart';
import 'package:shelf/shelf.dart' as shelf;

/// Echter Sync-Server im Speicher; die Apps erreichen ihn über einen
/// Test-HTTP-Client. [offline] simuliert Netzausfall bzw. Serverausfall.
class TestServer {
  TestServer() : speicher = Speicher.imSpeicher() {
    handler = syncHandler(speicher, k: Konfiguration(protokoll: protokoll.add, anmeldungenProFenster: 1000));
  }

  final Speicher speicher;
  late shelf.Handler handler;
  final protokoll = <String>[];
  bool offline = false;
  int anfragen = 0;

  /// Nach so vielen Anfragen wird die nächste noch verarbeitet, ihre
  /// Antwort geht aber verloren; danach scheitert jede Anfrage, bis
  /// [abbruchNach] wieder `null` ist (unterbrochener Abgleich).
  int? abbruchNach;
  bool _abgebrochen = false;

  static const adresse = 'http://localhost:8743';

  http.Client client() => MockClient((req) async {
        anfragen++;
        if (offline) throw http.ClientException('offline');
        var verlieren = false;
        if (abbruchNach != null) {
          if (abbruchNach == 0) {
            if (_abgebrochen) throw http.ClientException('Verbindung abgebrochen');
            _abgebrochen = verlieren = true;
          } else {
            abbruchNach = abbruchNach! - 1;
          }
        } else {
          _abgebrochen = false;
        }
        final antwort = await handler(shelf.Request(req.method, req.url, body: req.body, headers: req.headers));
        if (verlieren) throw http.ClientException('Antwort verloren');
        return http.Response.bytes(await antwort.read().expand((x) => x).toList(), antwort.statusCode, headers: antwort.headers);
      });

  /// Alles, was der Server gespeichert hat (für „Admin sieht nur Geheimtext“).
  String dump() => jsonEncode([
        for (final t in ['konten', 'geraete', 'objekte', 'kopplungen', 'meta'])
          for (final r in speicher.db.select('SELECT * FROM $t')) r.values.map((v) => '$v').toList(),
      ]);
}
