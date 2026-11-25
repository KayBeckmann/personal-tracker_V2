import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:personal_tracker/core/krypto/recovery_schluessel.dart';
import 'package:personal_tracker/core/modell/termin.dart';
import 'package:personal_tracker/core/sitzung.dart';
import 'package:personal_tracker/core/sync/sync_dienst.dart';

import '../hilfen.dart';
import '../sync_hilfen.dart';
import 'app_test.dart' show appStarten, breit, direktEinrichten, schreibe, tippe;
import 'sync_ui_test.dart' show warteBis;

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  testWidgets('Freigaben über die Oberfläche: Kalender teilen, Einladung annehmen, nur lesen, entfernen', (tester) async {
    final server = TestServer();
    addTearDown(server.speicher.schliessen);

    // Kay: verbinden, Namen setzen, Kalender teilen, Lena einladen (nur lesen).
    final kay = TestGeraet(name: 'kay.db', client: server.client());
    final ck = await appStarten(tester, kay, groesse: breit);
    final rkKay = await direktEinrichten(tester, ck);
    await tester.runAsync(() => ck.read(syncProvider.notifier).verbinden(server: TestServer.adresse, recovery: RecoverySchluessel.lesen(rkKay)!, geraetName: 'Laptop'));
    await tester.pumpAndSettle();
    await tippe(tester, 'nav-freigaben');
    expect(find.text('Noch nichts geteilt.'), findsOneWidget);
    await tippe(tester, 'freigabe-name-aendern');
    await schreibe(tester, 'freigabe-name-feld', 'Kay');
    await tippe(tester, 'freigabe-name-ok');
    expect(find.text('Andere sehen dich als „Kay“.'), findsOneWidget);
    await tippe(tester, 'freigabe-neu');
    await schreibe(tester, 'freigabe-titel', 'Familie');
    await tester.tap(find.byKey(const Key('freigabe-anlegen')));
    await warteBis(tester, () => ck.read(bestandProvider).raeume.isNotEmpty, grund: 'Raum angelegt');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('raum-Familie')), findsOneWidget);
    await tippe(tester, 'einladen-Familie');
    await tester.tap(find.byKey(const Key('einladen-lesen')));
    await warteBis(tester, () => find.byKey(const Key('einladung-anzeige')).evaluate().isNotEmpty, grund: 'Code');
    final code = tester.widget<SelectableText>(find.byKey(const Key('einladung-anzeige'))).data!;
    await tippe(tester, 'einladung-fertig');
    expect(find.text('1 offene Einladung(en).'), findsOneWidget);
    final raumId = ck.read(bestandProvider).raeume.keys.single;
    await tester.runAsync(() => ck.read(sitzungProvider.notifier).speichereTermin(
        Termin(id: 'geteilt-1', titel: 'Laternenumzug', beginn: DateTime(2026, 11, 11, 17), geaendert: DateTime.utc(2026), raum: raumId)));
    await tester.runAsync(() => ck.read(syncProvider.notifier).abgleichen());

    // Lena: eigenes Konto, nimmt per Code an und sieht den Termin nur lesend.
    await tester.pumpWidget(const SizedBox());
    final lena = TestGeraet(name: 'lena.db', client: server.client());
    final cl = await appStarten(tester, lena, groesse: breit);
    final rkLena = await direktEinrichten(tester, cl);
    await tester.runAsync(() async {
      final s = cl.read(sitzungProvider.notifier);
      await s.speichereEinstellungen(cl.read(bestandProvider).einstellungen.kopie(anzeigeName: 'Lena'));
      await cl.read(syncProvider.notifier).verbinden(server: TestServer.adresse, recovery: RecoverySchluessel.lesen(rkLena)!, geraetName: 'Handy');
    });
    await tester.pumpAndSettle();
    await tippe(tester, 'nav-freigaben');
    await tippe(tester, 'einladung-annehmen');
    await schreibe(tester, 'einladung-code', code.toLowerCase());
    await tester.tap(find.byKey(const Key('einladung-ok')));
    await warteBis(tester, () => cl.read(bestandProvider).termine.containsKey('geteilt-1'), grund: 'geteilter Termin');
    await tester.pumpAndSettle();
    expect(find.text('Von Kay'), findsOneWidget);
    expect(find.text('Kalender · nur lesen'), findsOneWidget);
    // Im Kalender: markiert und ohne Bearbeiten.
    await tippe(tester, 'nav-termine');
    final t = cl.read(bestandProvider).termine['geteilt-1']!;
    expect(t.raum, raumId);

    // Kay sieht Lena und entfernt sie wieder.
    await tester.pumpWidget(const SizedBox());
    final ck2 = await appStarten(tester, kay, groesse: breit);
    await tester.runAsync(() => ck2.read(sitzungProvider.notifier).entsperren('test-passwort'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => ck2.read(syncProvider.notifier).abgleichen());
    await tester.pumpAndSettle();
    await tippe(tester, 'nav-freigaben');
    expect(find.byKey(const Key('mitglied-Lena')), findsOneWidget);
    expect(find.text('nur lesen'), findsOneWidget);
    await tippe(tester, 'mitglied-entfernen-Lena');
    await tester.tap(find.byKey(const Key('bestaetigen-ja')));
    await warteBis(tester, () => ck2.read(bestandProvider).raeume.values.single.mitglieder.isEmpty, grund: 'entfernt');
    await tester.pumpAndSettle();
    expect(find.text('Noch niemand dabei.'), findsOneWidget);
    expect(ck2.read(bestandProvider).raeume.values.single.epoche, 2);
  });
}
