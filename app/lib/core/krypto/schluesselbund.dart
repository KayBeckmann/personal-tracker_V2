import 'dart:convert';
import 'dart:typed_data';

import 'kdf.dart';
import 'krypto.dart';
import 'recovery_schluessel.dart';

/// Unverschlüsselt gespeicherte Metadaten zum Entsperren: der zufällige
/// Datenschlüssel (DEK) liegt nur in zwei Hüllen — mit dem Passwort und
/// mit dem Recovery-Schlüssel verschlüsselt. Ohne eines von beiden sind
/// die Daten nicht lesbar.
class Schluesselbund {
  const Schluesselbund({
    required this.kdf,
    required this.huellePasswort,
    required this.huelleRecovery,
    required this.huelleBackup,
    required this.recoveryKennung,
    required this.pruefwert,
    this.biometrie = false,
  });

  static const version = 1;
  static const _aadPasswort = 'ptv2-dek-passwort';
  static const _aadRecovery = 'ptv2-dek-recovery';
  static const _aadPruef = 'ptv2-pruefwert';
  static const _aadBackup = 'ptv2-backup-schluessel';
  static const _pruefText = 'personal-tracker-v2';

  final KdfParameter kdf;
  final Geheimtext huellePasswort;
  final Geheimtext huelleRecovery;

  /// Backup-Schlüssel (aus dem Recovery-Schlüssel abgeleitet), mit dem DEK
  /// verschlüsselt: so lassen sich Sicherungen auch nach Entsperren per
  /// Passwort erstellen, ohne den Recovery-Schlüssel zu speichern.
  final Geheimtext huelleBackup;
  final String recoveryKennung;

  /// Mit dem DEK verschlüsselter Prüftext: erkennt einen falschen
  /// Schlüssel (z. B. aus dem Fingerabdruck-Speicher) sicher.
  final Geheimtext pruefwert;
  final bool biometrie;

  /// Neue Einrichtung: zufälliger DEK, Hüllen für Passwort und Recovery.
  static Future<({Schluesselbund bund, Uint8List dek})> anlegen(
    String passwort,
    RecoverySchluessel recovery, {
    KdfParameter? kdf,
    Uint8List? dek,
  }) async {
    final k = kdf ?? KdfParameter.standard();
    final d = dek ?? zufall(32);
    final kek = await k.ableiten(passwort);
    return (
      bund: Schluesselbund(
        kdf: k,
        huellePasswort: AesGcm.verschluesseln(kek, d, aad: _aadPasswort),
        huelleRecovery: AesGcm.verschluesseln(recovery.huellenSchluessel, d, aad: _aadRecovery),
        huelleBackup: AesGcm.verschluesseln(d, recovery.backupSchluessel, aad: _aadBackup),
        recoveryKennung: recovery.kennung,
        pruefwert: AesGcm.verschluesseln(d, Uint8List.fromList(utf8.encode(_pruefText)), aad: _aadPruef),
      ),
      dek: d,
    );
  }

  /// DEK per Passwort, `null` bei falschem Passwort.
  Future<Uint8List?> mitPasswort(String passwort) async {
    final kek = await kdf.ableiten(passwort);
    final d = AesGcm.entschluesseln(kek, huellePasswort, aad: _aadPasswort);
    return d != null && passt(d) ? d : null;
  }

  /// DEK per Recovery-Schlüssel, `null` wenn er nicht passt.
  Uint8List? mitRecovery(RecoverySchluessel r) {
    if (r.kennung != recoveryKennung) return null;
    final d = AesGcm.entschluesseln(r.huellenSchluessel, huelleRecovery, aad: _aadRecovery);
    return d != null && passt(d) ? d : null;
  }

  bool passt(Uint8List dek) {
    final t = AesGcm.entschluesseln(dek, pruefwert, aad: _aadPruef);
    return t != null && utf8.decode(t, allowMalformed: true) == _pruefText;
  }

  /// Schlüssel für Datensicherungen (passt zu [recoveryKennung]).
  Uint8List? backupSchluessel(Uint8List dek) => AesGcm.entschluesseln(dek, huelleBackup, aad: _aadBackup);

  /// Neues Passwort für denselben DEK (Daten bleiben unverändert).
  Future<Schluesselbund> mitNeuemPasswort(Uint8List dek, String passwort) async {
    final k = KdfParameter.standard();
    final kek = await k.ableiten(passwort);
    return _kopie(kdf: k, huellePasswort: AesGcm.verschluesseln(kek, dek, aad: _aadPasswort));
  }

  /// Neuer Recovery-Schlüssel für denselben DEK.
  Schluesselbund mitNeuemRecovery(Uint8List dek, RecoverySchluessel r) => _kopie(
        huelleRecovery: AesGcm.verschluesseln(r.huellenSchluessel, dek, aad: _aadRecovery),
        huelleBackup: AesGcm.verschluesseln(dek, r.backupSchluessel, aad: _aadBackup),
        recoveryKennung: r.kennung,
      );

  Schluesselbund mitBiometrie(bool an) => _kopie(biometrie: an);

  Schluesselbund _kopie({
    KdfParameter? kdf,
    Geheimtext? huellePasswort,
    Geheimtext? huelleRecovery,
    Geheimtext? huelleBackup,
    String? recoveryKennung,
    bool? biometrie,
  }) =>
      Schluesselbund(
        kdf: kdf ?? this.kdf,
        huellePasswort: huellePasswort ?? this.huellePasswort,
        huelleRecovery: huelleRecovery ?? this.huelleRecovery,
        huelleBackup: huelleBackup ?? this.huelleBackup,
        recoveryKennung: recoveryKennung ?? this.recoveryKennung,
        pruefwert: pruefwert,
        biometrie: biometrie ?? this.biometrie,
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'kdf': kdf.toJson(),
        'huellePasswort': huellePasswort.toJson(),
        'huelleRecovery': huelleRecovery.toJson(),
        'huelleBackup': huelleBackup.toJson(),
        'recoveryKennung': recoveryKennung,
        'pruefwert': pruefwert.toJson(),
        'biometrie': biometrie,
      };

  static Schluesselbund? fromJson(Map<String, dynamic>? j) {
    if (j == null || j['version'] != version) return null;
    final hp = Geheimtext.fromJson(j['huellePasswort']);
    final hr = Geheimtext.fromJson(j['huelleRecovery']);
    final hb = Geheimtext.fromJson(j['huelleBackup']);
    final pw = Geheimtext.fromJson(j['pruefwert']);
    if (hp == null || hr == null || hb == null || pw == null) return null;
    return Schluesselbund(
      kdf: KdfParameter.fromJson((j['kdf'] as Map).cast<String, dynamic>()),
      huellePasswort: hp,
      huelleRecovery: hr,
      huelleBackup: hb,
      recoveryKennung: j['recoveryKennung'] as String,
      pruefwert: pw,
      biometrie: j['biometrie'] == true,
    );
  }
}
