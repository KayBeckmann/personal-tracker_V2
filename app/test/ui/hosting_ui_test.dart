import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:personal_tracker/core/sync/sync_dienst.dart';
import 'package:personal_tracker_sync/personal_tracker_sync.dart';

import '../hilfen.dart';
import '../sync_hilfen.dart';
import 'app_test.dart' show appStarten, breit, direktEinrichten, schreibe, tippe;
import 'sync_ui_test.dart' show warteBis;

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  testWidgets('Hosting vorausgewählt, eigener Server gleichwertig; Einladungscode bei Bedarf; Speicher angezeigt', (tester) async {
    final server = TestServer();
    addTearDown(server.speicher.schliessen);
    server.handler = syncHandler(server.speicher,
        k: Konfiguration(registrierung: 'einladung', maxKonto: 100 * 1024 * 1024, anmeldungenProFenster: 1000));
    final g = TestGeraet(
      name: 'h.db',
      client: server.client(),
      hosting: (url: TestServer.adresse, name: 'Test-Hosting', hinweis: 'kostenpflichtig'),
    );
    final c = await appStarten(tester, g, groesse: breit);
    final rk = await direktEinrichten(tester, c);

    await tippe(tester, 'nav-einstellungen');
    await tippe(tester, 'sync-verbinden');
    // Hosting steht vorne und ist gewählt; ohne Server-Feld.
    expect(find.text('Test-Hosting'), findsOneWidget);
    expect(find.textContaining('kostenpflichtig'), findsOneWidget);
    expect(find.byKey(const Key('sync-server')), findsNothing);
    // Eigener Server bleibt gleichwertig wählbar – und zurück.
    await tippe(tester, 'sync-eigener');
    expect(find.byKey(const Key('sync-server')), findsOneWidget);
    await tippe(tester, 'sync-hosting');
    expect(find.byKey(const Key('sync-server')), findsNothing);
    expect(c.read(syncProvider).verbunden, isFalse, reason: 'nichts passiert ohne „Verbinden“');

    await schreibe(tester, 'sync-geheim', rk);
    await tester.tap(find.byKey(const Key('sync-los')));
    await warteBis(tester, () => find.byKey(const Key('sync-einladung')).evaluate().isNotEmpty, grund: 'Einladungsfeld');
    await tester.pumpAndSettle();
    expect(find.textContaining('Einladungscode des Betreibers'), findsOneWidget);
    await schreibe(tester, 'sync-einladung', server.speicher.registrierungAnlegen());
    await tester.tap(find.byKey(const Key('sync-los')));
    await warteBis(tester, () => c.read(syncProvider).letzter != null, grund: 'verbunden');
    await tester.pumpAndSettle();
    expect(c.read(syncProvider).server, TestServer.adresse);
    expect(find.textContaining('von 100 MiB'), findsOneWidget);
  });
}
