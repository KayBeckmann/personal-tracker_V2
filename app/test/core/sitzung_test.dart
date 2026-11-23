import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/krypto/recovery_schluessel.dart';
import 'package:personal_tracker/core/modell/aufgabe.dart';
import 'package:personal_tracker/core/modell/datum.dart';
import 'package:personal_tracker/core/modell/finanzen.dart';
import 'package:personal_tracker/core/modell/notiz.dart';
import 'package:personal_tracker/core/modell/termin.dart';
import 'package:personal_tracker/core/sitzung.dart';
import 'package:personal_tracker/core/speicher/backup.dart';
import 'package:personal_tracker/core/speicher/schema.dart';
import 'package:sembast/sembast.dart';

import '../hilfen.dart';

/// Legt synthetische Daten an: Termin, Notiz, zwei Konten, Buchung,
/// Umbuchung, Plan. Liefert den Recovery-Schlüssel.
Future<RecoverySchluessel> einrichtenMitDaten(SitzungNotifier s) async {
  final v = await s.einrichtungVorbereiten('passwort-1');
  await s.einrichtungAbschliessen(v.bund, v.dek);
  final t = DateTime.utc(2026);
  await s.speichereTermin(Termin(
    id: 't1',
    titel: 'Zahnarzt',
    beginn: DateTime(2026, 11, 23, 9, 30),
    ende: DateTime(2026, 11, 23, 10),
    wiederholung: const Wiederholung(Rhythmus.monatlich),
    erinnerungMinuten: 15,
    geaendert: t,
  ));
  await s.speichereNotiz(Notiz(id: 'n1', titel: 'Garten', text: '# Ideen\n- Hochbeet', erstellt: t, geaendert: t));
  await s.speichereKonto(Konto(id: 'giro', name: 'Giro', art: KontoArt.bank, anfangssaldoCent: 100000, geaendert: t));
  await s.speichereKonto(Konto(id: 'bar', name: 'Portemonnaie', art: KontoArt.bargeld, geaendert: t));
  await s.speichereBuchung(Buchung(
    id: 'b1',
    kontoId: 'giro',
    datum: DateTime(2026, 11, 5),
    empfaenger: 'Bäckerei',
    betragCent: -450,
    status: BuchungsStatus.gebucht,
    geaendert: t,
  ));
  await s.umbuchen(vonKonto: 'giro', nachKonto: 'bar', betragCent: 5000, datum: DateTime(2026, 11, 6));
  await s.speicherePlan(Plan(id: 'p1', kontoId: 'giro', empfaenger: 'Miete', betragCent: -85000, tag: 1, ab: monatVon(DateTime(2026, 11)), geaendert: t));
  await s.speichereAufgabe(Aufgabe(
    id: 'a1',
    titel: 'Mülltonne raus',
    faellig: DateTime(2026, 11, 23),
    erinnerungUm: 19 * 60,
    prioritaet: Prioritaet.hoch,
    wiederholung: const Wiederholung(Rhythmus.woechentlich),
    geaendert: t,
  ));
  return v.recovery;
}

void main() {
  test('Einrichten, Neustart, Entsperren: alles bleibt, Klartext nie in der DB', () async {
    final g = TestGeraet();
    var (c, ablage) = await g.starten();
    expect(c.read(sitzungProvider), isA<Einrichtung>());
    final r = await einrichtenMitDaten(c.read(sitzungProvider.notifier));
    final vorher = c.read(bestandProvider);
    expect(vorher.saldoCent('giro'), 100000 - 450 - 5000);
    expect(vorher.saldoCent('bar'), 5000);
    expect(g.erinnerungen.geplant, isNotEmpty);

    // Rohdaten der Datenbank: kein Klartext.
    final dump = jsonEncode([
      for (final store in ['termine', 'aufgaben', 'notizen', 'konten', 'buchungen', 'plaene'])
        for (final rec in await StoreRef<String, Object?>(store).find(ablage.db)) rec.value,
    ]);
    for (final wort in ['Zahnarzt', 'Mülltonne', 'Hochbeet', 'Bäckerei', 'Portemonnaie', 'Miete', '85000']) {
      expect(dump, isNot(contains(wort)));
    }

    await c.read(sitzungProvider.notifier).sperren();
    expect(c.read(sitzungProvider), isA<Gesperrt>());
    expect(g.erinnerungen.beendet, 1);
    c.dispose();
    await ablage.schliessen();

    // Neustart.
    (c, ablage) = await g.starten();
    final s = c.read(sitzungProvider.notifier);
    expect(c.read(sitzungProvider), isA<Gesperrt>());
    expect(await s.entsperren('falsch'), isFalse);
    expect(await s.entsperren('passwort-1'), isTrue);
    final nachher = c.read(bestandProvider);
    expect(jsonEncode(nachher.termine['t1']!.toJson()), jsonEncode(vorher.termine['t1']!.toJson()));
    expect(nachher.notizen['n1']!.text, '# Ideen\n- Hochbeet');
    expect(nachher.buchungen.values.where((b) => b.istUmbuchung), hasLength(2));
    expect(nachher.gegenbuchung(nachher.buchungen.values.firstWhere((b) => b.istUmbuchung && b.betragCent < 0))!.kontoId, 'bar');
    expect(nachher.saldoCent('giro'), vorher.saldoCent('giro'));

    // Recovery statt Passwort → neues Passwort erzwungen.
    await s.sperren();
    expect(await s.entsperrenMitRecovery(RecoverySchluessel.neu()), isFalse);
    expect(await s.entsperrenMitRecovery(r), isTrue);
    expect((c.read(sitzungProvider) as Entsperrt).neuesPasswortNoetig, isTrue);
    await s.neuesPasswort('passwort-2');
    await s.sperren();
    expect(await s.entsperren('passwort-1'), isFalse);
    expect(await s.entsperren('passwort-2'), isTrue);
  });

  test('Backup in frische Installation, falscher Schlüssel, Ersetzen', () async {
    final alt = TestGeraet();
    final (c1, _) = await alt.starten();
    final s1 = c1.read(sitzungProvider.notifier);
    final r = await einrichtenMitDaten(s1);
    final datei = s1.sicherungErstellen();
    await s1.sicherungVermerken();
    expect(c1.read(bestandProvider).einstellungen.letzteSicherung, isNotNull);

    // Frische Installation (anderes Gerät).
    final neu = TestGeraet();
    final (c2, _) = await neu.starten();
    expect(() => SitzungNotifier.sicherungPruefen(datei, RecoverySchluessel.neu()), throwsA(isA<BackupFehler>()));
    final geprueft = SitzungNotifier.sicherungPruefen(datei, r);
    expect(geprueft.inhalt.anzahl('buchungen'), 3);
    final s2 = c2.read(sitzungProvider.notifier);
    await s2.wiederherstellenNeu(geprueft.bestand, r, 'neues-geraet');
    final b2 = c2.read(bestandProvider);
    final b1 = c1.read(bestandProvider);
    expect(b2.termine.keys, b1.termine.keys);
    expect(b2.notizen['n1']!.text, b1.notizen['n1']!.text);
    expect(b2.saldoCent('giro'), b1.saldoCent('giro'));
    expect(b2.saldoCent('bar'), b1.saldoCent('bar'));
    expect(b2.plaene.keys, ['p1']);
    expect(jsonEncode(b2.aufgaben['a1']!.toJson()), jsonEncode(b1.aufgaben['a1']!.toJson()));

    // Neustart des neuen Geräts: neues Passwort gilt, Recovery bleibt derselbe.
    c2.dispose();
    final (c3, _) = await neu.starten();
    final s3 = c3.read(sitzungProvider.notifier);
    expect(await s3.entsperren('neues-geraet'), isTrue);
    await s3.sperren();
    expect(await s3.entsperrenMitRecovery(r), isTrue);

    // Ersetzen in einer laufenden Installation mit eigenen Daten.
    final dritt = TestGeraet();
    final (c4, _) = await dritt.starten();
    final s4 = c4.read(sitzungProvider.notifier);
    final v = await s4.einrichtungVorbereiten('pw-dritt');
    await s4.einrichtungAbschliessen(v.bund, v.dek);
    await s4.speichereNotiz(Notiz(id: 'eigene', titel: 'weg', text: '', erstellt: DateTime.utc(2026), geaendert: DateTime.utc(2026)));
    await s4.wiederherstellenErsetzen(geprueft.bestand, r);
    expect(c4.read(bestandProvider).notizen.keys, ['n1']);
    await s4.sperren();
    expect(await s4.entsperren('pw-dritt'), isTrue, reason: 'Passwort bleibt');
    await s4.sperren();
    expect(await s4.entsperrenMitRecovery(r), isTrue, reason: 'Recovery der Sicherung gilt jetzt');
    expect(await (() async { await s4.sperren(); return s4.entsperrenMitRecovery(v.recovery); })(), isFalse);
  });

  test('Fingerabdruck: einrichten, abbrechen, abschalten', () async {
    final g = TestGeraet();
    final (c, _) = await g.starten();
    final s = c.read(sitzungProvider.notifier);
    await einrichtenMitDaten(s);
    await s.biometrieSetzen(true);
    await s.sperren();
    g.biometrie.abbrechen = true;
    expect(await s.entsperrenMitBiometrie(), isFalse);
    g.biometrie.abbrechen = false;
    expect(await s.entsperrenMitBiometrie(), isTrue);
    await s.biometrieSetzen(false);
    expect(g.biometrie.gespeichert, isNull);
    await s.sperren();
    expect(await s.entsperrenMitBiometrie(), isFalse);
  });

  test('Umbuchung bearbeiten und löschen: immer beide Hälften', () async {
    final g = TestGeraet();
    final (c, _) = await g.starten();
    final s = c.read(sitzungProvider.notifier);
    await einrichtenMitDaten(s);
    final uid = c.read(bestandProvider).buchungen.values.firstWhere((b) => b.istUmbuchung).umbuchungId!;
    await s.umbuchen(umbuchungId: uid, vonKonto: 'giro', nachKonto: 'bar', betragCent: 7000, datum: DateTime(2026, 11, 7));
    final b = c.read(bestandProvider);
    expect(b.buchungen.values.where((x) => x.umbuchungId == uid), hasLength(2));
    expect(b.saldoCent('bar'), 7000);
    await s.loescheBuchung(b.buchungen.values.firstWhere((x) => x.umbuchungId == uid).id);
    expect(c.read(bestandProvider).buchungen.values.where((x) => x.istUmbuchung), isEmpty);
    expect(s.kontoLoeschbar('bar'), isTrue);
    expect(s.kontoLoeschbar('giro'), isFalse);
  });

  test('Aufgabe abhaken, rückgängig machen, löschen', () async {
    final g = TestGeraet()..jetzt = DateTime(2026, 11, 23, 20);
    final (c, _) = await g.starten();
    final s = c.read(sitzungProvider.notifier);
    await einrichtenMitDaten(s);
    final vorher = await s.aufgabeAbschliessen('a1');
    var a = c.read(bestandProvider).aufgaben['a1']!;
    expect(a.faellig, DateTime(2026, 11, 30));
    expect(a.verlauf, hasLength(1));
    expect(g.erinnerungen.geplant.last.aufgaben['a1']!.faellig, DateTime(2026, 11, 30), reason: 'Erinnerung neu geplant');
    await s.speichereAufgabe(vorher!);
    a = c.read(bestandProvider).aufgaben['a1']!;
    expect(a.faellig, DateTime(2026, 11, 23));
    expect(a.verlauf, isEmpty);
    await s.loescheAufgabe('a1');
    expect(c.read(bestandProvider).aufgaben, isEmpty);
  });

  test('Update: lokaler M1-Bestand (Schema 1) wird beim Entsperren angehoben', () async {
    final g = TestGeraet();
    var (c, ablage) = await g.starten();
    final s = c.read(sitzungProvider.notifier);
    await einrichtenMitDaten(s);
    await s.loescheAufgabe('a1');
    await ablage.setzeMeta(SitzungNotifier.metaSchema, 1);
    c.dispose();
    await ablage.schliessen();

    (c, ablage) = await g.starten();
    expect(await c.read(sitzungProvider.notifier).entsperren('passwort-1'), isTrue);
    expect(await ablage.meta(SitzungNotifier.metaSchema), aktuellesSchema);
    final b = c.read(bestandProvider);
    expect(b.notizen['n1']!.text, '# Ideen\n- Hochbeet');
    expect(b.saldoCent('bar'), 5000);
    expect(b.aufgaben, isEmpty);
    await c.read(sitzungProvider.notifier).speichereAufgabe(Aufgabe(id: 'neu', titel: 'Nach Update', geaendert: DateTime.utc(2026)));
    expect(c.read(bestandProvider).aufgaben.keys, ['neu']);
  });

  test('Zurücksetzen löscht alles', () async {
    final g = TestGeraet();
    final (c, ablage) = await g.starten();
    final s = c.read(sitzungProvider.notifier);
    await einrichtenMitDaten(s);
    await s.zuruecksetzen();
    expect(c.read(sitzungProvider), isA<Einrichtung>());
    expect(await ablage.meta(SitzungNotifier.metaBund), isNull);
    expect(await StoreRef<String, Object?>('notizen').count(ablage.db), 0);
  });
}
