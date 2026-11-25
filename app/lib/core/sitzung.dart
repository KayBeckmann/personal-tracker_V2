import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sembast/sembast.dart' show DatabaseClient;
import 'package:uuid/uuid.dart';

import 'dienste/biometrie.dart';
import 'dienste/erinnerungen.dart';
import 'krypto/kdf.dart';
import 'krypto/recovery_schluessel.dart';
import 'krypto/schluesselbund.dart';
import 'modell/aufgabe.dart';
import 'modell/einkauf.dart';
import 'modell/bestand.dart';
import 'modell/datum.dart';
import 'modell/finanzen.dart';
import 'modell/notiz.dart';
import 'modell/termin.dart';
import 'raeume/raum.dart';
import 'speicher/ablage.dart';
import 'speicher/backup.dart';
import 'speicher/rohdaten.dart';
import 'speicher/schema.dart';
import 'sync/sync_motor.dart';
import 'sync/sync_stand.dart';

final ablageProvider = Provider<Ablage>((ref) => throw UnimplementedError('Ablage wird in main() geöffnet'));

/// Beim Start gelesener Schlüsselbund (`null` = noch nicht eingerichtet).
final startBundProvider = Provider<Schluesselbund?>((ref) => null);
final biometrieProvider = Provider<Biometrie>((ref) => plattformBiometrie());
final erinnerungenProvider = Provider<ErinnerungsDienst>((ref) => plattformErinnerungen());

/// Ableitungsparameter für neue Passwörter (Tests nutzen schnelle Werte).
final kdfProvider = Provider<KdfParameter Function()>((ref) => KdfParameter.standard);
final uhrProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final sitzungProvider = NotifierProvider<SitzungNotifier, Sitzung>(SitzungNotifier.new);

/// Entsperrter Datenbestand; nur verwenden, wo die Sitzung entsperrt ist.
final bestandProvider = Provider<Bestand>((ref) {
  final s = ref.watch(sitzungProvider);
  return s is Entsperrt ? s.bestand : const Bestand();
});

sealed class Sitzung {
  const Sitzung();
}

/// Noch kein Schlüsselbund: neu beginnen oder aus Backup wiederherstellen.
class Einrichtung extends Sitzung {
  const Einrichtung();
}

class Gesperrt extends Sitzung {
  const Gesperrt(this.bund, {this.fehler});
  final Schluesselbund bund;
  final String? fehler;
}

class Entsperrt extends Sitzung {
  const Entsperrt({
    required this.bund,
    required this.dek,
    required this.bestand,
    this.neuesPasswortNoetig = false,
    this.defekt = const [],
    this.erinnerung,
  });

  final Schluesselbund bund;
  final Uint8List dek;
  final Bestand bestand;

  /// Nach Entsperren per Recovery-Schlüssel muss ein neues Passwort her.
  final bool neuesPasswortNoetig;

  /// Datensätze, die sich nicht entschlüsseln ließen (Bereich/ID).
  final List<String> defekt;
  final ErinnerungsStatus? erinnerung;

  Entsperrt mit({Schluesselbund? bund, Bestand? bestand, bool? neuesPasswortNoetig, ErinnerungsStatus? erinnerung}) => Entsperrt(
        bund: bund ?? this.bund,
        dek: dek,
        bestand: bestand ?? this.bestand,
        neuesPasswortNoetig: neuesPasswortNoetig ?? this.neuesPasswortNoetig,
        defekt: defekt,
        erinnerung: erinnerung ?? this.erinnerung,
      );
}

class SitzungNotifier extends Notifier<Sitzung> {
  static const _uuid = Uuid();
  static const metaBund = 'schluesselbund';
  static const metaSchema = 'schema';

  Ablage get _ablage => ref.read(ablageProvider);
  DateTime get _jetzt => ref.read(uhrProvider)();

  /// Lokale Änderungen und das Einspielen vom Server laufen nacheinander.
  final sperre = Sperre();

  /// Mit einem Sync-Konto verbunden: Änderungen werden vorgemerkt.
  bool _syncAktiv = false;
  bool get syncAktiv => _syncAktiv;

  @override
  Sitzung build() {
    final bund = ref.read(startBundProvider);
    return bund == null ? const Einrichtung() : Gesperrt(bund);
  }

  Entsperrt get _offen {
    final s = state;
    if (s is! Entsperrt) throw StateError('Nicht entsperrt');
    return s;
  }

  String neueId() => _uuid.v4();

  // ---------------------------------------------------------------------
  // Einrichten, Entsperren, Sperren

  /// Erster Schritt der Einrichtung: noch nichts speichern, bis der
  /// Recovery-Schlüssel bestätigt ist.
  Future<({Schluesselbund bund, Uint8List dek, RecoverySchluessel recovery})> einrichtungVorbereiten(String passwort) async {
    final r = RecoverySchluessel.neu();
    final (:bund, :dek) = await Schluesselbund.anlegen(passwort, r, kdf: ref.read(kdfProvider)());
    return (bund: bund, dek: dek, recovery: r);
  }

  Future<void> einrichtungAbschliessen(Schluesselbund bund, Uint8List dek) async {
    await _ablage.transaktion((tx) async {
      await _ablage.setzeMeta(metaSchema, aktuellesSchema, tx: tx);
      await _ablage.setzeMeta(metaBund, bund.toJson(), tx: tx);
    });
    state = Entsperrt(bund: bund, dek: dek, bestand: const Bestand());
  }

  Future<bool> entsperren(String passwort) async {
    final s = state;
    if (s is! Gesperrt) return false;
    final dek = await s.bund.mitPasswort(passwort);
    if (dek == null) return false;
    await _oeffnen(s.bund, dek);
    return true;
  }

  Future<bool> entsperrenMitRecovery(RecoverySchluessel r) async {
    final s = state;
    if (s is! Gesperrt) return false;
    final dek = s.bund.mitRecovery(r);
    if (dek == null) return false;
    await _oeffnen(s.bund, dek, neuesPasswortNoetig: true);
    return true;
  }

  Future<bool> entsperrenMitBiometrie() async {
    final s = state;
    if (s is! Gesperrt || !s.bund.biometrie) return false;
    final Uint8List? dek;
    try {
      dek = await ref.read(biometrieProvider).lesen();
    } catch (_) {
      return false;
    }
    if (dek == null || !s.bund.passt(dek)) return false;
    await _oeffnen(s.bund, dek);
    return true;
  }

  Future<void> _oeffnen(Schluesselbund bund, Uint8List dek, {bool neuesPasswortNoetig = false}) async {
    final schema = (await _ablage.meta(metaSchema) as int?) ?? aktuellesSchema;
    final defekt = <String>[];
    Rohdaten roh = {for (final b in Ablage.bereiche) b: await _ablage.lesen(dek, b, defekt: defekt)};
    if (schema != aktuellesSchema) {
      // Wirft bei neueren Ständen, bevor etwas verändert wird.
      roh = migrieren(roh, schema);
      await _alleSchreiben(dek, roh, schema: aktuellesSchema);
    }
    final bestand = bestandAus(roh);
    _syncAktiv = await SyncStand(_ablage, dek).verbindung() != null;
    state = Entsperrt(bund: bund, dek: dek, bestand: bestand, neuesPasswortNoetig: neuesPasswortNoetig, defekt: defekt);
    unawaited(_erinnerungenPlanen());
  }

  /// Liest den Bestand nach einem Abgleich neu aus der Ablage.
  Future<void> neuLaden() async {
    final s = state;
    if (s is! Entsperrt) return;
    final defekt = <String>[];
    final roh = {for (final b in Ablage.bereiche) b: await _ablage.lesen(s.dek, b, defekt: defekt)};
    final jetzt = state;
    if (jetzt is! Entsperrt) return;
    state = jetzt.mit(bestand: bestandAus(roh));
    unawaited(_erinnerungenPlanen());
  }

  /// Sync-Verbindung hergestellt oder getrennt.
  void syncAktivSetzen(bool an) => _syncAktiv = an;

  /// Schlüsselbund ersetzen (Recovery-Schlüssel eines Sync-Kontos).
  Future<void> bundErsetzen(Schluesselbund bund) async {
    await _ablage.setzeMeta(metaBund, bund.toJson());
    state = _offen.mit(bund: bund);
  }

  /// Frisches Gerät aus einem Sync-Konto: Schlüsselbund und Verbindung
  /// speichern, entsperrt mit leerem Bestand starten; die Daten kommen
  /// mit dem ersten Abgleich.
  Future<void> einrichtenAusSync(Schluesselbund bund, Uint8List dek, Verbindung v) async {
    final stand = SyncStand(_ablage, dek);
    await _ablage.transaktion((tx) async {
      await stand.loeschen(tx: tx);
      await stand.setzeVerbindung(v, tx: tx);
      await _ablage.setzeMeta(metaSchema, aktuellesSchema, tx: tx);
      await _ablage.setzeMeta(metaBund, bund.toJson(), tx: tx);
    });
    _syncAktiv = true;
    state = Entsperrt(bund: bund, dek: dek, bestand: const Bestand());
  }

  Future<void> sperren() async {
    final s = state;
    if (s is! Entsperrt) return;
    await ref.read(erinnerungenProvider).beenden();
    state = Gesperrt(s.bund);
  }

  Future<void> neuesPasswort(String passwort) async {
    final s = _offen;
    final bund = await s.bund.mitNeuemPasswort(s.dek, passwort, kdf: ref.read(kdfProvider)());
    await _ablage.setzeMeta(metaBund, bund.toJson());
    state = s.mit(bund: bund, neuesPasswortNoetig: false);
  }

  Future<bool> passwortAendern(String alt, String neu) async {
    if (await _offen.bund.mitPasswort(alt) == null) return false;
    await neuesPasswort(neu);
    return true;
  }

  Future<void> biometrieSetzen(bool an) async {
    final s = _offen;
    final b = ref.read(biometrieProvider);
    if (an) {
      await b.speichern(s.dek);
    } else {
      await b.loeschen();
    }
    final bund = s.bund.mitBiometrie(an);
    await _ablage.setzeMeta(metaBund, bund.toJson());
    state = (state as Entsperrt).mit(bund: bund);
  }

  /// Löscht alles auf diesem Gerät (letzter Ausweg ohne Passwort und
  /// Recovery-Schlüssel).
  Future<void> zuruecksetzen() async {
    await ref.read(erinnerungenProvider).beenden();
    try {
      await ref.read(biometrieProvider).loeschen();
    } catch (_) {}
    await _ablage.transaktion((tx) async {
      for (final b in [...Ablage.bereiche, ...Ablage.syncBereiche, ...Ablage.vaultBereiche]) {
        await _ablage.leeren(b, tx: tx);
      }
      await _ablage.setzeMeta(metaBund, null, tx: tx);
      await _ablage.setzeMeta(metaSchema, null, tx: tx);
    });
    _syncAktiv = false;
    state = const Einrichtung();
  }

  // ---------------------------------------------------------------------
  // Datensätze

  /// Schreibt Datensätze und merkt sie bei aktivem Sync vor. [neu] baut
  /// den Bestand aus dem Stand *nach* dem Warten auf die Sperre, damit ein
  /// gleichzeitiger Abgleich nicht überschrieben wird.
  Future<void> _aendern(List<(String, String, Map<String, dynamic>?)> datensaetze, Bestand Function(Bestand) neu) =>
      sperre.exklusiv(() async {
        final s = _offen;
        // Geteilte Einträge mit Leserecht bleiben unverändert (die
        // Oberfläche bietet das gar nicht erst an).
        for (final (bereich, id, json) in datensaetze) {
          if (!SyncMotor.raumBereiche.contains(bereich)) continue;
          final vorher = s.bestand.raumVon(bereich, id);
          for (final r in [vorher, json?['raum'] as String?]) {
            if (r != null && s.bestand.raeume[r]?.schreibbar == false) throw StateError('Dieser Eintrag ist nur lesbar.');
          }
        }
        final bestand = neu(s.bestand);
        final stand = _syncAktiv ? SyncStand(_ablage, s.dek) : null;
        Future<void> alle(DatabaseClient? tx) async {
          for (final (bereich, id, json) in datensaetze) {
            if (json == null) {
              await _ablage.loeschen(bereich, id, tx: tx);
            } else {
              await _ablage.schreiben(s.dek, bereich, id, json, tx: tx);
            }
            await stand?.vormerken(bereich, id, tx: tx);
          }
        }

        // Ein einzelner Datensatz ohne Sync braucht keine Transaktion.
        if (stand == null && datensaetze.length == 1) {
          await alle(null);
        } else {
          await _ablage.transaktion(alle);
        }
        state = _offen.mit(bestand: bestand);
      });

  Future<void> _schreiben(String bereich, String id, Map<String, dynamic> json, Bestand Function(Bestand) neu) =>
      _aendern([(bereich, id, json)], neu);

  Future<void> _loeschen(String bereich, List<String> ids, Bestand Function(Bestand) neu) =>
      _aendern([for (final id in ids) (bereich, id, null)], neu);

  Bestand get _b => _offen.bestand;

  Future<void> speichereTermin(Termin t) async {
    final x = t.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('termine', x.id, x.toJson(), (b) => b.kopie(termine: {...b.termine, x.id: x}));
    unawaited(_erinnerungenPlanen());
  }

  Future<void> loescheTermin(String id) async {
    await _loeschen('termine', [id], (b) => b.kopie(termine: {...b.termine}..remove(id)));
    unawaited(_erinnerungenPlanen());
  }

  /// Nur dieses Vorkommen einer Serie entfernen.
  Future<void> loescheVorkommen(Termin t, DateTime tag) =>
      speichereTermin(t.kopie(ausnahmen: {...t.ausnahmen, tagIso(tag)}));

  Future<void> speichereAufgabe(Aufgabe a) async {
    final x = a.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('aufgaben', x.id, x.toJson(), (b) => b.kopie(aufgaben: {...b.aufgaben, x.id: x}));
    unawaited(_erinnerungenPlanen());
  }

  Future<void> loescheAufgabe(String id) async {
    await _loeschen('aufgaben', [id], (b) => b.kopie(aufgaben: {...b.aufgaben}..remove(id)));
    unawaited(_erinnerungenPlanen());
  }

  /// Abhaken; liefert den vorigen Stand für „Rückgängig“.
  Future<Aufgabe?> aufgabeAbschliessen(String id) async {
    final a = _b.aufgaben[id];
    if (a == null || !a.offen) return null;
    await speichereAufgabe(a.abschliessen(_jetzt));
    return a;
  }

  Future<void> speichereNotiz(Notiz n) async {
    final x = n.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('notizen', x.id, x.toJson(), (b) => b.kopie(notizen: {...b.notizen, x.id: x}));
  }

  Future<void> loescheNotiz(String id) => _loeschen('notizen', [id], (b) => b.kopie(notizen: {...b.notizen}..remove(id)));

  Future<void> speichereKonto(Konto k) async {
    final x = k.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('konten', x.id, x.toJson(), (b) => b.kopie(konten: {...b.konten, x.id: x}));
  }

  /// Nur ohne Buchungen/Pläne löschbar — sonst archivieren.
  bool kontoLoeschbar(String id) =>
      !_b.buchungen.values.any((b) => b.kontoId == id) && !_b.plaene.values.any((p) => p.kontoId == id);

  Future<void> loescheKonto(String id) async {
    if (!kontoLoeschbar(id)) throw StateError('Konto hat Buchungen — bitte archivieren.');
    await _loeschen('konten', [id], (b) => b.kopie(konten: {...b.konten}..remove(id)));
  }

  Future<void> speichereBuchung(Buchung b) async {
    final x = b.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('buchungen', x.id, x.toJson(), (b) => b.kopie(buchungen: {...b.buchungen, x.id: x}));
  }

  /// Löscht eine Buchung, bei Umbuchungen beide Hälften.
  Future<void> loescheBuchung(String id) async {
    final b = _b.buchungen[id];
    if (b == null) return;
    final ids = [id, if (_b.gegenbuchung(b) case final g?) g.id];
    await _loeschen('buchungen', ids, (b) => b.kopie(buchungen: {...b.buchungen}..removeWhere((k, _) => ids.contains(k))));
  }

  /// Legt eine Umbuchung an oder ändert sie: Abgang auf [vonKonto]
  /// (negativ), Zugang auf [nachKonto] (positiv).
  Future<void> umbuchen({
    String? umbuchungId,
    required String vonKonto,
    required String nachKonto,
    required int betragCent,
    required DateTime datum,
    BuchungsStatus status = BuchungsStatus.gebucht,
    String? bemerkung,
  }) async {
    if (vonKonto == nachKonto) throw ArgumentError('Umbuchung braucht zwei verschiedene Konten.');
    final uid = umbuchungId ?? neueId();
    final alt = _b.buchungen.values.where((b) => b.umbuchungId == uid).toList();
    final abgang = alt.where((b) => b.betragCent < 0).firstOrNull;
    final zugang = alt.where((b) => b.betragCent >= 0).firstOrNull;
    final jetzt = _jetzt.toUtc();
    final name = 'Umbuchung';
    final neu = [
      Buchung(id: abgang?.id ?? neueId(), kontoId: vonKonto, datum: datum, empfaenger: name, betragCent: -betragCent.abs(), status: status, bemerkung: bemerkung, umbuchungId: uid, geaendert: jetzt),
      Buchung(id: zugang?.id ?? neueId(), kontoId: nachKonto, datum: datum, empfaenger: name, betragCent: betragCent.abs(), status: status, bemerkung: bemerkung, umbuchungId: uid, geaendert: jetzt),
    ];
    await _aendern([for (final b in neu) ('buchungen', b.id, b.toJson())], (x) => x.kopie(buchungen: {...x.buchungen, for (final b in neu) b.id: b}));
  }

  Future<void> speicherePlan(Plan p) async {
    final x = p.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('plaene', x.id, x.toJson(), (b) => b.kopie(plaene: {...b.plaene, x.id: x}));
  }

  Future<void> loeschePlan(String id) => _loeschen('plaene', [id], (b) => b.kopie(plaene: {...b.plaene}..remove(id)));

  /// Bucht das Vorkommen eines Plans in [monat] (Betrag/Datum anpassbar).
  Future<void> planBuchen(Plan p, Monat monat, {int? betragCent, DateTime? datum}) => speichereBuchung(Buchung(
        id: neueId(),
        kontoId: p.kontoId,
        datum: datum ?? p.faelligIm(monat),
        empfaenger: p.empfaenger,
        betragCent: betragCent ?? p.betragCent,
        status: BuchungsStatus.gebucht,
        bemerkung: p.bemerkung,
        planId: p.id,
        planMonat: monat,
        geaendert: _jetzt,
      ));

  /// Einmalig geplanten Posten als gebucht übernehmen.
  Future<void> geplantBuchen(Buchung b, {DateTime? datum}) => speichereBuchung(
        b.kopie(status: BuchungsStatus.gebucht, ausPlanung: !b.istUmbuchung, datum: datum),
      );

  /// Raumdaten (Schlüssel, Mitglieder, Ordner) speichern.
  Future<void> raumSpeichern(Raum r) => _schreiben('raeume', r.id, r.toJson(), (b) => b.kopie(raeume: {...b.raeume, r.id: r}));

  Future<void> speichereEinstellungen(Einstellungen e) async {
    await _schreiben('einstellungen', 'app', e.toJson(), (b) => b.kopie(einstellungen: e));
    unawaited(_erinnerungenPlanen());
  }

  // ---------------------------------------------------------------------
  // Einkauf (M6)

  Future<void> speichereFiliale(Filiale f) async {
    final x = f.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('filialen', x.id, x.toJson(), (b) => b.kopie(filialen: {...b.filialen, x.id: x}));
  }

  /// Löscht eine Filiale samt ihrer Preise (Listen verlieren nur die Zuordnung).
  Future<void> loescheFiliale(String id) async {
    final preise = [for (final p in _b.preise.values) if (p.filialeId == id) p.id];
    final listen = [for (final l in _b.einkaufslisten.values) if (l.filialeId == id) l.kopie(filialeId: () => null, geaendert: _jetzt.toUtc())];
    await _aendern(
      [('filialen', id, null), for (final p in preise) ('preise', p, null), for (final l in listen) ('einkaufslisten', l.id, l.toJson())],
      (b) => b.kopie(
        filialen: {...b.filialen}..remove(id),
        preise: {...b.preise}..removeWhere((k, _) => preise.contains(k)),
        einkaufslisten: {...b.einkaufslisten, for (final l in listen) l.id: l},
      ),
    );
  }

  Future<void> speicherePreis(Preis p) async {
    final x = p.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('preise', x.id, x.toJson(), (b) => b.kopie(preise: {...b.preise, x.id: x}));
  }

  Future<void> loeschePreis(String id) => _loeschen('preise', [id], (b) => b.kopie(preise: {...b.preise}..remove(id)));

  /// Speichert eine Liste. Wird sie geteilt oder wieder privat, ziehen ihre
  /// Posten mit; eine Filiale aus einem anderen Ort wird für den Raum der
  /// Liste kopiert (eine Filiale liegt immer an genau einem Ort).
  Future<Einkaufsliste> speichereListe(Einkaufsliste l) async {
    var x = l.kopie(geaendert: _jetzt.toUtc());
    final jetzt = _jetzt.toUtc();
    final aenderungen = <(String, String, Map<String, dynamic>?)>[];
    final neuePosten = <String, Posten>{};
    final neueFilialen = <String, Filiale>{};
    for (final p in _b.posten.values) {
      if (p.listeId != x.id || p.raum == x.raum) continue;
      final n = p.kopie(raum: () => x.raum, geaendert: jetzt);
      neuePosten[n.id] = n;
      aenderungen.add(('posten', n.id, n.toJson()));
    }
    final f = x.filialeId == null ? null : _b.filialen[x.filialeId];
    if (f != null && f.raum != x.raum) {
      final kopie = Filiale(id: neueId(), kette: f.kette, name: f.name, region: f.region, breite: f.breite, laenge: f.laenge, geaendert: jetzt, raum: x.raum);
      neueFilialen[kopie.id] = kopie;
      x = x.kopie(filialeId: () => kopie.id);
      aenderungen.add(('filialen', kopie.id, kopie.toJson()));
    }
    aenderungen.add(('einkaufslisten', x.id, x.toJson()));
    await _aendern(
      aenderungen,
      (b) => b.kopie(
        einkaufslisten: {...b.einkaufslisten, x.id: x},
        posten: {...b.posten, ...neuePosten},
        filialen: {...b.filialen, ...neueFilialen},
      ),
    );
    return x;
  }

  /// Löscht eine Liste mit ihren offenen Posten; Einkäufe (und Buchungen)
  /// bleiben erhalten.
  Future<void> loescheListe(String id) async {
    final posten = [for (final p in _b.posten.values) if (p.listeId == id) p.id];
    await _aendern(
      [('einkaufslisten', id, null), for (final p in posten) ('posten', p, null)],
      (b) => b.kopie(einkaufslisten: {...b.einkaufslisten}..remove(id), posten: {...b.posten}..removeWhere((k, _) => posten.contains(k))),
    );
  }

  Future<void> speicherePosten(Posten p) async {
    final x = p.kopie(geaendert: _jetzt.toUtc(), raum: () => _b.einkaufslisten[p.listeId]?.raum);
    await _schreiben('posten', x.id, x.toJson(), (b) => b.kopie(posten: {...b.posten, x.id: x}));
  }

  Future<void> loeschePosten(String id) => _loeschen('posten', [id], (b) => b.kopie(posten: {...b.posten}..remove(id)));

  /// Einkauf abschließen: die abgehakten Posten der Liste gelten als
  /// gekauft, und genau eine Buchung über [betragCent] entsteht auf
  /// [kontoId]. Ein Posten kann nur einmal gekauft werden.
  Future<Einkauf> einkaufAbschliessen({
    required String listeId,
    required int betragCent,
    required String kontoId,
    required DateTime datum,
    int? geschaetztCent,
  }) async {
    final liste = _b.einkaufslisten[listeId];
    if (liste == null) throw StateError('Liste nicht gefunden.');
    if (!_b.konten.containsKey(kontoId)) throw StateError('Konto nicht gefunden.');
    final gekauft = [for (final p in _b.postenVon(listeId)) if (p.abgehakt) p];
    if (gekauft.isEmpty) throw StateError('Es ist nichts abgehakt.');
    final jetzt = _jetzt.toUtc();
    final filiale = liste.filialeId == null ? null : _b.filialen[liste.filialeId];
    final einkaufId = neueId();
    final buchung = Buchung(
      id: neueId(),
      kontoId: kontoId,
      datum: datum,
      empfaenger: filiale?.anzeige ?? liste.name,
      betragCent: -betragCent.abs(),
      status: BuchungsStatus.gebucht,
      bemerkung: 'Einkauf „${liste.name}“: ${gekauft.length} Posten',
      geaendert: jetzt,
    );
    final einkauf = Einkauf(
      id: einkaufId,
      listeId: listeId,
      filialeId: liste.filialeId,
      datum: datum,
      geschaetztCent: geschaetztCent,
      betragCent: betragCent.abs(),
      kontoId: kontoId,
      buchungId: buchung.id,
      postenIds: [for (final p in gekauft) p.id],
      geaendert: jetzt,
    );
    final posten = [for (final p in gekauft) p.kopie(abgehakt: false, einkaufId: () => einkaufId, geaendert: jetzt)];
    await _aendern(
      [
        ('buchungen', buchung.id, buchung.toJson()),
        ('einkaeufe', einkauf.id, einkauf.toJson()),
        for (final p in posten) ('posten', p.id, p.toJson()),
      ],
      (b) => b.kopie(
        buchungen: {...b.buchungen, buchung.id: buchung},
        einkaeufe: {...b.einkaeufe, einkauf.id: einkauf},
        posten: {...b.posten, for (final p in posten) p.id: p},
      ),
    );
    return einkauf;
  }

  // ---------------------------------------------------------------------
  // Konflikte aus dem Sync

  /// Die Konflikt-Fassung übernehmen: Sie ersetzt den aktuellen Datensatz
  /// (bei Umbuchungen auch die Gegenhälfte, wenn sie ebenfalls einen
  /// Konflikt hat). Wirft, wenn das Ergebnis nicht stimmig wäre (z. B.
  /// Buchung auf ein inzwischen gelöschtes Konto).
  Future<void> konfliktUebernehmen(String id) async {
    final k = _b.konflikte[id];
    if (k == null) return;
    final uid = k.bereich == 'buchungen' ? k.daten['umbuchungId'] : null;
    final alle = [
      k,
      if (uid != null) ..._b.konflikte.values.where((x) => x.id != k.id && x.bereich == 'buchungen' && x.daten['umbuchungId'] == uid),
    ];
    final jetzt = _jetzt.toUtc().toIso8601String();
    final aenderungen = [
      for (final x in alle) ...[
        (x.bereich, x.originalId, <String, dynamic>{...x.daten, 'id': x.originalId, 'geaendert': jetzt}),
        ('konflikte', x.id, null),
      ],
    ];
    await _aendern(aenderungen, (b) {
      final roh = rohdatenVon(b);
      for (final (bereich, rid, json) in aenderungen) {
        roh[bereich] = [...roh[bereich]!.where((d) => d['id'] != rid), ?json];
      }
      return bestandAus(roh);
    });
    if (alle.any((x) => x.bereich == 'termine' || x.bereich == 'aufgaben')) unawaited(_erinnerungenPlanen());
  }

  /// Die Konflikt-Fassung verwerfen; der aktuelle Datensatz bleibt.
  Future<void> konfliktVerwerfen(String id) => _loeschen('konflikte', [id], (b) => b.kopie(konflikte: {...b.konflikte}..remove(id)));

  // ---------------------------------------------------------------------
  // Erinnerungen

  Future<void> _erinnerungenPlanen() async {
    final s = state;
    if (s is! Entsperrt) return;
    try {
      final status = await ref.read(erinnerungenProvider).planen(s.bestand, jetzt: _jetzt);
      if (!ref.mounted) return;
      final jetzt = state;
      if (jetzt is Entsperrt) state = jetzt.mit(erinnerung: status);
    } catch (e) {
      if (!ref.mounted) return;
      final jetzt = state;
      if (jetzt is Entsperrt) {
        state = jetzt.mit(erinnerung: ErinnerungsStatus(erlaubt: false, hinweis: 'Erinnerungen konnten nicht geplant werden: $e'));
      }
    }
  }

  Future<void> erinnerungenErlauben() async {
    await ref.read(erinnerungenProvider).erlaubnisAnfragen();
    await _erinnerungenPlanen();
  }

  // ---------------------------------------------------------------------
  // Sicherung und Wiederherstellung

  /// Verschlüsselte Komplettsicherung (Inhalt mit dem Backup-Schlüssel,
  /// der zum aktuellen Recovery-Schlüssel gehört).
  Uint8List sicherungErstellen() {
    final s = _offen;
    final schluessel = s.bund.backupSchluessel(s.dek);
    if (schluessel == null) throw StateError('Backup-Schlüssel nicht lesbar');
    return Backup.erstellen(
      daten: rohdatenVon(s.bestand),
      backupSchluessel: schluessel,
      recoveryKennung: s.bund.recoveryKennung,
      zeitpunkt: _jetzt,
    );
  }

  /// Nach erfolgreichem Speichern der Datei vermerken.
  Future<void> sicherungVermerken() => speichereEinstellungen(_b.einstellungen.kopie(letzteSicherung: _jetzt.toUtc()));

  /// Prüft eine Sicherung vollständig (inkl. aller Datensätze), ohne etwas
  /// zu verändern.
  static ({BackupInhalt inhalt, Bestand bestand}) sicherungPruefen(Uint8List datei, RecoverySchluessel r) {
    final inhalt = Backup.lesen(datei, r);
    return (inhalt: inhalt, bestand: bestandAus(inhalt.daten));
  }

  /// Frische Installation: Sicherung übernehmen, neues Passwort setzen.
  /// Der Recovery-Schlüssel bleibt derselbe wie in der Sicherung.
  Future<void> wiederherstellenNeu(Bestand bestand, RecoverySchluessel r, String passwort) async {
    final (:bund, :dek) = await Schluesselbund.anlegen(passwort, r, kdf: ref.read(kdfProvider)());
    await _alleSchreiben(dek, rohdatenVon(bestand), schema: aktuellesSchema, bund: bund);
    state = Entsperrt(bund: bund, dek: dek, bestand: bestand);
    unawaited(_erinnerungenPlanen());
  }

  /// Laufende Installation: ersetzt alle Daten. Passwort und Fingerabdruck
  /// bleiben; künftig gilt der Recovery-Schlüssel der Sicherung.
  /// Mit Sync nicht möglich: erst trennen (sonst würden die ersetzten
  /// Daten wieder vom Server eingespielt).
  Future<void> wiederherstellenErsetzen(Bestand bestand, RecoverySchluessel r) async {
    if (_syncAktiv) throw StateError('Bitte zuerst den Sync trennen.');
    final s = _offen;
    final bund = s.bund.mitNeuemRecovery(s.dek, r);
    await _alleSchreiben(s.dek, rohdatenVon(bestand), schema: aktuellesSchema, bund: bund);
    state = Entsperrt(bund: bund, dek: s.dek, bestand: bestand);
    unawaited(_erinnerungenPlanen());
  }

  /// Ersetzt alle Bereiche in einer Transaktion: bricht etwas ab, bleibt
  /// der alte Stand vollständig erhalten.
  Future<void> _alleSchreiben(Uint8List dek, Rohdaten roh, {required int schema, Schluesselbund? bund}) =>
      _ablage.transaktion((tx) async {
        for (final b in Ablage.bereiche) {
          await _ablage.leeren(b, tx: tx);
          for (final d in roh[b] ?? const <Map<String, dynamic>>[]) {
            await _ablage.schreiben(dek, b, d['id'] as String, d, tx: tx);
          }
        }
        await _ablage.setzeMeta(metaSchema, schema, tx: tx);
        if (bund != null) await _ablage.setzeMeta(metaBund, bund.toJson(), tx: tx);
      });
}
