import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:personal_tracker/core/krypto/recovery_schluessel.dart';
import 'package:personal_tracker/core/modell/agent.dart';
import 'package:personal_tracker/core/sitzung.dart';
import 'package:personal_tracker/core/sync/sync_dienst.dart';

import '../hilfen.dart';
import '../sync_hilfen.dart';
import 'app_test.dart' show appStarten, breit, direktEinrichten, schreibe, tippe;
import 'sync_ui_test.dart' show warteBis;

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  testWidgets('KI-Agent über die Oberfläche: verbinden, Vorschlag bestätigen, widerrufen', (tester) async {
    final server = TestServer();
    addTearDown(server.speicher.schliessen);
    final kay = TestGeraet(name: 'kay.db', client: server.client());
    final c = await appStarten(tester, kay, groesse: breit);
    final rk = await direktEinrichten(tester, c);

    // Ohne Sync keine Agenten-Karte.
    await tippe(tester, 'nav-einstellungen');
    expect(find.byKey(const Key('karte-agenten')), findsNothing);
    await tester.runAsync(() => c.read(syncProvider.notifier).verbinden(server: TestServer.adresse, recovery: RecoverySchluessel.lesen(rk)!, geraetName: 'Laptop'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('karte-agenten')), findsOneWidget);

    await tippe(tester, 'agent-verbinden');
    await schreibe(tester, 'agent-name', 'Claude');
    // Ohne Recht kein Code.
    await tester.tap(find.byKey(const Key('agent-code-erzeugen')));
    await warteBis(tester, () => find.text('Bitte mindestens ein Modul freigeben.').evaluate().isNotEmpty, grund: 'Fehlermeldung');
    await tester.ensureVisible(find.byKey(const Key('agent-recht-termine')));
    await tester.tap(find.descendant(of: find.byKey(const Key('agent-recht-termine')), matching: find.text('lesen')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('agent-code-erzeugen')));
    await warteBis(tester, () => find.byKey(const Key('agent-befehl')).evaluate().isNotEmpty, grund: 'Befehl');
    final befehl = tester.widget<SelectableText>(find.byKey(const Key('agent-befehl'))).data!;
    expect(befehl, startsWith('pt-agent koppeln --server ${TestServer.adresse} --code '));
    await tippe(tester, 'agent-fertig');
    final a = c.read(bestandProvider).agenten.values.single;
    expect(a.rechte, {'termine': 'lesen'});
    expect(find.text('Termine: lesen\nbis zum Widerruf'), findsOneWidget);

    // Ein Vorschlag des Agenten erscheint in der Übersicht und wird erst nach Bestätigung ausgeführt.
    await tester.runAsync(() => c.read(sitzungProvider.notifier).speichereVorschlag(AgentVorschlag(
        id: 'v1', agent: a.id, agentName: 'Claude', zeit: DateTime.utc(2026, 11, 25), art: 'loeschen', bereich: 'notizen',
        zielId: 'fehlt', beschreibung: 'Notiz „Alt“ löschen', status: 'offen')));
    await tippe(tester, 'nav-uebersicht');
    expect(find.byKey(const Key('hinweis-vorschlaege')), findsOneWidget);
    await tippe(tester, 'vorschlaege-ansehen');
    expect(find.text('Notiz „Alt“ löschen'), findsOneWidget);
    await tippe(tester, 'vorschlag-ablehnen-v1');
    expect(c.read(bestandProvider).agentVorschlaege['v1']!.status, 'abgelehnt');
    await tester.tap(find.text('Schließen'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hinweis-vorschlaege')), findsNothing);

    // Widerrufen.
    await tippe(tester, 'nav-einstellungen');
    await tippe(tester, 'agent-widerrufen-${a.id}');
    await tester.tap(find.text('Widerrufen').last);
    await warteBis(tester, () => c.read(bestandProvider).agenten.isEmpty, grund: 'widerrufen');
    await tester.pumpAndSettle();
    expect(find.byKey(Key('agent-${a.id}')), findsNothing);
  });
}
