import 'agent.dart';
import 'aufgabe.dart';
import 'einkauf.dart';
import 'finanzen.dart';
import 'konflikt.dart';
import 'notiz.dart';
import '../raeume/raum.dart';
import 'termin.dart';

/// Entschlüsselter Datenbestand im Speicher (nur solange entsperrt).
class Bestand {
  const Bestand({
    this.termine = const {},
    this.aufgaben = const {},
    this.notizen = const {},
    this.konten = const {},
    this.buchungen = const {},
    this.plaene = const {},
    this.konflikte = const {},
    this.raeume = const {},
    this.filialen = const {},
    this.preise = const {},
    this.einkaufslisten = const {},
    this.posten = const {},
    this.einkaeufe = const {},
    this.agenten = const {},
    this.agentProtokoll = const {},
    this.agentVorschlaege = const {},
    this.einstellungen = const Einstellungen(),
  });

  final Map<String, Termin> termine;
  final Map<String, Aufgabe> aufgaben;
  final Map<String, Notiz> notizen;
  final Map<String, Konto> konten;
  final Map<String, Buchung> buchungen;
  final Map<String, Plan> plaene;

  /// Abweichende Fassungen aus dem Abgleich (siehe [Konflikt]).
  final Map<String, Konflikt> konflikte;

  /// Geteilte Kalender, Aufgabenlisten und Vault-Ordner (eigene und fremde).
  final Map<String, Raum> raeume;

  /// Einkauf (M6): Filialen, beobachtete Preise, Listen, Posten und
  /// abgeschlossene Einkäufe.
  final Map<String, Filiale> filialen;
  final Map<String, Preis> preise;
  final Map<String, Einkaufsliste> einkaufslisten;
  final Map<String, Posten> posten;
  final Map<String, Einkauf> einkaeufe;

  /// KI-Agenten (M8): Zugänge, Protokoll ihrer Aufrufe, Vorschläge.
  final Map<String, AgentZugang> agenten;
  final Map<String, AgentProtokoll> agentProtokoll;
  final Map<String, AgentVorschlag> agentVorschlaege;
  final Einstellungen einstellungen;

  Bestand kopie({
    Map<String, Termin>? termine,
    Map<String, Aufgabe>? aufgaben,
    Map<String, Notiz>? notizen,
    Map<String, Konto>? konten,
    Map<String, Buchung>? buchungen,
    Map<String, Plan>? plaene,
    Map<String, Konflikt>? konflikte,
    Map<String, Raum>? raeume,
    Map<String, Filiale>? filialen,
    Map<String, Preis>? preise,
    Map<String, Einkaufsliste>? einkaufslisten,
    Map<String, Posten>? posten,
    Map<String, Einkauf>? einkaeufe,
    Map<String, AgentZugang>? agenten,
    Map<String, AgentProtokoll>? agentProtokoll,
    Map<String, AgentVorschlag>? agentVorschlaege,
    Einstellungen? einstellungen,
  }) =>
      Bestand(
        termine: termine ?? this.termine,
        aufgaben: aufgaben ?? this.aufgaben,
        notizen: notizen ?? this.notizen,
        konten: konten ?? this.konten,
        buchungen: buchungen ?? this.buchungen,
        plaene: plaene ?? this.plaene,
        konflikte: konflikte ?? this.konflikte,
        raeume: raeume ?? this.raeume,
        filialen: filialen ?? this.filialen,
        preise: preise ?? this.preise,
        einkaufslisten: einkaufslisten ?? this.einkaufslisten,
        posten: posten ?? this.posten,
        einkaeufe: einkaeufe ?? this.einkaeufe,
        agenten: agenten ?? this.agenten,
        agentProtokoll: agentProtokoll ?? this.agentProtokoll,
        agentVorschlaege: agentVorschlaege ?? this.agentVorschlaege,
        einstellungen: einstellungen ?? this.einstellungen,
      );

  /// Kontostand: Anfangssaldo plus alle gebuchten Buchungen (inklusive
  /// Umbuchungen). Geplantes zählt nicht.
  int saldoCent(String kontoId) {
    var s = konten[kontoId]?.anfangssaldoCent ?? 0;
    for (final b in buchungen.values) {
      if (b.kontoId == kontoId && b.gebucht) s += b.betragCent;
    }
    return s;
  }

  /// Die Gegenbuchung einer Umbuchung.
  Buchung? gegenbuchung(Buchung b) => b.umbuchungId == null
      ? null
      : buchungen.values.where((x) => x.umbuchungId == b.umbuchungId && x.id != b.id).firstOrNull;

  List<Notiz> get notizenNeuesteZuerst => notizen.values.toList()..sort((a, b) => b.geaendert.compareTo(a.geaendert));

  List<Konto> get kontenSortiert => konten.values.toList()
    ..sort((a, b) {
      if (a.archiviert != b.archiviert) return a.archiviert ? 1 : -1;
      final art = a.art.index.compareTo(b.art.index);
      return art != 0 ? art : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  /// Räume einer Art, nach Name.
  List<Raum> raeumeDerArt(RaumArt art) => raeume.values.where((r) => r.art == art).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  int get anzahlDatensaetze =>
      termine.length +
      aufgaben.length +
      notizen.length +
      konten.length +
      buchungen.length +
      plaene.length +
      filialen.length +
      preise.length +
      einkaufslisten.length +
      posten.length +
      einkaeufe.length;

  /// Raum eines geteilten Datensatzes (`null` = privat oder unbekannt).
  String? raumVon(String bereich, String id) => switch (bereich) {
        'termine' => termine[id]?.raum,
        'aufgaben' => aufgaben[id]?.raum,
        'filialen' => filialen[id]?.raum,
        'preise' => preise[id]?.raum,
        'einkaufslisten' => einkaufslisten[id]?.raum,
        'posten' => posten[id]?.raum,
        _ => null,
      };

  /// Offene Posten einer Liste (noch nicht gekauft).
  List<Posten> postenVon(String listeId) => posten.values.where((p) => p.listeId == listeId && p.offen).toList()
    ..sort((a, b) => a.abgehakt == b.abgehakt ? a.name.toLowerCase().compareTo(b.name.toLowerCase()) : (a.abgehakt ? 1 : -1));
}
