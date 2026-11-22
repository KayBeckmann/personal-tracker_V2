import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:personal_tracker/core/kalender/vorkommen.dart';
import 'package:personal_tracker/core/modell/datum.dart';
import 'package:personal_tracker/core/modell/finanzen.dart';
import 'package:personal_tracker/core/modell/notiz.dart';
import 'package:personal_tracker/core/modell/termin.dart';
import 'package:personal_tracker/core/sitzung.dart';
import 'package:personal_tracker/ui/app.dart';
import 'package:personal_tracker/ui/format.dart';
import 'package:personal_tracker/ui/notizen/notiz_editor.dart';

import '../hilfen.dart';

const breit = Size(1280, 900);
const handy = Size(390, 844);

Future<ProviderContainer> appStarten(WidgetTester tester, TestGeraet g, {Size groesse = breit}) async {
  tester.view.physicalSize = groesse;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final (c, _) = (await tester.runAsync(g.starten))!;
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const TrackerApp()));
  await tester.pumpAndSettle();
  return c;
}

/// Richtet die Sitzung direkt ein (ohne UI) und liefert den Recovery-Schlüssel als Text.
Future<String> direktEinrichten(WidgetTester tester, ProviderContainer c, {String passwort = 'test-passwort'}) async {
  final s = c.read(sitzungProvider.notifier);
  final rk = await tester.runAsync(() async {
    final v = await s.einrichtungVorbereiten(passwort);
    await s.einrichtungAbschliessen(v.bund, v.dek);
    return v.recovery.anzeigen();
  });
  await tester.pumpAndSettle();
  return rk!;
}

Future<void> tippe(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

Future<void> schreibe(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.enterText(find.descendant(of: find.byKey(Key(key)), matching: find.byType(EditableText)).first, text);
  await tester.pump();
}

/// Wählt einen Eintrag in einem Dropdown (der letzte Treffer ist das Menü).
Future<void> waehle(WidgetTester tester, String key, String eintrag) async {
  await tippe(tester, key);
  await tester.tap(find.text(eintrag).last);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  testWidgets('Erster Start: Passwort, Recovery bestätigen, Sperren, Entsperren, Recovery', (tester) async {
    final g = TestGeraet();
    final c = await appStarten(tester, g);
    expect(find.text('Willkommen.'), findsOneWidget);

    await tippe(tester, 'neu-beginnen');
    await schreibe(tester, 'pw1', 'kurz');
    await tippe(tester, 'pw-weiter');
    expect(find.textContaining('Mindestens 8 Zeichen'), findsOneWidget);
    await schreibe(tester, 'pw1', 'mein-langes-passwort');
    await schreibe(tester, 'pw2', 'mein-langes-passwort');
    await tippe(tester, 'pw-weiter');

    final rk = tester.widget<SelectableText>(find.byKey(const Key('recovery-anzeige'))).data!;
    expect(rk, matches(RegExp(r'^(\w{4}-){7}\w{4}$')));
    expect(c.read(sitzungProvider), isA<Einrichtung>(), reason: 'erst nach Bestätigung gespeichert');
    await schreibe(tester, 'rk-kontrolle', 'XXXX');
    await tippe(tester, 'einrichtung-fertig');
    expect(find.byKey(const Key('zugang-fehler')), findsOneWidget);
    await schreibe(tester, 'rk-kontrolle', rk.split('-').last.toLowerCase());
    await tippe(tester, 'einrichtung-fertig');
    expect(find.text('Ein guter Überblick.'), findsOneWidget);
    expect(find.textContaining('Lokal & verschlüsselt'), findsWidgets);

    await tippe(tester, 'sperren');
    expect(find.text('Willkommen zurück.'), findsOneWidget);
    await schreibe(tester, 'entsperren-pw', 'falsch-falsch');
    await tippe(tester, 'entsperren');
    expect(find.text('Das Passwort stimmt nicht.'), findsOneWidget);
    await schreibe(tester, 'entsperren-pw', 'mein-langes-passwort');
    await tippe(tester, 'entsperren');
    expect(find.text('Ein guter Überblick.'), findsOneWidget);

    // Passwort vergessen → Recovery → neues Passwort.
    await tippe(tester, 'sperren');
    await tippe(tester, 'recovery-umschalten');
    await schreibe(tester, 'rk-entsperren', rk);
    await tippe(tester, 'rk-oeffnen');
    expect(find.text('Neues Passwort.'), findsOneWidget);
    await schreibe(tester, 'pw1', 'ganz-neues-passwort');
    await schreibe(tester, 'pw2', 'ganz-neues-passwort');
    await tippe(tester, 'pw-speichern');
    expect(find.text('Ein guter Überblick.'), findsOneWidget);
  });

  testWidgets('Haushaltsbuch: Konten, Ausgabe, Umbuchung, Rahmen und Übersicht', (tester) async {
    final g = TestGeraet();
    final c = await appStarten(tester, g);
    await direktEinrichten(tester, c);
    await tippe(tester, 'nav-finanzen');

    await tippe(tester, 'buchung-neu'); // ohne Konto: „Erstes Konto“
    await schreibe(tester, 'konto-name', 'Girokonto');
    await schreibe(tester, 'konto-anfang', '1.000,00');
    await tippe(tester, 'formular-speichern');
    await tippe(tester, 'konto-neu');
    await schreibe(tester, 'konto-name', 'Portemonnaie');
    await waehle(tester, 'konto-art', 'Bargeld');
    await tippe(tester, 'formular-speichern');

    await tippe(tester, 'buchung-neu');
    await schreibe(tester, 'buchung-betrag', '12,50');
    await schreibe(tester, 'buchung-empfaenger', 'Bäckerei');
    await waehle(tester, 'buchung-konto', 'Girokonto · Bank');
    await tippe(tester, 'formular-speichern');

    await tippe(tester, 'umbuchung-neu');
    await waehle(tester, 'umbuchung-von', 'Girokonto · Bank');
    await waehle(tester, 'umbuchung-nach', 'Portemonnaie · Bargeld');
    await schreibe(tester, 'umbuchung-betrag', '50');
    await tippe(tester, 'formular-speichern');

    final b = c.read(bestandProvider);
    final giro = b.konten.values.firstWhere((k) => k.name == 'Girokonto');
    final bar = b.konten.values.firstWhere((k) => k.name == 'Portemonnaie');
    expect(b.saldoCent(giro.id), 100000 - 1250 - 5000);
    expect(b.saldoCent(bar.id), 5000);
    expect(find.text(euro(100000 - 1250 - 5000)), findsOneWidget);
    expect(find.text(euro(5000)), findsWidgets);
    expect(find.text('Girokonto › Portemonnaie'), findsOneWidget);

    await tippe(tester, 'rahmen-setzen');
    await schreibe(tester, 'rahmen-betrag', '500');
    await tippe(tester, 'rahmen-ok');
    expect(c.read(bestandProvider).einstellungen.ausgabenrahmenCent, 50000);
    expect(find.textContaining('Rahmen ${euro(50000, ganz: true)}'), findsOneWidget);
    expect(find.textContaining('noch keine Schätzung'), findsOneWidget, reason: 'kein abgeschlossener Monat');

    await tippe(tester, 'nav-uebersicht');
    expect(tester.widget<Text>(find.byKey(const Key('geld-gebucht'))).data, euro(1250), reason: 'Umbuchung ist keine Ausgabe');
  });

  testWidgets('Notizen auf dem Handy: anlegen, Vorschau, Suche, ungespeichert verlassen', (tester) async {
    final g = TestGeraet();
    final c = await appStarten(tester, g, groesse: handy);
    await direktEinrichten(tester, c);
    await tippe(tester, 'nav-notizen');
    await tippe(tester, 'notiz-neu');
    await schreibe(tester, 'notiz-titel', 'Garten');
    await schreibe(tester, 'notiz-text', '# Ideen\n\n- Hochbeet bauen');
    await tippe(tester, 'notiz-speichern');
    await tester.tap(find.text('Vorschau'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('notiz-vorschau')), matching: find.textContaining('Hochbeet bauen')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Garten'), findsOneWidget);
    expect(c.read(bestandProvider).notizen.values.single.text, '# Ideen\n\n- Hochbeet bauen');

    await schreibe(tester, 'notiz-suche', 'hochbeet');
    expect(find.text('Garten'), findsOneWidget);
    await schreibe(tester, 'notiz-suche', 'xyz');
    expect(find.text('Keine Notiz passt zur Suche.'), findsOneWidget);
    await schreibe(tester, 'notiz-suche', '');

    await tester.tap(find.text('Garten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bearbeiten'));
    await tester.pumpAndSettle();
    await schreibe(tester, 'notiz-text', 'geändert');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tippe(tester, 'bestaetigen-ja');
    expect(c.read(bestandProvider).notizen.values.single.text, '# Ideen\n\n- Hochbeet bauen');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Termin mit Wiederholung: im Kalender, nur heutiges Vorkommen löschen', (tester) async {
    final g = TestGeraet();
    final c = await appStarten(tester, g);
    await direktEinrichten(tester, c);
    await tippe(tester, 'nav-termine');
    await tippe(tester, 'termin-neu');
    await schreibe(tester, 'termin-titel', 'Yoga');
    await waehle(tester, 'termin-wiederholung', 'wöchentlich');
    await tippe(tester, 'termin-speichern');

    final t = c.read(bestandProvider).termine.values.single;
    expect(t.wiederholung!.rhythmus, Rhythmus.woechentlich);
    final heute = tagVon(DateTime.now());
    final schluessel = 'vorkommen-${t.id}-${tagIso(heute)}';
    expect(find.byKey(Key(schluessel)), findsOneWidget);

    await tippe(tester, schluessel);
    await tippe(tester, 'vorkommen-loeschen-einzeln');
    expect(find.byKey(Key(schluessel)), findsNothing);
    final rest = c.read(bestandProvider).termine.values.single;
    expect(rest.ausnahmen, {tagIso(heute)});
    expect(vorkommenIm(rest, heute.add(const Duration(days: 7)), heute.add(const Duration(days: 7))), hasLength(1));
  });

  testWidgets('Sicherung über die Oberfläche: erstellen und auf neuem Gerät einlesen', (tester) async {
    final alt = TestGeraet();
    final c1 = await appStarten(tester, alt);
    final rk = await direktEinrichten(tester, c1);
    final s = c1.read(sitzungProvider.notifier);
    final jetzt = DateTime.now().toUtc();
    await tester.runAsync(() async {
      await s.speichereNotiz(Notiz(id: 'n1', titel: 'Wichtig', text: 'Inhalt', erstellt: jetzt, geaendert: jetzt));
      await s.speichereKonto(Konto(id: 'k1', name: 'Giro', art: KontoArt.bank, geaendert: jetzt));
      await s.speichereBuchung(Buchung(id: 'b1', kontoId: 'k1', datum: DateTime.now(), empfaenger: 'Laden', betragCent: -999, status: BuchungsStatus.gebucht, geaendert: jetzt));
      await s.speichereTermin(Termin(id: 't1', titel: 'Arzt', beginn: DateTime.now(), geaendert: jetzt));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hinweis-sicherung')), findsOneWidget, reason: 'Daten ohne Sicherung');
    await tippe(tester, 'nav-einstellungen');
    await tippe(tester, 'sicherung-erstellen');
    expect(alt.dateien.gespeichert, hasLength(1));
    expect(find.textContaining('Letzte Sicherung:'), findsOneWidget);
    final datei = alt.dateien.gespeichert.values.single;

    // Neues Gerät.
    await tester.pumpWidget(const SizedBox());
    final neu = TestGeraet();
    final c2 = await appStarten(tester, neu);
    await tippe(tester, 'aus-sicherung');
    neu.dateien.zumOeffnen = (name: 'sicherung.ptbackup', bytes: datei);
    await tippe(tester, 'sicherung-waehlen');
    expect(find.textContaining('Sicherung vom'), findsOneWidget);
    await schreibe(tester, 'rk-eingabe', 'AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA');
    await tippe(tester, 'sicherung-pruefen');
    expect(find.text('Dieser Recovery-Schlüssel gehört nicht zu dieser Sicherung.'), findsOneWidget);
    await schreibe(tester, 'rk-eingabe', rk);
    await tippe(tester, 'sicherung-pruefen');
    expect(find.byKey(const Key('sicherung-vorschau')), findsOneWidget);
    await schreibe(tester, 'pw1', 'neues-geraet-pw');
    await schreibe(tester, 'pw2', 'neues-geraet-pw');
    await tippe(tester, 'sicherung-uebernehmen');
    expect(find.text('Ein guter Überblick.'), findsOneWidget);
    final b = c2.read(bestandProvider);
    expect(b.notizen['n1']!.text, 'Inhalt');
    expect(b.saldoCent('k1'), -999);
    expect(b.termine.keys, ['t1']);
  });

  testWidgets('Sperren schließt offene Seiten (keine Daten über dem Sperrbildschirm)', (tester) async {
    final g = TestGeraet();
    final c = await appStarten(tester, g, groesse: handy);
    await direktEinrichten(tester, c);
    await tippe(tester, 'nav-notizen');
    await tippe(tester, 'notiz-neu');
    expect(find.byType(NotizEditor), findsOneWidget);
    await tester.runAsync(() => c.read(sitzungProvider.notifier).sperren());
    await tester.pumpAndSettle();
    expect(find.byType(NotizEditor), findsNothing);
    expect(find.text('Willkommen zurück.'), findsOneWidget);
  });

  for (final (name, groesse) in [('klein', const Size(360, 640)), ('Tablet', const Size(900, 1200)), ('breit', const Size(1600, 1000))]) {
    testWidgets('Alle Bereiche ohne Layoutfehler ($name)', (tester) async {
      final g = TestGeraet();
      final c = await appStarten(tester, g, groesse: groesse);
      await direktEinrichten(tester, c);
      final s = c.read(sitzungProvider.notifier);
      final jetzt = DateTime.now();
      await tester.runAsync(() async {
        await s.speichereKonto(Konto(id: 'k1', name: 'Girokonto mit sehr langem Namen', art: KontoArt.bank, anfangssaldoCent: 123456789, geaendert: jetzt));
        await s.speichereKonto(Konto(id: 'k2', name: 'Bar', art: KontoArt.bargeld, geaendert: jetzt));
        await s.speicherePlan(Plan(id: 'p1', kontoId: 'k1', empfaenger: 'Miete', betragCent: -85000, tag: 1, ab: monatVon(jetzt), geaendert: jetzt));
        await s.speichereBuchung(Buchung(id: 'b1', kontoId: 'k1', datum: jetzt, empfaenger: 'Supermarkt am Marktplatz', betragCent: -4599, status: BuchungsStatus.gebucht, geaendert: jetzt));
        await s.umbuchen(vonKonto: 'k1', nachKonto: 'k2', betragCent: 2000, datum: jetzt);
        await s.speichereTermin(Termin(id: 't1', titel: 'Ein ziemlich langer Termintitel für die Ansicht', beginn: jetzt, ort: 'Rathaus', erinnerungMinuten: 15, wiederholung: const Wiederholung(Rhythmus.taeglich), geaendert: jetzt));
        await s.speichereNotiz(Notiz(id: 'n1', titel: '', text: '# Überschrift\nText', erstellt: jetzt, geaendert: jetzt));
      });
      await tester.pumpAndSettle();
      for (final bereich in ['uebersicht', 'termine', 'notizen', 'finanzen', 'einstellungen']) {
        await tippe(tester, 'nav-$bereich');
        final fehler = tester.takeException();
        expect(fehler, isNull, reason: '$bereich: ${fehler is FlutterError ? fehler.toStringDeep() : fehler}');
      }
    });
  }
}
