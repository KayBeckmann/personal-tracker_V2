import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/modell/termin.dart';
import 'package:personal_tracker/core/raeume/raum.dart';
import 'package:personal_tracker/core/raeume/raum_dienst.dart';
import 'package:personal_tracker/core/sync/sync_krypto.dart';
import 'package:personal_tracker/core/vault/vault_datei.dart';
import 'package:personal_tracker/core/vault/vault_dienst.dart';

import '../sync_hilfen.dart';
import 'sitzung_test.dart' show einrichtenMitDaten;
import 'sync_test.dart' show Geraet;

Uint8List t(String s) => Uint8List.fromList(utf8.encode(s));

/// Eine Person mit eigenem Konto und Gerät.
class Person {
  Person(this.g);
  final Geraet g;

  RaumDienst get raeume => g.c.read(raumDienstProvider);
  VaultNotifier get v => g.c.read(vaultProvider.notifier);
  List<String> get pfade => [for (final d in g.c.read(vaultProvider).dateien) d.pfad];
  VaultDatei? an(String pfad) => g.c.read(vaultProvider).dateien.where((d) => d.pfad == pfad).firstOrNull;
  Raum raum(String name) => g.b.raeume.values.firstWhere((r) => r.name == name);
  Iterable<Termin> geteilt(String raum) => g.b.termine.values.where((x) => x.raum == raum);

  Future<void> sync() async {
    await g.abgleichen();
    await v.laden();
  }
}

Termin termin(String id, String titel, {String? raum}) =>
    Termin(id: id, titel: titel, beginn: DateTime(2026, 12, 1, 18), geaendert: DateTime.utc(2026, 11, 25), raum: raum);

void main() {
  late TestServer server;
  setUp(() => server = TestServer());
  tearDown(() => server.speicher.schliessen());

  Future<Person> person(String name) async {
    final g = await Geraet(server, name).start();
    g.c.listen(vaultProvider, (_, _) {});
    final r = await einrichtenMitDaten(g.s);
    await g.s.speichereEinstellungen(g.b.einstellungen.kopie(anzeigeName: name));
    await g.sync.verbinden(server: TestServer.adresse, recovery: r, geraetName: '$name-Handy');
    await g.ruhig();
    return Person(g);
  }

  Future<void> einladenUndAnnehmen(Person eig, Raum r, Person gast, String recht, {String? ordner}) async {
    final (:code, bis: _) = await eig.raeume.einladen(r, recht);
    await gast.raeume.annehmen(code.anzeigen().toLowerCase(), ordner: ordner);
    await eig.sync();
  }

  test('Geteilter Kalender: Schreib- und Leserecht, privat bleibt privat, Widerruf mit neuem Schlüssel', () async {
    final kay = await person('Kay');
    final lena = await person('Lena');
    final tim = await person('Tim');
    final fam = await kay.raeume.anlegen(art: RaumArt.kalender, name: 'Familie');
    await einladenUndAnnehmen(kay, fam, lena, 'schreiben');
    await einladenUndAnnehmen(kay, kay.raum('Familie'), tim, 'lesen');
    expect(kay.raum('Familie').mitglieder.map((m) => '${m.name}:${m.recht}'), ['Lena:schreiben', 'Tim:lesen']);

    await kay.g.s.speichereTermin(termin('fest-1', 'Weihnachtsessen', raum: fam.id));
    await kay.sync();
    await lena.sync();
    await tim.sync();
    expect(lena.geteilt(fam.id).map((x) => x.titel), ['Weihnachtsessen']);
    expect(tim.geteilt(fam.id).map((x) => x.titel), ['Weihnachtsessen']);
    // Mitglieder sehen, wer dabei ist; ihre privaten Termine bleiben getrennt.
    expect(tim.raum('Familie').von, 'Kay');
    expect(tim.raum('Familie').mitgliederNamen.map((m) => m.name), ['Lena', 'Tim']);
    expect(lena.g.b.termine['t1']!.raum, isNull);
    expect(lena.g.b.termine.values.where((x) => x.titel == 'Zahnarzt'), hasLength(1));

    // Schreiben: Lena ändert, Kay bekommt es. Tim (nur lesen) wird nicht gesendet.
    await lena.g.s.speichereTermin(lena.g.b.termine['fest-1']!.kopie(titel: 'Weihnachtsessen bei Oma'));
    await lena.sync();
    // Mit Leserecht lässt sich nichts ändern (die Oberfläche bietet es nicht an).
    await expectLater(tim.g.s.speichereTermin(tim.g.b.termine['fest-1']!.kopie(titel: 'Von Tim geändert')), throwsStateError);
    await kay.sync();
    expect(kay.g.b.termine['fest-1']!.titel, 'Weihnachtsessen bei Oma');

    // Widerruf: Tim ist raus, verliert den Raum; neue Inhalte mit neuem Schlüssel.
    final m = kay.raum('Familie').mitglieder.firstWhere((x) => x.name == 'Tim');
    await kay.raeume.entfernen(kay.raum('Familie'), m);
    expect(kay.raum('Familie').epoche, 2);
    await kay.g.s.speichereTermin(termin('fest-2', 'Silvester', raum: fam.id));
    await kay.sync();
    await tim.sync();
    expect(tim.g.b.raeume, isEmpty);
    expect(tim.geteilt(fam.id), isEmpty);
    expect(tim.g.b.termine.containsKey('fest-2'), isFalse);
    await lena.sync();
    expect(lena.geteilt(fam.id).map((x) => x.titel).toSet(), {'Weihnachtsessen bei Oma', 'Silvester'});
    expect(lena.raum('Familie').epoche, 2);

    // Der Server sieht weder Namen noch Inhalte.
    final dump = server.dump() + jsonEncode([for (final r in server.speicher.db.select('SELECT * FROM raum_objekte')) r.values.map((v) => '$v').toList()]);
    for (final w in ['Familie', 'Weihnachtsessen', 'Silvester', 'Lena', 'Tim', 'Kay']) {
      expect(dump, isNot(contains(w)), reason: w);
    }
  });

  test('Privat ↔ geteilt verschieben; zweites Gerät des Eigentümers; Freigabe beenden macht alles wieder privat', () async {
    final kay = await person('Kay');
    final lena = await person('Lena');
    final fam = await kay.raeume.anlegen(art: RaumArt.kalender, name: 'Familie');
    await einladenUndAnnehmen(kay, fam, lena, 'schreiben');

    // Kays zweites Gerät per Kopplung.
    final (:code, bis: _) = await kay.g.sync.kopplungErstellen();
    final kay2 = Person(await Geraet(server, 'kay2').start());
    kay2.g.c.listen(vaultProvider, (_, _) {});
    await kay2.g.sync.neuKoppeln(server: TestServer.adresse, code: Kopplungscode.lesen(code.anzeigen())!, passwort: 'pw-kay2');
    await kay2.sync();
    expect(kay2.raum('Familie').mitglieder.map((m) => m.name), ['Lena']);

    await kay.g.s.speichereTermin(kay.g.b.termine['t1']!.kopie(raum: () => fam.id));
    await kay.sync();
    await lena.sync();
    await kay2.sync();
    // Kays „Zahnarzt“ (t1) ist jetzt geteilt; Lenas eigener t1 bleibt unberührt.
    expect(kay2.g.b.termine['t1']!.raum, fam.id);
    expect(lena.g.b.termine['t1']!.raum, isNull, reason: 'gleiche lokale ID, aber Lenas privater Termin');

    // Zurück ins Private: Lena verliert ihn wieder.
    await kay2.g.s.speichereTermin(kay2.g.b.termine['t1']!.kopie(raum: () => null));
    await kay2.sync();
    await kay.sync();
    expect(kay.g.b.termine['t1']!.raum, isNull);

    // Freigabe beenden: Lena verliert alles, Kay behält es privat.
    await kay.g.s.speichereTermin(termin('fest-1', 'Fest', raum: fam.id));
    await kay.sync();
    await lena.sync();
    expect(lena.geteilt(fam.id), hasLength(1));
    await kay.raeume.verlassen(kay.raum('Familie'));
    await kay.sync();
    await kay2.sync();
    await lena.sync();
    expect(lena.g.b.raeume, isEmpty);
    expect(lena.geteilt(fam.id), isEmpty);
    expect(kay.g.b.termine['fest-1']!.raum, isNull);
    expect(kay2.g.b.termine['fest-1']!.raum, isNull);
    expect(kay2.g.b.raeume, isEmpty);
  });

  test('Ein Mitglied kann einen wieder privaten Eintrag nicht zurückholen', () async {
    final kay = await person('Kay');
    final lena = await person('Lena');
    final fam = await kay.raeume.anlegen(art: RaumArt.kalender, name: 'Familie');
    await einladenUndAnnehmen(kay, fam, lena, 'schreiben');
    await kay.g.s.speichereTermin(termin('x-1', 'Erst geteilt', raum: fam.id));
    await kay.sync();
    await lena.sync();
    await kay.g.s.speichereTermin(kay.g.b.termine['x-1']!.kopie(raum: () => null, titel: 'Jetzt privat'));
    await kay.sync();
    // Lena (bzw. ihre App) schreibt den Eintrag mit bekannter ID wieder in den Raum.
    await lena.g.s.speichereTermin(termin('x-1', 'Übernommen?', raum: fam.id));
    await lena.sync();
    await kay.sync();
    expect(kay.g.b.termine['x-1']!.titel, 'Jetzt privat');
    expect(kay.g.b.termine['x-1']!.raum, isNull);
  });

  test('Geteilter Vault-Ordner: eingehängt, beidseitig bearbeitet, Verschieben teilt/entteilt, Secret-Prüfung beim Teilen', () async {
    final kay = await person('Kay');
    final lena = await person('Lena');
    final gross = Uint8List.fromList(List.generate(200 * 1024, (i) => i * 31 % 256));
    await kay.v.speichern(pfad: 'Familie/Plan.md', inhalt: t('# Plan'));
    await kay.v.speichern(pfad: 'Familie/Fotos/bild.bin', inhalt: gross);
    await kay.v.speichern(pfad: 'Privat/geheim.md', inhalt: t('nur für mich'));
    await kay.v.speichern(pfad: 'Privat/zugang.md', inhalt: t('Passwort: Pferd-Batterie-77'));
    await kay.v.freigeben(kay.an('Privat/zugang.md')!);
    await kay.sync();

    final fam = await kay.raeume.anlegen(art: RaumArt.vault, name: 'Familie', ordner: 'Familie');
    await kay.sync();
    await einladenUndAnnehmen(kay, fam, lena, 'schreiben');
    await lena.sync();
    expect(lena.pfade, ['Geteilt/Familie/Fotos/bild.bin', 'Geteilt/Familie/Plan.md']);
    expect(await lena.v.inhalt(lena.an('Geteilt/Familie/Fotos/bild.bin')!), gross);

    await lena.v.speichern(alt: lena.an('Geteilt/Familie/Plan.md'), pfad: 'Geteilt/Familie/Plan.md', inhalt: t('# Plan\n- Lena war hier'));
    await lena.sync();
    await kay.sync();
    expect(await kay.v.text(kay.an('Familie/Plan.md')!), contains('Lena war hier'));

    // Privat → geteilt: Kay verschiebt eine Datei in den Ordner; die
    // Datei mit Secret wird beim Teilen neu geprüft und bleibt gesperrt.
    await kay.v.umbenennen(kay.an('Privat/geheim.md')!, 'Familie/geheim.md');
    await kay.v.umbenennen(kay.an('Privat/zugang.md')!, 'Familie/zugang.md');
    await kay.sync();
    expect(kay.g.status.vaultGesperrt, {kay.an('Familie/zugang.md')!.id});
    await lena.sync();
    expect(lena.pfade, contains('Geteilt/Familie/geheim.md'));
    expect(lena.pfade, isNot(contains('Geteilt/Familie/zugang.md')));

    // Geteilt → privat: Lena verliert sie.
    await kay.v.umbenennen(kay.an('Familie/geheim.md')!, 'Privat/geheim.md');
    await kay.sync();
    await lena.sync();
    expect(lena.pfade, isNot(contains('Geteilt/Familie/geheim.md')));
    expect(lena.pfade.where((p) => !p.startsWith('Geteilt/')), isEmpty);

    final dump = server.dump();
    for (final w in ['Plan', 'Familie', 'Lena war hier', 'geheim']) {
      expect(dump, isNot(contains(w)), reason: w);
    }
  });

  test('Einladungscodes: falsch, benutzt, eigener Raum', () async {
    final kay = await person('Kay');
    final lena = await person('Lena');
    final fam = await kay.raeume.anlegen(art: RaumArt.aufgaben, name: 'Haushalt');
    final (:code, bis: _) = await kay.raeume.einladen(fam, 'schreiben');
    await expectLater(lena.raeume.annehmen('ABCD'), throwsA(isA<RaumFehler>()));
    await expectLater(kay.raeume.annehmen(code.text), throwsA(isA<RaumFehler>()));
    await lena.raeume.annehmen(code.text);
    await expectLater(lena.raeume.annehmen(code.text), throwsA(isA<RaumFehler>()));
    expect(lena.raum('Haushalt').recht, 'schreiben');
  });
}
