import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/finanzen/prognose.dart';
import 'package:personal_tracker/core/modell/bestand.dart';
import 'package:personal_tracker/core/modell/datum.dart';
import 'package:personal_tracker/core/modell/finanzen.dart';

final _t = DateTime.utc(2026);
var _n = 0;

Buchung buchung(DateTime d, int cent, {BuchungsStatus status = BuchungsStatus.gebucht, String konto = 'giro', String? umbuchung, String? plan, bool ausPlanung = false}) =>
    Buchung(
      id: 'b${_n++}',
      kontoId: konto,
      datum: d,
      empfaenger: 'Test',
      betragCent: cent,
      status: status,
      umbuchungId: umbuchung,
      planId: plan,
      planMonat: plan == null ? null : monatVon(d),
      ausPlanung: ausPlanung,
      geaendert: _t,
    );

Bestand bestand(List<Buchung> b, {List<Plan> plaene = const [], int? rahmen}) => Bestand(
      konten: {
        'giro': Konto(id: 'giro', name: 'Giro', art: KontoArt.bank, anfangssaldoCent: 100000, geaendert: _t),
        'bar': Konto(id: 'bar', name: 'Bar', art: KontoArt.bargeld, geaendert: _t),
      },
      buchungen: {for (final x in b) x.id: x},
      plaene: {for (final p in plaene) p.id: p},
      einstellungen: Einstellungen(ausgabenrahmenCent: rahmen),
    );

void main() {
  final heute = DateTime(2026, 11, 22);

  test('Ohne abgeschlossenen Monat: keine Durchschnittsschätzung', () {
    final p = berechnePrognose(bestand([buchung(DateTime(2026, 11, 3), -5000)]), heute);
    expect(p.basis, isEmpty);
    expect(p.durchschnittVariabelCent, isNull);
    expect(p.restVariabelCent, isNull);
    expect(p.gebuchtAusgabenCent, 5000);
    expect(p.erwartetBisMonatsendeCent, 0);
  });

  test('Durchschnitt aus einem, zwei und drei abgeschlossenen Monaten', () {
    final b1 = [buchung(DateTime(2026, 10, 5), -30000), buchung(DateTime(2026, 11, 2), -10000)];
    final p1 = berechnePrognose(bestand(b1), heute);
    expect(p1.basis.map((b) => b.monat), [monatVon(DateTime(2026, 10))]);
    expect(p1.durchschnittVariabelCent, 30000);
    expect(p1.restVariabelCent, 20000, reason: '300 € Ø − 100 € schon gebucht');

    final b2 = [...b1, buchung(DateTime(2026, 9, 5), -10000)];
    expect(berechnePrognose(bestand(b2), heute).durchschnittVariabelCent, 20000);

    final b3 = [...b2, buchung(DateTime(2026, 8, 5), -20000), buchung(DateTime(2026, 7, 5), -99999)];
    final p3 = berechnePrognose(bestand(b3), heute);
    expect(p3.basis, hasLength(3), reason: 'höchstens drei Monate');
    expect(p3.durchschnittVariabelCent, 20000);

    // Monat ohne Ausgaben zwischen erstem Datenmonat und jetzt zählt als 0.
    final lueckig = [buchung(DateTime(2026, 8, 5), -30000), buchung(DateTime(2026, 11, 1), -1)];
    final pl = berechnePrognose(bestand(lueckig), heute);
    expect(pl.basis.map((b) => b.cent), [30000, 0, 0]);
    expect(pl.durchschnittVariabelCent, 10000);
  });

  test('Mehr schon ausgegeben als der Durchschnitt: Rest 0, nie negativ', () {
    final p = berechnePrognose(
      bestand([buchung(DateTime(2026, 10, 5), -10000), buchung(DateTime(2026, 11, 2), -50000)]),
      heute,
    );
    expect(p.restVariabelCent, 0);
  });

  test('Umbuchung ändert Salden gegenläufig, aber nie Einnahmen/Ausgaben', () {
    final b = bestand([
      buchung(DateTime(2026, 10, 5), -20000),
      buchung(DateTime(2026, 11, 3), -5000, konto: 'giro', umbuchung: 'u1'),
      buchung(DateTime(2026, 11, 3), 5000, konto: 'bar', umbuchung: 'u1'),
    ]);
    final p = berechnePrognose(b, heute);
    expect(p.gebuchtAusgabenCent, 0);
    expect(p.gebuchtEinnahmenCent, 0);
    expect(p.restVariabelCent, 20000);
    expect(b.saldoCent('giro'), 100000 - 20000 - 5000);
    expect(b.saldoCent('bar'), 5000);
  });

  test('Geplantes wird nicht doppelt gezählt', () {
    final miete = Plan(
      id: 'miete',
      kontoId: 'giro',
      empfaenger: 'Vermieter',
      betragCent: -85000,
      tag: 1,
      ab: monatVon(DateTime(2026, 9)),
      geaendert: _t,
    );
    final b = bestand(
      [
        // Oktober: Miete gebucht (aus Plan) + variable 200 €.
        buchung(DateTime(2026, 10, 1), -85000, plan: 'miete'),
        buchung(DateTime(2026, 10, 9), -20000),
        // November: einmalig geplant (offen) und einmalig geplant+gebucht.
        buchung(DateTime(2026, 11, 28), -12000, status: BuchungsStatus.geplant),
        buchung(DateTime(2026, 11, 10), -3000, ausPlanung: true),
        buchung(DateTime(2026, 11, 25), 250000, status: BuchungsStatus.geplant),
      ],
      plaene: [miete],
      rahmen: 150000,
    );
    final p = berechnePrognose(b, heute);
    expect(p.basis.single.cent, 20000, reason: 'Miete ist kein variabler Durchschnitt');
    expect(p.gebuchtAusgabenCent, 3000);
    expect(p.gebuchtVariabelCent, 0);
    expect(p.offen.map((o) => o.betragCent), [-85000, 250000, -12000]);
    expect(p.offenAusgabenCent, 85000 + 12000, reason: 'Miete November noch offen + einmaliger Posten');
    expect(p.offenEinnahmenCent, 250000);
    expect(p.restVariabelCent, 20000);
    expect(p.erwartetBisMonatsendeCent, 85000 + 12000 + 20000);
    expect(p.erwartetGesamtAusgabenCent, 3000 + 117000);
    expect(p.rahmenRestCent, 150000 - 120000);

    // Miete im November gebucht → nicht mehr offen, nicht variabel.
    final gebucht = bestand([...b.buchungen.values, buchung(DateTime(2026, 11, 1), -85000, plan: 'miete')], plaene: [miete]);
    final p2 = berechnePrognose(gebucht, heute);
    expect(p2.offenAusgabenCent, 12000);
    expect(p2.gebuchtAusgabenCent, 88000);
    expect(p2.gebuchtVariabelCent, 0);
  });

  test('Vergangener Monat: keine Schätzung, Kontostand ohne Geplantes', () {
    final b = bestand([
      buchung(DateTime(2026, 9, 5), -10000),
      buchung(DateTime(2026, 10, 5), -20000),
      buchung(DateTime(2026, 10, 20), -5000, status: BuchungsStatus.geplant),
    ]);
    final p = berechnePrognose(b, heute, monat: monatVon(DateTime(2026, 10)));
    expect(p.abgeschlossen, isTrue);
    expect(p.restVariabelCent, 0);
    expect(p.erwartetBisMonatsendeCent, 0);
    expect(p.basis.map((x) => x.monat), [monatVon(DateTime(2026, 9))], reason: 'nur Monate davor');
    expect(b.saldoCent('giro'), 100000 - 30000);
  });
}
