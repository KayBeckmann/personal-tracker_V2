import 'package:sembast_web/sembast_web.dart';

/// Browser: IndexedDB. Daten bleiben nur, solange der Browser den
/// Speicher nicht räumt — deshalb Backup und „dauerhafter Speicher“.
DatabaseFactory datenbankFabrik() => databaseFactoryWeb;

Future<String> datenbankPfad(String name) async => name;
