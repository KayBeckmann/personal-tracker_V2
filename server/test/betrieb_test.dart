import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:personal_tracker_sync/personal_tracker_sync.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

final _r = Random(9);
String geheim() => base64Url.encode([for (var i = 0; i < 32; i++) _r.nextInt(256)]);

Future<(int, Map<String, dynamic>)> anfrage(Handler h, String methode, String pfad, {Object? body, String? token}) async {
  final a = await h(Request(methode, Uri.parse('http://test$pfad'),
      body: body == null ? null : jsonEncode(body), headers: {if (token != null) 'authorization': 'Bearer $token'}));
  final t = await a.readAsString();
  return (a.statusCode, t.isEmpty ? <String, dynamic>{} : (jsonDecode(t) as Map).cast<String, dynamic>());
}

Map<String, Object?> neuesKonto([String? einladung]) => {
      'recoveryAuth': geheim(),
      'recoveryHuelle': 'H',
      'schluesselPaket': 'P',
      'geraetName': 'g',
      if (einladung != null) 'einladung': einladung,
    };

void main() {
  late Speicher s;
  setUp(() => s = Speicher.imSpeicher());
  tearDown(() => s.schliessen());

  test('Registrierung: offen, zu, nur mit Einladung (einmalig, ablaufend)', () async {
    var h = syncHandler(s);
    expect((await anfrage(h, 'GET', '/v1/info')).$2['registrierung'], 'offen');
    expect((await anfrage(h, 'POST', '/v1/konten', body: neuesKonto())).$1, 201);

    h = syncHandler(s, k: const Konfiguration(registrierung: 'zu'));
    var (st, j) = await anfrage(h, 'POST', '/v1/konten', body: neuesKonto());
    expect((st, j['fehler']), (403, 'registrierung-zu'));

    h = syncHandler(s, k: const Konfiguration(registrierung: 'einladung'));
    expect((await anfrage(h, 'GET', '/v1/info')).$2['registrierung'], 'einladung');
    (st, j) = await anfrage(h, 'POST', '/v1/konten', body: neuesKonto());
    expect((st, j['fehler']), (403, 'einladung-noetig'));
    (st, j) = await anfrage(h, 'POST', '/v1/konten', body: neuesKonto('AAAAA-BBBBB-CCCCC-DDDDD'));
    expect((st, j['fehler']), (403, 'einladung-ungueltig'));

    final code = s.registrierungAnlegen();
    expect(code, matches(RegExp(r'^([0-9A-Z]{5}-){3}[0-9A-Z]{5}$')));
    expect(s.db.select('SELECT hash FROM registrierungen').map((r) => r['hash']).join(), isNot(contains(code.replaceAll('-', ''))));
    // Kleinschreibung und ohne Trenner geht auch – aber nur einmal.
    expect((await anfrage(h, 'POST', '/v1/konten', body: neuesKonto(code.toLowerCase().replaceAll('-', '')))).$1, 201);
    (st, j) = await anfrage(h, 'POST', '/v1/konten', body: neuesKonto(code));
    expect((st, j['fehler']), (403, 'einladung-ungueltig'));

    final alt = s.registrierungAnlegen(gueltig: const Duration(milliseconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect((await anfrage(h, 'POST', '/v1/konten', body: neuesKonto(alt))).$1, 403);
    expect(s.kontenUebersicht(), hasLength(2));
  });

  test('Kontingent je Konto überschreibt den Standard; Konto zeigt es an', () async {
    final h = syncHandler(s, k: const Konfiguration(maxKonto: 4000));
    final (_, e) = await anfrage(h, 'POST', '/v1/konten', body: neuesKonto());
    final token = e['token'] as String, konto = e['konto'] as String;
    Future<int> schreiben(int n) async => (await anfrage(h, 'POST', '/v1/objekte', token: token, body: {
          'aenderungen': [
            {'id': [for (var i = 0; i < 64; i++) _r.nextInt(16).toRadixString(16)].join(), 'basis': 0, 'aenderung': 'a${_r.nextInt(1 << 30)}', 'daten': 'x' * n},
          ],
        })).$1;
    expect(await schreiben(3000), 200);
    expect(await schreiben(3000), 413);
    var (_, k) = await anfrage(h, 'GET', '/v1/konto', token: token);
    expect(k['kontingent'], 4000);
    expect(k['belegtGesamt'], 3000);

    expect(s.kontoZuPraefix(konto.substring(0, 8)), konto);
    expect(s.kontoZuPraefix(konto.substring(0, 3)), isNull);
    s.kontingentSetzen(konto, 10000);
    expect(await schreiben(3000), 200);
    (_, k) = await anfrage(h, 'GET', '/v1/konto', token: token);
    expect(k['kontingent'], 10000);
    s.kontingentSetzen(konto, 0);
    expect(await schreiben(5000), 200);
    (_, k) = await anfrage(h, 'GET', '/v1/konto', token: token);
    expect(k.containsKey('kontingent'), isFalse);
    s.kontingentSetzen(konto, null);
    expect(await schreiben(10), 413);
    final u = s.kontenUebersicht().single;
    expect((u['belegt'], u['geraete']), (11000, 1));
  });

  test('Gesundheit und Zustand ohne Inhalte; Integritätsprüfung', () async {
    final h = syncHandler(s);
    final (st, j) = await anfrage(h, 'GET', '/v1/gesund');
    expect((st, j['ok']), (200, true));
    await anfrage(h, 'POST', '/v1/konten', body: neuesKonto());
    expect(s.zustand()['konten'], 1);
    expect(s.pruefen(), 'ok');
  });

  test('Migration 5 → 6 behält Konten', () {
    final d = Directory.systemTemp.createTempSync('pt-m9');
    addTearDown(() => d.deleteSync(recursive: true));
    final pfad = '${d.path}/sync.db';
    var x = Speicher.oeffnen(pfad);
    x.kontoAnlegen(recoveryAuth: [1, 2, 3], recoveryHuelle: 'H', schluesselPaket: 'P', geraetName: 'g');
    x.db.execute('ALTER TABLE konten DROP COLUMN kontingent');
    x.db.execute('DROP TABLE registrierungen');
    x.db.execute('PRAGMA user_version = 5');
    x.schliessen();
    x = Speicher.oeffnen(pfad);
    expect(x.kontenUebersicht().single['kontingent'], isNull);
    expect(x.registrierungAnlegen(), isNotEmpty);
    x.schliessen();
  });
}
