import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:personal_tracker/core/modell/notiz.dart';
import 'package:personal_tracker/core/sitzung.dart';
import 'package:personal_tracker/core/sync/sync_dienst.dart';

import '../hilfen.dart';
import '../sync_hilfen.dart';
import 'app_test.dart' show appStarten, breit, direktEinrichten, handy, schreibe, tippe;

/// Wartet (mit echter Zeit für Netz und Datenbank), bis [bedingung] gilt.
Future<void> warteBis(WidgetTester tester, bool Function() bedingung, {String grund = ''}) async {
  for (var i = 0; i < 200; i++) {
    if (bedingung()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('Zeitüberschreitung: $grund');
}

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  testWidgets('Sync über die Oberfläche: verbinden, koppeln, Konflikt lösen, trennen', (tester) async {
    final server = TestServer();
    addTearDown(server.speicher.schliessen);

    // Gerät A (Browser, breit): Daten anlegen und verbinden.
    final a = TestGeraet(name: 'a.db', client: server.client());
    final ca = await appStarten(tester, a, groesse: breit);
    final rk = await direktEinrichten(tester, ca);
    final t = DateTime.now().toUtc();
    await tester.runAsync(() => ca.read(sitzungProvider.notifier).speichereNotiz(Notiz(id: 'n1', titel: 'Einkauf', text: 'Milch', erstellt: t, geaendert: t)));
    await tester.pumpAndSettle();

    await tippe(tester, 'nav-einstellungen');
    expect(find.text('Optional synchronisieren'), findsOneWidget);
    await tippe(tester, 'sync-verbinden');
    expect(find.textContaining('1 Datensätze auf diesem Gerät'), findsOneWidget);
    await schreibe(tester, 'sync-server', 'http://sync.example.org');
    await schreibe(tester, 'sync-geheim', rk);
    await tippe(tester, 'sync-los');
    expect(find.textContaining('HTTPS-Adresse'), findsOneWidget);
    await schreibe(tester, 'sync-server', TestServer.adresse);
    await tester.tap(find.byKey(const Key('sync-los')));
    await warteBis(tester, () => ca.read(syncProvider).letzter != null, grund: 'erster Abgleich A');
    await tester.pumpAndSettle();
    expect(find.text('Synchronisieren'), findsOneWidget);
    expect(find.byKey(const Key('seitenleiste-sync')), findsOneWidget);
    expect(server.dump(), isNot(contains('Milch')));

    await tippe(tester, 'sync-geraet-hinzufuegen');
    await warteBis(tester, () => find.byKey(const Key('kopplung-code')).evaluate().isNotEmpty, grund: 'Kopplungscode');
    final code = tester.widget<SelectableText>(find.byKey(const Key('kopplung-code'))).data!;
    await tippe(tester, 'kopplung-fertig');

    // Gerät B (Handy, frisch): per Code koppeln.
    await tester.pumpWidget(const SizedBox());
    final b = TestGeraet(name: 'b.db', client: server.client());
    final cb = await appStarten(tester, b, groesse: handy);
    await tippe(tester, 'mit-geraet-verbinden');
    await schreibe(tester, 'sync-server', TestServer.adresse);
    await schreibe(tester, 'sync-geheim', code.toLowerCase());
    await schreibe(tester, 'sync-pw1', 'passwort-handy');
    await schreibe(tester, 'sync-pw2', 'passwort-handy');
    await tester.tap(find.byKey(const Key('sync-los')));
    await warteBis(tester, () => cb.read(bestandProvider).notizen.containsKey('n1'), grund: 'Daten auf B');
    await tester.pumpAndSettle();
    expect(find.text('Ein guter Überblick.'), findsOneWidget);
    expect(find.textContaining('Der Sync ersetzt keine Sicherung'), findsOneWidget);

    // Gleichzeitig geändert: B sieht den Konflikt und übernimmt seine Fassung.
    await tester.runAsync(() async {
      final n = ca.read(bestandProvider).notizen['n1']!;
      await ca.read(sitzungProvider.notifier).speichereNotiz(n.kopie(text: 'Milch und Brot'));
      await cb.read(sitzungProvider.notifier).speichereNotiz(n.kopie(text: 'Hafermilch'));
      await ca.read(syncProvider.notifier).abgleichen();
      await cb.read(syncProvider.notifier).abgleichen();
    });
    await tester.pumpAndSettle();
    expect(cb.read(bestandProvider).notizen['n1']!.text, 'Milch und Brot');
    expect(find.byKey(const Key('hinweis-konflikte')), findsOneWidget);
    await tippe(tester, 'konflikte-ansehen');
    expect(find.textContaining('Andere Fassung: Hafermilch'), findsOneWidget);
    final id = cb.read(bestandProvider).konflikte.keys.single;
    await tester.tap(find.byKey(Key('konflikt-uebernehmen-$id')));
    await warteBis(tester, () => cb.read(bestandProvider).konflikte.isEmpty, grund: 'Konflikt gelöst');
    await tester.pumpAndSettle();
    expect(cb.read(bestandProvider).notizen['n1']!.text, 'Hafermilch');
    expect(find.text('Keine Konflikte — alles abgeglichen.'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // Trennen: Daten bleiben, kein Sync mehr.
    await tippe(tester, 'nav-einstellungen');
    await tippe(tester, 'sync-trennen');
    await tester.tap(find.byKey(const Key('sync-trennen-ok')));
    await warteBis(tester, () => !cb.read(syncProvider).verbunden, grund: 'getrennt');
    await tester.pumpAndSettle();
    expect(find.text('Optional synchronisieren'), findsOneWidget);
    expect(cb.read(bestandProvider).notizen['n1']!.text, 'Hafermilch');
    // Ersetzendes Einlesen einer Sicherung ist mit Sync gesperrt, jetzt wieder frei.
    expect(cb.read(sitzungProvider.notifier).syncAktiv, isFalse);
  });
}
