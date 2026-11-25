import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:personal_tracker/core/modell/einkauf.dart';
import 'package:personal_tracker/core/modell/finanzen.dart';
import 'package:personal_tracker/core/regionen/regionen.dart';
import 'package:personal_tracker/core/sitzung.dart';

import 'package:personal_tracker/ui/format.dart';

import '../hilfen.dart';
import 'app_test.dart' show appStarten, breit, direktEinrichten, schreibe, tippe, waehle;

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  testWidgets('Einkauf: Filialen mit Position, Liste, Preise mit Grundpreis, unbekannter Preis, nächste Filiale, Abschließen', (tester) async {
    final g = TestGeraet();
    final c = await appStarten(tester, g, groesse: breit);
    await direktEinrichten(tester, c);
    await tester.runAsync(() => c.read(sitzungProvider.notifier).speichereKonto(
        Konto(id: 'bar', name: 'Portemonnaie', art: KontoArt.bargeld, anfangssaldoCent: 5000, geaendert: DateTime.utc(2026))));
    await tester.pumpAndSettle();
    await tippe(tester, 'nav-einkauf');
    expect(find.text('Einkauf.'), findsOneWidget);

    // Zwei Filialen derselben Kette, eine mit Position „hier“.
    g.standort.position = (breite: 52.5200, laenge: 13.4050);
    await tippe(tester, 'filiale-neu');
    await schreibe(tester, 'filiale-kette', 'Aldi Süd');
    await schreibe(tester, 'filiale-name', 'Hauptstraße');
    await tippe(tester, 'filiale-hier');
    expect(find.textContaining('Position: 52.52000'), findsOneWidget);
    await tippe(tester, 'filiale-speichern');
    g.standort.position = (breite: 52.4000, laenge: 13.0000);
    await tippe(tester, 'filiale-neu');
    await schreibe(tester, 'filiale-kette', 'Aldi Süd');
    await schreibe(tester, 'filiale-name', 'Bahnhof');
    await tippe(tester, 'filiale-hier');
    await tippe(tester, 'filiale-speichern');
    expect(find.byKey(const Key('filiale-Hauptstraße')), findsOneWidget);
    expect(find.byKey(const Key('filiale-Bahnhof')), findsOneWidget);

    // Liste ohne Filiale; „Nächste“ wählt die Hauptstraße.
    await tippe(tester, 'liste-neu');
    await schreibe(tester, 'liste-name', 'Wocheneinkauf');
    await tippe(tester, 'liste-speichern');
    await tippe(tester, 'liste-Wocheneinkauf');
    expect(find.text('Keine Filiale gewählt'), findsOneWidget);
    g.standort.position = (breite: 52.5201, laenge: 13.4051);
    await tippe(tester, 'naechste-filiale');
    expect(find.text('Aldi Süd · Hauptstraße'), findsOneWidget);

    // Posten mit Preis (Grundpreis) und einer ohne Preis.
    await tippe(tester, 'posten-neu');
    await schreibe(tester, 'posten-name', 'Mehl');
    await schreibe(tester, 'posten-menge', '1');
    await waehle(tester, 'posten-einheit', 'kg');
    await tippe(tester, 'posten-preis');
    await schreibe(tester, 'preis-betrag', '1,49');
    await schreibe(tester, 'preis-menge', '500');
    await waehle(tester, 'preis-einheit', 'g');
    await tester.pumpAndSettle();
    expect(find.text('Grundpreis ${euro(298)} je kg'), findsOneWidget);
    await tippe(tester, 'preis-speichern');
    await tippe(tester, 'posten-neu');
    await schreibe(tester, 'posten-name', 'Safran');
    await tippe(tester, 'posten-speichern');
    expect(find.textContaining('Preis unbekannt'), findsOneWidget);
    expect(find.textContaining('Geschätzt ${euro(298)} · 1 Posten ohne Preis (nicht mitgezählt)'), findsOneWidget);

    // Mehl in den Wagen, abschließen: genau eine Buchung.
    await tippe(tester, 'posten-haken-Mehl');
    await tippe(tester, 'einkauf-abschliessen');
    expect(find.textContaining('Geschätzt aus den Preisen: ${euro(298)}'), findsOneWidget);
    await schreibe(tester, 'abschluss-betrag', '3,05');
    await waehle(tester, 'abschluss-konto', 'Portemonnaie · Bargeld');
    await tippe(tester, 'abschluss-ok');
    final b = c.read(bestandProvider);
    expect(b.saldoCent('bar'), 5000 - 305);
    expect(b.buchungen.values.single.empfaenger, 'Aldi Süd · Hauptstraße');
    expect(find.byKey(const Key('posten-Mehl')), findsNothing);
    expect(find.byKey(const Key('posten-Safran')), findsOneWidget);
    expect(find.byKey(const Key('einkauf-abschliessen')), findsNothing);

    // Standort verweigert: verständliche Meldung, nichts geändert.
    g.standort.position = null;
    await tester.pump(const Duration(seconds: 5)); // „Gebucht“-Hinweis ausblenden
    await tester.pumpAndSettle();
    await tippe(tester, 'naechste-filiale');
    expect(find.textContaining('Ohne Standortfreigabe'), findsOneWidget);
  });

  testWidgets('M10: Kette und Region aus der Liste, alte Region zuordnen, Barcode eintippen und wiedererkennen', (tester) async {
    final g = TestGeraet();
    final c = await appStarten(tester, g, groesse: breit);
    await direktEinrichten(tester, c);
    await tester.runAsync(() => c.read(regionenProvider.future));
    await tippe(tester, 'nav-einkauf');

    // Neue Filiale: Kette aus den Vorschlägen, Region über das Kfz-Kennzeichen.
    await tippe(tester, 'filiale-neu');
    await schreibe(tester, 'filiale-kette', 'lid');
    await tester.pumpAndSettle();
    await tippe(tester, 'kette-lidl');
    await schreibe(tester, 'filiale-name', 'Hafen');
    await tippe(tester, 'filiale-region');
    expect(find.byKey(const Key('region-quellen')), findsOneWidget);
    await schreibe(tester, 'region-suche', 'NWM');
    await tester.pumpAndSettle();
    await tippe(tester, 'region-13074');
    expect(find.text('Nordwestmecklenburg (Landkreis, Mecklenburg-Vorpommern)'), findsOneWidget);
    await tippe(tester, 'filiale-speichern');
    final neu = c.read(bestandProvider).filialen.values.single;
    expect([neu.kette, neu.ketteSchluessel, neu.region, neu.regionSchluessel], ['Lidl', 'lidl', 'Nordwestmecklenburg', '13074']);

    // Ältere Filiale mit frei eingetippter Region: Hinweis und Vorschlag.
    await tester.runAsync(() => c.read(sitzungProvider.notifier).speichereFiliale(
        Filiale(id: 'alt', kette: 'Dorfladen', name: 'Markt', region: 'GVM', geaendert: DateTime.utc(2026))));
    await tester.pumpAndSettle();
    expect(find.textContaining('Region „GVM“ zuordnen'), findsOneWidget);
    await tippe(tester, 'filiale-Markt');
    expect(find.textContaining('„GVM“ – bitte aus der Liste wählen'), findsOneWidget);
    await tippe(tester, 'filiale-region-vorschlag');
    await tippe(tester, 'filiale-speichern');
    final alt = c.read(bestandProvider).filialen['alt']!;
    expect([alt.region, alt.regionSchluessel, alt.ketteSchluessel], ['Nordwestmecklenburg', '13074', null]);

    // Posten mit Barcode; ein ungültiger wird abgelehnt.
    await tippe(tester, 'liste-neu');
    await schreibe(tester, 'liste-name', 'Woche');
    await tippe(tester, 'liste-speichern');
    await tippe(tester, 'liste-Woche');
    await tippe(tester, 'posten-neu');
    await schreibe(tester, 'posten-name', 'Hafermilch');
    await schreibe(tester, 'posten-ean', '4006381333932');
    await tippe(tester, 'posten-speichern');
    expect(find.textContaining('Barcode ist ungültig'), findsOneWidget);
    await schreibe(tester, 'posten-ean', '4006381333931');
    await tippe(tester, 'posten-speichern');
    expect(c.read(bestandProvider).posten.values.single.ean, '4006381333931');

    // Über den Scanner (hier: Nummer eintippen) wird der bekannte Artikel erkannt.
    await tippe(tester, 'posten-scannen-neu');
    await schreibe(tester, 'scanner-eingabe', '4006381333931');
    await tippe(tester, 'scanner-uebernehmen');
    expect(tester.widget<TextField>(find.byKey(const Key('posten-name'))).controller!.text, 'Hafermilch');
    expect(tester.widget<TextField>(find.byKey(const Key('posten-ean'))).controller!.text, '4006381333931');
  });
}
