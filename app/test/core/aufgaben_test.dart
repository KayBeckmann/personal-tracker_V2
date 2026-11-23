import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/aufgaben/auswahl.dart';
import 'package:personal_tracker/core/dienste/erinnerungen.dart';
import 'package:personal_tracker/core/modell/aufgabe.dart';
import 'package:personal_tracker/core/modell/bestand.dart';
import 'package:personal_tracker/core/modell/termin.dart';

Aufgabe aufgabe(
  String id, {
  DateTime? faellig,
  Prioritaet p = Prioritaet.normal,
  Wiederholung? w,
  int? um,
  DateTime? erledigt,
}) =>
    Aufgabe(
      id: id,
      titel: 'Aufgabe $id',
      faellig: faellig,
      prioritaet: p,
      wiederholung: w,
      erinnerungUm: um,
      erledigt: erledigt,
      geaendert: DateTime.utc(2026),
    );

void main() {
  // Montag, 23.11.2026, 10:00
  final jetzt = DateTime(2026, 11, 23, 10);

  test('Wiederkehrend: nächste Fälligkeit nach Abschluss', () {
    final woche = const Wiederholung(Rhythmus.woechentlich);
    // Pünktlich abgehakt → eine Woche später.
    expect(aufgabe('a', faellig: DateTime(2026, 11, 23), w: woche).naechsteFaelligkeit(jetzt), DateTime(2026, 11, 30));
    // Früh abgehakt → keine Runde übersprungen.
    expect(aufgabe('a', faellig: DateTime(2026, 11, 25), w: woche).naechsteFaelligkeit(jetzt), DateTime(2026, 12, 2));
    // Drei Wochen überfällig → nicht nachholen, nächster Serientag nach heute.
    expect(aufgabe('a', faellig: DateTime(2026, 11, 2), w: woche).naechsteFaelligkeit(jetzt), DateTime(2026, 11, 30));
    expect(aufgabe('a', faellig: DateTime(2026, 11, 4), w: woche).naechsteFaelligkeit(jetzt), DateTime(2026, 11, 25));
    // Alle 3 Tage.
    expect(
      aufgabe('a', faellig: DateTime(2026, 11, 23), w: const Wiederholung(Rhythmus.taeglich, intervall: 3)).naechsteFaelligkeit(jetzt),
      DateTime(2026, 11, 26),
    );
    // Serienende überschritten → keine weitere Runde.
    expect(
      aufgabe('a', faellig: DateTime(2026, 11, 23), w: Wiederholung(Rhythmus.woechentlich, bis: DateTime(2026, 11, 29))).naechsteFaelligkeit(jetzt),
      isNull,
    );
  });

  test('Monatlich am 31. fällt auf den Monatsletzten und bleibt beim 31.', () {
    var a = aufgabe('m', faellig: DateTime(2027, 1, 31), w: const Wiederholung(Rhythmus.monatlich));
    final tage = <DateTime>[];
    var t = DateTime(2027, 1, 31, 12);
    for (var i = 0; i < 3; i++) {
      a = a.abschliessen(t);
      tage.add(a.faellig!);
      t = a.faellig!.add(const Duration(hours: 12));
    }
    expect(tage, [DateTime(2027, 2, 28), DateTime(2027, 3, 31), DateTime(2027, 4, 30)]);
    expect(a.verlauf.map((r) => r.faellig), [DateTime(2027, 3, 31), DateTime(2027, 2, 28), DateTime(2027, 1, 31)]);
    expect(a.offen, isTrue);
  });

  test('Abhaken: einmalig erledigt, wiederkehrend mit Verlauf, Serienende erledigt', () {
    final einmal = aufgabe('e', faellig: DateTime(2026, 11, 23)).abschliessen(jetzt);
    expect(einmal.offen, isFalse);
    expect(einmal.wiedereroeffnen().offen, isTrue);

    final serie = aufgabe('s', faellig: DateTime(2026, 11, 23), w: const Wiederholung(Rhythmus.woechentlich)).abschliessen(jetzt);
    expect(serie.offen, isTrue);
    expect(serie.faellig, DateTime(2026, 11, 30));
    expect(serie.serienStart, DateTime(2026, 11, 23));
    expect(serie.verlauf.single.faellig, DateTime(2026, 11, 23));

    final letzte = aufgabe('l', faellig: DateTime(2026, 11, 23), w: Wiederholung(Rhythmus.woechentlich, bis: DateTime(2026, 11, 23))).abschliessen(jetzt);
    expect(letzte.offen, isFalse);
    expect(letzte.verlauf, hasLength(1));

    // Der Verlauf bleibt begrenzt.
    var lang = aufgabe('v', faellig: DateTime(2020, 1, 1), w: const Wiederholung(Rhythmus.taeglich));
    for (var i = 0; i < Aufgabe.verlaufMax + 5; i++) {
      lang = lang.abschliessen(lang.faellig!);
    }
    expect(lang.verlauf, hasLength(Aufgabe.verlaufMax));
  });

  test('JSON-Rundweg und Standardwerte', () {
    final a = Aufgabe(
      id: 'x',
      titel: 'Steuer',
      notiz: 'Belege sammeln',
      faellig: DateTime(2026, 12, 1),
      erinnerungUm: 8 * 60 + 30,
      prioritaet: Prioritaet.hoch,
      wiederholung: const Wiederholung(Rhythmus.jaehrlich, intervall: 1),
      verlauf: [Runde(DateTime(2025, 12, 1), DateTime.utc(2025, 12, 1, 9))],
      geaendert: DateTime.utc(2026),
    );
    final b = Aufgabe.fromJson(jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
    expect(b.erinnerung, DateTime(2026, 12, 1, 8, 30));
    final minimal = Aufgabe.fromJson({'id': 'm', 'titel': 'x', 'geaendert': '2026-01-01T00:00:00.000Z'});
    expect(minimal.prioritaet, Prioritaet.normal);
    expect(minimal.erinnerung, isNull);
  });

  test('Übersicht: Überfällig, Heute, Diese Woche ohne Dubletten', () {
    final heute = DateTime(2026, 11, 23);
    final liste = [
      aufgabe('alt', faellig: DateTime(2026, 11, 20)),
      aufgabe('alt-hoch', faellig: DateTime(2026, 11, 22), p: Prioritaet.hoch),
      aufgabe('h1', faellig: heute, p: Prioritaet.niedrig),
      aufgabe('h2', faellig: heute, p: Prioritaet.hoch),
      aufgabe('h3', faellig: heute),
      aufgabe('w-niedrig', faellig: DateTime(2026, 11, 24), p: Prioritaet.niedrig),
      aufgabe('w-normal', faellig: DateTime(2026, 11, 25)),
      aufgabe('w-hoch', faellig: DateTime(2026, 11, 29), p: Prioritaet.hoch),
      aufgabe('spaet-hoch', faellig: DateTime(2026, 12, 5), p: Prioritaet.hoch),
      aufgabe('frei-hoch', p: Prioritaet.hoch),
      aufgabe('frei', p: Prioritaet.normal),
      aufgabe('fertig', faellig: heute, p: Prioritaet.hoch, erledigt: DateTime.utc(2026, 11, 23)),
    ];
    final a = TagesAuswahl(liste, jetzt);
    expect(a.ueberfaellig.map((x) => x.id), ['alt-hoch', 'alt']);
    expect(a.heute.map((x) => x.id), ['h2', 'h3']);
    expect(a.heuteWeitere, 1);
    expect(a.woche.map((x) => x.id), ['w-hoch', 'frei-hoch']);
    expect(a.wocheWeitere, 1, reason: 'w-normal; niedrige und spätere zählen nicht');
    final gezeigt = [...a.ueberfaellig, ...a.heute, ...a.woche].map((x) => x.id).toList();
    expect(gezeigt.toSet(), hasLength(gezeigt.length));

    final g = gruppieren(liste, jetzt);
    expect(g[Gruppe.spaeter]!.map((x) => x.id), ['spaet-hoch']);
    expect(g[Gruppe.ohneDatum]!.map((x) => x.id), ['frei-hoch', 'frei']);
    expect(g.values.expand((l) => l).any((x) => x.id == 'fertig'), isFalse);
    // Der siebte Tag gehört noch zur Woche, der achte nicht.
    expect(gruppeVon(aufgabe('7', faellig: DateTime(2026, 11, 30)), jetzt), Gruppe.woche);
    expect(gruppeVon(aufgabe('8', faellig: DateTime(2026, 12, 1)), jetzt), Gruppe.spaeter);
  });

  test('Erinnerungen: nur offene Aufgaben mit Datum und Uhrzeit, Titel verborgen', () {
    final b = Bestand(aufgaben: {
      for (final a in [
        aufgabe('mit', faellig: DateTime(2026, 11, 24), um: 9 * 60),
        aufgabe('ohne-zeit', faellig: DateTime(2026, 11, 24)),
        aufgabe('vorbei', faellig: DateTime(2026, 11, 23), um: 8 * 60),
        aufgabe('erledigt', faellig: DateTime(2026, 11, 24), um: 9 * 60, erledigt: DateTime.utc(2026, 11, 22)),
      ])
        a.id: a,
    });
    final e = faelligeErinnerungen(b, jetzt, jetzt.add(const Duration(days: 30)));
    expect(e.single.titel, 'Aufgabe mit');
    expect(e.single.zeitpunkt, DateTime(2026, 11, 24, 9));
    expect(e.single.text, 'Heute fällig', reason: 'Text gilt zum Zeitpunkt der Erinnerung');
    expect(e.single.ueberschrift(mitTitel: false), 'Aufgabe');
    expect(e.single.istAufgabe, isTrue);
  });
}
