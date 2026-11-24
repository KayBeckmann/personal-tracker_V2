import 'dart:io';

import 'package:personal_tracker_sync/personal_tracker_sync.dart';
import 'package:shelf/shelf_io.dart' as io;

/// Start: `dart run bin/server.dart` oder das kompilierte Programm.
/// Einstellungen über Umgebungsvariablen:
///
/// - `PT_DB` – Pfad der SQLite-Datei (Standard `daten/sync.db`)
/// - `PT_HOST` / `PT_PORT` – Adresse (Standard `127.0.0.1:8743`)
/// - `PT_URSPRUNG` – erlaubter Ursprung der Web-App (Standard `*`)
/// - `PT_HINTER_PROXY=1` – Client-IP aus `X-Forwarded-For` (nur hinter
///   eigenem Reverse-Proxy setzen)
/// - `PT_MAX_KONTO_MB` – Speicherplatz je Konto in MiB (Standard: unbegrenzt)
///
/// `pt-sync sichern <ziel.db>` schreibt eine konsistente Kopie der
/// Datenbank (auch bei laufendem Server) und beendet sich.
///
/// TLS übernimmt ein Reverse-Proxy (siehe README). Ohne TLS nehmen die
/// Apps nur Adressen auf `localhost` an.
Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final pfad = env['PT_DB'] ?? 'daten/sync.db';
  if (args.length == 2 && args.first == 'sichern') {
    final s = Speicher.oeffnen(pfad);
    s.sichern(args[1]);
    s.schliessen();
    stdout.writeln('Gesichert nach ${args[1]}');
    return;
  }
  File(pfad).parent.createSync(recursive: true);
  final speicher = Speicher.oeffnen(pfad);
  final handler = syncHandler(
    speicher,
    k: Konfiguration(
      ursprung: env['PT_URSPRUNG'] ?? '*',
      hinterProxy: env['PT_HINTER_PROXY'] == '1',
      maxKonto: (int.tryParse(env['PT_MAX_KONTO_MB'] ?? '') ?? 0) * 1024 * 1024,
      protokoll: stdout.writeln,
    ),
  );
  final server = await io.serve(handler, env['PT_HOST'] ?? '127.0.0.1', int.parse(env['PT_PORT'] ?? '8743'));
  server.autoCompress = true;
  stdout.writeln('Personal-Tracker-Sync $serverVersion (API v$apiVersion, DB-Schema $dbSchema) auf '
      'http://${server.address.host}:${server.port}, Datenbank $pfad');

  Future<void> beenden(ProcessSignal _) async {
    await server.close();
    speicher.schliessen();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(beenden);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(beenden);
}
