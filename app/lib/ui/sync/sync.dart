import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/krypto/recovery_schluessel.dart';
import '../../core/sitzung.dart';
import '../../core/sync/sync_api.dart';
import '../../core/sync/sync_dienst.dart';
import '../../core/sync/sync_krypto.dart';
import '../bausteine.dart';
import '../format.dart';
import '../thema.dart';
import '../zugang/rahmen.dart';

/// Kurzer Status für Seitenleiste und Übersicht.
String syncKurztext(SyncStatus s, DateTime jetzt) {
  if (s.laeuft) return 'Gleiche ab …';
  if (s.fehler != null) {
    return switch (s.fehlerArt) {
      SyncFehlerArt.netz => s.ausstehend > 0 ? 'Offline · ${_aenderungen(s.ausstehend)} warten' : 'Server nicht erreichbar',
      SyncFehlerArt.anmeldung => 'Gerät nicht mehr angemeldet',
      SyncFehlerArt.version => 'App-Update nötig',
      _ => 'Abgleich mit Fehler',
    };
  }
  if (s.ausstehend > 0) return '${_aenderungen(s.ausstehend)} warten';
  final l = s.letzter;
  return l == null ? 'Noch nicht abgeglichen' : 'Abgeglichen ${vorWieLanger(l, jetzt)}';
}

String _aenderungen(int n) => n == 1 ? '1 Änderung' : '$n Änderungen';

String _host(String? server) => server == null ? '' : (Uri.tryParse(serverAdresse(server).toString())?.authority ?? server);

// ---------------------------------------------------------------------------
// Karte in den Einstellungen

class SyncKarte extends ConsumerWidget {
  const SyncKarte({super.key, required this.vorherSichern});

  /// Sicherung erstellen (vor der Erstverbindung empfohlen).
  final Future<void> Function() vorherSichern;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncProvider);
    final f = context.farben;
    final klein = TextStyle(fontSize: 13, color: f.gedaempft);

    if (!s.verbunden) {
      return Karte(
        key: const Key('karte-sync'),
        titel: 'Optional synchronisieren',
        marke: 'aus',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Mit deinem eigenen Sync-Server gleichen Handy und Browser ab. Alles wird vorher auf dem Gerät '
              'verschlüsselt — der Server sieht keine Inhalte. Ohne Verbindung bleibt alles wie jetzt.',
              style: klein,
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('sync-verbinden'),
                  onPressed: () => syncAblaufOeffnen(context, SyncWeg.verbinden, vorherSichern: vorherSichern),
                  icon: const Icon(Icons.cloud_sync_outlined, size: 18),
                  label: const Text('Mit Server verbinden …'),
                ),
                OutlinedButton(
                  key: const Key('sync-koppeln'),
                  onPressed: () => syncAblaufOeffnen(context, SyncWeg.koppeln, vorherSichern: vorherSichern),
                  child: const Text('Mit Kopplungscode …'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final fehler = s.fehler;
    return Karte(
      key: const Key('karte-sync'),
      titel: 'Synchronisieren',
      marke: s.fehler == null ? 'an' : 'Problem',
      markeWarnung: s.fehler != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Server: ${_host(s.server)}', style: klein),
          const SizedBox(height: 6),
          Text(
            syncKurztext(s, DateTime.now()),
            key: const Key('sync-status'),
            style: TextStyle(fontWeight: FontWeight.w600, color: fehler == null ? f.text : f.warnText),
          ),
          if (fehler != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(fehler, style: TextStyle(fontSize: 13, color: f.warnText))),
          const SizedBox(height: 6),
          Text('Automatisch bei geöffneter App: nach dem Entsperren, kurz nach Änderungen und alle 5 Minuten.', style: klein),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Vault: Dateien über ${ref.watch(bestandProvider).einstellungen.vaultMaxMiB} MiB lädt diese App nicht hoch.',
                  key: const Key('vault-grenze'),
                  style: klein,
                ),
              ),
              TextButton(key: const Key('vault-grenze-aendern'), onPressed: () => _grenze(context, ref), child: const Text('Ändern')),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('sync-jetzt'),
                onPressed: s.laeuft ? null : () => ref.read(syncProvider.notifier).abgleichen(),
                icon: const Icon(Icons.sync, size: 18),
                label: const Text('Jetzt abgleichen'),
              ),
              OutlinedButton(key: const Key('sync-geraet-hinzufuegen'), onPressed: () => kopplungZeigen(context), child: const Text('Gerät hinzufügen')),
              OutlinedButton(key: const Key('sync-geraete'), onPressed: () => geraeteZeigen(context), child: const Text('Geräte')),
              TextButton(key: const Key('sync-trennen'), onPressed: () => _trennen(context, ref), child: const Text('Trennen …')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _grenze(BuildContext context, WidgetRef ref) async {
    final e = ref.read(bestandProvider).einstellungen;
    final neu = await eingabeDialog<int>(
      context,
      start: ['${e.vaultMaxMiB}'],
      builder: (ctx, f) => AlertDialog(
        title: const Text('Größte Vault-Datei'),
        content: TextField(
          key: const Key('vault-grenze-feld'),
          controller: f[0],
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'MiB', helperText: 'Größere Dateien bleiben auf dem Gerät (Standard 100).'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
            key: const Key('vault-grenze-ok'),
            onPressed: () {
              final n = int.tryParse(f[0].text.trim());
              if (n != null && n > 0 && n <= 4096) Navigator.pop(ctx, n);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (neu != null) await ref.read(sitzungProvider.notifier).speichereEinstellungen(e.kopie(vaultMaxMiB: neu));
  }

  Future<void> _trennen(BuildContext context, WidgetRef ref) async {
    var loeschen = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Sync trennen?'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Alle Daten bleiben auf diesem Gerät. Es gleicht danach nicht mehr ab; '
                    'andere Geräte arbeiten weiter mit dem Server.'),
                const SizedBox(height: 8),
                CheckboxListTile(
                  key: const Key('sync-konto-loeschen'),
                  contentPadding: EdgeInsets.zero,
                  value: loeschen,
                  onChanged: (v) => setState(() => loeschen = v ?? false),
                  title: const Text('Auch das Konto und alle Daten auf dem Server löschen'),
                  subtitle: const Text('Andere Geräte werden dabei ebenfalls getrennt.'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
            FilledButton(
              key: const Key('sync-trennen-ok'),
              style: loeschen ? FilledButton.styleFrom(backgroundColor: ctx.farben.fehler) : null,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(loeschen ? 'Trennen und löschen' : 'Trennen'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(syncProvider.notifier).trennen(kontoLoeschen: loeschen);
      if (context.mounted) meldung(context, loeschen ? 'Getrennt, Konto auf dem Server gelöscht.' : 'Sync getrennt. Die Daten bleiben hier.');
    } on SyncFehler catch (e) {
      if (context.mounted) meldung(context, e.meldung, fehler: true);
    }
  }
}

// ---------------------------------------------------------------------------
// Verbinden / Koppeln

enum SyncWeg {
  /// Dieses Gerät hat Daten und meldet sich mit dem Recovery-Schlüssel an.
  verbinden,

  /// Dieses Gerät hat Daten und koppelt sich per Code an ein Konto.
  koppeln,

  /// Neue Installation per Kopplungscode.
  neuKoppeln,

  /// Neue Installation aus dem Server mit dem Recovery-Schlüssel.
  neuRecovery;

  bool get neu => this == neuKoppeln || this == neuRecovery;
  bool get mitCode => this == koppeln || this == neuKoppeln;
}

Future<void> syncAblaufOeffnen(BuildContext context, SyncWeg weg, {Future<void> Function()? vorherSichern}) =>
    Navigator.of(context).push(MaterialPageRoute(
      builder: (ctx) => Scaffold(
        backgroundColor: ctx.farben.flaeche,
        appBar: AppBar(backgroundColor: ctx.farben.flaeche, surfaceTintColor: Colors.transparent),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SyncAblauf(
                weg: weg,
                vorherSichern: vorherSichern,
                onAbbrechen: () => Navigator.pop(ctx),
                onFertig: (text) {
                  Navigator.pop(ctx);
                  meldung(context, text);
                },
              ),
            ),
          ),
        ),
      ),
    ));

class SyncAblauf extends ConsumerStatefulWidget {
  const SyncAblauf({super.key, required this.weg, required this.onAbbrechen, this.onFertig, this.vorherSichern});

  final SyncWeg weg;
  final VoidCallback onAbbrechen;
  final void Function(String meldung)? onFertig;
  final Future<void> Function()? vorherSichern;

  @override
  ConsumerState<SyncAblauf> createState() => _SyncAblaufState();
}

class _SyncAblaufState extends ConsumerState<SyncAblauf> {
  final _form = GlobalKey<FormState>();
  final _server = TextEditingController();
  final _geheim = TextEditingController();
  final _name = TextEditingController(text: standardGeraetName());
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  bool _arbeitet = false;
  String? _fehler;

  @override
  void dispose() {
    for (final c in [_server, _geheim, _name, _pw1, _pw2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _los() async {
    setState(() => _fehler = null);
    if (!_form.currentState!.validate()) return;
    final weg = widget.weg;
    final sync = ref.read(syncProvider.notifier);
    final code = weg.mitCode ? Kopplungscode.lesen(_geheim.text) : null;
    final recovery = weg.mitCode ? null : RecoverySchluessel.lesen(_geheim.text);
    setState(() => _arbeitet = true);
    try {
      final name = _name.text.trim().isEmpty ? standardGeraetName() : _name.text.trim();
      final bericht = await switch (weg) {
        SyncWeg.verbinden => sync.verbinden(server: _server.text, recovery: recovery!, geraetName: name),
        SyncWeg.koppeln => sync.koppeln(server: _server.text, code: code!, geraetName: name),
        SyncWeg.neuKoppeln => sync.neuKoppeln(server: _server.text, code: code!, passwort: _pw1.text, geraetName: name),
        SyncWeg.neuRecovery => sync.neuAusRecovery(server: _server.text, recovery: recovery!, passwort: _pw1.text, geraetName: name),
      };
      if (!mounted) return;
      final status = ref.read(syncProvider);
      widget.onFertig?.call(bericht != null
          ? 'Verbunden und abgeglichen.'
          : 'Verbunden. Der erste Abgleich ist noch nicht durch (${status.fehler ?? 'unbekannt'}) und wird automatisch fortgesetzt.');
    } on SyncFehler catch (e) {
      if (mounted) setState(() => _fehler = e.meldung);
    } catch (e) {
      if (mounted) setState(() => _fehler = 'Verbinden fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _arbeitet = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final weg = widget.weg;
    final f = context.farben;
    final s = ref.watch(sitzungProvider);
    final anzahl = s is Entsperrt ? s.bestand.anzahlDatensaetze : 0;
    final (oberzeile, titel, unterzeile) = switch (weg) {
      SyncWeg.verbinden => (
          'Sync einrichten',
          'Mit deinem Server verbinden.',
          'Mit dem Recovery-Schlüssel wird das Konto angelegt — oder, falls es auf dem Server schon eines dazu gibt, '
              'dieses Gerät dort angemeldet. Mit demselben Schlüssel kommst du später auch ohne altes Gerät wieder an die Daten.',
        ),
      SyncWeg.koppeln || SyncWeg.neuKoppeln => (
          'Gerät koppeln',
          'Mit einem anderen Gerät verbinden.',
          'Auf dem verbundenen Gerät unter „Speicher & Sicherheit“ bei „Synchronisieren“ auf „Gerät hinzufügen“ tippen und den Code hier '
              'eingeben. Er gilt 10 Minuten und nur einmal.',
        ),
      SyncWeg.neuRecovery => (
          'Wiederherstellen',
          'Vom Sync-Server holen.',
          'Wenn kein verbundenes Gerät mehr da ist: Serveradresse und Recovery-Schlüssel holen alle Daten zurück.',
        ),
    };
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Seitenkopf(oberzeile: oberzeile, titel: titel, unterzeile: unterzeile),
          const SizedBox(height: 22),
          TextFormField(
            key: const Key('sync-server'),
            controller: _server,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Serveradresse', hintText: 'https://sync.example.org'),
            validator: (v) {
              try {
                serverAdresse(v ?? '');
                return null;
              } on SyncFehler catch (e) {
                return e.meldung;
              }
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('sync-geheim'),
            controller: _geheim,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: weg.mitCode ? 'Kopplungscode' : 'Recovery-Schlüssel',
              hintText: weg.mitCode ? 'XXXX-XXXX-XXXX-XXXX-XXXX' : 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX',
            ),
            validator: (v) => weg.mitCode
                ? (Kopplungscode.lesen(v ?? '') == null ? 'Der Code hat 20 Zeichen (Buchstaben und Ziffern).' : null)
                : (RecoverySchluessel.lesen(v ?? '') == null ? 'Der Recovery-Schlüssel hat 32 Zeichen in acht Vierergruppen.' : null),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('sync-geraetname'),
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name dieses Geräts', helperText: 'Nur für deine Geräteliste; verschlüsselt gespeichert.'),
          ),
          if (weg.neu) ...[
            const SizedBox(height: 12),
            PasswortFeld(key: const Key('sync-pw1'), controller: _pw1, label: 'Neues App-Passwort für dieses Gerät', validator: passwortRegel),
            const SizedBox(height: 12),
            PasswortFeld(
              key: const Key('sync-pw2'),
              controller: _pw2,
              label: 'Passwort wiederholen',
              validator: (v) => v != _pw1.text ? 'Die Passwörter sind verschieden.' : null,
            ),
          ] else ...[
            const SizedBox(height: 18),
            Hinweis(
              fett: 'Vorschau',
              text: '$anzahl Datensätze auf diesem Gerät werden verschlüsselt hochgeladen und mit dem Konto zusammengeführt. '
                  'Der Server sieht keine Inhalte.'
                  '${weg == SyncWeg.koppeln ? ' Danach gilt hier der Recovery-Schlüssel des Kontos.' : ''}',
            ),
            if (widget.vorherSichern != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('sync-vorher-sichern'),
                  onPressed: _arbeitet ? null : widget.vorherSichern,
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('Vorher Sicherung erstellen (empfohlen)'),
                ),
              ),
            ],
          ],
          if (_fehler != null) Fehlertext(_fehler!),
          const SizedBox(height: 18),
          if (_arbeitet)
            Laedt(weg.neu ? 'Schlüssel wird abgeleitet, Daten werden geholt …' : 'Verbinde und gleiche ab …')
          else ...[
            FilledButton(
              key: const Key('sync-los'),
              onPressed: _los,
              child: Text(weg.neu ? 'Verbinden und Daten holen' : 'Verbinden'),
            ),
            TextButton(onPressed: widget.onAbbrechen, child: Text(weg.neu ? 'Zurück' : 'Abbrechen')),
          ],
          const SizedBox(height: 8),
          Text(
            'Unverschlüsseltes HTTP ist nur für localhost erlaubt. Eigener Server: siehe server/README.md im Projekt.',
            style: TextStyle(fontSize: 12, color: f.leise),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Gerät hinzufügen, Geräte verwalten

Future<void> kopplungZeigen(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _KopplungDialog());

class _KopplungDialog extends ConsumerStatefulWidget {
  const _KopplungDialog();

  @override
  ConsumerState<_KopplungDialog> createState() => _KopplungDialogState();
}

class _KopplungDialogState extends ConsumerState<_KopplungDialog> {
  ({Kopplungscode code, DateTime bis})? _kopplung;
  String? _fehler;

  @override
  void initState() {
    super.initState();
    ref.read(syncProvider.notifier).kopplungErstellen().then(
      (k) {
        if (mounted) setState(() => _kopplung = k);
      },
      onError: (Object e) {
        if (mounted) setState(() => _fehler = e is SyncFehler ? e.meldung : '$e');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = _kopplung;
    final server = ref.watch(syncProvider).server;
    return AlertDialog(
      title: const Text('Gerät hinzufügen'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_fehler != null)
              Fehlertext(_fehler!)
            else if (k == null)
              const Laedt('Code wird erzeugt …')
            else ...[
              const Text('Auf dem neuen Gerät „Mit einem anderen Gerät verbinden“ (beim ersten Start) oder unter '
                  '„Speicher & Sicherheit“ „Mit Kopplungscode …“ wählen und eingeben:'),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: context.farben.notizHg, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  children: [
                    Text('Server', style: TextStyle(fontSize: 12, color: context.farben.gedaempft)),
                    SelectableText(server ?? '', key: const Key('kopplung-server')),
                    const SizedBox(height: 10),
                    Text('Kopplungscode', style: TextStyle(fontSize: 12, color: context.farben.gedaempft)),
                    Semantics(
                      label: 'Kopplungscode ${k.code.anzeigen()}',
                      container: true,
                      child: ExcludeSemantics(
                        child: SelectableText(
                          k.code.anzeigen(),
                          key: const Key('kopplung-code'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontFamily: 'NotoSansMono', fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: 1.2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text('Gültig bis ${uhrzeit(k.bis)} Uhr, nur einmal. Wer den Code kennt, bekommt Zugriff auf alle Daten — '
                  'also nur selbst abtippen, nicht verschicken.'),
            ],
          ],
        ),
      ),
      actions: [
        if (k != null)
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: k.code.anzeigen()));
              meldung(context, 'Code kopiert.');
            },
            child: const Text('Kopieren'),
          ),
        FilledButton(key: const Key('kopplung-fertig'), onPressed: () => Navigator.pop(context), child: const Text('Fertig')),
      ],
    );
  }
}

Future<void> geraeteZeigen(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _GeraeteDialog());

class _GeraeteDialog extends ConsumerStatefulWidget {
  const _GeraeteDialog();

  @override
  ConsumerState<_GeraeteDialog> createState() => _GeraeteDialogState();
}

class _GeraeteDialogState extends ConsumerState<_GeraeteDialog> {
  List<SyncGeraet>? _liste;
  String? _fehler;

  @override
  void initState() {
    super.initState();
    _laden();
  }

  Future<void> _laden() async {
    try {
      final l = await ref.read(syncProvider.notifier).geraete();
      if (mounted) setState(() => _liste = l);
    } catch (e) {
      if (mounted) setState(() => _fehler = e is SyncFehler ? e.meldung : '$e');
    }
  }

  Future<void> _entfernen(SyncGeraet g) async {
    final ok = await bestaetigen(
      context,
      titel: '„${g.name}“ entfernen?',
      text: 'Das Gerät kann danach nicht mehr abgleichen. Was es schon hat, bleibt dort — '
          'bei Verlust des Geräts zusätzlich einen neuen Recovery-Schlüssel erzeugen.',
      ja: 'Entfernen',
    );
    if (!ok) return;
    try {
      await ref.read(syncProvider.notifier).geraetEntfernen(g.id);
      await _laden();
    } catch (e) {
      if (mounted) setState(() => _fehler = e is SyncFehler ? e.meldung : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _liste;
    final jetzt = DateTime.now();
    return AlertDialog(
      title: const Text('Geräte'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_fehler != null) Fehlertext(_fehler!),
            if (l == null && _fehler == null) const Laedt('Wird geladen …'),
            if (l != null)
              for (final g in l)
                ListTile(
                  key: Key('geraet-${g.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(g.dieses ? Icons.smartphone : (g.agent ? Icons.smart_toy_outlined : Icons.devices_other)),
                  title: Text(g.dieses ? '${g.name} (dieses Gerät)' : (g.agent ? '${g.name} (KI-Agent)' : g.name)),
                  subtitle: Text('seit ${datumKurz(g.erstellt.toLocal())} · zuletzt ${vorWieLanger(g.zuletzt.toLocal(), jetzt)}'),
                  trailing: g.dieses
                      ? null
                      : IconButton(
                          key: Key('geraet-entfernen-${g.id}'),
                          tooltip: 'Entfernen',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _entfernen(g),
                        ),
                ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Schließen'))],
    );
  }
}

// ---------------------------------------------------------------------------
// Recovery-Schlüssel erneuern

Future<void> recoveryErneuern(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _RecoveryDialog());

class _RecoveryDialog extends ConsumerStatefulWidget {
  const _RecoveryDialog();

  @override
  ConsumerState<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends ConsumerState<_RecoveryDialog> {
  final _neu = RecoverySchluessel.neu();
  final _kontrolle = TextEditingController();
  bool _arbeitet = false;
  String? _fehler;

  @override
  void dispose() {
    _kontrolle.dispose();
    super.dispose();
  }

  Future<void> _uebernehmen() async {
    if (_kontrolle.text.trim().toUpperCase() != _neu.anzeigen().split('-').last) {
      setState(() => _fehler = 'Die letzten vier Zeichen stimmen nicht — bitte vom Zettel abschreiben.');
      return;
    }
    setState(() {
      _arbeitet = true;
      _fehler = null;
    });
    try {
      await ref.read(syncProvider.notifier).recoveryErneuern(_neu);
      if (!mounted) return;
      Navigator.pop(context);
      meldung(context, 'Neuer Recovery-Schlüssel gilt. Bitte jetzt eine neue Sicherung erstellen.');
    } on SyncFehler catch (e) {
      if (mounted) setState(() => _fehler = 'Der Server ist nicht erreichbar, der alte Schlüssel gilt weiter. (${e.meldung})');
    } finally {
      if (mounted) setState(() => _arbeitet = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncProvider).verbunden;
    return AlertDialog(
      title: const Text('Neuer Recovery-Schlüssel'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Der alte Schlüssel gilt danach nicht mehr — weder zum Entsperren noch für neue Sicherungen'
                  '${sync ? ' noch für den Server; die anderen Geräte übernehmen den neuen beim nächsten Abgleich' : ''}. '
                  'Ältere Sicherungsdateien lassen sich weiterhin nur mit dem alten Schlüssel öffnen.'),
              const SizedBox(height: 14),
              RecoveryAnzeige(_neu),
              TextField(
                key: const Key('rk-neu-kontrolle'),
                controller: _kontrolle,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Kontrolle: letzte 4 Zeichen'),
              ),
              if (_fehler != null) Fehlertext(_fehler!),
              if (_arbeitet) const Laedt('Wird gespeichert …'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
        FilledButton(key: const Key('rk-neu-ok'), onPressed: _arbeitet ? null : _uebernehmen, child: const Text('Aufgeschrieben — übernehmen')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Konflikte

const _bereichName = {
  'termine': 'Termin',
  'aufgaben': 'Aufgabe',
  'notizen': 'Notiz',
  'konten': 'Konto',
  'buchungen': 'Buchung',
  'plaene': 'Geplanter Posten',
};

const _feldName = {
  'titel': 'Titel',
  'text': 'Text',
  'notiz': 'Notiz',
  'ort': 'Ort',
  'beginn': 'Beginn',
  'ende': 'Ende',
  'ganztags': 'Ganztägig',
  'faellig': 'Fällig',
  'prioritaet': 'Wichtigkeit',
  'erledigt': 'Erledigt',
  'name': 'Name',
  'art': 'Art',
  'archiviert': 'Archiviert',
  'empfaenger': 'Empfänger',
  'datum': 'Datum',
  'status': 'Status',
  'bemerkung': 'Bemerkung',
  'kontoId': 'Konto',
  'tag': 'Tag',
};

String _wert(String feld, Object? w, Map<String, String> konten) {
  if (w == null) return '—';
  if (feld.endsWith('Cent') && w is int) return euro(w);
  if (feld == 'kontoId') return konten['$w'] ?? '$w';
  if (w is bool) return w ? 'ja' : 'nein';
  final t = w is String ? w : '$w';
  return t.length > 120 ? '${t.substring(0, 120)} …' : t;
}

Future<void> konflikteZeigen(BuildContext context) => Navigator.of(context).push(MaterialPageRoute(
      builder: (ctx) => Scaffold(
        backgroundColor: ctx.farben.flaeche,
        appBar: AppBar(backgroundColor: ctx.farben.flaeche, surfaceTintColor: Colors.transparent),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
          child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: const KonflikteSeite())),
        ),
      ),
    ));

class KonflikteSeite extends ConsumerWidget {
  const KonflikteSeite({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(bestandProvider);
    final roh = <String, Map<String, Map<String, dynamic>>>{
      'termine': {for (final x in b.termine.values) x.id: x.toJson()},
      'aufgaben': {for (final x in b.aufgaben.values) x.id: x.toJson()},
      'notizen': {for (final x in b.notizen.values) x.id: x.toJson()},
      'konten': {for (final x in b.konten.values) x.id: x.toJson()},
      'buchungen': {for (final x in b.buchungen.values) x.id: x.toJson()},
      'plaene': {for (final x in b.plaene.values) x.id: x.toJson()},
    };
    final konten = {for (final k in b.konten.values) k.id: k.name};
    final liste = b.konflikte.values.toList()..sort((x, y) => y.entstanden.compareTo(x.entstanden));
    final f = context.farben;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Seitenkopf(
          oberzeile: '${liste.length} offen',
          titel: 'Sync-Konflikte.',
          unterzeile: 'Diese Einträge wurden auf zwei Geräten gleichzeitig geändert. Die zuerst angekommene Fassung gilt; '
              'die andere ist hier aufgehoben und zählt nirgends mit, bis du entscheidest.',
        ),
        const SizedBox(height: 22),
        if (liste.isEmpty) const Karte(child: Leer('Keine Konflikte — alles abgeglichen.')),
        for (final k in liste)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Builder(builder: (context) {
              final aktuell = roh[k.bereich]?[k.originalId];
              final felder = {...k.daten.keys, ...?aktuell?.keys}
                  .where((x) => !const {'id', 'geaendert', 'erstellt', 'verlauf', 'serienStart', 'umbuchungId', 'planId'}.contains(x))
                  .where((x) => aktuell == null || '${aktuell[x]}' != '${k.daten[x]}')
                  .toList();
              final name = '${k.daten['titel'] ?? k.daten['name'] ?? k.daten['empfaenger'] ?? ''}';
              return Karte(
                key: Key('konflikt-${k.id}'),
                titel: '${_bereichName[k.bereich] ?? k.bereich} · $name',
                marke: datumKurz(k.entstanden.toLocal()),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (aktuell == null)
                      Text('Der aktuelle Eintrag wurde inzwischen gelöscht.', style: TextStyle(color: f.warnText))
                    else if (felder.isEmpty)
                      Text('Inhaltlich gleich.', style: TextStyle(color: f.gedaempft)),
                    for (final feld in felder)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_feldName[feld] ?? feld, style: TextStyle(fontSize: 12, color: f.gedaempft)),
                            if (aktuell != null) Text('Aktuell: ${_wert(feld, aktuell[feld], konten)}'),
                            Text('Andere Fassung: ${_wert(feld, k.daten[feld], konten)}', style: TextStyle(color: f.warnText)),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          key: Key('konflikt-verwerfen-${k.id}'),
                          onPressed: () => ref.read(sitzungProvider.notifier).konfliktVerwerfen(k.id),
                          child: const Text('Aktuelle behalten'),
                        ),
                        FilledButton(
                          key: Key('konflikt-uebernehmen-${k.id}'),
                          onPressed: () async {
                            try {
                              await ref.read(sitzungProvider.notifier).konfliktUebernehmen(k.id);
                            } catch (e) {
                              if (context.mounted) meldung(context, 'Geht nicht: $e', fehler: true);
                            }
                          },
                          child: Text(aktuell == null ? 'Wiederherstellen' : 'Andere Fassung übernehmen'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ),
      ],
    );
  }
}

/// Bei Bedarf in der Übersicht: Hinweis auf offene Konflikte.
class KonfliktHinweis extends ConsumerWidget {
  const KonfliktHinweis({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(bestandProvider).konflikte.length;
    if (n == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Hinweis(
        key: const Key('hinweis-konflikte'),
        warnung: true,
        fett: n == 1 ? '1 Sync-Konflikt' : '$n Sync-Konflikte',
        text: 'Auf zwei Geräten gleichzeitig geändert — beide Fassungen sind erhalten.',
        aktion: TextButton(key: const Key('konflikte-ansehen'), onPressed: () => konflikteZeigen(context), child: const Text('Ansehen')),
      ),
    );
  }
}

/// Aktualisiert die relative Zeitangabe („vor 2 Min.“) regelmäßig.
class SyncStatusText extends ConsumerStatefulWidget {
  const SyncStatusText({super.key, required this.style});
  final TextStyle style;

  @override
  ConsumerState<SyncStatusText> createState() => _SyncStatusTextState();
}

class _SyncStatusTextState extends ConsumerState<SyncStatusText> {
  Timer? _takt;

  @override
  void dispose() {
    _takt?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(syncProvider);
    if (!s.verbunden) {
      _takt?.cancel();
      _takt = null;
      return Text('Lokal & verschlüsselt\nKein Konto, kein Server', style: widget.style);
    }
    _takt ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    return Text(
      'Verschlüsselt synchronisiert\n${syncKurztext(s, DateTime.now())}',
      key: const Key('seitenleiste-sync'),
      style: s.fehler == null ? widget.style : widget.style.copyWith(color: context.farben.warnText),
    );
  }
}
