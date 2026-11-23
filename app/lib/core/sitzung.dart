import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'dienste/biometrie.dart';
import 'dienste/erinnerungen.dart';
import 'krypto/kdf.dart';
import 'krypto/recovery_schluessel.dart';
import 'krypto/schluesselbund.dart';
import 'modell/aufgabe.dart';
import 'modell/bestand.dart';
import 'modell/datum.dart';
import 'modell/finanzen.dart';
import 'modell/notiz.dart';
import 'modell/termin.dart';
import 'speicher/ablage.dart';
import 'speicher/backup.dart';
import 'speicher/rohdaten.dart';
import 'speicher/schema.dart';

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
    state = Entsperrt(bund: bund, dek: dek, bestand: bestand, neuesPasswortNoetig: neuesPasswortNoetig, defekt: defekt);
    unawaited(_erinnerungenPlanen());
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
      for (final b in Ablage.bereiche) {
        await _ablage.leeren(b, tx: tx);
      }
      await _ablage.setzeMeta(metaBund, null, tx: tx);
      await _ablage.setzeMeta(metaSchema, null, tx: tx);
    });
    state = const Einrichtung();
  }

  // ---------------------------------------------------------------------
  // Datensätze

  Future<void> _schreiben(String bereich, String id, Map<String, dynamic> json, Bestand neu) async {
    final s = _offen;
    await _ablage.schreiben(s.dek, bereich, id, json);
    state = (state as Entsperrt).mit(bestand: neu);
  }

  Future<void> _loeschen(String bereich, List<String> ids, Bestand neu) async {
    await _ablage.transaktion((tx) async {
      for (final id in ids) {
        await _ablage.loeschen(bereich, id, tx: tx);
      }
    });
    state = _offen.mit(bestand: neu);
  }

  Bestand get _b => _offen.bestand;

  Future<void> speichereTermin(Termin t) async {
    final x = t.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('termine', x.id, x.toJson(), _b.kopie(termine: {..._b.termine, x.id: x}));
    unawaited(_erinnerungenPlanen());
  }

  Future<void> loescheTermin(String id) async {
    await _loeschen('termine', [id], _b.kopie(termine: {..._b.termine}..remove(id)));
    unawaited(_erinnerungenPlanen());
  }

  /// Nur dieses Vorkommen einer Serie entfernen.
  Future<void> loescheVorkommen(Termin t, DateTime tag) =>
      speichereTermin(t.kopie(ausnahmen: {...t.ausnahmen, tagIso(tag)}));

  Future<void> speichereAufgabe(Aufgabe a) async {
    final x = a.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('aufgaben', x.id, x.toJson(), _b.kopie(aufgaben: {..._b.aufgaben, x.id: x}));
    unawaited(_erinnerungenPlanen());
  }

  Future<void> loescheAufgabe(String id) async {
    await _loeschen('aufgaben', [id], _b.kopie(aufgaben: {..._b.aufgaben}..remove(id)));
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
    await _schreiben('notizen', x.id, x.toJson(), _b.kopie(notizen: {..._b.notizen, x.id: x}));
  }

  Future<void> loescheNotiz(String id) => _loeschen('notizen', [id], _b.kopie(notizen: {..._b.notizen}..remove(id)));

  Future<void> speichereKonto(Konto k) async {
    final x = k.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('konten', x.id, x.toJson(), _b.kopie(konten: {..._b.konten, x.id: x}));
  }

  /// Nur ohne Buchungen/Pläne löschbar — sonst archivieren.
  bool kontoLoeschbar(String id) =>
      !_b.buchungen.values.any((b) => b.kontoId == id) && !_b.plaene.values.any((p) => p.kontoId == id);

  Future<void> loescheKonto(String id) async {
    if (!kontoLoeschbar(id)) throw StateError('Konto hat Buchungen — bitte archivieren.');
    await _loeschen('konten', [id], _b.kopie(konten: {..._b.konten}..remove(id)));
  }

  Future<void> speichereBuchung(Buchung b) async {
    final x = b.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('buchungen', x.id, x.toJson(), _b.kopie(buchungen: {..._b.buchungen, x.id: x}));
  }

  /// Löscht eine Buchung, bei Umbuchungen beide Hälften.
  Future<void> loescheBuchung(String id) async {
    final b = _b.buchungen[id];
    if (b == null) return;
    final ids = [id, if (_b.gegenbuchung(b) case final g?) g.id];
    await _loeschen('buchungen', ids, _b.kopie(buchungen: {..._b.buchungen}..removeWhere((k, _) => ids.contains(k))));
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
    await _ablage.transaktion((tx) async {
      for (final b in neu) {
        await _ablage.schreiben(_offen.dek, 'buchungen', b.id, b.toJson(), tx: tx);
      }
    });
    state = _offen.mit(bestand: _b.kopie(buchungen: {..._b.buchungen, for (final b in neu) b.id: b}));
  }

  Future<void> speicherePlan(Plan p) async {
    final x = p.kopie(geaendert: _jetzt.toUtc());
    await _schreiben('plaene', x.id, x.toJson(), _b.kopie(plaene: {..._b.plaene, x.id: x}));
  }

  Future<void> loeschePlan(String id) => _loeschen('plaene', [id], _b.kopie(plaene: {..._b.plaene}..remove(id)));

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

  Future<void> speichereEinstellungen(Einstellungen e) async {
    await _schreiben('einstellungen', 'app', e.toJson(), _b.kopie(einstellungen: e));
    unawaited(_erinnerungenPlanen());
  }

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
  Future<void> wiederherstellenErsetzen(Bestand bestand, RecoverySchluessel r) async {
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
