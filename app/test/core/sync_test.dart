import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/krypto/recovery_schluessel.dart';
import 'package:personal_tracker/core/modell/bestand.dart';
import 'package:personal_tracker/core/modell/finanzen.dart';
import 'package:personal_tracker/core/modell/notiz.dart';
import 'package:personal_tracker/core/sitzung.dart';
import 'package:personal_tracker/core/speicher/ablage.dart';
import 'package:personal_tracker/core/speicher/rohdaten.dart';
import 'package:personal_tracker/core/speicher/schema.dart';
import 'package:personal_tracker/core/sync/sync_api.dart';
import 'package:personal_tracker/core/sync/sync_dienst.dart';
import 'package:personal_tracker/core/sync/sync_krypto.dart';
import 'package:personal_tracker/core/sync/sync_stand.dart';
import 'package:personal_tracker_sync/personal_tracker_sync.dart';
import 'package:sembast/sembast.dart' show DatabaseFactory;

import '../hilfen.dart';
import '../sync_hilfen.dart';
import 'sitzung_test.dart' show einrichtenMitDaten;

/// Ein Gerät mit eigener Ablage, verbunden mit [server].
class Geraet {
  Geraet(TestServer server, String name, {DatabaseFactory? fabrik}) : g = TestGeraet(fabrik: fabrik, name: '$name.db', client: server.client());

  final TestGeraet g;
  late ProviderContainer c;
  late Ablage ablage;

  Future<Geraet> start() async {
    final (neu, abl) = await g.starten();
    c = neu;
    ablage = abl;
    c.listen(syncProvider, (_, _) {});
    return this;
  }

  /// App neu starten und mit Passwort entsperren.
  Future<void> neustart(String passwort) async {
    c.dispose();
    await ablage.schliessen();
    await start();
    expect(await s.entsperren(passwort), isTrue);
    await sync.abgleichen();
  }

  SitzungNotifier get s => c.read(sitzungProvider.notifier);
  SyncNotifier get sync => c.read(syncProvider.notifier);
  SyncStatus get status => c.read(syncProvider);
  Bestand get b => c.read(bestandProvider);
  Entsperrt get offen => c.read(sitzungProvider) as Entsperrt;

  Future<void> abgleichen() async {
    await sync.abgleichen();
    expect(status.fehler, isNull, reason: status.fehler);
  }
}

/// Vergleichbare Darstellung eines Bestands (Listen nach ID sortiert).
String vergleichbar(Bestand b) {
  final roh = rohdatenVon(b)..remove('einstellungen');
  return jsonEncode({
    for (final e in (roh.entries.toList()..sort((x, y) => x.key.compareTo(y.key))))
      e.key: (e.value.toList()..sort((x, y) => '${x['id']}'.compareTo('${y['id']}'))),
  });
}

Notiz notiz(Geraet d, String id, String text) =>
    Notiz(id: id, titel: 'Notiz $id', text: text, erstellt: d.g.jetzt.toUtc(), geaendert: d.g.jetzt.toUtc());

void main() {
  late TestServer server;
  setUp(() => server = TestServer());
  tearDown(() => server.speicher.schliessen());

  /// Gerät A mit Daten verbunden, Gerät B per Kopplungscode dazu.
  Future<(Geraet, Geraet, RecoverySchluessel)> zweiGeraete() async {
    final a = await Geraet(server, 'a').start();
    final r = await einrichtenMitDaten(a.s);
    await a.sync.verbinden(server: TestServer.adresse, recovery: r, geraetName: 'Handy');
    expect(a.status.fehler, isNull, reason: a.status.fehler);
    final (:code, bis: _) = await a.sync.kopplungErstellen();
    final b = await Geraet(server, 'b').start();
    await b.sync.neuKoppeln(server: TestServer.adresse, code: Kopplungscode.lesen(code.anzeigen())!, passwort: 'passwort-b', geraetName: 'Laptop');
    await b.abgleichen();
    return (a, b, r);
  }

  test('Erstverbindung lädt alles verschlüsselt hoch; der Server sieht keinen Inhalt', () async {
    final a = await Geraet(server, 'a').start();
    final r = await einrichtenMitDaten(a.s);
    final bericht = await a.sync.verbinden(server: TestServer.adresse, recovery: r, geraetName: 'Handy');
    expect(a.status.verbunden, isTrue);
    expect(a.status.ausstehend, 0);
    expect(bericht!.gesendet, a.b.anzahlDatensaetze);

    final dump = server.dump();
    for (final wort in ['Zahnarzt', 'Mülltonne', 'Hochbeet', 'Bäckerei', 'Portemonnaie', 'Giro', 'Miete', '85000', '-450', 'Handy', 'termine', 'buchungen']) {
      expect(dump, isNot(contains(wort)), reason: wort);
    }
    // Weder Recovery-Schlüssel noch Kontoschlüssel liegen dort.
    final v = (await SyncStand(a.ablage, a.offen.dek).verbindung())!;
    expect(dump, isNot(contains(base64Encode(v.schluessel.bytes))));
    expect(dump, isNot(contains(base64Url.encode(r.syncAnmeldung))));
    expect(dump, isNot(contains(r.anzeigen())));
    // Das Protokoll enthält keine Inhalte und keine Token.
    expect(server.protokoll.join('\n'), isNot(contains(v.token)));
  });

  test('Zweites Gerät per Kopplungscode bekommt alles und denselben Recovery-Schlüssel', () async {
    final (a, b, r) = await zweiGeraete();
    expect(vergleichbar(b.b), vergleichbar(a.b));
    expect(b.b.saldoCent('giro'), 100000 - 450 - 5000);
    expect(b.offen.bund.recoveryKennung, a.offen.bund.recoveryKennung);
    // Code ist verbraucht.
    final c = await Geraet(server, 'c').start();
    final (:code, bis: _) = await a.sync.kopplungErstellen();
    await c.sync.neuKoppeln(server: TestServer.adresse, code: code, passwort: 'pw-c');
    final d = await Geraet(server, 'd').start();
    await expectLater(
      d.sync.neuKoppeln(server: TestServer.adresse, code: code, passwort: 'pw-d'),
      throwsA(isA<SyncFehler>().having((e) => e.art, 'art', SyncFehlerArt.nichtGefunden)),
    );
    // B lässt sich neu starten, mit eigenem Passwort entsperren und per
    // Recovery-Schlüssel des Kontos öffnen; seine Sicherung passt zu r.
    await b.neustart('passwort-b');
    expect(vergleichbar(b.b), vergleichbar(a.b));
    final sicherung = b.s.sicherungErstellen();
    expect(vergleichbar(SitzungNotifier.sicherungPruefen(sicherung, r).bestand), vergleichbar(a.b));
  });

  test('Offline auf beiden Geräten ändern, danach gleichen beide ab', () async {
    final (a, b, _) = await zweiGeraete();
    server.offline = true;
    await a.s.speichereNotiz(notiz(a, 'na', 'von A'));
    await b.s.speichereNotiz(notiz(b, 'nb', 'von B'));
    await b.s.loescheTermin('t1');
    await a.sync.abgleichen();
    expect(a.status.fehlerArt, SyncFehlerArt.netz);
    expect(a.status.ausstehend, 1);
    server.offline = false;
    await a.abgleichen();
    await b.abgleichen();
    await a.abgleichen();
    expect(vergleichbar(a.b), vergleichbar(b.b));
    expect(a.b.notizen.keys, containsAll(['na', 'nb', 'n1']));
    expect(a.b.termine, isEmpty);
    expect(a.b.konflikte, isEmpty);
    expect(a.status.ausstehend, 0);
  });

  test('Gleichzeitige Änderung: nichts wird überschrieben, Konflikt-Fassung bleibt sichtbar', () async {
    final (a, b, _) = await zweiGeraete();
    final n = a.b.notizen['n1']!;
    await a.s.speichereNotiz(n.kopie(text: 'Fassung A'));
    await b.s.speichereNotiz(n.kopie(text: 'Fassung B'));
    await a.abgleichen();
    await b.abgleichen();
    await a.abgleichen();
    // Die zuerst angekommene Fassung gilt, die andere ist ein Konflikt.
    for (final d in [a, b]) {
      expect(d.b.notizen['n1']!.text, 'Fassung A');
      expect(d.b.konflikte.length, 1);
      final k = d.b.konflikte.values.single;
      expect(k.bereich, 'notizen');
      expect(k.originalId, 'n1');
      expect(k.daten['text'], 'Fassung B');
    }
    // Auf A die B-Fassung übernehmen; B übernimmt das beim Abgleich.
    await a.s.konfliktUebernehmen(a.b.konflikte.keys.single);
    await a.abgleichen();
    await b.abgleichen();
    for (final d in [a, b]) {
      expect(d.b.notizen['n1']!.text, 'Fassung B');
      expect(d.b.konflikte, isEmpty);
    }
  });

  test('Konflikt bei Buchungen zählt nicht im Saldo; Verwerfen behält die aktuelle', () async {
    final (a, b, _) = await zweiGeraete();
    final x = a.b.buchungen['b1']!;
    await a.s.speichereBuchung(x.kopie(betragCent: -500));
    await b.s.speichereBuchung(x.kopie(betragCent: -9999));
    await a.abgleichen();
    await b.abgleichen();
    expect(b.b.buchungen['b1']!.betragCent, -500);
    expect(b.b.saldoCent('giro'), 100000 - 500 - 5000);
    expect(b.b.konflikte.values.single.daten['betragCent'], -9999);
    await b.s.konfliktVerwerfen(b.b.konflikte.keys.single);
    await b.abgleichen();
    await a.abgleichen();
    expect(a.b.konflikte, isEmpty);
    expect(a.b.buchungen['b1']!.betragCent, -500);
  });

  test('Konflikt bei Umbuchung: Übernehmen nimmt beide Hälften mit', () async {
    final (a, b, _) = await zweiGeraete();
    final uid = a.b.buchungen.values.firstWhere((x) => x.istUmbuchung).umbuchungId!;
    Future<void> aendern(Geraet d, int cent) =>
        d.s.umbuchen(umbuchungId: uid, vonKonto: 'giro', nachKonto: 'bar', betragCent: cent, datum: DateTime(2026, 11, 6));
    await aendern(a, 6000);
    await aendern(b, 7000);
    await a.abgleichen();
    await b.abgleichen();
    expect(b.b.saldoCent('bar'), 6000);
    expect(b.b.konflikte.length, 2);
    await b.s.konfliktUebernehmen(b.b.konflikte.keys.first);
    expect(b.b.konflikte, isEmpty);
    expect(b.b.saldoCent('bar'), 7000);
    expect(b.b.saldoCent('giro'), 100000 - 450 - 7000);
    await b.abgleichen();
    await a.abgleichen();
    expect(a.b.saldoCent('bar'), 7000);
  });

  test('Löschen gegen Ändern: die Änderung bleibt erhalten', () async {
    final (a, b, _) = await zweiGeraete();
    await a.s.loescheNotiz('n1');
    await b.s.speichereNotiz(b.b.notizen['n1']!.kopie(text: 'noch wichtig'));
    await a.abgleichen();
    await b.abgleichen();
    await a.abgleichen();
    for (final d in [a, b]) {
      expect(d.b.notizen['n1']?.text, 'noch wichtig');
      expect(d.b.konflikte, isEmpty);
    }
    // Umgekehrt: erst geändert angekommen, dann hier gelöscht.
    await b.s.speichereNotiz(b.b.notizen['n1']!.kopie(text: 'B ändert'));
    await a.s.loescheNotiz('n1');
    await b.abgleichen();
    await a.abgleichen();
    expect(a.b.notizen['n1']?.text, 'B ändert');
  });

  test('Konto gelöscht, auf dem anderen Gerät offline gebucht: Konto bleibt', () async {
    final (a, b, _) = await zweiGeraete();
    await a.s.speichereKonto(Konto(id: 'spar', name: 'Sparbuch', art: KontoArt.bank, geaendert: a.g.jetzt.toUtc()));
    await a.abgleichen();
    await b.abgleichen();
    await a.s.loescheKonto('spar');
    await b.s.speichereBuchung(Buchung(
      id: 'zins',
      kontoId: 'spar',
      datum: DateTime(2026, 11, 20),
      empfaenger: 'Zinsen',
      betragCent: 12,
      status: BuchungsStatus.gebucht,
      geaendert: b.g.jetzt.toUtc(),
    ));
    await a.abgleichen();
    await b.abgleichen();
    await a.abgleichen();
    for (final d in [a, b]) {
      expect(d.b.konten.containsKey('spar'), isTrue);
      expect(d.b.saldoCent('spar'), 12);
    }
  });

  test('Abbruch mitten in der Erstübertragung: Wiederaufnahme ohne Dubletten', () async {
    final a = await Geraet(server, 'a').start();
    final r = await einrichtenMitDaten(a.s);
    for (var i = 0; i < 30; i++) {
      await a.s.speichereNotiz(notiz(a, 'x$i', 'Text $i'));
    }
    // info, Konto anlegen, abrufen – beim Senden kommt die Antwort nicht
    // mehr an (der Server hat aber gespeichert), danach ist die Leitung tot.
    server.abbruchNach = 3;
    await a.sync.verbinden(server: TestServer.adresse, recovery: r);
    expect(a.status.fehlerArt, SyncFehlerArt.netz);
    expect(a.status.ausstehend, greaterThan(0));
    server.abbruchNach = null;
    await a.abgleichen();
    expect(a.status.ausstehend, 0);
    expect(server.speicher.db.select('SELECT count(*) n FROM objekte').first['n'], a.b.anzahlDatensaetze);
    // Neues Gerät per Recovery sieht genau denselben Stand.
    final n = await Geraet(server, 'n').start();
    await n.sync.neuAusRecovery(server: TestServer.adresse, recovery: r, passwort: 'pw-neu');
    await n.abgleichen();
    expect(vergleichbar(n.b), vergleichbar(a.b));
  });

  test('Uhrzeiten der Geräte spielen für den Abgleich keine Rolle', () async {
    final (a, b, _) = await zweiGeraete();
    b.g.jetzt = DateTime(2020, 1, 1); // Uhr von B weit zurück
    await a.s.speichereNotiz(a.b.notizen['n1']!.kopie(text: 'A neu'));
    await a.abgleichen();
    await b.s.speichereNotiz(b.b.notizen['n1']!.kopie(text: 'B mit falscher Uhr'));
    await b.abgleichen();
    await a.abgleichen();
    // B hatte A's Stand noch nicht → Konflikt, nichts geht verloren.
    expect(a.b.notizen['n1']!.text, 'A neu');
    expect(a.b.konflikte.values.single.daten['text'], 'B mit falscher Uhr');
    // Nach dem Abgleich ändert B auf Basis des aktuellen Stands: kein Konflikt.
    await b.s.speichereNotiz(b.b.notizen['n1']!.kopie(text: 'B danach'));
    await b.abgleichen();
    await a.abgleichen();
    expect(a.b.notizen['n1']!.text, 'B danach');
    expect(a.b.konflikte.length, 1);
  });

  test('Alle Geräte verloren: Recovery-Schlüssel holt alles vom Server', () async {
    final (a, _, r) = await zweiGeraete();
    final erwartet = vergleichbar(a.b);
    final neu = await Geraet(server, 'ersatz').start();
    final falsch = RecoverySchluessel.neu();
    await expectLater(
      neu.sync.neuAusRecovery(server: TestServer.adresse, recovery: falsch, passwort: 'x'),
      throwsA(isA<SyncFehler>().having((e) => e.art, 'art', SyncFehlerArt.nichtGefunden)),
    );
    await neu.sync.neuAusRecovery(server: TestServer.adresse, recovery: r, passwort: 'pw-ersatz');
    await neu.abgleichen();
    expect(vergleichbar(neu.b), erwartet);
    expect((await neu.sync.geraete()).map((g) => g.name), containsAll(['Handy', 'Laptop', 'Android']));
  });

  test('Entferntes Gerät kann nicht mehr abgleichen, behält aber seine Daten', () async {
    final (a, b, _) = await zweiGeraete();
    final geraete = await a.sync.geraete();
    final idB = geraete.firstWhere((g) => g.name == 'Laptop').id;
    await a.sync.geraetEntfernen(idB);
    await b.sync.abgleichen();
    expect(b.status.fehlerArt, SyncFehlerArt.anmeldung);
    expect(b.b.notizen, isNotEmpty);
    await b.sync.trennen();
    expect(b.s.syncAktiv, isFalse);
    expect(b.b.notizen, isNotEmpty);
    await b.s.speichereNotiz(notiz(b, 'lokal', 'nur lokal'));
    expect(await SyncStand(b.ablage, b.offen.dek).anzahlAusstehend(), 0);
  });

  test('Recovery-Schlüssel erneuern: gilt auf dem Server und auf allen Geräten', () async {
    final (a, b, alt) = await zweiGeraete();
    final neu = RecoverySchluessel.neu();
    await a.sync.recoveryErneuern(neu);
    expect(a.offen.bund.recoveryKennung, neu.kennung);
    await b.abgleichen();
    expect(b.offen.bund.recoveryKennung, neu.kennung);
    final x = await Geraet(server, 'x').start();
    await expectLater(x.sync.neuAusRecovery(server: TestServer.adresse, recovery: alt, passwort: 'p'), throwsA(isA<SyncFehler>()));
    await x.sync.neuAusRecovery(server: TestServer.adresse, recovery: neu, passwort: 'p');
    await x.abgleichen();
    expect(vergleichbar(x.b), vergleichbar(a.b));
    // Sicherungen von B lassen sich jetzt mit dem neuen Schlüssel öffnen.
    expect(() => SitzungNotifier.sicherungPruefen(b.s.sicherungErstellen(), neu), returnsNormally);
  });

  test('Umzug auf einen anderen Server ohne Dubletten', () async {
    final (a, b, r) = await zweiGeraete();
    final ziel = TestServer();
    final a2 = Geraet(ziel, 'a', fabrik: a.g.fabrik);
    // Gleiche Ablage, neuer Client: A trennt und verbindet sich neu.
    await a.sync.trennen();
    a.c.dispose();
    await a.ablage.schliessen();
    await a2.start();
    expect(await a2.s.entsperren('passwort-1'), isTrue);
    await a2.sync.verbinden(server: TestServer.adresse, recovery: r);
    expect(a2.status.fehler, isNull);
    await b.sync.trennen();
    b.c.dispose();
    await b.ablage.schliessen();
    final b2 = await Geraet(ziel, 'b', fabrik: b.g.fabrik).start();
    expect(await b2.s.entsperren('passwort-b'), isTrue);
    // B verbindet sich mit demselben Recovery-Schlüssel: Konto existiert.
    await b2.sync.verbinden(server: TestServer.adresse, recovery: r);
    await b2.abgleichen();
    await a2.abgleichen();
    expect(vergleichbar(a2.b), vergleichbar(b2.b));
    expect(a2.b.konflikte, isEmpty);
    expect(ziel.speicher.db.select('SELECT count(*) n FROM objekte').first['n'], a2.b.anzahlDatensaetze);
    ziel.speicher.schliessen();
  });

  test('Server aus älterer Sicherung zurückgespielt: Geräte bauen ihn neu auf', () async {
    final (a, b, _) = await zweiGeraete();
    final kopie = '${Directory.systemTemp.createTempSync('ptsync').path}/kopie.db';
    server.speicher.sichern(kopie);
    await a.s.speichereNotiz(notiz(a, 'spaet', 'nach der Serversicherung'));
    await a.abgleichen();
    // Server stirbt, Admin spielt die ältere Sicherung zurück.
    final alt = Speicher.oeffnen(kopie);
    server.handler = syncHandler(alt);
    await a.abgleichen();
    await b.abgleichen();
    expect(b.b.notizen['spaet']?.text, 'nach der Serversicherung');
    expect(a.b.konflikte, isEmpty);
    alt.schliessen();
  });

  test('Daten einer neueren App-Version werden nicht eingespielt', () async {
    final (a, b, _) = await zweiGeraete();
    final v = (await SyncStand(a.ablage, a.offen.dek).verbindung())!;
    final daten = v.schluessel.verschluesseln(Umschlag(bereich: 'notizen', id: 'zukunft', schema: aktuellesSchema + 1, daten: {'id': 'zukunft'}));
    server.speicher.schreiben(v.konto, [(id: v.schluessel.objektId('notizen', 'zukunft'), basis: 0, aenderung: 'z', daten: daten)]);
    final vorher = vergleichbar(b.b);
    await b.sync.abgleichen();
    expect(b.status.fehlerArt, SyncFehlerArt.version);
    expect(vergleichbar(b.b), vorher);
  });

  test('Untergeschobene oder vertauschte Objekte werden nicht übernommen', () async {
    final (a, b, _) = await zweiGeraete();
    final v = (await SyncStand(a.ablage, a.offen.dek).verbindung())!;
    // Server (Angreifer) legt ein Objekt mit fremdem Schlüssel ab …
    final fremd = Kontoschluessel.neu();
    server.speicher.schreiben(v.konto, [
      (id: fremd.objektId('notizen', 'boese'), basis: 0, aenderung: 'b1', daten: fremd.verschluesseln(const Umschlag(bereich: 'notizen', id: 'boese', schema: 3, daten: {'id': 'boese'}))),
    ]);
    // … und kopiert den Geheimtext von n1 unter eine andere ID.
    final n1 = server.speicher.db.select('SELECT daten FROM objekte WHERE id = ?', [v.schluessel.objektId('notizen', 'n1')]).first['daten'] as String;
    server.speicher.schreiben(v.konto, [(id: v.schluessel.objektId('notizen', 'kopie'), basis: 0, aenderung: 'b2', daten: n1)]);
    await b.sync.abgleichen();
    expect(b.status.fehler, contains('2 Einträge'));
    expect(b.b.notizen.keys, isNot(contains('boese')));
    expect(b.b.notizen.keys, isNot(contains('kopie')));
  });

  test('Ohne Server bleibt alles wie in M1/M2: keine Anfrage, nichts vorgemerkt', () async {
    final a = await Geraet(server, 'a').start();
    await einrichtenMitDaten(a.s);
    expect(a.s.syncAktiv, isFalse);
    expect(await a.sync.abgleichen(), isNull);
    expect(server.anfragen, 0);
    expect(await SyncStand(a.ablage, a.offen.dek).anzahlAusstehend(), 0);
  });

  test('Serveradresse: HTTPS Pflicht, HTTP nur lokal', () {
    expect(serverAdresse('sync.example.org').toString(), 'https://sync.example.org');
    expect(serverAdresse('https://sync.example.org/pt/').toString(), 'https://sync.example.org/pt');
    expect(serverAdresse('http://localhost:8743').toString(), 'http://localhost:8743');
    expect(() => serverAdresse('http://sync.example.org'), throwsA(isA<SyncFehler>()));
    expect(() => serverAdresse('ftp://x'), throwsA(isA<SyncFehler>()));
    expect(() => serverAdresse(''), throwsA(isA<SyncFehler>()));
  });

  test('Kopplungscode: tolerant lesbar, Paket nur mit richtigem Code', () {
    final c = Kopplungscode.neu();
    expect(c.anzeigen(), matches(RegExp(r'^([0-9A-Z]{4}-){4}[0-9A-Z]{4}$')));
    expect(Kopplungscode.lesen(c.anzeigen().toLowerCase())!.slot, c.slot);
    final k = Kontoschluessel.neu();
    final paket = c.paket('konto1', k);
    expect(c.paketOeffnen(paket)!.schluessel.bytes, k.bytes);
    expect(Kopplungscode.neu().paketOeffnen(paket), isNull);
    expect(Kopplungscode.lesen('zu kurz'), isNull);
  });
}
