import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../krypto/recovery_schluessel.dart';
import '../krypto/schluesselbund.dart';
import '../sitzung.dart';
import 'sync_api.dart';
import 'sync_krypto.dart';
import 'sync_motor.dart';
import 'sync_stand.dart';

/// HTTP-Client für den Sync (Tests setzen einen eigenen ein).
final httpClientProvider = Provider<http.Client>((ref) => http.Client());

/// Abstände für den automatischen Abgleich (Tests: kürzer oder aus).
final syncTaktProvider = Provider<({Duration nachAenderung, Duration regelmaessig})>(
  (ref) => (nachAenderung: const Duration(seconds: 2), regelmaessig: const Duration(minutes: 5)),
);

final syncProvider = NotifierProvider<SyncNotifier, SyncStatus>(SyncNotifier.new);

class SyncStatus {
  const SyncStatus({
    this.verbunden = false,
    this.server,
    this.geraet,
    this.laeuft = false,
    this.letzter,
    this.fehler,
    this.fehlerArt,
    this.ausstehend = 0,
    this.vaultGesperrt = const {},
    this.vaultZuGross = const {},
    this.vaultFehlt = const {},
  });

  final bool verbunden;
  final String? server;
  final String? geraet;
  final bool laeuft;
  final DateTime? letzter;
  final String? fehler;
  final SyncFehlerArt? fehlerArt;

  /// Lokale Änderungen, die noch nicht beim Server sind.
  final int ausstehend;

  /// Vault-Dateien, die beim letzten Abgleich nicht gesendet wurden
  /// (Secret-Treffer ohne Freigabe, zu groß, Block fehlt).
  final Set<String> vaultGesperrt;
  final Set<String> vaultZuGross;
  final Set<String> vaultFehlt;

  SyncStatus mit({
    bool? laeuft,
    DateTime? letzter,
    String? Function()? fehler,
    SyncFehlerArt? Function()? fehlerArt,
    int? ausstehend,
    Set<String>? vaultGesperrt,
    Set<String>? vaultZuGross,
    Set<String>? vaultFehlt,
  }) =>
      SyncStatus(
        verbunden: verbunden,
        server: server,
        geraet: geraet,
        laeuft: laeuft ?? this.laeuft,
        letzter: letzter ?? this.letzter,
        fehler: fehler != null ? fehler() : this.fehler,
        fehlerArt: fehlerArt != null ? fehlerArt() : this.fehlerArt,
        ausstehend: ausstehend ?? this.ausstehend,
        vaultGesperrt: vaultGesperrt ?? this.vaultGesperrt,
        vaultZuGross: vaultZuGross ?? this.vaultZuGross,
        vaultFehlt: vaultFehlt ?? this.vaultFehlt,
      );
}

/// Ein Gerät des Sync-Kontos (Name nur auf Geräten mit Schlüssel lesbar).
typedef SyncGeraet = ({String id, String name, DateTime erstellt, DateTime zuletzt, bool dieses});

String standardGeraetName() => kIsWeb ? 'Browser' : 'Android';

/// Verbindung, Kopplung und automatischer Abgleich. Synchronisiert wird
/// nur bei entsperrter App: nach dem Entsperren, kurz nach Änderungen,
/// alle paar Minuten und auf Knopfdruck. Kein Hintergrund-Sync.
class SyncNotifier extends Notifier<SyncStatus> {
  Timer? _verzoegert;
  Timer? _regelmaessig;
  Future<SyncBericht?>? _laufend;
  Future<SyncBericht?>? _wartend;

  SitzungNotifier get _sitzung => ref.read(sitzungProvider.notifier);
  http.Client get _client => ref.read(httpClientProvider);

  @override
  SyncStatus build() {
    ref.listen(sitzungProvider, (vorher, jetzt) {
      if (jetzt is! Entsperrt) {
        _anhalten();
        if (vorher is Entsperrt) state = const SyncStatus();
        return;
      }
      if (vorher is! Entsperrt) {
        unawaited(_starten());
      } else if (!identical(vorher.bestand, jetzt.bestand) && _sitzung.syncAktiv) {
        _bald();
      }
    });
    ref.onDispose(_anhalten);
    return const SyncStatus();
  }

  Entsperrt get _offen {
    final s = ref.read(sitzungProvider);
    if (s is! Entsperrt) throw StateError('Nicht entsperrt');
    return s;
  }

  SyncStand _stand() => SyncStand(ref.read(ablageProvider), _offen.dek);

  Future<Verbindung> _verbindung() async {
    final v = await _stand().verbindung();
    if (v == null) throw SyncFehler(SyncFehlerArt.anmeldung, 'Nicht mit einem Sync-Server verbunden.');
    return v;
  }

  SyncApi _api(String server, {String? token}) => SyncApi(serverAdresse(server), client: _client, token: token);

  Future<void> _starten() async {
    final v = await _stand().verbindung();
    if (!ref.mounted) return;
    if (v == null) {
      state = const SyncStatus();
      return;
    }
    state = SyncStatus(verbunden: true, server: v.server, geraet: v.geraet, ausstehend: await _stand().anzahlAusstehend());
    final takt = ref.read(syncTaktProvider).regelmaessig;
    _regelmaessig?.cancel();
    if (takt > Duration.zero) _regelmaessig = Timer.periodic(takt, (_) => unawaited(abgleichen()));
    unawaited(abgleichen());
  }

  void _anhalten() {
    _verzoegert?.cancel();
    _regelmaessig?.cancel();
    _verzoegert = _regelmaessig = null;
  }

  /// Nach einer Änderung außerhalb des Bestands (z. B. Vault-Datei).
  void nachAenderung() {
    if (_sitzung.syncAktiv) _bald();
  }

  void _bald() {
    final takt = ref.read(syncTaktProvider).nachAenderung;
    if (takt <= Duration.zero) return;
    _verzoegert?.cancel();
    _verzoegert = Timer(takt, () async {
      if (!ref.mounted || ref.read(sitzungProvider) is! Entsperrt) return;
      final n = await _stand().anzahlAusstehend();
      if (n > 0) unawaited(abgleichen());
    });
  }

  /// Ein Abgleich, der *nach* diesem Aufruf beginnt: Läuft schon einer,
  /// folgt genau ein weiterer im Anschluss. Fehler landen im Status (und
  /// werden nicht geworfen).
  Future<SyncBericht?> abgleichen() {
    if (_laufend == null) return _beginnen();
    return _wartend ??= _laufend!.then((_) {
      _wartend = null;
      return _beginnen();
    });
  }

  /// Wartet, bis kein Abgleich mehr läuft oder ansteht.
  Future<void> leerlauf() async {
    while (_laufend != null || _wartend != null) {
      await (_wartend ?? _laufend);
    }
  }

  Future<SyncBericht?> _beginnen() => _laufend = _abgleichen().whenComplete(() => _laufend = null);

  Future<SyncBericht?> _abgleichen() async {
    if (ref.read(sitzungProvider) is! Entsperrt || !_sitzung.syncAktiv) return null;
    final s = _offen;
    state = state.mit(laeuft: true);
    try {
      final v = await _verbindung();
      final motor = SyncMotor(
        ablage: ref.read(ablageProvider),
        dek: s.dek,
        api: _api(v.server, token: v.token),
        sperre: _sitzung.sperre,
        uhr: ref.read(uhrProvider),
        vaultMaxBytes: s.bestand.einstellungen.vaultMaxMiB * 1024 * 1024,
      );
      final bericht = await motor.abgleichen();
      if (!ref.mounted || ref.read(sitzungProvider) is! Entsperrt) return bericht;
      if (bericht.lokalGeaendert || bericht.neuAufgebaut) await _sitzung.neuLaden();
      await _recoveryAbgleichen(v, bericht.konto);
      state = state.mit(
        laeuft: false,
        letzter: ref.read(uhrProvider)(),
        fehler: () => bericht.defekt > 0 ? '${bericht.defekt} Einträge vom Server ließen sich nicht entschlüsseln und wurden übersprungen.' : null,
        fehlerArt: () => bericht.defekt > 0 ? SyncFehlerArt.daten : null,
        ausstehend: await _stand().anzahlAusstehend(),
        vaultGesperrt: bericht.vaultGesperrt,
        vaultZuGross: bericht.vaultZuGross,
        vaultFehlt: bericht.vaultFehlt,
      );
      return bericht;
    } catch (e) {
      if (!ref.mounted) return null;
      final f = e is SyncFehler ? e : SyncFehler(SyncFehlerArt.server, 'Abgleich fehlgeschlagen: $e');
      var ausstehend = state.ausstehend;
      if (ref.read(sitzungProvider) is Entsperrt) ausstehend = await _stand().anzahlAusstehend();
      state = state.mit(laeuft: false, fehler: () => f.meldung, fehlerArt: () => f.art, ausstehend: ausstehend);
      return null;
    }
  }

  /// Hat ein anderes Gerät den Recovery-Schlüssel erneuert, übernimmt
  /// dieses Gerät ihn (für Sicherungen und Entsperren).
  Future<void> _recoveryAbgleichen(Verbindung v, Map<String, dynamic>? konto) async {
    final paket = konto?['schluesselPaket'];
    if (paket is! String) return;
    final teile = v.schluessel.recoveryTeileAus(paket);
    final s = _offen;
    if (teile == null || teile.kennung == s.bund.recoveryKennung) return;
    await _sitzung.bundErsetzen(s.bund.mitRecoveryTeilen(s.dek, teile));
  }

  // ---------------------------------------------------------------------
  // Verbinden (dieses Gerät hat schon Daten)

  /// Mit dem Recovery-Schlüssel verbinden: legt das Konto an oder meldet
  /// sich bei einem vorhandenen an. Alle lokalen Daten werden danach
  /// verschlüsselt hochgeladen bzw. mit dem Konto zusammengeführt.
  Future<SyncBericht?> verbinden({required String server, required RecoverySchluessel recovery, String? geraetName}) async {
    final s = _offen;
    final api = _api(server);
    await api.info();
    final name = geraetName ?? standardGeraetName();
    final passtLokal = s.bund.mitRecovery(recovery) != null;
    ({String konto, String geraet, String token})? neu;
    Kontoschluessel? ks;
    if (passtLokal) {
      try {
        ks = Kontoschluessel.neu();
        neu = await api.kontoAnlegen(
          recoveryAnmeldung: recovery.syncAnmeldung,
          recoveryHuelle: recovery.huelleFuer(ks),
          schluesselPaket: ks.schluesselPaket(RecoveryTeile.von(recovery)),
          geraetName: ks.geraetName(name),
        );
      } on SyncFehler catch (e) {
        if (e.art != SyncFehlerArt.vorhanden) rethrow;
      }
    }
    if (neu == null) {
      final ({String konto, String geraet, String token, String recoveryHuelle}) a;
      try {
        a = await api.recoveryAnmelden(recovery.syncAnmeldung, '');
      } on SyncFehler catch (e) {
        if (e.art == SyncFehlerArt.nichtGefunden && !passtLokal) {
          throw SyncFehler(SyncFehlerArt.nichtGefunden,
              'Dieser Recovery-Schlüssel gehört nicht zu diesem Gerät, und auf dem Server gibt es dazu kein Konto.');
        }
        rethrow;
      }
      ks = recovery.kontoschluesselAus(a.recoveryHuelle);
      if (ks == null) throw SyncFehler(SyncFehlerArt.daten, 'Der Kontoschlüssel auf dem Server passt nicht zum Recovery-Schlüssel.');
      await api.mitToken(a.token).geraetUmbenennen(a.geraet, ks.geraetName(name));
      neu = (konto: a.konto, geraet: a.geraet, token: a.token);
      // Ab jetzt gilt der Recovery-Schlüssel des Kontos.
      if (!passtLokal) await _sitzung.bundErsetzen(s.bund.mitNeuemRecovery(s.dek, recovery));
    }
    return _verbunden(Verbindung(server: server.trim(), konto: neu.konto, geraet: neu.geraet, token: neu.token, schluessel: ks!, name: name));
  }

  /// Mit einem Kopplungscode eines anderen Geräts verbinden; lokale Daten
  /// werden mit dem Konto zusammengeführt. Der Recovery-Schlüssel des
  /// Kontos ersetzt den bisherigen dieses Geräts.
  Future<SyncBericht?> koppeln({required String server, required Kopplungscode code, String? geraetName}) async {
    final s = _offen;
    final (v, teile) = await _einloesen(server, code, geraetName ?? standardGeraetName());
    if (teile.kennung != s.bund.recoveryKennung) await _sitzung.bundErsetzen(s.bund.mitRecoveryTeilen(s.dek, teile));
    return _verbunden(v);
  }

  Future<SyncBericht?> _verbunden(Verbindung v) async {
    final ablage = ref.read(ablageProvider);
    final stand = _stand();
    await _sitzung.sperre.exklusiv(() => ablage.transaktion((tx) async {
          await stand.loeschen(tx: tx);
          await stand.setzeVerbindung(v, tx: tx);
          await stand.allesVormerken(tx: tx);
        }));
    _sitzung.syncAktivSetzen(true);
    await _starten();
    return _laufend;
  }

  Future<(Verbindung, RecoveryTeile)> _einloesen(String server, Kopplungscode code, String name) async {
    final api = _api(server);
    await api.info();
    final e = await api.kopplungEinloesen(code.slot, '');
    final p = code.paketOeffnen(e.paket);
    if (p == null) throw SyncFehler(SyncFehlerArt.daten, 'Das Kopplungspaket ließ sich nicht öffnen.');
    final mitToken = api.mitToken(e.token);
    final konto = await mitToken.konto();
    final teile = p.schluessel.recoveryTeileAus(konto['schluesselPaket'] as String);
    if (teile == null) throw SyncFehler(SyncFehlerArt.daten, 'Das Schlüsselpaket des Kontos ließ sich nicht öffnen.');
    await mitToken.geraetUmbenennen(e.geraet, p.schluessel.geraetName(name));
    return (Verbindung(server: server.trim(), konto: e.konto, geraet: e.geraet, token: e.token, schluessel: p.schluessel, name: name), teile);
  }

  // ---------------------------------------------------------------------
  // Frisches Gerät (noch keine Daten)

  /// Neue Installation per Kopplungscode: Passwort setzen, Daten holen.
  Future<SyncBericht?> neuKoppeln({required String server, required Kopplungscode code, required String passwort, String? geraetName}) async {
    final (v, teile) = await _einloesen(server, code, geraetName ?? standardGeraetName());
    final (:bund, :dek) = await Schluesselbund.anlegenMitTeilen(passwort, teile, kdf: ref.read(kdfProvider)());
    await _sitzung.einrichtenAusSync(bund, dek, v);
    return _laufend ?? abgleichen();
  }

  /// Alle Geräte verloren: mit Recovery-Schlüssel vom Server holen.
  Future<SyncBericht?> neuAusRecovery({
    required String server,
    required RecoverySchluessel recovery,
    required String passwort,
    String? geraetName,
  }) async {
    final api = _api(server);
    await api.info();
    final a = await api.recoveryAnmelden(recovery.syncAnmeldung, '');
    final ks = recovery.kontoschluesselAus(a.recoveryHuelle);
    if (ks == null) throw SyncFehler(SyncFehlerArt.daten, 'Der Kontoschlüssel auf dem Server passt nicht zum Recovery-Schlüssel.');
    final name = geraetName ?? standardGeraetName();
    await api.mitToken(a.token).geraetUmbenennen(a.geraet, ks.geraetName(name));
    final (:bund, :dek) = await Schluesselbund.anlegen(passwort, recovery, kdf: ref.read(kdfProvider)());
    await _sitzung.einrichtenAusSync(
      bund,
      dek,
      Verbindung(server: server.trim(), konto: a.konto, geraet: a.geraet, token: a.token, schluessel: ks, name: name),
    );
    return _laufend ?? abgleichen();
  }

  // ---------------------------------------------------------------------
  // Verwaltung

  static const kopplungGueltig = Duration(minutes: 10);

  /// Einmal-Code für ein weiteres Gerät (10 Minuten gültig).
  Future<({Kopplungscode code, DateTime bis})> kopplungErstellen() async {
    final v = await _verbindung();
    final code = Kopplungscode.neu();
    await _api(v.server, token: v.token).kopplungAnlegen(code.slot, code.paket(v.konto, v.schluessel), kopplungGueltig);
    return (code: code, bis: ref.read(uhrProvider)().add(kopplungGueltig));
  }

  Future<List<SyncGeraet>> geraete() async {
    final v = await _verbindung();
    final k = await _api(v.server, token: v.token).konto();
    return [
      for (final g in (k['geraete'] as List).cast<Map<String, dynamic>>())
        (
          id: g['id'] as String,
          name: v.schluessel.geraetNameAus(g['name'] as String) ?? 'Unbekanntes Gerät',
          erstellt: DateTime.parse(g['erstellt'] as String),
          zuletzt: DateTime.parse(g['zuletzt'] as String),
          dieses: g['id'] == v.geraet,
        ),
    ];
  }

  Future<void> geraetEntfernen(String id) async {
    final v = await _verbindung();
    await _api(v.server, token: v.token).geraetEntfernen(id);
  }

  /// Trennt dieses Gerät; die Daten bleiben lokal. Mit [kontoLoeschen]
  /// wird zusätzlich alles auf dem Server gelöscht (muss klappen).
  Future<void> trennen({bool kontoLoeschen = false}) async {
    final v = await _verbindung();
    final api = _api(v.server, token: v.token);
    if (kontoLoeschen) {
      await api.kontoLoeschen();
    } else {
      try {
        await api.geraetEntfernen(v.geraet);
      } on SyncFehler {
        // Offline oder schon entfernt: lokal trotzdem trennen.
      }
    }
    _anhalten();
    final ablage = ref.read(ablageProvider);
    await _sitzung.sperre.exklusiv(() => ablage.transaktion((tx) => _stand().loeschen(tx: tx)));
    _sitzung.syncAktivSetzen(false);
    state = const SyncStatus();
  }

  /// Neuer Recovery-Schlüssel. Mit Sync zuerst beim Server (online
  /// nötig), damit der alte dort nicht weiter gilt; andere Geräte
  /// übernehmen ihn beim nächsten Abgleich.
  Future<void> recoveryErneuern(RecoverySchluessel neu) async {
    final s = _offen;
    if (_sitzung.syncAktiv) {
      final v = await _verbindung();
      await _api(v.server, token: v.token).recoveryErsetzen(
        recoveryAnmeldung: neu.syncAnmeldung,
        recoveryHuelle: neu.huelleFuer(v.schluessel),
        schluesselPaket: v.schluessel.schluesselPaket(RecoveryTeile.von(neu)),
      );
    }
    await _sitzung.bundErsetzen(s.bund.mitNeuemRecovery(s.dek, neu));
  }
}
