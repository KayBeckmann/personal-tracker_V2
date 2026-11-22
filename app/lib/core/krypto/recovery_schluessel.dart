import 'dart:typed_data';

import 'krypto.dart';

/// Recovery-Schlüssel: 160 Bit Zufall, angezeigt in Crockford-Base32
/// (keine verwechselbaren Zeichen I, L, O, U) als acht Vierergruppen.
/// Er öffnet die App ohne Passwort und entschlüsselt Datensicherungen.
/// Er wird nie gespeichert — nur daraus abgeleitete Hüllen und eine
/// Kennung, an der ein Backup den passenden Schlüssel erkennt.
class RecoverySchluessel {
  RecoverySchluessel._(this.bytes);

  factory RecoverySchluessel.neu() => RecoverySchluessel._(zufall(laenge));

  static const laenge = 20;
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  final Uint8List bytes;

  /// Schlüssel für die Hülle des Datenschlüssels.
  Uint8List get huellenSchluessel => hkdf(bytes, 'ptv2-recovery-huelle-v1');

  /// Schlüssel für Datensicherungen.
  Uint8List get backupSchluessel => hkdf(bytes, 'ptv2-backup-v1');

  /// Öffentliche Kennung (kein Geheimnis): zeigt, ob ein Backup zu diesem
  /// Schlüssel passt, ohne den Schlüssel selbst preiszugeben.
  String get kennung => hex(hkdf(bytes, 'ptv2-kennung-v1', laenge: 8));

  /// `XXXX-XXXX-…` (8 Gruppen à 4 Zeichen).
  String anzeigen() {
    final zeichen = StringBuffer();
    var puffer = 0, bits = 0;
    for (final b in bytes) {
      puffer = ((puffer << 8) | b) & 0xffff;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        zeichen.write(_alphabet[(puffer >> bits) & 31]);
      }
    }
    final s = zeichen.toString();
    return [for (var i = 0; i < s.length; i += 4) s.substring(i, i + 4)].join('-');
  }

  /// Liest eine Eingabe tolerant (Kleinbuchstaben, Leerzeichen, Bindestriche,
  /// O→0, I/L→1). `null` bei falscher Länge oder unbekannten Zeichen.
  static RecoverySchluessel? lesen(String eingabe) {
    final s = eingabe
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-_.]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    if (s.length != laenge * 8 ~/ 5) return null;
    final out = <int>[];
    var puffer = 0, bits = 0;
    for (final c in s.split('')) {
      final v = _alphabet.indexOf(c);
      if (v < 0) return null;
      puffer = ((puffer << 5) | v) & 0xffff;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((puffer >> bits) & 0xff);
      }
    }
    return RecoverySchluessel._(Uint8List.fromList(out));
  }
}
