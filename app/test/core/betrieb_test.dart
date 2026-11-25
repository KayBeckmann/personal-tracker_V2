import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/krypto/recovery_schluessel.dart';
import 'package:personal_tracker/core/sync/sync_api.dart';
import 'package:personal_tracker_sync/personal_tracker_sync.dart';

import '../sync_hilfen.dart';
import 'sitzung_test.dart' show einrichtenMitDaten;
import 'sync_test.dart' show Geraet;

void main() {
  late TestServer server;
  setUp(() => server = TestServer());
  tearDown(() => server.speicher.schliessen());

  void modus(String registrierung, {int maxKonto = 0}) => server.handler = syncHandler(server.speicher,
      k: Konfiguration(registrierung: registrierung, maxKonto: maxKonto, anmeldungenProFenster: 1000, protokoll: server.protokoll.add));

  Future<(Geraet, RecoverySchluessel)> geraet(String name) async {
    final g = await Geraet(server, name).start();
    return (g, await einrichtenMitDaten(g.s));
  }

  test('Registrierung mit Einladung: ohne und mit falschem Code abgelehnt, mit Code angelegt; Kontingent sichtbar', () async {
    modus('einladung', maxKonto: 50 * 1024 * 1024);
    final (kay, rk) = await geraet('Kay');
    await expectLater(kay.sync.verbinden(server: TestServer.adresse, recovery: rk),
        throwsA(isA<SyncFehler>().having((e) => e.art, 'art', SyncFehlerArt.einladung)));
    await expectLater(kay.sync.verbinden(server: TestServer.adresse, recovery: rk, einladung: 'AAAAA-BBBBB-CCCCC-DDDDD'),
        throwsA(isA<SyncFehler>().having((e) => e.art, 'art', SyncFehlerArt.einladung)));
    expect(server.speicher.kontenUebersicht(), isEmpty);

    final code = server.speicher.registrierungAnlegen();
    await kay.sync.verbinden(server: TestServer.adresse, recovery: rk, einladung: code.toLowerCase());
    await kay.ruhig();
    expect(kay.status.fehler, isNull);
    expect(kay.status.belegt, greaterThan(0));
    expect(kay.status.kontingent, 50 * 1024 * 1024);

    // Bestehendes Konto braucht keinen Code: trennen und wieder verbinden.
    await kay.sync.trennen();
    await kay.sync.verbinden(server: TestServer.adresse, recovery: rk);
    await kay.abgleichen();
    expect(server.speicher.kontenUebersicht(), hasLength(1));

    // Betreiber hebt das Kontingent auf.
    server.speicher.kontingentSetzen(server.speicher.kontenUebersicht().single['konto'] as String, 0);
    await kay.abgleichen();
    expect(kay.status.kontingent, isNull);
  });

  test('Registrierung zu: kein neues Konto, verständliche Meldung', () async {
    modus('zu');
    final (lena, rk) = await geraet('Lena');
    await expectLater(
      lena.sync.verbinden(server: TestServer.adresse, recovery: rk, einladung: 'egal'),
      throwsA(isA<SyncFehler>().having((e) => e.meldung, 'meldung', contains('keine neuen Konten'))),
    );
    expect(lena.status.verbunden, isFalse);
  });
}
