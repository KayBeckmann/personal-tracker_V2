import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/krypto/schluesselbund.dart';
import 'core/sitzung.dart';
import 'core/speicher/ablage.dart';
import 'ui/app.dart';
import 'ui/navigation.dart';
import 'ui/speicherstatus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de_DE');
  final ablage = await Ablage.oeffnen();
  final roh = await ablage.meta(SitzungNotifier.metaBund);
  final bund = Schluesselbund.fromJson(roh is Map ? roh.cast<String, dynamic>() : null);
  final gespeichert = await ablage.meta(FarbschemaNotifier.meta);
  final schema = ThemeMode.values.where((m) => m.name == gespeichert).firstOrNull;
  // Browser: um dauerhaften Speicher bitten (sonst darf er räumen).
  await dauerhaftenSpeicherAnfragen();
  runApp(ProviderScope(
    overrides: [
      ablageProvider.overrideWithValue(ablage),
      startBundProvider.overrideWithValue(bund),
      startFarbschemaProvider.overrideWithValue(schema ?? ThemeMode.system),
    ],
    child: const TrackerApp(),
  ));
}
