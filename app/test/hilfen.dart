import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:personal_tracker/core/dienste/biometrie.dart';
import 'package:personal_tracker/core/dienste/erinnerungen.dart';
import 'package:personal_tracker/core/dienste/standort.dart';
import 'package:personal_tracker/core/krypto/kdf.dart';
import 'package:personal_tracker/core/krypto/schluesselbund.dart';
import 'package:personal_tracker/core/modell/bestand.dart';
import 'package:personal_tracker/core/sitzung.dart';
import 'package:personal_tracker/core/speicher/ablage.dart';
import 'package:personal_tracker/core/sync/sync_dienst.dart';
import 'package:personal_tracker/ui/dateien.dart';
import 'package:sembast/sembast_memory.dart';

/// Schnelle Ableitung nur für Tests (synchron, ohne Isolate — passt auch
/// in Widget-Tests).
KdfParameter testKdf() => KdfParameter.pbkdf2(iterationen: 1000);

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

/// Dateiablage im Speicher: „gespeicherte“ Sicherungen und eine Datei,
/// die beim Öffnen gewählt wird.
class FakeDateien implements Dateien {
  final gespeichert = <String, Uint8List>{};
  ({String name, Uint8List bytes})? zumOeffnen;

  @override
  Future<bool> speichern(String name, Uint8List bytes) async {
    gespeichert[name] = bytes;
    return true;
  }

  @override
  Future<({String name, Uint8List bytes})?> oeffnen() async => zumOeffnen;
}

/// Standort im Test: fest eingestellt oder verweigert.
class FakeStandort implements Standort {
  ({double breite, double laenge})? position = (breite: 52.5200, laenge: 13.4050);
  @override
  Future<({double breite, double laenge})> holen() async {
    final p = position;
    if (p == null) throw StandortFehler('Ohne Standortfreigabe geht das nicht.');
    return p;
  }
}

/// Simuliert eine Installation: gleiche Fabrik + Name = gleiches Gerät.
class TestGeraet {
  TestGeraet({DatabaseFactory? fabrik, this.name = 'test.db', this.client}) : fabrik = fabrik ?? newDatabaseFactoryMemory();

  final DatabaseFactory fabrik;
  final String name;

  /// Verbindung zum (Test-)Sync-Server; ohne gibt es keinen Netzzugriff.
  final http.Client? client;
  final biometrie = FakeBiometrie();
  final erinnerungen = FakeErinnerungen();
  final dateien = FakeDateien();
  final standort = FakeStandort();
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
        dateienProvider.overrideWithValue(dateien),
        standortProvider.overrideWithValue(standort),
        // Automatischer Abgleich aus: Tests gleichen ausdrücklich ab.
        syncTaktProvider.overrideWithValue((nachAenderung: Duration.zero, regelmaessig: Duration.zero)),
        if (client != null) httpClientProvider.overrideWithValue(client!),
      ];
}
