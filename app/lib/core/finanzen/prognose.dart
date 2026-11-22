import '../modell/bestand.dart';
import '../modell/datum.dart';

/// Noch nicht gebuchter, bekannt geplanter Posten eines Monats.
class OffenerPosten {
  const OffenerPosten({required this.datum, required this.empfaenger, required this.betragCent, this.planId, this.buchungId});

  final DateTime datum;
  final String empfaenger;
  final int betragCent;

  /// Vorkommen eines wiederkehrenden Plans …
  final String? planId;

  /// … oder eine einmalig geplante Buchung.
  final String? buchungId;
}

/// Monatsvorschau des Haushaltsbuchs (Kays Regel vom 22.11.2026):
///
/// Erwartet bis Monatsende = offene geplante Ausgaben
///   + max(0, Ø variable Ausgaben der bis zu 3 letzten abgeschlossenen
///     Monate − bereits gebuchte variable Ausgaben dieses Monats).
///
/// Ohne abgeschlossenen Monat gibt es keinen Durchschnitt. Einnahmen
/// stehen getrennt. Umbuchungen zählen nie. Gebuchtes, geplantes und
/// geschätztes bleiben getrennte Werte — nichts davon ist ein Kontostand.
class Prognose {
  const Prognose({
    required this.monat,
    required this.abgeschlossen,
    required this.gebuchtAusgabenCent,
    required this.gebuchtEinnahmenCent,
    required this.gebuchtVariabelCent,
    required this.offen,
    required this.basis,
    required this.ausgabenrahmenCent,
  });

  final Monat monat;

  /// Vergangener Monat: keine Schätzung mehr.
  final bool abgeschlossen;
  final int gebuchtAusgabenCent;
  final int gebuchtEinnahmenCent;
  final int gebuchtVariabelCent;
  final List<OffenerPosten> offen;

  /// Variable Ausgaben je abgeschlossenem Monat, auf dem der Durchschnitt
  /// beruht (älteste zuerst, höchstens drei).
  final List<({Monat monat, int cent})> basis;
  final int? ausgabenrahmenCent;

  int get offenAusgabenCent => offen.where((p) => p.betragCent < 0).fold(0, (s, p) => s - p.betragCent);
  int get offenEinnahmenCent => offen.where((p) => p.betragCent > 0).fold(0, (s, p) => s + p.betragCent);

  /// `null` ohne abgeschlossenen Monat.
  int? get durchschnittVariabelCent =>
      basis.isEmpty ? null : (basis.fold(0, (s, b) => s + b.cent) / basis.length).round();

  /// Geschätzte noch kommende variable Ausgaben; `null` ohne Grundlage.
  int? get restVariabelCent {
    if (abgeschlossen) return 0;
    final d = durchschnittVariabelCent;
    if (d == null) return null;
    final r = d - gebuchtVariabelCent;
    return r < 0 ? 0 : r;
  }

  int get erwartetBisMonatsendeCent => (abgeschlossen ? 0 : offenAusgabenCent) + (restVariabelCent ?? 0);
  int get erwartetGesamtAusgabenCent => gebuchtAusgabenCent + erwartetBisMonatsendeCent;
  int get erwartetGesamtEinnahmenCent => gebuchtEinnahmenCent + (abgeschlossen ? 0 : offenEinnahmenCent);

  /// Rahmen minus (gebucht + erwartet); `null` ohne Rahmen.
  int? get rahmenRestCent => ausgabenrahmenCent == null ? null : ausgabenrahmenCent! - erwartetGesamtAusgabenCent;
}

Prognose berechnePrognose(Bestand bestand, DateTime heute, {Monat? monat}) {
  final aktuell = monatVon(heute);
  final m = monat ?? aktuell;

  var ausgaben = 0, einnahmen = 0, variabel = 0;
  final offen = <OffenerPosten>[];
  final variabelJeMonat = <Monat, int>{};
  Monat? ersterMonat;

  for (final b in bestand.buchungen.values) {
    if (b.istUmbuchung) continue;
    final bm = monatVon(b.datum);
    if (b.gebucht) {
      if (ersterMonat == null || bm < ersterMonat) ersterMonat = bm;
      if (b.variabel && b.betragCent < 0) {
        variabelJeMonat[bm] = (variabelJeMonat[bm] ?? 0) - b.betragCent;
      }
      if (bm == m) {
        if (b.betragCent < 0) {
          ausgaben -= b.betragCent;
          if (b.variabel) variabel -= b.betragCent;
        } else {
          einnahmen += b.betragCent;
        }
      }
    } else if (bm == m) {
      offen.add(OffenerPosten(datum: b.datum, empfaenger: b.empfaenger, betragCent: b.betragCent, buchungId: b.id));
    }
  }

  final erledigt = {
    for (final b in bestand.buchungen.values)
      if (b.planId != null && b.planMonat != null) '${b.planId}|${b.planMonat}',
  };
  for (final p in bestand.plaene.values) {
    if (p.giltIm(m) && !erledigt.contains('${p.id}|$m')) {
      offen.add(OffenerPosten(datum: p.faelligIm(m), empfaenger: p.empfaenger, betragCent: p.betragCent, planId: p.id));
    }
  }
  offen.sort((a, b) => a.datum.compareTo(b.datum));

  // Abgeschlossen = vor dem aktuellen Monat und ab dem ersten Monat mit
  // gebuchten Daten; davon die letzten drei.
  final basis = <({Monat monat, int cent})>[];
  if (ersterMonat != null) {
    final bisMonat = (m < aktuell ? m : aktuell) - 1;
    for (var x = bisMonat; x >= ersterMonat && basis.length < 3; x--) {
      basis.insert(0, (monat: x, cent: variabelJeMonat[x] ?? 0));
    }
  }

  return Prognose(
    monat: m,
    abgeschlossen: m < aktuell,
    gebuchtAusgabenCent: ausgaben,
    gebuchtEinnahmenCent: einnahmen,
    gebuchtVariabelCent: variabel,
    offen: offen,
    basis: basis,
    ausgabenrahmenCent: bestand.einstellungen.ausgabenrahmenCent,
  );
}
