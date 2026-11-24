import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/sync/sync_krypto.dart';
import 'package:personal_tracker/core/vault/secret_muster.g.dart';
import 'package:personal_tracker/core/vault/secrets.dart';
import 'package:personal_tracker/core/vault/vault_datei.dart';
import 'package:personal_tracker/core/vault/vault_dienst.dart';

import '../sync_hilfen.dart';
import 'sitzung_test.dart' show einrichtenMitDaten;
import 'sync_test.dart' show Geraet;

Uint8List t(String s) => Uint8List.fromList(utf8.encode(s));

extension on Geraet {
  VaultNotifier get v => c.read(vaultProvider.notifier);
  List<VaultDatei> get dateien => c.read(vaultProvider).dateien;
  VaultDatei? an(String pfad) => dateien.where((d) => d.pfad == pfad).firstOrNull;
  Future<String> lies(String pfad) async => v.text(an(pfad)!);
  Future<void> vaultAbgleichen() async {
    await abgleichen();
    await v.laden();
  }
}

void main() {
  group('Secret-Erkennung', () {
    test('Dart-Kopie entspricht protokoll/secret-muster.json', () {
      expect(jsonDecode(secretMusterJson), jsonDecode(File('../protokoll/secret-muster.json').readAsStringSync()));
    });

    test('gemeinsame Beispiele (dieselben wie im Plugin)', () {
      final p = SecretPruefung.standard();
      final faelle = (jsonDecode(File('../protokoll/secret-beispiele.json').readAsStringSync())['faelle'] as List).cast<Map<String, dynamic>>();
      for (final f in faelle) {
        expect(p.pruefeText(f['text'] as String).map((x) => x.regel).toSet(), (f['regeln'] as List).toSet(), reason: f['text'] as String);
      }
    });

    test('meldet Zeilen, nie Werte; Binärdateien gelten als nicht prüfbar', () {
      final p = SecretPruefung.standard();
      final treffer = p.pruefeText('# Zugang\n\nNichts hier\nPasswort: Pferd-Batterie-77\n');
      expect(treffer, [(regel: 'Passwort- oder Token-Zuweisung', zeile: 4)]);
      expect(treffer.toString(), isNot(contains('Pferd')));
      expect(p.pruefen(Uint8List.fromList([0x89, 0x50, 0, 1, 2])), isNull);
      expect(p.pruefen(t('harmlos')), isEmpty);
    });
  });

  group('Dateien und Blöcke', () {
    final ks = Kontoschluessel.neu();

    test('kleine Dateien liegen im Objekt, große in Blöcken; Blöcke sind gebunden', () {
      final klein = ks.vaultDatei(id: 'a', pfad: 'a.md', inhalt: t('# A'), geaendert: DateTime.utc(2026));
      expect(klein.inhalt, t('# A'));
      expect(klein.bloecke, isEmpty);

      final gross = Uint8List.fromList(List.generate(2 * vaultBlockGroesse + 10, (i) => i * 7 % 256));
      final neu = <String, Uint8List>{};
      final d = ks.vaultDatei(id: 'b', pfad: 'b.bin', inhalt: gross, geaendert: DateTime.utc(2026), neueBloecke: neu);
      expect(d.inhalt, isNull);
      expect(d.bloecke.map((b) => b.groesse), [vaultBlockGroesse, vaultBlockGroesse, 10]);
      expect(d.sha256, sha256Hex(gross));
      expect(VaultDatei.fromJson(jsonDecode(jsonEncode(d.toJson()))).bloecke, d.bloecke);

      final b = d.bloecke.last;
      final geheim = ks.blockVerschluesseln(b.id, neu[b.id]!);
      expect(geheim.length, 12 + 4096 + 16, reason: 'auf 4 KiB aufgefüllt');
      expect(ks.blockEntschluesseln(b.id, geheim, b.groesse), neu[b.id]);
      // Unter falscher ID, mit anderem Schlüssel oder verändert: abgelehnt.
      expect(ks.blockEntschluesseln(d.bloecke.first.id, geheim, b.groesse), isNull);
      expect(Kontoschluessel.neu().blockEntschluesseln(b.id, geheim, b.groesse), isNull);
      expect(ks.blockEntschluesseln(b.id, Uint8List.fromList(geheim)..[20] ^= 1, b.groesse), isNull);
      // Gleicher Inhalt, gleiche ID; anderer Kontoschlüssel, andere ID.
      expect(ks.blockId(neu[b.id]!), b.id);
      expect(Kontoschluessel.neu().blockId(neu[b.id]!), isNot(b.id));
    });

    test('Pfade außerhalb des Vaults werden abgelehnt', () {
      for (final p in ['../x.md', '/etc/passwd', 'a//b.md', 'a/./b', 'C:/x', 'a\u0000b', '']) {
        expect(() => vaultPfad(p), throwsFormatException, reason: p);
      }
      expect(vaultPfad('Ordner/Unter/Notiz.md'), 'Ordner/Unter/Notiz.md');
      expect(vaultPfad(r'Ordner\Notiz.md'), 'Ordner/Notiz.md');
      expect(vaultPfad('.obsidian/plugins/x/data.json'), '.obsidian/plugins/x/data.json');
    });

    test('Konfliktnamen sind lesbar und kollisionssicher', () {
      final zeit = DateTime(2026, 11, 24, 14, 3);
      expect(konfliktPfad('Ordner/Notiz.md', zeit, 'Handy', (_) => false), 'Ordner/Notiz (Konflikt 2026-11-24 1403 Handy).md');
      final belegt = {'Notiz (Konflikt 2026-11-24 1403 Handy).md', 'Notiz (Konflikt 2026-11-24 1403 Handy 2).md'};
      expect(konfliktPfad('Notiz.md', zeit, 'Handy', belegt.contains), 'Notiz (Konflikt 2026-11-24 1403 Handy 3).md');
      expect(konfliktPfad('ohne-endung', zeit, 'Ha/n:dy', (_) => false), 'ohne-endung (Konflikt 2026-11-24 1403 Handy)');
      expect(konfliktPfad('.obsidian/app.json', zeit, '', (_) => false), '.obsidian/app (Konflikt 2026-11-24 1403).json');
    });
  });

  group('Abgleich', () {
    late TestServer server;
    setUp(() => server = TestServer());
    tearDown(() => server.speicher.schliessen());

    Future<(Geraet, Geraet)> zweiGeraete() async {
      final a = await Geraet(server, 'a').start();
      a.c.listen(vaultProvider, (_, _) {});
      final r = await einrichtenMitDaten(a.s);
      await a.sync.verbinden(server: TestServer.adresse, recovery: r, geraetName: 'Handy');
      final (:code, bis: _) = await a.sync.kopplungErstellen();
      final b = await Geraet(server, 'b').start();
      b.c.listen(vaultProvider, (_, _) {});
      await b.sync.neuKoppeln(server: TestServer.adresse, code: Kopplungscode.lesen(code.anzeigen())!, passwort: 'passwort-b', geraetName: 'Laptop');
      await b.abgleichen();
      return (a, b);
    }

    test('Markdown und große Anhänge kommen an; der Server sieht keinen Inhalt', () async {
      final (a, b) = await zweiGeraete();
      await a.v.speichern(pfad: 'Projekte/Hochbeet.md', inhalt: t('# Hochbeet\n\nSiehe [[Garten]] und ![[foto.png]]\n'));
      final bild = Uint8List.fromList(List.generate(300 * 1024, (i) => Random(1).nextInt(256) ^ (i % 256)));
      await a.v.speichern(pfad: 'Anhänge/foto.png', inhalt: bild);
      await a.vaultAbgleichen();
      expect(a.status.ausstehend, 0);

      await b.vaultAbgleichen();
      expect(b.dateien.map((d) => d.pfad), ['Anhänge/foto.png', 'Projekte/Hochbeet.md']);
      expect(await b.lies('Projekte/Hochbeet.md'), contains('[[Garten]]'));
      // Großer Anhang: erst beim Öffnen vom Server geholt, dann im Zwischenspeicher.
      final vorher = server.anfragen;
      expect(await b.v.inhalt(b.an('Anhänge/foto.png')!), bild);
      expect(server.anfragen, greaterThan(vorher));
      final danach = server.anfragen;
      expect(await b.v.inhalt(b.an('Anhänge/foto.png')!), bild);
      expect(server.anfragen, danach);

      final dump = server.dump();
      for (final wort in ['Hochbeet', 'Garten', 'Projekte', 'foto.png', 'Anhänge', 'vault']) {
        expect(dump, isNot(contains(wort)), reason: wort);
      }
      expect(server.speicher.db.select('SELECT count(*) n FROM bloecke').first['n'], 1);
    });

    test('Umbenennen hier und Ändern dort werden ohne Konflikt zusammengeführt', () async {
      final (a, b) = await zweiGeraete();
      await a.v.speichern(pfad: 'Notiz.md', inhalt: t('eins'));
      await a.vaultAbgleichen();
      await b.vaultAbgleichen();

      await a.v.umbenennen(a.an('Notiz.md')!, 'Archiv/Notiz.md');
      await b.v.speichern(alt: b.an('Notiz.md'), pfad: 'Notiz.md', inhalt: t('zwei'));
      await a.vaultAbgleichen();
      await b.vaultAbgleichen();
      await a.vaultAbgleichen();

      for (final g in [a, b]) {
        expect(g.dateien.map((d) => d.pfad), ['Archiv/Notiz.md']);
        expect(await g.lies('Archiv/Notiz.md'), 'zwei');
      }
    });

    test('Gleichzeitig verschieden geändert: Serverfassung gilt, die andere wird Konfliktkopie', () async {
      final (a, b) = await zweiGeraete();
      await a.v.speichern(pfad: 'Plan.md', inhalt: t('Basis'));
      await a.vaultAbgleichen();
      await b.vaultAbgleichen();

      await a.v.speichern(alt: a.an('Plan.md'), pfad: 'Plan.md', inhalt: t('Fassung A'));
      await b.v.speichern(alt: b.an('Plan.md'), pfad: 'Plan.md', inhalt: t('Fassung B'));
      await a.vaultAbgleichen();
      b.g.jetzt = DateTime(2026, 11, 24, 14, 3);
      await b.vaultAbgleichen();
      await a.vaultAbgleichen();

      const kopie = 'Plan (Konflikt 2026-11-24 1403 Laptop).md';
      for (final g in [a, b]) {
        expect(g.dateien.map((d) => d.pfad), ['Plan (Konflikt 2026-11-24 1403 Laptop).md', 'Plan.md']);
        expect(await g.lies('Plan.md'), 'Fassung A');
        expect(await g.lies(kopie), 'Fassung B');
      }

      // Zweiter Konflikt an derselben Datei zur selben Minute: neuer Name.
      await a.v.speichern(alt: a.an('Plan.md'), pfad: 'Plan.md', inhalt: t('A2'));
      await b.v.speichern(alt: b.an('Plan.md'), pfad: 'Plan.md', inhalt: t('B2'));
      await a.vaultAbgleichen();
      await b.vaultAbgleichen();
      await a.vaultAbgleichen();
      expect(b.dateien.map((d) => d.pfad), contains('Plan (Konflikt 2026-11-24 1403 Laptop 2).md'));
      expect(a.dateien.length, 3);
    });

    test('Löschen gegen Ändern: die Änderung bleibt', () async {
      final (a, b) = await zweiGeraete();
      await a.v.speichern(pfad: 'x.md', inhalt: t('alt'));
      await a.vaultAbgleichen();
      await b.vaultAbgleichen();
      await a.v.loeschen(a.an('x.md')!);
      await b.v.speichern(alt: b.an('x.md'), pfad: 'x.md', inhalt: t('neu'));
      await a.vaultAbgleichen();
      await b.vaultAbgleichen();
      await a.vaultAbgleichen();
      expect(await a.lies('x.md'), 'neu');

      // Ohne Gegenänderung wird gelöscht.
      await a.v.loeschen(a.an('x.md')!);
      await a.vaultAbgleichen();
      await b.vaultAbgleichen();
      expect(b.dateien, isEmpty);
    });

    test('Derselbe Pfad offline auf zwei Geräten neu angelegt: keine Datei geht verloren', () async {
      final (a, b) = await zweiGeraete();
      await a.v.speichern(pfad: 'Neu.md', inhalt: t('von A'));
      await b.v.speichern(pfad: 'Neu.md', inhalt: t('von B'));
      await a.vaultAbgleichen();
      await b.vaultAbgleichen();
      await a.vaultAbgleichen();
      await b.vaultAbgleichen();
      final pa = a.dateien.map((d) => d.pfad).toList();
      expect(pa.length, 2);
      expect(pa, contains('Neu.md'));
      expect(b.dateien.map((d) => d.pfad).toList(), pa);
      final inhalte = {for (final p in pa) await a.lies(p)};
      expect(inhalte, {'von A', 'von B'});
    });

    test('Dieselbe Datei auf zwei Geräten neu angelegt: keine Dublette', () async {
      final (a, b) = await zweiGeraete();
      await a.v.speichern(pfad: 'Gleich.md', inhalt: t('derselbe Text'));
      await b.v.speichern(pfad: 'Gleich.md', inhalt: t('derselbe Text'));
      await a.vaultAbgleichen();
      await b.vaultAbgleichen();
      await a.vaultAbgleichen();
      expect(a.dateien.map((d) => d.pfad), ['Gleich.md']);
      expect(b.dateien.map((d) => d.id), a.dateien.map((d) => d.id));
      expect(b.status.ausstehend, 0);
    });

    test('Secret blockiert das Hochladen, bis genau dieser Inhalt freigegeben ist', () async {
      final (a, b) = await zweiGeraete();
      await a.v.speichern(pfad: 'Zugang.md', inhalt: t('Server\nPasswort: Pferd-Batterie-77\n'));
      await a.vaultAbgleichen();
      final d = a.an('Zugang.md')!;
      expect(a.status.vaultGesperrt, {d.id});
      expect(a.c.read(vaultProvider).ausstehend, {d.id});
      expect(server.dump(), isNot(contains('Pferd')));
      await b.vaultAbgleichen();
      expect(b.dateien, isEmpty);
      expect(await a.v.pruefen(d), [(regel: 'Passwort- oder Token-Zuweisung', zeile: 2)]);

      await a.v.freigeben(d);
      await a.vaultAbgleichen();
      expect(a.status.vaultGesperrt, isEmpty);
      await b.vaultAbgleichen();
      expect(await b.lies('Zugang.md'), contains('Pferd'));

      // Geänderter Inhalt muss neu freigegeben werden.
      await a.v.speichern(alt: a.an('Zugang.md'), pfad: 'Zugang.md', inhalt: t('Passwort: Anderes-Geheimnis-9'));
      await a.vaultAbgleichen();
      expect(a.status.vaultGesperrt, {d.id});
      // Reines Umbenennen auf B (Inhalt ist schon beim Server) geht durch.
      await b.v.umbenennen(b.an('Zugang.md')!, 'Privat/Zugang.md');
      await b.vaultAbgleichen();
      expect(b.status.vaultGesperrt, isEmpty);
      expect(b.status.ausstehend, 0);
    });

    test('Dateien über der Größengrenze bleiben lokal', () async {
      final (a, _) = await zweiGeraete();
      await a.s.speichereEinstellungen(a.b.einstellungen.kopie(vaultMaxMiB: 1));
      await a.v.speichern(pfad: 'gross.bin', inhalt: Uint8List(1024 * 1024 + 1));
      await a.v.speichern(pfad: 'klein.bin', inhalt: Uint8List(1000));
      await a.vaultAbgleichen();
      expect(a.status.vaultZuGross, {a.an('gross.bin')!.id});
      expect(a.status.ausstehend, 1);
    });

    test('Nicht mehr benutzte Blöcke werden aufgeräumt, benutzte nie', () async {
      final (a, b) = await zweiGeraete();
      final groesse = 100 * 1024;
      await a.v.speichern(pfad: 'a.bin', inhalt: Uint8List(groesse)..[0] = 1);
      await a.v.speichern(pfad: 'b.bin', inhalt: Uint8List(groesse)..[0] = 2);
      await a.vaultAbgleichen();
      await a.v.speichern(alt: a.an('a.bin'), pfad: 'a.bin', inhalt: Uint8List(groesse)..[0] = 3);
      await a.vaultAbgleichen();
      expect(server.speicher.db.select('SELECT count(*) n FROM bloecke').first['n'], 3);

      // Einen Tag später, alle Blöcke älter als die Schonfrist.
      server.speicher.db.execute('UPDATE bloecke SET erstellt = 0');
      b.g.jetzt = b.g.jetzt.add(const Duration(days: 2));
      await b.vaultAbgleichen();
      expect(server.speicher.db.select('SELECT count(*) n FROM bloecke').first['n'], 2);
      expect(await b.v.inhalt(b.an('a.bin')!), Uint8List(groesse)..[0] = 3);
      expect(await b.v.inhalt(b.an('b.bin')!), Uint8List(groesse)..[0] = 2);
    });

    test('Fehlt ein Block beim Server, meldet die App das verständlich', () async {
      final (a, b) = await zweiGeraete();
      await a.v.speichern(pfad: 'weg.bin', inhalt: Uint8List(80 * 1024)..[5] = 5);
      await a.vaultAbgleichen();
      await b.vaultAbgleichen();
      server.speicher.db.execute('DELETE FROM bloecke');
      expect(() => b.v.inhalt(b.an('weg.bin')!), throwsA(isA<Object>()));
      // A hat den Block noch und kann die Datei weiter öffnen.
      expect(await a.v.inhalt(a.an('weg.bin')!), Uint8List(80 * 1024)..[5] = 5);
    });

    test('Ohne Vault-Dateien gibt es keine Block-Anfragen', () async {
      final (a, _) = await zweiGeraete();
      final vorher = server.protokoll.length;
      await a.vaultAbgleichen();
      expect(server.protokoll.skip(vorher).where((z) => z.contains('bloecke')), isEmpty);
    });

  });
}
