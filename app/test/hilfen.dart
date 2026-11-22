import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:personal_tracker/core/dienste/biometrie.dart';
import 'package:personal_tracker/core/dienste/erinnerungen.dart';
import 'package:personal_tracker/core/krypto/kdf.dart';
import 'package:personal_tracker/core/krypto/schluesselbund.dart';
import 'package:personal_tracker/core/modell/bestand.dart';
import 'package:personal_tracker/core/sitzung.dart';
import 'package:personal_tracker/core/speicher/ablage.dart';
import 'package:sembast/sembast_memory.dart';

/// Schnelle Ableitung nur für Tests.
KdfParameter testKdf() => KdfParameter.argon2id(speicherKiB: 64, iterationen: 1);

class FakeBiometrie implements Biometrie {
  Uint8List? gespeichert;
  bool abbrechen = false;
  @override
  bool get unterstuetzt => true;
  @override
  Future<void> speichern(Uint8List dek) async => gespeichert = dek;
  @override
  Future<Uint8List?> lesen() async => abbrechen ? null : gespeichert;
  @override
  Future<void> loeschen() async => gespeichert = null;
}

class FakeErinnerungen implements ErinnerungsDienst {
  final geplant = <Bestand>[];
  var beendet = 0;
  @override
  Future<ErinnerungsStatus> planen(Bestand bestand, {DateTime? jetzt}) async {
    geplant.add(bestand);
    return const ErinnerungsStatus(erlaubt: true);
  }

  @override
  Future<ErinnerungsStatus> erlaubnisAnfragen() async => const ErinnerungsStatus(erlaubt: true);
  @override
  Future<void> beenden() async => beendet++;
}

/// Simuliert eine Installation: gleiche Fabrik + Name = gleiches Gerät.
class TestGeraet {
  TestGeraet({DatabaseFactory? fabrik, this.name = 'test.db'}) : fabrik = fabrik ?? newDatabaseFactoryMemory();

  final DatabaseFactory fabrik;
  final String name;
  final biometrie = FakeBiometrie();
  final erinnerungen = FakeErinnerungen();
  DateTime jetzt = DateTime(2026, 11, 22, 10);

  /// „App-Start“: Ablage öffnen, Schlüsselbund lesen, Container bauen.
  Future<(ProviderContainer, Ablage)> starten() async {
    final ablage = await Ablage.oeffnen(factory: fabrik, name: name);
    final roh = await ablage.meta(SitzungNotifier.metaBund);
    final bund = Schluesselbund.fromJson(roh == null ? null : (roh as Map).cast<String, dynamic>());
    final c = ProviderContainer(overrides: overrides(ablage, bund));
    return (c, ablage);
  }

  List<Override> overrides(Ablage ablage, Schluesselbund? bund) => [
        ablageProvider.overrideWithValue(ablage),
        startBundProvider.overrideWithValue(bund),
        biometrieProvider.overrideWithValue(biometrie),
        erinnerungenProvider.overrideWithValue(erinnerungen),
        kdfProvider.overrideWithValue(testKdf),
        uhrProvider.overrideWithValue(() => jetzt),
      ];
}
