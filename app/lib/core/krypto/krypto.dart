import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Kryptografische Grundbausteine (etablierte Verfahren aus pointycastle,
/// keine Eigenbauten): AES-256-GCM für Datensätze und Schlüsselhüllen,
/// HKDF-SHA256 für abgeleitete Schlüssel, sichere Zufallszahlen.

final _zufallsquelle = Random.secure();

Uint8List zufall(int laenge) =>
    Uint8List.fromList([for (var i = 0; i < laenge; i++) _zufallsquelle.nextInt(256)]);

/// Geheimtext mit Nonce, als JSON `{n, c}` (Base64) speicherbar.
class Geheimtext {
  const Geheimtext(this.nonce, this.daten);

  final Uint8List nonce;
  final Uint8List daten;

  Map<String, dynamic> toJson() => {'n': base64Encode(nonce), 'c': base64Encode(daten)};

  static Geheimtext? fromJson(Object? json) {
    if (json is! Map) return null;
    final n = json['n'], c = json['c'];
    if (n is! String || c is! String) return null;
    try {
      return Geheimtext(base64Decode(n), base64Decode(c));
    } on FormatException {
      return null;
    }
  }
}

/// AES-256-GCM. [aad] bindet den Geheimtext an seinen Zweck (z. B. Ablage
/// und Datensatz-ID), damit vertauschte Datensätze auffallen.
class AesGcm {
  const AesGcm._();

  static Geheimtext verschluesseln(Uint8List schluessel, Uint8List klartext, {String aad = ''}) {
    final nonce = zufall(12);
    return Geheimtext(nonce, _gcm(true, schluessel, nonce, aad).process(klartext));
  }

  /// `null`, wenn Schlüssel, Nonce, AAD oder Daten nicht zusammenpassen.
  static Uint8List? entschluesseln(Uint8List schluessel, Geheimtext g, {String aad = ''}) {
    try {
      return _gcm(false, schluessel, g.nonce, aad).process(g.daten);
    } on InvalidCipherTextException {
      return null;
    } on ArgumentError {
      return null;
    } on StateError {
      return null;
    }
  }

  static GCMBlockCipher _gcm(bool verschluesseln, Uint8List schluessel, Uint8List nonce, String aad) =>
      GCMBlockCipher(AESEngine())
        ..init(
          verschluesseln,
          AEADParameters(KeyParameter(schluessel), 128, nonce, Uint8List.fromList(utf8.encode(aad))),
        );
}

/// HKDF-SHA256 (RFC 5869) für Schlüssel aus hochentropischem Material,
/// etwa dem Recovery-Schlüssel.
Uint8List hkdf(Uint8List material, String info, {int laenge = 32}) {
  final h = HKDFKeyDerivator(SHA256Digest())
    ..init(HkdfParameters(material, laenge, null, Uint8List.fromList(utf8.encode(info))));
  final out = Uint8List(laenge);
  h.deriveKey(null, 0, out, 0);
  return out;
}

String hex(Uint8List bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

bool gleich(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}
