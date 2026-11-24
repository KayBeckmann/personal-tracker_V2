import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/sitzung.dart';
import '../../core/sync/sync_dienst.dart';
import '../../core/vault/secrets.dart';
import '../../core/vault/vault_datei.dart';
import '../../core/vault/vault_dienst.dart';
import '../bausteine.dart';
import '../dateien.dart';
import '../format.dart';
import '../thema.dart';

String groesseText(int b) => b < 1024
    ? '$b B'
    : b < 1024 * 1024
        ? '${(b / 1024).toStringAsFixed(b < 10 * 1024 ? 1 : 0).replaceAll('.', ',')} KB'
        : '${(b / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';

IconData _icon(VaultDatei d) => d.istMarkdown
    ? Icons.description_outlined
    : d.istBild
        ? Icons.image_outlined
        : d.endung == 'pdf'
            ? Icons.picture_as_pdf_outlined
            : Icons.insert_drive_file_outlined;

/// Dateien des Obsidian-Vaults (aus dem Sync). Ordner lassen sich
/// durchgehen, Markdown bearbeiten; andere Dateien ansehen oder speichern.
class VaultSeite extends ConsumerStatefulWidget {
  const VaultSeite({super.key});

  @override
  ConsumerState<VaultSeite> createState() => _VaultSeiteState();
}

class _VaultSeiteState extends ConsumerState<VaultSeite> {
  final _suche = TextEditingController();
  String _ordner = '';
  bool _versteckte = false;
  bool _exportiert = false;

  @override
  void dispose() {
    _suche.dispose();
    super.dispose();
  }

  bool _sichtbar(String pfad) => _versteckte || !pfad.split('/').any((t) => t.startsWith('.'));

  Future<void> _neu() async {
    final pfad = await eingabeDialog<String>(
      context,
      start: [_ordner.isEmpty ? 'Neue Notiz.md' : '$_ordner/Neue Notiz.md'],
      builder: (ctx, f) => AlertDialog(
        title: const Text('Neue Markdown-Datei'),
        content: TextField(
          key: const Key('vault-neu-pfad'),
          controller: f[0],
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Pfad im Vault', helperText: 'Ordner mit „/“ trennen'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(key: const Key('vault-neu-ok'), onPressed: () => Navigator.pop(ctx, f[0].text), child: const Text('Anlegen')),
        ],
      ),
    );
    if (pfad == null || !mounted) return;
    final p = pfad.trim().toLowerCase().endsWith('.md') ? pfad.trim() : '${pfad.trim()}.md';
    try {
      final d = await ref.read(vaultProvider.notifier).speichern(pfad: p, inhalt: Uint8List(0));
      if (mounted) await vaultDateiOeffnen(context, d);
    } on VaultFehler catch (e) {
      if (mounted) meldung(context, e.meldung, fehler: true);
    }
  }

  Future<void> _exportieren() async {
    setState(() => _exportiert = true);
    try {
      final bytes = await ref.read(vaultProvider.notifier).exportieren();
      final jetzt = DateTime.now();
      final name = 'vault-${jetzt.year}-${jetzt.month.toString().padLeft(2, '0')}-${jetzt.day.toString().padLeft(2, '0')}.zip';
      if (await ref.read(dateienProvider).speichern(name, bytes) && mounted) {
        meldung(context, 'Vault als ZIP gespeichert (unverschlüsselt). Bitte sicher aufbewahren.');
      }
    } catch (e) {
      if (mounted) meldung(context, 'Export fehlgeschlagen: $e', fehler: true);
    } finally {
      if (mounted) setState(() => _exportiert = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(vaultProvider);
    final sync = ref.watch(syncProvider);
    final f = context.farben;
    final suche = _suche.text.trim().toLowerCase();
    final alle = v.dateien.where((d) => _sichtbar(d.pfad)).toList();

    final List<Widget> zeilen;
    if (suche.isNotEmpty) {
      final treffer = alle.where((d) =>
          d.pfad.toLowerCase().contains(suche) ||
          (d.istMarkdown && d.inhalt != null && utf8.decode(d.inhalt!, allowMalformed: true).toLowerCase().contains(suche)));
      zeilen = [for (final d in treffer) _DateiZeile(datei: d, mitOrdner: true)];
    } else {
      final praefix = _ordner.isEmpty ? '' : '$_ordner/';
      final ordner = <String>{};
      final dateien = <VaultDatei>[];
      for (final d in alle) {
        if (!d.pfad.startsWith(praefix)) continue;
        final rest = d.pfad.substring(praefix.length);
        if (rest.contains('/')) {
          ordner.add(rest.substring(0, rest.indexOf('/')));
        } else {
          dateien.add(d);
        }
      }
      zeilen = [
        if (_ordner.isNotEmpty)
          Zeile(
            key: const Key('vault-hoch'),
            vorne: Icon(Icons.arrow_upward, size: 20, color: f.gedaempft),
            titel: 'Zurück',
            unter: _ordner,
            onTap: () => setState(() => _ordner = _ordner.contains('/') ? _ordner.substring(0, _ordner.lastIndexOf('/')) : ''),
          ),
        for (final o in (ordner.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))))
          Zeile(
            key: Key('vault-ordner-$o'),
            vorne: Icon(Icons.folder_outlined, size: 20, color: f.gedaempft),
            titel: o,
            onTap: () => setState(() => _ordner = '$praefix$o'),
          ),
        for (final d in dateien) _DateiZeile(datei: d),
      ];
    }

    final gesperrt = v.dateien.where((d) => sync.vaultGesperrt.contains(d.id)).toList();
    final zuGross = v.dateien.where((d) => sync.vaultZuGross.contains(d.id)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Seitenkopf(
          oberzeile: '${v.dateien.length} ${v.dateien.length == 1 ? 'Datei' : 'Dateien'} · Ende-zu-Ende-verschlüsselt',
          titel: 'Vault.',
          unterzeile: 'Dein Obsidian-Vault über den Sync. Markdown lässt sich hier bearbeiten, Obsidian ist dafür nicht nötig.',
          aktionen: [
            if (sync.verbunden)
              FilledButton.icon(key: const Key('vault-neu'), onPressed: _neu, icon: const Icon(Icons.add, size: 18), label: const Text('Markdown')),
            if (v.dateien.isNotEmpty)
              OutlinedButton(
                key: const Key('vault-export'),
                onPressed: _exportiert ? null : _exportieren,
                child: Text(_exportiert ? 'Exportiert …' : 'Als ZIP'),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (!sync.verbunden)
          const Hinweis(
            icon: Icons.cloud_off_outlined,
            text: 'Der Vault kommt über den Sync. Verbinde die App unter „Speicher & Sicherheit“ und richte in Obsidian das Plugin „Personal Tracker Sync“ ein.',
          ),
        for (final d in gesperrt)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Hinweis(
              warnung: true,
              icon: Icons.key_outlined,
              fett: d.pfad,
              text: 'Möglicherweise steht ein Secret darin. Die Datei bleibt auf diesem Gerät, bis du sie prüfst und freigibst.',
              aktion: TextButton(key: Key('vault-pruefen-${d.pfad}'), onPressed: () => vaultDateiOeffnen(context, d), child: const Text('Prüfen')),
            ),
          ),
        if (zuGross.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Hinweis(
              warnung: true,
              text: '${zuGross.map((d) => d.pfad).join(', ')}: größer als die Grenze (${ref.watch(bestandProvider).einstellungen.vaultMaxMiB} MiB), bleibt auf diesem Gerät.',
            ),
          ),
        TextField(
          key: const Key('vault-suche'),
          controller: _suche,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: 'Dateinamen und Markdown durchsuchen',
            suffixIcon: _suche.text.isEmpty ? null : IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(_suche.clear)),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                suche.isNotEmpty ? 'Suchergebnisse' : (_ordner.isEmpty ? 'Vault' : _ordner),
                style: TextStyle(color: f.gedaempft, fontSize: 13),
              ),
            ),
            Text('Versteckte Ordner', style: TextStyle(color: f.gedaempft, fontSize: 13)),
            Switch(key: const Key('vault-versteckte'), value: _versteckte, onChanged: (x) => setState(() => _versteckte = x)),
          ],
        ),
        Karte(
          child: zeilen.isEmpty
              ? Leer(v.geladen ? (suche.isEmpty ? 'Noch keine Dateien.' : 'Nichts gefunden.') : 'Lädt …')
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: zeilen),
        ),
      ],
    );
  }
}

class _DateiZeile extends ConsumerWidget {
  const _DateiZeile({required this.datei, this.mitOrdner = false});
  final VaultDatei datei;
  final bool mitOrdner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = context.farben;
    final wartet = ref.watch(vaultProvider.select((v) => v.ausstehend.contains(datei.id)));
    final gesperrt = ref.watch(syncProvider.select((s) => s.vaultGesperrt.contains(datei.id)));
    final g = datei.geaendert.toLocal();
    return Zeile(
      key: Key('vault-datei-${datei.pfad}'),
      vorne: Icon(_icon(datei), size: 20, color: f.gedaempft),
      titel: datei.name,
      unter: [
        if (mitOrdner && datei.ordner.isNotEmpty) datei.ordner,
        groesseText(datei.groesse),
        '${datumKurz(g)} ${uhrzeit(g)}',
        if (gesperrt) 'gesperrt (Secret?)' else if (wartet) 'wartet auf Abgleich',
      ].join(' · '),
      onTap: () => vaultDateiOeffnen(context, datei),
    );
  }
}

Future<void> vaultDateiOeffnen(BuildContext context, VaultDatei d) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => VaultDateiSeite(datei: d)));

/// Eine Datei: Markdown bearbeiten (Quelltext bleibt unverändert, auch
/// YAML und [[Wikilinks]]), Bilder ansehen, sonst Infos und Speichern.
class VaultDateiSeite extends ConsumerStatefulWidget {
  const VaultDateiSeite({super.key, required this.datei});
  final VaultDatei datei;

  @override
  ConsumerState<VaultDateiSeite> createState() => _VaultDateiSeiteState();
}

class _VaultDateiSeiteState extends ConsumerState<VaultDateiSeite> {
  late VaultDatei _d = widget.datei;
  final _text = TextEditingController();
  Uint8List? _inhalt;
  String? _fehler;
  String _geladen = '';
  bool _vorschau = true;
  List<SecretTreffer>? _treffer;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    _laden();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _laden() async {
    try {
      final v = ref.read(vaultProvider.notifier);
      final b = await v.inhalt(_d);
      final gesperrt = ref.read(syncProvider).vaultGesperrt.contains(_d.id);
      final treffer = gesperrt ? SecretPruefung.standard().pruefen(b) : null;
      if (!mounted) return;
      setState(() {
        _inhalt = b;
        _treffer = treffer;
        if (_d.istMarkdown) {
          _geladen = utf8.decode(b, allowMalformed: true);
          _text.text = _geladen;
          _vorschau = _geladen.trim().isNotEmpty;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _fehler = e is VaultFehler ? e.meldung : 'Laden fehlgeschlagen: $e');
    }
  }

  bool get _geaendert => _d.istMarkdown && _inhalt != null && _text.text != _geladen;

  Future<void> _speichern() async {
    try {
      final neu = await ref.read(vaultProvider.notifier).speichern(alt: _d, pfad: _d.pfad, inhalt: Uint8List.fromList(utf8.encode(_text.text)));
      setState(() {
        _d = neu;
        _geladen = _text.text;
      });
    } on VaultFehler catch (e) {
      if (mounted) meldung(context, e.meldung, fehler: true);
    }
  }

  Future<void> _umbenennen() async {
    final pfad = await eingabeDialog<String>(
      context,
      start: [_d.pfad],
      builder: (ctx, f) => AlertDialog(
        title: const Text('Umbenennen oder verschieben'),
        content: TextField(key: const Key('vault-pfad'), controller: f[0], autofocus: true, decoration: const InputDecoration(labelText: 'Pfad im Vault')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(key: const Key('vault-pfad-ok'), onPressed: () => Navigator.pop(ctx, f[0].text), child: const Text('Übernehmen')),
        ],
      ),
    );
    if (pfad == null || pfad.trim() == _d.pfad || !mounted) return;
    try {
      final neu = await ref.read(vaultProvider.notifier).umbenennen(_d, pfad);
      setState(() => _d = neu);
      if (mounted) meldung(context, 'Verschoben. Links in anderen Dateien bleiben unverändert.');
    } on VaultFehler catch (e) {
      if (mounted) meldung(context, e.meldung, fehler: true);
    }
  }

  Future<void> _loeschen() async {
    if (!await bestaetigen(context, titel: 'Datei löschen?', text: '„${_d.pfad}“ wird auf allen verbundenen Geräten gelöscht (in Obsidian landet sie im Papierkorb).')) return;
    await ref.read(vaultProvider.notifier).loeschen(_d);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _freigeben() async {
    if (!await bestaetigen(
      context,
      titel: 'Diese Fassung hochladen?',
      text: 'Die Datei wird verschlüsselt übertragen und erscheint auf allen verbundenen Geräten. Die Freigabe gilt nur für den jetzigen Inhalt.',
      ja: 'Freigeben',
    )) {
      return;
    }
    await ref.read(vaultProvider.notifier).freigeben(_d);
    if (mounted) setState(() => _treffer = null);
  }

  Future<void> _herunterladen() async {
    final b = _inhalt;
    if (b == null) return;
    await ref.read(dateienProvider).speichern(_d.name, b);
  }

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    final dunkel = Theme.of(context).brightness == Brightness.dark;
    final breit = MediaQuery.sizeOf(context).width >= 980;
    final b = _inhalt;
    final g = _d.geaendert.toLocal();

    Widget inhalt;
    if (_fehler != null) {
      inhalt = Hinweis(warnung: true, text: _fehler!);
    } else if (b == null) {
      inhalt = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    } else if (_d.istMarkdown) {
      final editor = TextField(
        key: const Key('vault-text'),
        controller: _text,
        maxLines: null,
        minLines: 16,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(fontFamily: 'NotoSansMono', fontSize: 14, height: 1.5),
      );
      final vorschau = Container(
        key: const Key('vault-vorschau'),
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: f.karte, borderRadius: BorderRadius.circular(12), border: Border.all(color: f.karteRand)),
        child: _text.text.trim().isEmpty
            ? const Leer('Noch kein Text.')
            : MarkdownBlock(data: _text.text, config: dunkel ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig),
      );
      inhalt = breit
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: editor), const SizedBox(width: 18), Expanded(child: vorschau)])
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<bool>(
                  key: const Key('vault-modus'),
                  showSelectedIcon: false,
                  segments: const [ButtonSegment(value: false, label: Text('Bearbeiten')), ButtonSegment(value: true, label: Text('Vorschau'))],
                  selected: {_vorschau},
                  onSelectionChanged: (s) => setState(() => _vorschau = s.first),
                ),
                const SizedBox(height: 12),
                _vorschau ? vorschau : editor,
              ],
            );
    } else if (_d.istBild) {
      inhalt = ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(b, key: const Key('vault-bild'), fit: BoxFit.contain));
    } else {
      inhalt = Karte(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Diese Datei lässt sich hier nicht anzeigen.', style: TextStyle(color: f.gedaempft)),
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: _herunterladen, icon: const Icon(Icons.download_outlined, size: 18), label: const Text('Speichern unter …')),
          ],
        ),
      );
    }

    return PopScope(
      canPop: !_geaendert,
      onPopInvokedWithResult: (bereits, _) async {
        if (bereits) return;
        if (await bestaetigen(context, titel: 'Änderungen verwerfen?', text: 'Die Datei hat ungespeicherte Änderungen.', ja: 'Verwerfen') && context.mounted) {
          _text.text = _geladen;
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: f.flaeche,
        appBar: AppBar(
          backgroundColor: f.flaeche,
          surfaceTintColor: Colors.transparent,
          title: Text(_d.name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(key: const Key('vault-umbenennen'), tooltip: 'Umbenennen oder verschieben', onPressed: _umbenennen, icon: const Icon(Icons.drive_file_move_outline)),
            if (b != null && !_d.istMarkdown)
              IconButton(tooltip: 'Speichern unter', onPressed: _herunterladen, icon: const Icon(Icons.download_outlined)),
            IconButton(key: const Key('vault-loeschen'), tooltip: 'Löschen', onPressed: _loeschen, icon: const Icon(Icons.delete_outline)),
            if (_d.istMarkdown)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton(key: const Key('vault-speichern'), onPressed: _geaendert ? _speichern : null, child: const Text('Speichern')),
              ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: breit ? 1180 : 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${_d.pfad} · ${groesseText(_d.groesse)} · ${datumKurz(g)} ${uhrzeit(g)}',
                      key: const Key('vault-info'),
                      style: TextStyle(fontSize: 12, color: f.leise),
                    ),
                    const SizedBox(height: 12),
                    if (_treffer != null && _treffer!.isNotEmpty) ...[
                      Hinweis(
                        warnung: true,
                        icon: Icons.key_outlined,
                        fett: 'Möglicherweise ein Secret',
                        text: '${_treffer!.map((t) => '${t.regel} in Zeile ${t.zeile}').join(', ')}. '
                            'Am besten das Secret entfernen (z. B. in einen Passwortmanager). Sonst bleibt die Datei auf diesem Gerät, bis du genau diese Fassung freigibst.',
                        aktion: TextButton(key: const Key('vault-freigeben'), onPressed: _freigeben, child: const Text('Freigeben')),
                      ),
                      const SizedBox(height: 12),
                    ],
                    inhalt,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
