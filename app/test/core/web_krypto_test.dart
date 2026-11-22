@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/krypto/kdf.dart';
import 'package:personal_tracker/core/krypto/krypto.dart';
import 'package:personal_tracker/core/krypto/recovery_schluessel.dart';
import 'package:personal_tracker/core/krypto/schluesselbund.dart';
import 'package:personal_tracker/core/speicher/backup.dart';

/// Im Browser (dart2js): WebCrypto-PBKDF2 und pointycastle als JavaScript.
void main() {
  test('PBKDF2 über WebCrypto entspricht dem RFC-6070-Testvektor', () async {
    // RFC 6070 ist SHA-1; für SHA-256 der bekannte Vektor (P="password", S="salt", c=1).
    final k = KdfParameter.pbkdf2(iterationen: 1, salz: Uint8List.fromList(utf8.encode('salt')));
    expect(hex(await k.ableiten('password')), '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
  });

  test('Schlüsselbund, AES-GCM und Backup im Browser', () async {
    final r = RecoverySchluessel.neu();
    final (:bund, :dek) = await Schluesselbund.anlegen('pw-im-browser', r, kdf: KdfParameter.pbkdf2(iterationen: 1000));
    expect(await bund.mitPasswort('pw-im-browser'), dek);
    expect(await bund.mitPasswort('falsch'), isNull);
    expect(bund.mitRecovery(RecoverySchluessel.lesen(r.anzeigen())!), dek);
    final datei = Backup.erstellen(
      daten: {'notizen': [{'id': 'n', 'text': 'ä€'}]},
      backupSchluessel: bund.backupSchluessel(dek)!,
      recoveryKennung: r.kennung,
    );
    expect(Backup.lesen(datei, r).daten['notizen']!.single['text'], 'ä€');
    final g = AesGcm.verschluesseln(dek, Uint8List.fromList(List.generate(5000, (i) => i % 251)));
    expect(AesGcm.entschluesseln(dek, g)!.length, 5000);
  });
}
