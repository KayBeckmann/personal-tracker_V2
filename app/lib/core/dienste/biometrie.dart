import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Entsperren per Fingerabdruck (nur Android). Der Datenschlüssel liegt
/// dann zusätzlich im Android-Keystore, an starke Biometrie gebunden
/// (`setUserAuthenticationRequired`): Lesen geht nur nach erfolgreicher
/// Prüfung durch das System.
abstract class Biometrie {
  bool get unterstuetzt;
  Future<void> speichern(Uint8List dek);

  /// `null`, wenn abgebrochen oder nicht eingerichtet.
  Future<Uint8List?> lesen();
  Future<void> loeschen();
}

class KeineBiometrie implements Biometrie {
  const KeineBiometrie();
  @override
  bool get unterstuetzt => false;
  @override
  Future<void> speichern(Uint8List dek) async => throw UnsupportedError('Fingerabdruck gibt es nur in der Android-App.');
  @override
  Future<Uint8List?> lesen() async => null;
  @override
  Future<void> loeschen() async {}
}

class AndroidBiometrie implements Biometrie {
  const AndroidBiometrie();

  static const _schluessel = 'ptv2-dek';
  static const _optionen = AndroidOptions.biometric(
    enforceBiometrics: true,
    biometricType: AndroidBiometricType.strongBiometricOnly,
    resetOnError: false,
    biometricPromptTitle: 'Personal Tracker entsperren',
    biometricPromptSubtitle: 'Mit Fingerabdruck bestätigen',
    biometricPromptNegativeButton: 'Abbrechen',
  );
  static const _speicher = FlutterSecureStorage(aOptions: _optionen);

  @override
  bool get unterstuetzt => true;

  @override
  Future<void> speichern(Uint8List dek) => _speicher.write(key: _schluessel, value: base64Encode(dek));

  @override
  Future<Uint8List?> lesen() async {
    final w = await _speicher.read(key: _schluessel);
    return w == null ? null : base64Decode(w);
  }

  @override
  Future<void> loeschen() => _speicher.delete(key: _schluessel);
}

Biometrie plattformBiometrie() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? const AndroidBiometrie() : const KeineBiometrie();
