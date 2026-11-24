import 'dart:convert';
import 'dart:math';

import 'package:personal_tracker_sync/personal_tracker_sync.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

final _r = Random(7);
String geheim() => base64Url.encode([for (var i = 0; i < 32; i++) _r.nextInt(256)]);
String hex(int n) => [for (var i = 0; i < n; i++) _r.nextInt(16).toRadixString(16)].join();

class Client {
  Client(this.h);
  final Handler h;
  String? token;

  Future<(int, Map<String, dynamic>)> anfrage(String methode, String pfad, [Object? body]) async {
    final antwort = await h(Request(
      methode,
      Uri.parse('http://test$pfad'),
      body: body == null ? null : jsonEncode(body),
      headers: {if (token != null) 'authorization': 'Bearer $token'},
    ));
    final text = await antwort.readAsString();
    return (antwort.statusCode, text.isEmpty ? <String, dynamic>{} : (jsonDecode(text) as Map).cast<String, dynamic>());
  }
}

void main() {
  late Speicher s;
  late Handler h;
  final protokoll = <String>[];

  setUp(() {
    s = Speicher.imSpeicher();
    protokoll.clear();
    h = syncHandler(s, k: Konfiguration(protokoll: protokoll.add, anmeldungenProFenster: 50));
  });
  tearDown(() => s.schliessen());

  Future<(Client, String recovery)> konto() async {
    final c = Client(h);
    final rec = geheim();
    final (st, j) = await c.anfrage('POST', '/v1/konten', {
      'recoveryAuth': rec,
      'recoveryHuelle': 'HUELLE',
      'schluesselPaket': 'PAKET',
      'geraetName': 'enc-name-1',
    });
    expect(st, 201);
    c.token = j['token'] as String;
    return (c, rec);
  }

  test('info nennt API-Version', () async {
    final (st, j) = await Client(h).anfrage('GET', '/v1/info');
    expect(st, 200);
    expect(j['api'], 1);
    expect(j['instanz'], isA<String>());
  });

  test('ohne Token kein Zugriff, falscher Token auch nicht', () async {
    final c = Client(h);
    expect((await c.anfrage('GET', '/v1/objekte')).$1, 401);
    c.token = geheim();
    expect((await c.anfrage('GET', '/v1/konto')).$1, 401);
    c.token = 'kein base64 !!';
    expect((await c.anfrage('GET', '/v1/konto')).$1, 401);
  });

  test('Schreiben, Abrufen, Konflikt und idempotente Wiederholung', () async {
    final (c, _) = await konto();
    final id = hex(32);
    var (st, j) = await c.anfrage('POST', '/v1/objekte', {
      'aenderungen': [
        {'id': id, 'basis': 0, 'aenderung': 'a1', 'daten': 'X1'},
      ],
    });
    expect(st, 200);
    expect(j['ergebnisse'][0]['status'], 'ok');
    expect(j['ergebnisse'][0]['seq'], 1);

    // Wiederholung derselben Änderung (z. B. Antwort ging verloren).
    (st, j) = await c.anfrage('POST', '/v1/objekte', {
      'aenderungen': [
        {'id': id, 'basis': 0, 'aenderung': 'a1', 'daten': 'X1'},
      ],
    });
    expect(j['ergebnisse'][0], {'id': id, 'status': 'ok', 'seq': 1});

    // Veraltete Basis -> Konflikt mit Serverfassung.
    (st, j) = await c.anfrage('POST', '/v1/objekte', {
      'aenderungen': [
        {'id': id, 'basis': 0, 'aenderung': 'a2', 'daten': 'X2'},
      ],
    });
    expect(j['ergebnisse'][0]['status'], 'konflikt');
    expect(j['ergebnisse'][0]['daten'], 'X1');

    (st, j) = await c.anfrage('POST', '/v1/objekte', {
      'aenderungen': [
        {'id': id, 'basis': 1, 'aenderung': 'a3', 'daten': 'X3'},
      ],
    });
    expect(j['ergebnisse'][0]['seq'], 2);

    (st, j) = await c.anfrage('GET', '/v1/objekte?seit=0');
    expect(j['objekte'], [
      {'id': id, 'seq': 2, 'daten': 'X3'},
    ]);
    expect(j['bis'], 2);
    expect(j['mehr'], false);
  });

  test('Abruf in Seiten', () async {
    final (c, _) = await konto();
    await c.anfrage('POST', '/v1/objekte', {
      'aenderungen': [
        for (var i = 0; i < 5; i++) {'id': hex(32), 'basis': 0, 'aenderung': 'a$i', 'daten': 'D$i'},
      ],
    });
    var (_, j) = await c.anfrage('GET', '/v1/objekte?seit=0&max=2');
    expect((j['objekte'] as List).length, 2);
    expect(j['mehr'], true);
    expect(j['bis'], 2);
    (_, j) = await c.anfrage('GET', '/v1/objekte?seit=4&max=2');
    expect(j['mehr'], false);
    expect(j['bis'], 5);
    (_, j) = await c.anfrage('GET', '/v1/objekte?seit=5');
    expect(j['objekte'], isEmpty);
    expect(j['bis'], 5);
  });

  test('Konten sind voneinander getrennt', () async {
    final (a, _) = await konto();
    final (b, _) = await konto();
    final id = hex(32);
    await a.anfrage('POST', '/v1/objekte', {
      'aenderungen': [
        {'id': id, 'basis': 0, 'aenderung': 'x', 'daten': 'GEHEIM-A'},
      ],
    });
    final (_, j) = await b.anfrage('GET', '/v1/objekte?seit=0');
    expect(j['objekte'], isEmpty);
    final (_, k) = await a.anfrage('GET', '/v1/konto');
    final fremdesGeraet = ((await b.anfrage('GET', '/v1/konto')).$2['geraet']) as String;
    expect((await a.anfrage('DELETE', '/v1/geraete/$fremdesGeraet')).$1, 404);
    expect(k['objekte'], 1);
  });

  test('Kopplung: einmal einlösbar, danach weg; Gerät widerrufbar', () async {
    final (a, _) = await konto();
    final slot = hex(64);
    expect((await a.anfrage('POST', '/v1/kopplungen', {'slot': slot, 'paket': 'P', 'gueltigSekunden': 600})).$1, 201);
    final neu = Client(h);
    var (st, j) = await neu.anfrage('POST', '/v1/kopplungen/$slot/einloesen', {'geraetName': 'enc-2'});
    expect(st, 200);
    expect(j['paket'], 'P');
    neu.token = j['token'] as String;
    expect((await neu.anfrage('GET', '/v1/konto')).$1, 200);
    (st, j) = await Client(h).anfrage('POST', '/v1/kopplungen/$slot/einloesen', {'geraetName': 'x'});
    expect(st, 404);

    final (_, info) = await a.anfrage('GET', '/v1/konto');
    expect((info['geraete'] as List).length, 2);
    final id2 = ((await neu.anfrage('GET', '/v1/konto')).$2['geraet']) as String;
    expect((await a.anfrage('DELETE', '/v1/geraete/$id2')).$1, 200);
    expect((await neu.anfrage('GET', '/v1/objekte')).$1, 401);
    // Protokoll enthält keine vollständigen IDs.
    expect(protokoll.any((z) => z.contains(slot) || z.contains(id2)), isFalse);
  });

  test('Kopplung läuft ab', () async {
    final (a, _) = await konto();
    final slot = hex(64);
    await a.anfrage('POST', '/v1/kopplungen', {'slot': slot, 'paket': 'P', 'gueltigSekunden': 30});
    s.db.execute('UPDATE kopplungen SET ablauf = 0');
    expect((await Client(h).anfrage('POST', '/v1/kopplungen/$slot/einloesen', {'geraetName': 'x'})).$1, 404);
  });

  test('Recovery-Anmeldung und -Wechsel', () async {
    final (a, rec) = await konto();
    final r = Client(h);
    var (st, j) = await r.anfrage('POST', '/v1/anmelden/recovery', {'recoveryAuth': rec, 'geraetName': 'neu'});
    expect(st, 200);
    expect(j['recoveryHuelle'], 'HUELLE');
    expect((await Client(h).anfrage('POST', '/v1/anmelden/recovery', {'recoveryAuth': geheim(), 'geraetName': 'x'})).$1, 404);

    final neu = geheim();
    (st, j) = await a.anfrage('PUT', '/v1/konto/recovery', {'recoveryAuth': neu, 'recoveryHuelle': 'H2', 'schluesselPaket': 'P2'});
    expect(st, 200);
    expect((await Client(h).anfrage('POST', '/v1/anmelden/recovery', {'recoveryAuth': rec, 'geraetName': 'x'})).$1, 404);
    (st, j) = await Client(h).anfrage('POST', '/v1/anmelden/recovery', {'recoveryAuth': neu, 'geraetName': 'x'});
    expect(j['recoveryHuelle'], 'H2');
    // Ein zweites Konto mit demselben Recovery-Schlüssel gibt es nicht.
    expect((await Client(h).anfrage('POST', '/v1/konten', {
      'recoveryAuth': neu,
      'recoveryHuelle': 'h',
      'schluesselPaket': 'p',
      'geraetName': 'n',
    }))
        .$1, 409);
  });

  test('Konto löschen entfernt alles', () async {
    final (a, _) = await konto();
    await a.anfrage('POST', '/v1/objekte', {
      'aenderungen': [
        {'id': hex(32), 'basis': 0, 'aenderung': 'x', 'daten': 'D'},
      ],
    });
    expect((await a.anfrage('DELETE', '/v1/konto')).$1, 200);
    expect((await a.anfrage('GET', '/v1/konto')).$1, 401);
    expect(s.db.select('SELECT count(*) n FROM objekte').first['n'], 0);
  });

  test('Eingaben werden geprüft', () async {
    final (a, _) = await konto();
    expect((await a.anfrage('POST', '/v1/objekte', {'aenderungen': 'x'})).$1, 400);
    expect((await a.anfrage('POST', '/v1/objekte', {
      'aenderungen': [
        {'id': '../x', 'basis': 0, 'aenderung': 'x', 'daten': 'D'},
      ],
    }))
        .$1, 400);
    expect((await a.anfrage('POST', '/v1/kopplungen', {'slot': 'kurz', 'paket': 'P', 'gueltigSekunden': 60})).$1, 400);
    expect((await Client(h).anfrage('POST', '/v1/konten', {'recoveryAuth': 'abc'})).$1, 400);
  });

  test('Anmeldeversuche werden begrenzt', () async {
    final eng = syncHandler(s, k: const Konfiguration(anmeldungenProFenster: 3));
    final c = Client(eng);
    final codes = [
      for (var i = 0; i < 5; i++) (await c.anfrage('POST', '/v1/anmelden/recovery', {'recoveryAuth': geheim(), 'geraetName': 'x'})).$1,
    ];
    expect(codes, [404, 404, 404, 429, 429]);
  });

  test('CORS-Vorabanfrage', () async {
    final a = await h(Request('OPTIONS', Uri.parse('http://test/v1/objekte')));
    expect(a.statusCode, 204);
    expect(a.headers['access-control-allow-headers'], contains('authorization'));
  });
}
