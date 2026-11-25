import '../modell/einkauf.dart';

/// Woher der Preis eines Postens stammt.
enum PreisHerkunft {
  /// Aus der Filiale der Liste.
  filiale,

  /// Aus einer anderen Filiale derselben Region (nur Schätzung).
  region,

  /// Die Liste hat keine Filiale: jüngster bekannter Preis (nur Schätzung).
  ohneFiliale,

  /// Packung und Posten lassen sich nicht umrechnen (z. B. Stück gegen g).
  nichtVergleichbar,

  /// Kein Preis bekannt – zählt nicht als 0 €.
  unbekannt,
}

typedef PostenWert = ({Preis? preis, int? kostenCent, PreisHerkunft herkunft});

/// Jüngster Preis für [schluessel], optional nur aus bestimmten Filialen.
/// Mit [ean] zählen zuerst Preise mit demselben Barcode (genau das
/// Produkt), erst ohne solche die Preise mit gleichem Namen.
Preis? juengsterPreis(Iterable<Preis> preise, String schluessel, {String? ean, bool Function(String filialeId)? filiale}) {
  if (ean != null) {
    final genau = _juengster(preise, (p) => p.ean == ean, filiale);
    if (genau != null) return genau;
  }
  return _juengster(preise, (p) => p.schluessel == schluessel, filiale);
}

Preis? _juengster(Iterable<Preis> preise, bool Function(Preis) passt, bool Function(String filialeId)? filiale) {
  Preis? best;
  for (final p in preise) {
    if (!passt(p) || (filiale != null && !filiale(p.filialeId))) continue;
    if (best == null || p.datum.isAfter(best.datum) || (p.datum == best.datum && p.geaendert.isAfter(best.geaendert))) best = p;
  }
  return best;
}

/// Kosten von [menge] [einheit] bei diesem Packungspreis; `null`, wenn
/// sich die Einheiten nicht umrechnen lassen.
int? kostenCent(Preis p, double menge, Einheit einheit) {
  if (einheit == Einheit.packung) return (p.packungsPreisCent * menge).round();
  if (p.packungsEinheit == Einheit.packung) {
    // Preis je Packung, Posten in Stück: eine Packung je Stück.
    return einheit == Einheit.stueck ? (p.packungsPreisCent * menge).round() : null;
  }
  if (einheit.basis != p.packungsEinheit.basis || p.packungsMenge <= 0) return null;
  final anteil = (menge * einheit.faktor) / (p.packungsMenge * p.packungsEinheit.faktor);
  return (p.packungsPreisCent * anteil).round();
}

/// Bewertet einen Posten für eine Liste in [filialeId]. Bevorzugt wird der
/// jüngste Preis aus genau dieser Filiale, dann aus derselben Region.
/// Zwei Filialen einer Kette werden nie vermischt.
PostenWert bewerten(Posten p, Iterable<Preis> preise, Map<String, Filiale> filialen, String? filialeId) {
  Preis? preis;
  var herkunft = PreisHerkunft.unbekannt;
  if (filialeId == null) {
    preis = juengsterPreis(preise, p.schluessel, ean: p.ean);
    if (preis != null) herkunft = PreisHerkunft.ohneFiliale;
  } else {
    preis = juengsterPreis(preise, p.schluessel, ean: p.ean, filiale: (f) => f == filialeId);
    if (preis != null) {
      herkunft = PreisHerkunft.filiale;
    } else {
      final region = filialen[filialeId]?.regionVergleich;
      if (region != null) {
        preis = juengsterPreis(preise, p.schluessel, ean: p.ean, filiale: (f) => filialen[f]?.regionVergleich == region);
        if (preis != null) herkunft = PreisHerkunft.region;
      }
    }
  }
  if (preis == null) return (preis: null, kostenCent: null, herkunft: PreisHerkunft.unbekannt);
  final k = kostenCent(preis, p.menge, p.einheit);
  return (preis: preis, kostenCent: k, herkunft: k == null ? PreisHerkunft.nichtVergleichbar : herkunft);
}

/// Geschätzte Summe einer Liste. Sie ist keine Buchung; Posten ohne
/// verwertbaren Preis werden gezählt, nicht als 0 € addiert.
class ListenSchaetzung {
  ListenSchaetzung(Iterable<Posten> posten, Iterable<Preis> preise, Map<String, Filiale> filialen, String? filialeId) {
    for (final p in posten) {
      final w = bewerten(p, preise, filialen, filialeId);
      werte[p.id] = w;
      if (w.kostenCent == null) {
        ohnePreis++;
        continue;
      }
      summeCent += w.kostenCent!;
      if (w.herkunft != PreisHerkunft.filiale) geschaetzt++;
    }
  }

  final werte = <String, PostenWert>{};
  int summeCent = 0;

  /// Posten ohne (verwertbaren) Preis.
  int ohnePreis = 0;

  /// Posten mit Preis aus einer anderen Filiale oder ohne Filiale.
  int geschaetzt = 0;

  bool get vollstaendig => ohnePreis == 0;
}
