import 'dart:convert';
import 'dart:math';

import 'package:personal_tracker_sync/personal_tracker_sync.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

final _r = Random(3);
String geheim() => base64Url.encode([for (var i = 0; i < 32; i++) _r.nextInt(256)]);

/// Eine Instanz im Speicher unter einer festen öffentlichen Adresse.
class Instanz {
  Instanz(this.url) : s = Speicher.imSpeicher() {
    h = syncHandler(s, k: Konfiguration(instanz: url, anmeldungenProFenster: 1000));
    katalog = Katalog(s, instanz: url);
  }
  final String url;
  final Speicher s;
  late final Handler h;
  late final Katalog katalog;

  Future<(int, Map<String, dynamic>)> anfrage(String methode, String pfad, {String? token, Object? body}) async {
    final a = await h(Request(methode, Uri.parse('$url$pfad'), body: body == null ? null : jsonEncode(body), headers: {if (token != null) 'authorization': 'Bearer $token'}));
    final t = await a.readAsString();
    return (a.statusCode, t.isEmpty ? <String, dynamic>{} : (jsonDecode(t) as Map).cast<String, dynamic>());
  }

  Future<String> konto() async {
    final (_, j) = await anfrage('POST', '/v1/konten', body: {'recoveryAuth': geheim(), 'recoveryHuelle': 'H', 'schluesselPaket': 'P', 'geraetName': 'g'});
    return j['token'] as String;
  }

  Future<Map<String, dynamic>> preis(String token, {String artikel = 'Butter', String filiale = 'Hauptstraße', int cent = 229, String tag = '2026-11-20'}) async {
    final (st, j) = await anfrage('POST', '/v1/katalog/beitraege', token: token, body: {
      'typ': 'preis',
      'artikel': artikel,
      'packungsMenge': 250,
      'packungsEinheit': 'g',
      'kette': 'Aldi Süd',
      'filiale': filiale,
      'region': 'Musterstadt',
      'preisCent': cent,
      'waehrung': 'EUR',
      'tag': tag,
    });
    expect(st, 201, reason: '$j');
    return j;
  }

  Future<List<Map<String, dynamic>>> suche(String token, [String artikel = '']) async =>
      ((await anfrage('GET', '/v1/katalog/preise?artikel=$artikel', token: token)).$2['preise'] as List).cast<Map<String, dynamic>>();
}

void main() {
  late Instanz a, b, c;
  late Map<String, Instanz> netz;

  /// Abruf über das „Netz“ der Test-Instanzen; [manipuliert] ersetzt Antworten.
  final manipuliert = <String, String>{};
  Future<(int, String)> abruf(Uri u) async {
    final key = '${u.scheme}://${u.authority}';
    if (manipuliert.containsKey(u.toString())) return (200, manipuliert[u.toString()]!);
    final i = netz[key];
    if (i == null) throw Exception('nicht erreichbar');
    final r = await i.h(Request('GET', u));
    return (r.statusCode, await r.readAsString());
  }

  setUp(() {
    // Tage im Test relativ zu heute, damit die Plausibilitätsprüfung passt.
    a = Instanz('https://a.example');
    b = Instanz('https://b.example');
    c = Instanz('https://c.example');
    netz = {a.url: a, b.url: b, c.url: c};
    manipuliert.clear();
  });

  String heute([int minus = 0]) => DateTime.now().toUtc().subtract(Duration(days: minus)).toIso8601String().substring(0, 10);

  test('Eine Instanz: Urheber zählt nicht, eine zweite Person bestätigt; Zurückziehen', () async {
    final kay = await a.konto(), lena = await a.konto();
    final p = await a.preis(kay, tag: heute());
    expect((await a.suche(kay)).single['bestaetigt'], isFalse);
    // Selbst bestätigen geht nicht.
    expect((await a.anfrage('POST', '/v1/katalog/beitraege', token: kay, body: {'typ': 'bestaetigung', 'ziel': {'instanz': a.url, 'id': p['id']}})).$1, 403);
    await a.anfrage('POST', '/v1/katalog/beitraege', token: lena, body: {'typ': 'bestaetigung', 'ziel': {'instanz': a.url, 'id': p['id']}});
    await a.anfrage('POST', '/v1/katalog/beitraege', token: lena, body: {'typ': 'bestaetigung', 'ziel': {'instanz': a.url, 'id': p['id']}});
    final x = (await a.suche(kay)).single;
    expect(x['bestaetigt'], isTrue);
    expect(x['bestaetigungen'], 1, reason: 'dieselbe Person zählt nur einmal');
    expect(x['eigen'], isTrue);
    expect(x['autor'], matches(RegExp(r'^p-[0-9a-f]{12}@https://a\.example$')));
    // Kein Klarname, keine Konto-ID.
    expect(jsonEncode(x), isNot(contains('konto')));
    // Zurückziehen: nur eigene.
    expect((await a.anfrage('POST', '/v1/katalog/beitraege', token: lena, body: {'typ': 'rueckzug', 'ziel': {'instanz': a.url, 'id': p['id']}})).$1, 403);
    expect((await a.anfrage('POST', '/v1/katalog/beitraege', token: kay, body: {'typ': 'rueckzug', 'ziel': {'instanz': a.url, 'id': p['id']}})).$1, 201);
    expect(await a.suche(kay), isEmpty);
    expect((await a.anfrage('GET', '/v1/katalog/meine', token: kay)).$2['beitraege'], isEmpty);
  });

  test('Föderation: Vorschlag auf A, Bestätigung auf B, sichtbar auf beiden; zwei Filialen getrennt', () async {
    a.katalog.peerHinzufuegen(b.url);
    b.katalog.peerHinzufuegen(a.url);
    final kay = await a.konto(), tim = await b.konto();
    final p = await a.preis(kay, tag: heute());
    await a.preis(kay, filiale: 'Bahnhof', cent: 199, tag: heute());
    await b.katalog.abgleichen(abruf);
    final beiB = await b.suche(tim, 'butter');
    expect(beiB.length, 2);
    expect(beiB.every((x) => x['bestaetigt'] == false), isTrue);
    expect(beiB.map((x) => x['instanz']).toSet(), {a.url});
    await b.anfrage('POST', '/v1/katalog/beitraege', token: tim, body: {'typ': 'bestaetigung', 'ziel': {'instanz': a.url, 'id': p['id']}});
    await a.katalog.abgleichen(abruf);
    final beiA = await a.suche(kay, 'butter');
    expect(beiA.firstWhere((x) => x['filiale'] == 'Hauptstraße')['bestaetigt'], isTrue);
    expect(beiA.firstWhere((x) => x['filiale'] == 'Bahnhof')['bestaetigt'], isFalse, reason: 'andere Filiale bestätigt nicht mit');
    // Gleicher Preis, gleiche Packung, gleiche Filiale von jemand anderem zählt als Bestätigung.
    await b.preis(tim, filiale: 'Bahnhof', cent: 199, tag: heute(3));
    await a.katalog.abgleichen(abruf);
    expect((await a.suche(kay, 'butter')).firstWhere((x) => x['filiale'] == 'Bahnhof' && x['instanz'] == a.url)['bestaetigt'], isTrue);
    // Erneutes Abrufen ist idempotent.
    final vorher = (await a.suche(kay)).length;
    final e = await a.katalog.abgleichen(abruf);
    expect(e.neu, 0);
    expect((await a.suche(kay)).length, vorher);
  });

  test('Zurückziehen und Betreiber-Sperre wirken föderiert; Instanz-Sperre blendet lokal aus', () async {
    b.katalog.peerHinzufuegen(a.url);
    final kay = await a.konto(), tim = await b.konto();
    final p = await a.preis(kay, tag: heute());
    await a.preis(kay, artikel: 'Milch', tag: heute());
    await b.katalog.abgleichen(abruf);
    expect((await b.suche(tim)).length, 2);
    await a.anfrage('POST', '/v1/katalog/beitraege', token: kay, body: {'typ': 'rueckzug', 'ziel': {'instanz': a.url, 'id': p['id']}});
    await b.katalog.abgleichen(abruf);
    expect((await b.suche(tim)).map((x) => x['artikel']), ['Milch']);
    // Betreiber von A sperrt Kays Pseudonym.
    final pseudonym = (await a.anfrage('GET', '/v1/katalog/ich', token: kay)).$2['pseudonym'] as String;
    expect(a.katalog.kontoSperren(pseudonym), 1);
    expect((await a.anfrage('POST', '/v1/katalog/beitraege', token: kay, body: {'typ': 'preis'})).$1, 403);
    await b.katalog.abgleichen(abruf);
    expect(await b.suche(tim), isEmpty);
    // Instanz-Sperre auf B: neue Beiträge von A bleiben unsichtbar.
    final lena = await a.konto();
    await a.preis(lena, artikel: 'Brot', tag: heute());
    b.katalog.instanzSperren(a.url);
    await b.katalog.abgleichen(abruf);
    expect(await b.suche(tim), isEmpty);
  });

  test('Ungültige Feed-Einträge werden übersprungen; fremdes Zurückziehen zählt nicht; falsche Instanz wird abgelehnt', () async {
    b.katalog.peerHinzufuegen(a.url);
    b.katalog.peerHinzufuegen(c.url);
    final kay = await a.konto(), tim = await b.konto(), eve = await c.konto();
    final p = await a.preis(kay, tag: heute());
    await c.preis(eve, artikel: 'Käse', tag: heute());
    final echt = (await a.h(Request('GET', Uri.parse('${a.url}/k1/feed?seit=0&max=500')))).readAsString();
    final feed = jsonDecode(await echt) as Map<String, dynamic>;
    final eintraege = [
      ...(feed['eintraege'] as List),
      {'seq': 90, 'id': 'kaputt-123', 'autor': 'p-000000000000', 'typ': 'preis', 'preisCent': -5},
      {'seq': 91, 'id': 'kaputt-124', 'autor': 'nicht-pseudonym', 'typ': 'preis'},
      'kein Objekt',
    ];
    manipuliert['${a.url}/k1/feed?seit=0&max=500'] = jsonEncode({...feed, 'eintraege': eintraege, 'bis': 91});
    // C behauptet, A's Preis zurückzuziehen.
    final cFeed = jsonDecode(await (await c.h(Request('GET', Uri.parse('${c.url}/k1/feed?seit=0&max=500')))).readAsString()) as Map<String, dynamic>;
    manipuliert['${c.url}/k1/feed?seit=0&max=500'] = jsonEncode({
      ...cFeed,
      'eintraege': [
        ...(cFeed['eintraege'] as List),
        {'seq': 50, 'id': 'boese-rueckzug-1', 'autor': 'p-111111111111', 'typ': 'rueckzug', 'ziel': {'instanz': a.url, 'id': p['id']}},
      ],
      'bis': 50,
    });
    final e = await b.katalog.abgleichen(abruf);
    expect(e.ungueltig, 4);
    expect((await b.suche(tim)).map((x) => x['artikel']).toSet(), {'Butter', 'Käse'});
    // Eine Instanz, die unter falscher Adresse antwortet, wird nicht übernommen.
    b.katalog.peerHinzufuegen('https://falsch.example');
    netz['https://falsch.example'] = c;
    final e2 = await b.katalog.abgleichen(abruf);
    expect(e2.fehler.keys, contains('https://falsch.example'));
  });

  test('Offene Föderation: Instanzen werden weitergereicht; ausgefallene halten nichts auf', () async {
    // A kennt B, B kennt C. A lernt C über den Feed von B.
    a.katalog.peerHinzufuegen(b.url);
    b.katalog.peerHinzufuegen(c.url);
    a.katalog.peerHinzufuegen('https://weg.example');
    final eve = await c.konto(), kay = await a.konto();
    await c.preis(eve, artikel: 'Quark', tag: heute());
    final e = await a.katalog.abgleichen(abruf);
    expect(e.fehler.keys, ['https://weg.example']);
    await a.katalog.abgleichen(abruf);
    expect((await a.suche(kay)).map((x) => x['artikel']), ['Quark']);
  });

  test('Konto löschen zieht Beiträge zurück; ohne öffentliche Adresse keine Föderation', () async {
    b.katalog.peerHinzufuegen(a.url);
    final kay = await a.konto(), tim = await b.konto();
    await a.preis(kay, tag: heute());
    await b.katalog.abgleichen(abruf);
    expect(await b.suche(tim), hasLength(1));
    await a.anfrage('DELETE', '/v1/konto', token: kay);
    await b.katalog.abgleichen(abruf);
    expect(await b.suche(tim), isEmpty);

    final lokal = Speicher.imSpeicher();
    addTearDown(lokal.schliessen);
    final h = syncHandler(lokal);
    expect((await h(Request('GET', Uri.parse('http://x/k1/info')))).statusCode, 404);
  });

  test('Plausibilität: Preis, Tag, Einheit, Länge', () {
    Map<String, dynamic> basis() => {
          'typ': 'preis', 'artikel': 'X', 'packungsMenge': 1, 'packungsEinheit': 'l', 'kette': 'K', 'filiale': 'F', 'region': 'R',
          'preisCent': 100, 'waehrung': 'EUR', 'tag': heute(),
        };
    expect(Katalog.pruefen(basis()), isNotNull);
    expect(Katalog.pruefen({...basis(), 'preisCent': 0}), isNull);
    expect(Katalog.pruefen({...basis(), 'waehrung': 'USD'}), isNull);
    expect(Katalog.pruefen({...basis(), 'packungsEinheit': 'packung'}), isNull);
    expect(Katalog.pruefen({...basis(), 'tag': '2099-01-01'}), isNull);
    expect(Katalog.pruefen({...basis(), 'artikel': 'A' * 101}), isNull);
    expect(Katalog.pruefen({...basis(), 'artikel': 'Zeile\nUmbruch'}), isNull);
    expect(Katalog.pruefen({...basis(), 'breite': 52.5})!.containsKey('breite'), isFalse, reason: 'unbekannte Felder (z. B. Position) werden nicht übernommen');
  });
}
