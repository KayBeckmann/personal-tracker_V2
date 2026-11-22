import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import 'kdf_web_stub.dart' if (dart.library.js_interop) 'kdf_web.dart';
import 'krypto.dart';

/// Schlüsselableitung aus dem App-Passwort. Das Verfahren steht im
/// Schlüsselbund, damit eine Installation es beim Entsperren wiederfindet.
///
/// - Android: Argon2id (speicherhart). Gemessen braucht die reine
///   Dart-Umsetzung im Browser ~18 s — dort daher
/// - Web: PBKDF2-SHA256 über WebCrypto (nativ im Browser) mit 600.000
///   Iterationen (OWASP-Empfehlung 2023).
class KdfParameter {
  const KdfParameter._({
    required this.verfahren,
    required this.salz,
    required this.iterationen,
    this.speicherKiB = 0,
  });

  factory KdfParameter.argon2id({int speicherKiB = 1 << 15, int iterationen = 3, Uint8List? salz}) =>
      KdfParameter._(verfahren: verfahrenArgon2id, salz: salz ?? zufall(16), iterationen: iterationen, speicherKiB: speicherKiB);

  factory KdfParameter.pbkdf2({int iterationen = 600000, Uint8List? salz}) =>
      KdfParameter._(verfahren: verfahrenPbkdf2, salz: salz ?? zufall(16), iterationen: iterationen);

  /// Standard der laufenden Plattform.
  factory KdfParameter.standard() => kIsWeb ? KdfParameter.pbkdf2() : KdfParameter.argon2id();

  static const verfahrenArgon2id = 'argon2id';
  static const verfahrenPbkdf2 = 'pbkdf2-sha256';

  final String verfahren;
  final Uint8List salz;
  final int iterationen;
  final int speicherKiB;

  Map<String, dynamic> toJson() => {
        'verfahren': verfahren,
        'salz': base64Encode(salz),
        'iterationen': iterationen,
        if (verfahren == verfahrenArgon2id) 'speicherKiB': speicherKiB,
      };

  static KdfParameter fromJson(Map<String, dynamic> j) => KdfParameter._(
        verfahren: j['verfahren'] as String,
        salz: base64Decode(j['salz'] as String),
        iterationen: j['iterationen'] as int,
        speicherKiB: (j['speicherKiB'] as int?) ?? 0,
      );

  /// 32-Byte-Schlüssel aus dem Passwort. Argon2id läuft in einem eigenen
  /// Isolate, damit die Oberfläche nicht einfriert.
  Future<Uint8List> ableiten(String passwort) async {
    final pw = Uint8List.fromList(utf8.encode(passwort));
    switch (verfahren) {
      case verfahrenArgon2id:
        final s = salz, i = iterationen, m = speicherKiB;
        return kIsWeb ? _argon2(pw, s, i, m) : Isolate.run(() => _argon2(pw, s, i, m));
      case verfahrenPbkdf2:
        return kIsWeb ? pbkdf2Web(pw, salz, iterationen) : _pbkdf2(pw, salz, iterationen);
      default:
        throw StateError('Unbekanntes Ableitungsverfahren: $verfahren');
    }
  }
}

Uint8List _argon2(Uint8List pw, Uint8List salz, int iterationen, int speicherKiB) {
  final g = Argon2BytesGenerator()
    ..init(Argon2Parameters(
      Argon2Parameters.ARGON2_id,
      salz,
      desiredKeyLength: 32,
      iterations: iterationen,
      memory: speicherKiB,
      lanes: 1,
      version: Argon2Parameters.ARGON2_VERSION_13,
    ));
  final out = Uint8List(32);
  g.deriveKey(pw, 0, out, 0);
  return out;
}

Uint8List _pbkdf2(Uint8List pw, Uint8List salz, int iterationen) {
  final g = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))..init(Pbkdf2Parameters(salz, iterationen, 32));
  return g.process(pw);
}
