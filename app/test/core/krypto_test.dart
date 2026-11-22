import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/krypto/kdf.dart';
import 'package:personal_tracker/core/krypto/krypto.dart';
import 'package:personal_tracker/core/krypto/recovery_schluessel.dart';
import 'package:personal_tracker/core/krypto/schluesselbund.dart';

/// Schnelle Parameter nur für Tests.
KdfParameter testKdf() => KdfParameter.argon2id(speicherKiB: 64, iterationen: 1);

void main() {
  test('AES-GCM: Rundweg, falsche AAD und manipulierte Daten scheitern', () {
    final k = zufall(32);
    final g = AesGcm.verschluesseln(k, Uint8List.fromList(utf8.encode('Miete 850 €')), aad: 'buchungen/1');
    expect(utf8.decode(AesGcm.entschluesseln(k, g, aad: 'buchungen/1')!), 'Miete 850 €');
    expect(AesGcm.entschluesseln(k, g, aad: 'buchungen/2'), isNull);
    expect(AesGcm.entschluesseln(zufall(32), g, aad: 'buchungen/1'), isNull);
    final kaputt = Uint8List.fromList(g.daten)..[0] ^= 1;
    expect(AesGcm.entschluesseln(k, Geheimtext(g.nonce, kaputt), aad: 'buchungen/1'), isNull);
  });

  test('Recovery-Schlüssel: Anzeige, tolerantes Einlesen, Fehleingaben', () {
    final r = RecoverySchluessel.neu();
    final text = r.anzeigen();
    expect(text, matches(RegExp(r'^([0-9A-HJKMNP-TV-Z]{4}-){7}[0-9A-HJKMNP-TV-Z]{4}$')));
    final gelesen = RecoverySchluessel.lesen(' ${text.toLowerCase().replaceAll('-', ' ')} ')!;
    expect(gelesen.bytes, r.bytes);
    expect(gelesen.kennung, r.kennung);
    expect(RecoverySchluessel.lesen(text.substring(0, 20)), isNull);
    expect(RecoverySchluessel.lesen('${text.substring(0, 38)}U'), isNull, reason: 'U ist kein Crockford-Zeichen');
    // O/0 und I/L/1 werden gleich behandelt.
    final mitO = text.replaceAll('0', 'O');
    expect(RecoverySchluessel.lesen(mitO)!.bytes, r.bytes);
  });

  test('Schlüsselbund: Passwort, Recovery, Passwortwechsel, Backup-Schlüssel', () async {
    final r = RecoverySchluessel.neu();
    final (:bund, :dek) = await Schluesselbund.anlegen('geheim123', r, kdf: testKdf());
    final gespeichert = Schluesselbund.fromJson(jsonDecode(jsonEncode(bund.toJson())) as Map<String, dynamic>)!;

    expect(await gespeichert.mitPasswort('geheim123'), dek);
    expect(await gespeichert.mitPasswort('falsch'), isNull);
    expect(gespeichert.mitRecovery(r), dek);
    expect(gespeichert.mitRecovery(RecoverySchluessel.neu()), isNull);
    expect(gespeichert.backupSchluessel(dek), r.backupSchluessel);
    expect(gespeichert.passt(zufall(32)), isFalse);

    final neu = await gespeichert.mitNeuemPasswort(dek, 'anders456');
    expect(await neu.mitPasswort('geheim123'), isNull);
    expect(await neu.mitPasswort('anders456'), dek);
    expect(neu.mitRecovery(r), dek, reason: 'Recovery bleibt gültig');

    final r2 = RecoverySchluessel.neu();
    final getauscht = neu.mitNeuemRecovery(dek, r2);
    expect(getauscht.mitRecovery(r), isNull);
    expect(getauscht.mitRecovery(r2), dek);
    expect(getauscht.backupSchluessel(dek), r2.backupSchluessel);
  });

  test('KDF-Parameter überstehen das Speichern; PBKDF2 auf der VM rechnet', () async {
    final k = KdfParameter.pbkdf2(iterationen: 1000);
    final wieder = KdfParameter.fromJson(jsonDecode(jsonEncode(k.toJson())) as Map<String, dynamic>);
    expect(await wieder.ableiten('pw'), await k.ableiten('pw'));
    expect(await k.ableiten('pw'), isNot(await k.ableiten('pW')));
    expect(KdfParameter.standard().verfahren, KdfParameter.verfahrenArgon2id);
  });
}
