import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/krypto/recovery_schluessel.dart';
import 'package:personal_tracker/core/speicher/backup.dart';
import 'package:personal_tracker/core/speicher/schema.dart';

void main() {
  final r = RecoverySchluessel.neu();
  final Rohdaten daten = {
    'notizen': [
      {'id': 'n1', 'titel': 'Einkauf', 'text': '# Liste\n- Butter'},
    ],
    'buchungen': [
      {'id': 'b1', 'umbuchungId': 'u1'},
      {'id': 'b2', 'umbuchungId': 'u1'},
    ],
  };

  Uint8List datei() => Backup.erstellen(daten: daten, backupSchluessel: r.backupSchluessel, recoveryKennung: r.kennung);

  test('Rundweg mit dem richtigen Recovery-Schlüssel', () {
    final inhalt = Backup.lesen(datei(), r);
    expect(inhalt.daten, daten);
    expect(inhalt.anzahl('buchungen'), 2);
    expect(utf8.decode(datei()), isNot(contains('Butter')), reason: 'Inhalt nur verschlüsselt');
  });

  test('Falscher Schlüssel, Manipulation und fremde Dateien werden verständlich abgelehnt', () {
    expect(() => Backup.lesen(datei(), RecoverySchluessel.neu()), throwsA(isA<BackupFehler>().having((e) => e.meldung, 'meldung', contains('gehört nicht'))));

    final j = jsonDecode(utf8.decode(datei())) as Map<String, dynamic>;
    final c = base64Decode(j['c'] as String)..[3] ^= 0xff;
    final kaputt = Uint8List.fromList(utf8.encode(jsonEncode({...j, 'c': base64Encode(c)})));
    expect(() => Backup.lesen(kaputt, r), throwsA(isA<BackupFehler>().having((e) => e.meldung, 'meldung', contains('beschädigt'))));

    final kopfGeaendert = Uint8List.fromList(utf8.encode(jsonEncode({...j, 'erstellt': '2020-01-01T00:00:00.000Z'})));
    expect(() => Backup.lesen(kopfGeaendert, r), throwsA(isA<BackupFehler>()));

    expect(() => Backup.lesen(Uint8List.fromList(utf8.encode('hallo')), r), throwsA(isA<BackupFehler>()));
    expect(() => Backup.lesen(Uint8List.fromList([0xff, 0xfe]), r), throwsA(isA<BackupFehler>()));

    final neuer = Uint8List.fromList(utf8.encode(jsonEncode({...j, 'version': 99})));
    expect(() => Backup.kopfLesen(neuer), throwsA(isA<BackupFehler>().having((e) => e.meldung, 'meldung', contains('neueren'))));
  });

  test('Migration: ältere Schemata werden angehoben, neuere abgelehnt', () {
    Rohdaten v0zuV1(Rohdaten d) => {
          for (final e in d.entries) e.key: [for (final x in e.value) {...x, 'migriert': true}],
        };
    final m = migrieren(daten, 0, schritte: {0: v0zuV1}, ziel: 1);
    expect(m['notizen']!.single['migriert'], isTrue);
    expect(() => migrieren(daten, 2), throwsA(isA<SchemaFehler>()));
    expect(() => migrieren(daten, 0, schritte: const {}, ziel: 1), throwsA(isA<SchemaFehler>()));
  });
}
