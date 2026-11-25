import 'dart:async';
import 'dart:convert';
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
/// - `PT_OEFFENTLICHE_URL` – eigene Adresse (`https://…`) für den föderierten
///   Preiskatalog; ohne sie bleibt der Katalog auf dieser Instanz
/// - `PT_KATALOG_PEERS` – Startliste anderer Instanzen, durch Komma getrennt
/// - `PT_KATALOG_MINUTEN` – Abstand des Abrufs anderer Instanzen (Standard 10)
/// - `PT_REGISTRIERUNG` – neue Konten: `offen` (Standard), `einladung`
///   (Einmal-Code vom Betreiber) oder `zu`
///
/// Betrieb (siehe BETRIEB.md): `pt-sync einladung [tage]`, `pt-sync konten`,
/// `pt-sync kontingent <konto> <MiB|standard>`, `pt-sync konto-loeschen <konto>`,
/// `pt-sync status`, `pt-sync pruefen`.
///
/// `pt-sync sichern <ziel.db>` schreibt eine konsistente Kopie der
/// Datenbank (auch bei laufendem Server) und beendet sich.
///
/// Katalog (Betreiber): `pt-sync katalog sperren <pseudonym>`,
/// `pt-sync katalog instanz-sperren <url>`, `pt-sync katalog instanz-freigeben <url>`,
/// `pt-sync katalog abgleichen`.
///
/// TLS übernimmt ein Reverse-Proxy (siehe README). Ohne TLS nehmen die
/// Apps nur Adressen auf `localhost` an.
Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final pfad = env['PT_DB'] ?? 'daten/sync.db';
  final instanz = Katalog.normalisieren(env['PT_OEFFENTLICHE_URL'] ?? '') ?? 'lokal';
  if (args.length == 2 && args.first == 'sichern') {
    final s = Speicher.oeffnen(pfad);
    s.sichern(args[1]);
    s.schliessen();
    stdout.writeln('Gesichert nach ${args[1]}');
    return;
  }
  if (args.isNotEmpty && _betrieb.contains(args.first)) {
    final s = Speicher.oeffnen(pfad);
    try {
      exitCode = _betriebsbefehl(s, args, instanz);
    } on SpeicherFehler catch (e) {
      stderr.writeln(e.meldung);
      exitCode = 1;
    }
    s.schliessen();
    return;
  }
  final registrierung = env['PT_REGISTRIERUNG'] ?? 'offen';
  if (!const ['offen', 'einladung', 'zu'].contains(registrierung)) {
    stderr.writeln('PT_REGISTRIERUNG muss offen, einladung oder zu sein.');
    exitCode = 64;
    return;
  }
  if (args.isNotEmpty && args.first == 'katalog') {
    final s = Speicher.oeffnen(pfad);
    final k = Katalog(s, instanz: instanz);
    try {
      switch (args.skip(1).toList()) {
        case ['sperren', final p]:
          stdout.writeln('Gesperrt, ${k.kontoSperren(p)} Beiträge zurückgezogen.');
        case ['instanz-sperren', final u]:
          k.instanzSperren(Katalog.normalisieren(u) ?? u);
          stdout.writeln('Instanz $u gesperrt.');
        case ['instanz-freigeben', final u]:
          k.instanzSperren(Katalog.normalisieren(u) ?? u, gesperrt: false);
          stdout.writeln('Instanz $u freigegeben.');
        case ['abgleichen']:
          final e = await k.abgleichen(_abruf);
          stdout.writeln('${e.neu} neu, ${e.ungueltig} ungültig, Fehler: ${e.fehler}');
        default:
          stderr.writeln('Unbekannter Katalog-Befehl.');
          exitCode = 64;
      }
    } on SpeicherFehler catch (e) {
      stderr.writeln(e.meldung);
      exitCode = 1;
    }
    s.schliessen();
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
      instanz: instanz,
      registrierung: registrierung,
      protokoll: stdout.writeln,
    ),
  );
  final server = await io.serve(handler, env['PT_HOST'] ?? '127.0.0.1', int.parse(env['PT_PORT'] ?? '8743'));
  server.autoCompress = true;
  stdout.writeln('Personal-Tracker-Sync $serverVersion (API v$apiVersion, DB-Schema $dbSchema) auf '
      'http://${server.address.host}:${server.port}, Datenbank $pfad, Registrierung $registrierung');

  // Föderierter Katalog: andere Instanzen regelmäßig abrufen.
  Timer? katalogTakt;
  if (instanz != 'lokal') {
    final katalog = Katalog(speicher, instanz: instanz);
    for (final u in (env['PT_KATALOG_PEERS'] ?? '').split(',')) {
      if (u.trim().isNotEmpty) katalog.peerHinzufuegen(u);
    }
    Future<void> abgleichen() async {
      final e = await katalog.abgleichen(_abruf);
      stdout.writeln('Katalog: ${e.neu} neu, ${e.ungueltig} ungültig${e.fehler.isEmpty ? '' : ', nicht erreichbar: ${e.fehler.keys.join(', ')}'}');
    }

    katalogTakt = Timer.periodic(Duration(minutes: int.tryParse(env['PT_KATALOG_MINUTEN'] ?? '') ?? 10), (_) => abgleichen());
    unawaited(abgleichen());
  }

  Future<void> beenden(ProcessSignal _) async {
    katalogTakt?.cancel();
    await server.close();
    speicher.schliessen();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(beenden);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(beenden);
}

/// GET mit Zeitlimit und Größengrenze (Katalog anderer Instanzen).
Future<(int, String)> _abruf(Uri u) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await c.getUrl(u).timeout(const Duration(seconds: 15));
    req.headers.set('accept', 'application/json');
    final res = await req.close().timeout(const Duration(seconds: 30));
    final teile = <int>[];
    await for (final t in res.timeout(const Duration(seconds: 30))) {
      teile.addAll(t);
      if (teile.length > 16 * 1024 * 1024) throw const FormatException('Antwort zu groß');
    }
    return (res.statusCode, utf8.decode(teile, allowMalformed: true));
  } finally {
    c.close(force: true);
  }
}

const _betrieb = {'einladung', 'konten', 'kontingent', 'konto-loeschen', 'status', 'pruefen'};

String _mib(int b) => (b / (1024 * 1024)).toStringAsFixed(1);

/// Befehle für Betreiber. Sie zeigen nie Inhalte (die kennt der Server nicht).
int _betriebsbefehl(Speicher s, List<String> args, String instanz) {
  switch (args) {
    case ['einladung']:
    case ['einladung', _]:
      final tage = args.length == 2 ? int.tryParse(args[1]) : 14;
      if (tage == null || tage < 1 || tage > 365) {
        stderr.writeln('Gültigkeit in Tagen: 1 bis 365.');
        return 64;
      }
      stdout.writeln(s.registrierungAnlegen(gueltig: Duration(days: tage)));
      stderr.writeln('Einmal-Code für ein neues Konto, $tage Tage gültig (nur mit PT_REGISTRIERUNG=einladung nötig).');
      return 0;
    case ['konten']:
      stdout.writeln('konto       erstellt    MiB  kontingent  geraete  zuletzt');
      for (final k in s.kontenUebersicht()) {
        final q = k['kontingent'] as int?;
        stdout.writeln('${(k['konto'] as String).substring(0, 10)}  ${(k['erstellt'] as String).substring(0, 10)}  '
            '${_mib(k['belegt'] as int).padLeft(6)}  ${(q == null ? 'standard' : _mib(q)).padLeft(10)}  '
            '${'${k['geraete']}'.padLeft(7)}  ${(k['zuletzt'] as String?)?.substring(0, 10) ?? '-'}');
      }
      return 0;
    case ['kontingent', final p, final wert]:
      final konto = s.kontoZuPraefix(p);
      if (konto == null) {
        stderr.writeln('Kein eindeutiges Konto zu „$p“ (mindestens 6 Zeichen der ID).');
        return 1;
      }
      final mib = wert == 'standard' ? null : int.tryParse(wert);
      if (wert != 'standard' && (mib == null || mib < 0)) {
        stderr.writeln('Kontingent in MiB (0 = unbegrenzt) oder „standard“.');
        return 64;
      }
      s.kontingentSetzen(konto, mib == null ? null : mib * 1024 * 1024);
      stdout.writeln('Kontingent für $konto: ${mib == null ? 'Standard der Instanz' : mib == 0 ? 'unbegrenzt' : '$mib MiB'}.');
      return 0;
    case ['konto-loeschen', final p]:
      final konto = s.kontoZuPraefix(p);
      if (konto == null || konto != p.toLowerCase()) {
        stderr.writeln('Zum Löschen die vollständige Konto-ID angeben (siehe „pt-sync konten“).');
        return 1;
      }
      s.transaktion(() => Katalog(s, instanz: instanz).kontoEntfernen(konto));
      s.kontoLoeschen(konto);
      stdout.writeln('Konto $konto mit allen Geräten, Daten und Räumen gelöscht; Katalogbeiträge zurückgezogen.');
      return 0;
    case ['status']:
      final z = s.zustand();
      stdout.writeln('Server $serverVersion, DB-Schema $dbSchema, Instanz $instanz');
      stdout.writeln('${z['konten']} Konten, ${z['geraete']} Geräte, ${z['raeume']} Räume, ${_mib(z['bytes']! as int)} MiB Geheimtext');
      return 0;
    case ['pruefen']:
      final e = s.pruefen();
      stdout.writeln(e == 'ok' ? 'Datenbank in Ordnung.' : e);
      return e == 'ok' ? 0 : 1;
    default:
      stderr.writeln('Unbekannter Befehl.');
      return 64;
  }
}
