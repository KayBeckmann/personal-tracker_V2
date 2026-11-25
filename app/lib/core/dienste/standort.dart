import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// Aktuelle Position, nur auf ausdrücklichen Knopfdruck (Filiale merken,
/// nächste Filiale finden). Kein Hintergrund-Standort, keine Karte und kein
/// Kartendienst – die Position bleibt verschlüsselt in der App.
abstract class Standort {
  /// `null` mit [StandortFehler], wenn nicht erlaubt oder nicht verfügbar.
  Future<({double breite, double laenge})> holen();
}

class StandortFehler implements Exception {
  StandortFehler(this.meldung);
  final String meldung;
  @override
  String toString() => meldung;
}

class GeraeteStandort implements Standort {
  const GeraeteStandort();

  @override
  Future<({double breite, double laenge})> holen() async {
    if (!await Geolocator.isLocationServiceEnabled()) throw StandortFehler('Standort ist auf diesem Gerät ausgeschaltet.');
    var erlaubnis = await Geolocator.checkPermission();
    if (erlaubnis == LocationPermission.denied) erlaubnis = await Geolocator.requestPermission();
    if (erlaubnis == LocationPermission.denied || erlaubnis == LocationPermission.deniedForever) {
      throw StandortFehler('Ohne Standortfreigabe geht das nicht. Die Filiale lässt sich auch ohne Position anlegen.');
    }
    final p = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
    return (breite: p.latitude, laenge: p.longitude);
  }
}

final standortProvider = Provider<Standort>((ref) => const GeraeteStandort());
