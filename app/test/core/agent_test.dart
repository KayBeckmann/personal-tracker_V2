import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/agent/agent_dienst.dart';
import 'package:personal_tracker/core/modell/agent.dart';
import 'package:personal_tracker/core/sync/sync_api.dart';
import 'package:personal_tracker/core/sync/sync_krypto.dart';

import '../sync_hilfen.dart';
import 'sitzung_test.dart' show einrichtenMitDaten;
import 'sync_test.dart' show Geraet;

void main() {
  late TestServer server;
  setUp(() => server = TestServer());
  tearDown(() => server.speicher.schliessen());

  Future<Geraet> person(String name) async {
    final g = await Geraet(server, name).start();
    final r = await einrichtenMitDaten(g.s);
    await g.sync.verbinden(server: TestServer.adresse, recovery: r, geraetName: name);
    await g.ruhig();
    return g;
  }

  AgentVorschlag vorschlag(String id, String art, String bereich, String ziel) => AgentVorschlag(
        id: id,
        agent: 'a',
        agentName: 'Claude',
        zeit: DateTime.utc(2026, 11, 25),
        art: art,
        bereich: bereich,
        zielId: ziel,
        beschreibung: 'Termin „Zahnarzt“ löschen',
        status: 'offen',
      );

  test('Agent einrichten: nur gültige Rechte, Kopplung als Agenten-Gerät, Widerruf meldet ab', () async {
    final kay = await person('Kay');
    final dienst = kay.c.read(agentProvider);
    await expectLater(dienst.einrichten(name: 'Claude', rechte: {'termine': 'aus', 'quatsch': 'schreiben'}), throwsA(isA<AgentFehler>()));

    final e = await dienst.einrichten(name: 'Claude', rechte: {'termine': 'lesen', 'notizen': 'schreiben', 'quatsch': 'schreiben', 'vault': 'aus'}, ablaufTage: 30);
    expect(e.agent.rechte, {'termine': 'lesen', 'notizen': 'schreiben'});
    expect(kay.b.agenten[e.agent.id]!.ablaufTage, 30);
    final zeile = server.speicher.db.select('SELECT art, geraet_ablauf FROM kopplungen').single;
    expect(zeile['art'], 'agent');
    expect(zeile['geraet_ablauf'], isNotNull);

    // Die Brücke löst ein: das Paket trägt die Rechte, das Gerät ist ein Agent.
    final api = SyncApi(Uri.parse(TestServer.adresse), client: server.client());
    final ein = await api.kopplungEinloesen(e.code.slot, '');
    final p = e.code.paketOeffnen(ein.paket)!;
    expect(p.agent, isTrue);
    // Wie pt-agent: das Gerät heißt „Agent: <Name>“.
    await api.mitToken(ein.token).geraetUmbenennen(ein.geraet, p.schluessel.geraetName('Agent: Claude'));
    var geraete = await kay.sync.geraete();
    expect(geraete.where((g) => g.agent).map((g) => g.id), [ein.geraet]);
    // Agenten dürfen nichts verwalten.
    await expectLater(api.mitToken(ein.token).kopplungAnlegen('x' * 43, 'p', const Duration(minutes: 5)), throwsA(isA<SyncFehler>()));

    // Ein Agenten-Code taugt nicht zum Koppeln eines Geräts.
    final zweiter = await dienst.einrichten(name: 'Zweiter', rechte: {'termine': 'lesen'});
    final neu = await Geraet(server, 'Neu').start();
    await expectLater(neu.sync.neuKoppeln(server: TestServer.adresse, code: zweiter.code, passwort: 'pw-neu', geraetName: 'Neu'), throwsA(isA<SyncFehler>()));
    expect((await kay.sync.geraete()).where((g) => g.agent).length, 1);

    // Widerruf: Gerät weg, Token ungültig, Zugang weg.
    await dienst.widerrufen(kay.b.agenten[e.agent.id]!);
    geraete = await kay.sync.geraete();
    expect(geraete.where((g) => g.agent), isEmpty);
    expect(kay.b.agenten.containsKey(e.agent.id), isFalse);
    await expectLater(api.mitToken(ein.token).konto(), throwsA(isA<SyncFehler>()));
  });

  test('Vorschläge: erst die Person löscht; Ablehnen ändert nichts', () async {
    final kay = await person('Kay');
    final dienst = kay.c.read(agentProvider);
    await kay.s.speichereVorschlag(vorschlag('v1', 'loeschen', 'termine', 't1'));
    await kay.s.speichereVorschlag(vorschlag('v2', 'loeschen', 'notizen', 'n1'));
    expect(kay.b.termine.containsKey('t1'), isTrue);

    await dienst.entscheiden(kay.b.agentVorschlaege['v2']!, annehmen: false);
    expect(kay.b.notizen.containsKey('n1'), isTrue);
    expect(kay.b.agentVorschlaege['v2']!.status, 'abgelehnt');

    await dienst.entscheiden(kay.b.agentVorschlaege['v1']!, annehmen: true);
    expect(kay.b.termine.containsKey('t1'), isFalse);
    expect(kay.b.agentVorschlaege['v1']!.status, 'angenommen');

    // Bereits entschieden: nichts passiert mehr.
    await dienst.entscheiden(kay.b.agentVorschlaege['v2']!, annehmen: true);
    expect(kay.b.notizen.containsKey('n1'), isTrue);
    await kay.abgleichen();
  });

  test('Kopplungscode: Geräte-Pakete sind keine Agenten-Pakete', () {
    final c = Kopplungscode.neu();
    expect(c.paketOeffnen(c.paket('konto', Kontoschluessel.neu()))!.agent, isFalse);
  });
}
