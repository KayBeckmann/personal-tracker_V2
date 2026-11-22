import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/kalender/vorkommen.dart';
import 'package:personal_tracker/core/modell/termin.dart';

Termin termin(DateTime beginn, {DateTime? ende, bool ganztag = false, Wiederholung? w, Set<String> ausnahmen = const {}, int? erinnerung}) =>
    Termin(
      id: 't',
      titel: 'Test',
      beginn: beginn,
      ende: ende,
      ganztaegig: ganztag,
      wiederholung: w,
      ausnahmen: ausnahmen,
      erinnerungMinuten: erinnerung,
      geaendert: DateTime.utc(2026),
    );

List<DateTime> starts(Termin t, DateTime von, DateTime bis) => [for (final v in vorkommenIm(t, von, bis)) v.beginn];

void main() {
  test('Einzeltermin nur an seinem Tag', () {
    final t = termin(DateTime(2026, 11, 23, 9, 30));
    expect(starts(t, DateTime(2026, 11, 23), DateTime(2026, 11, 23)), [DateTime(2026, 11, 23, 9, 30)]);
    expect(starts(t, DateTime(2026, 11, 24), DateTime(2026, 11, 30)), isEmpty);
  });

  test('Wöchentlich, alle 2 Wochen, mit Ende und gelöschtem Vorkommen', () {
    final t = termin(
      DateTime(2026, 11, 2, 18),
      w: Wiederholung(Rhythmus.woechentlich, intervall: 2, bis: DateTime(2026, 12, 31)),
      ausnahmen: {'2026-11-30'},
    );
    expect(starts(t, DateTime(2026, 11, 1), DateTime(2027, 1, 31)), [
      DateTime(2026, 11, 2, 18),
      DateTime(2026, 11, 16, 18),
      DateTime(2026, 12, 14, 18),
      DateTime(2026, 12, 28, 18),
    ]);
  });

  test('Täglich über die Zeitumstellung behält die Uhrzeit; lange Serien springen', () {
    final t = termin(DateTime(2020, 3, 1, 8), w: const Wiederholung(Rhythmus.taeglich));
    final v = starts(t, DateTime(2026, 3, 28), DateTime(2026, 3, 30));
    expect(v, [DateTime(2026, 3, 28, 8), DateTime(2026, 3, 29, 8), DateTime(2026, 3, 30, 8)]);
  });

  test('Monatlich am 31. entfällt in kürzeren Monaten; jährlich am 29.02.', () {
    final m = termin(DateTime(2026, 1, 31, 10), w: const Wiederholung(Rhythmus.monatlich));
    expect(starts(m, DateTime(2026, 1, 1), DateTime(2026, 5, 31)).map((d) => d.month), [1, 3, 5]);
    final j = termin(DateTime(2024, 2, 29), ganztag: true, w: const Wiederholung(Rhythmus.jaehrlich));
    expect(starts(j, DateTime(2025, 1, 1), DateTime(2028, 12, 31)).map((d) => d.year), [2028]);
  });

  test('Mehrtägig: berührt auch Folgetage; Termin bis Mitternacht nicht', () {
    final urlaub = termin(DateTime(2026, 11, 20), ende: DateTime(2026, 11, 24), ganztag: true);
    expect(vorkommenIm(urlaub, DateTime(2026, 11, 23), DateTime(2026, 11, 23)), hasLength(1));
    expect(vorkommenIm(urlaub, DateTime(2026, 11, 25), DateTime(2026, 11, 25)), isEmpty);
    final abend = termin(DateTime(2026, 11, 22, 20), ende: DateTime(2026, 11, 23));
    expect(vorkommenIm(abend, DateTime(2026, 11, 23), DateTime(2026, 11, 23)), isEmpty);

    final wiederkehrendMehrtaegig = termin(
      DateTime(2026, 11, 6),
      ende: DateTime(2026, 11, 8),
      ganztag: true,
      w: const Wiederholung(Rhythmus.woechentlich),
    );
    expect(starts(wiederkehrendMehrtaegig, DateTime(2026, 11, 15), DateTime(2026, 11, 15)), [DateTime(2026, 11, 13)]);
  });

  test('Erinnerungszeitpunkt: Minuten vorher, ganztägig ab 09:00', () {
    final t = termin(DateTime(2026, 11, 23, 9, 30), erinnerung: 15);
    expect(vorkommenIm(t, DateTime(2026, 11, 23), DateTime(2026, 11, 23)).single.erinnerung, DateTime(2026, 11, 23, 9, 15));
    final g = termin(DateTime(2026, 11, 24), ganztag: true, erinnerung: 24 * 60);
    expect(vorkommenIm(g, DateTime(2026, 11, 24), DateTime(2026, 11, 24)).single.erinnerung, DateTime(2026, 11, 23, 9));
  });
}
