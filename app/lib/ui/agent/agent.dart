import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_dienst.dart';
import '../../core/modell/agent.dart';
import '../../core/sitzung.dart';
import '../../core/sync/sync_api.dart';
import '../../core/sync/sync_dienst.dart';
import '../../core/sync/sync_krypto.dart';
import '../bausteine.dart';
import '../format.dart';
import '../thema.dart';
import '../zugang/rahmen.dart';

String _fehlertext(Object e) => e is AgentFehler ? e.meldung : (e is SyncFehler ? e.meldung : '$e');

String _laufzeit(AgentZugang a) {
  final b = a.ablauf;
  return b == null ? 'bis zum Widerruf' : 'bis ${datumKurz(b.toLocal())}';
}

String _rechteText(Map<String, String> r) =>
    [for (final e in r.entries) '${agentModule[e.key] ?? e.key}: ${e.value == 'schreiben' ? 'schreiben' : 'lesen'}'].join(' · ');

// ---------------------------------------------------------------------------
// Karte in den Einstellungen

/// KI-Agenten verwalten (nur mit Sync, denn der Agent liest über den Server).
class AgentKarte extends ConsumerWidget {
  const AgentKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(syncProvider).verbunden) return const SizedBox.shrink();
    final b = ref.watch(bestandProvider);
    final f = context.farben;
    final klein = TextStyle(fontSize: 13, color: f.gedaempft);
    final agenten = b.agenten.values.toList()..sort((a, c) => a.erstellt.compareTo(c.erstellt));
    final jetzt = DateTime.now();
    return Karte(
      key: const Key('karte-agenten'),
      titel: 'KI-Agenten',
      marke: agenten.isEmpty ? 'keine' : '${agenten.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Ein KI-Agent (z. B. Claude über MCP) greift über die Brücke „pt-agent“ auf deinem Rechner zu — '
            'nur auf die Module, die du freigibst. Löschen und Veröffentlichen schlägt er nur vor.',
            style: klein,
          ),
          for (final a in agenten)
            ListTile(
              key: Key('agent-${a.id}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(a.name),
              subtitle: Text(
                '${_rechteText(a.rechte)}\n${_laufzeit(a)}'
                '${a.ablauf != null && a.ablauf!.isBefore(jetzt) ? ' (abgelaufen)' : ''}',
              ),
              isThreeLine: true,
              trailing: Wrap(
                children: [
                  IconButton(
                    key: Key('agent-protokoll-${a.id}'),
                    tooltip: 'Protokoll',
                    icon: const Icon(Icons.receipt_long_outlined),
                    onPressed: () => showDialog<void>(context: context, builder: (_) => _ProtokollDialog(a)),
                  ),
                  IconButton(
                    key: Key('agent-widerrufen-${a.id}'),
                    tooltip: 'Widerrufen',
                    icon: const Icon(Icons.block),
                    onPressed: () => _widerrufen(context, ref, a),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('agent-verbinden'),
                onPressed: () => showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const _EinrichtenDialog()),
                icon: const Icon(Icons.smart_toy_outlined, size: 18),
                label: const Text('KI-Agent verbinden …'),
              ),
              if (b.agentVorschlaege.values.any((v) => v.offen))
                TextButton(key: const Key('agent-vorschlaege'), onPressed: () => vorschlaegeZeigen(context), child: const Text('Vorschläge')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _widerrufen(BuildContext context, WidgetRef ref, AgentZugang a) async {
    final ok = await bestaetigen(
      context,
      titel: '„${a.name}“ widerrufen?',
      text: 'Der Agent wird beim Server abgemeldet und kann danach nichts mehr lesen oder ändern. '
          'Was er schon gelesen hat, lässt sich nicht zurückholen.',
      ja: 'Widerrufen',
    );
    if (!ok || !context.mounted) return;
    try {
      await ref.read(agentProvider).widerrufen(a);
      if (context.mounted) meldung(context, 'Agent widerrufen.');
    } catch (e) {
      if (context.mounted) meldung(context, _fehlertext(e), fehler: true);
    }
  }
}

// ---------------------------------------------------------------------------
// Einrichten

class _EinrichtenDialog extends ConsumerStatefulWidget {
  const _EinrichtenDialog();

  @override
  ConsumerState<_EinrichtenDialog> createState() => _EinrichtenDialogState();
}

class _EinrichtenDialogState extends ConsumerState<_EinrichtenDialog> {
  final _name = TextEditingController(text: 'Claude');
  final _rechte = <String, String>{for (final m in agentModule.keys) m: 'aus'};
  int? _tage;
  bool _arbeitet = false;
  String? _fehler;
  ({Kopplungscode code, AgentZugang agent})? _ergebnis;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _erzeugen() async {
    setState(() {
      _arbeitet = true;
      _fehler = null;
    });
    try {
      final e = await ref.read(agentProvider).einrichten(name: _name.text, rechte: _rechte, ablaufTage: _tage);
      if (mounted) setState(() => _ergebnis = e);
    } catch (e) {
      if (mounted) setState(() => _fehler = _fehlertext(e));
    } finally {
      if (mounted) setState(() => _arbeitet = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = _ergebnis;
    return AlertDialog(
      title: const Text('KI-Agent verbinden'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(child: e == null ? _formular() : _code(e)),
      ),
      actions: e == null
          ? [
              TextButton(onPressed: _arbeitet ? null : () => Navigator.pop(context), child: const Text('Abbrechen')),
              FilledButton(key: const Key('agent-code-erzeugen'), onPressed: _arbeitet ? null : _erzeugen, child: const Text('Code erzeugen')),
            ]
          : [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: e.code.anzeigen()));
                  meldung(context, 'Code kopiert.');
                },
                child: const Text('Kopieren'),
              ),
              FilledButton(key: const Key('agent-fertig'), onPressed: () => Navigator.pop(context), child: const Text('Fertig')),
            ],
    );
  }

  Widget _formular() {
    final f = context.farben;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(key: const Key('agent-name'), controller: _name, decoration: const InputDecoration(labelText: 'Name des Agenten')),
        const SizedBox(height: 14),
        Text('Rechte je Modul', style: TextStyle(fontWeight: FontWeight.w600, color: f.text)),
        for (final m in agentModule.entries)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Expanded(child: Text(m.value)),
                SegmentedButton<String>(
                  key: Key('agent-recht-${m.key}'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'aus', label: Text('aus')),
                    ButtonSegment(value: 'lesen', label: Text('lesen')),
                    ButtonSegment(value: 'schreiben', label: Text('schreiben')),
                  ],
                  selected: {_rechte[m.key]!},
                  onSelectionChanged: (s) => setState(() => _rechte[m.key] = s.first),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        DropdownButtonFormField<int?>(
          key: const Key('agent-laufzeit'),
          initialValue: _tage,
          decoration: const InputDecoration(labelText: 'Gültig'),
          items: const [
            DropdownMenuItem(value: null, child: Text('bis zum Widerruf')),
            DropdownMenuItem(value: 7, child: Text('7 Tage')),
            DropdownMenuItem(value: 30, child: Text('30 Tage')),
            DropdownMenuItem(value: 90, child: Text('90 Tage')),
          ],
          onChanged: (v) => setState(() => _tage = v),
        ),
        const SizedBox(height: 10),
        Text(
          '„schreiben“ heißt anlegen und ändern. Löschen und Veröffentlichen führt der Agent nie selbst aus, '
          'sondern legt einen Vorschlag an, den du bestätigst. Jeder Zugriff wird protokolliert (ohne Inhalte).',
          style: TextStyle(fontSize: 13, color: f.gedaempft),
        ),
        if (_fehler != null) Padding(padding: const EdgeInsets.only(top: 10), child: Fehlertext(_fehler!)),
      ],
    );
  }

  Widget _code(({Kopplungscode code, AgentZugang agent}) e) {
    final f = context.farben;
    final server = ref.watch(syncProvider).server ?? '';
    final befehl = 'pt-agent koppeln --server $server --code ${e.code.anzeigen()}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Auf dem Rechner, auf dem der Agent läuft, einmal ausführen:', style: TextStyle(color: f.text)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: f.notizHg, borderRadius: BorderRadius.circular(12)),
          child: Semantics(
            label: 'Befehl $befehl',
            container: true,
            child: ExcludeSemantics(
              child: SelectableText(befehl, key: const Key('agent-befehl'), style: const TextStyle(fontFamily: 'NotoSansMono', fontSize: 14)),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Danach „pt-agent mcp“ als MCP-Server im KI-Programm eintragen. Der Code gilt ${AgentDienst.kopplungGueltig.inMinutes} Minuten '
          'und nur einmal. ${_rechteText(e.agent.rechte)}, ${_laufzeit(e.agent)}.',
          style: TextStyle(fontSize: 13, color: f.gedaempft),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Protokoll

class _ProtokollDialog extends ConsumerWidget {
  const _ProtokollDialog(this.agent);
  final AgentZugang agent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(bestandProvider).agentProtokoll.values.where((x) => x.agent == agent.id).toList()
      ..sort((a, c) => c.zeit.compareTo(a.zeit));
    return AlertDialog(
      title: Text('Protokoll: ${agent.name}'),
      content: SizedBox(
        width: 480,
        child: p.isEmpty
            ? const Leer('Noch keine Zugriffe.')
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final x in p.take(200))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(switch (x.art) {
                        'schreiben' => Icons.edit_outlined,
                        'vorschlag' => Icons.help_outline,
                        _ => Icons.visibility_outlined,
                      }),
                      title: Text('${x.werkzeug} · ${agentModule[x.modul] ?? x.modul}'),
                      subtitle: Text('${datumKurz(x.zeit.toLocal())} ${uhrzeit(x.zeit.toLocal())} · ${x.anzahl} Einträge'),
                    ),
                ],
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Schließen'))],
    );
  }
}

// ---------------------------------------------------------------------------
// Vorschläge

Future<void> vorschlaegeZeigen(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _VorschlaegeDialog());

class _VorschlaegeDialog extends ConsumerWidget {
  const _VorschlaegeDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offen = ref.watch(bestandProvider).agentVorschlaege.values.where((v) => v.offen).toList()
      ..sort((a, c) => a.zeit.compareTo(c.zeit));
    return AlertDialog(
      title: const Text('Vorschläge von KI-Agenten'),
      content: SizedBox(
        width: 480,
        child: offen.isEmpty
            ? const Leer('Keine offenen Vorschläge.')
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final v in offen)
                    Padding(
                      key: Key('vorschlag-${v.id}'),
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('${v.agentName} schlägt vor: ${v.art == 'loeschen' ? 'Löschen' : 'Veröffentlichen'}',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(v.beschreibung),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                key: Key('vorschlag-ablehnen-${v.id}'),
                                onPressed: () => _entscheiden(context, ref, v, false),
                                child: const Text('Ablehnen'),
                              ),
                              FilledButton(
                                key: Key('vorschlag-annehmen-${v.id}'),
                                onPressed: () => _entscheiden(context, ref, v, true),
                                child: Text(v.art == 'loeschen' ? 'Löschen' : 'Veröffentlichen'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Schließen'))],
    );
  }

  Future<void> _entscheiden(BuildContext context, WidgetRef ref, AgentVorschlag v, bool annehmen) async {
    try {
      await ref.read(agentProvider).entscheiden(v, annehmen: annehmen);
    } catch (e) {
      if (context.mounted) meldung(context, _fehlertext(e), fehler: true);
    }
  }
}

/// Bei Bedarf in der Übersicht: Hinweis auf offene Agenten-Vorschläge.
class VorschlagHinweis extends ConsumerWidget {
  const VorschlagHinweis({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(bestandProvider).agentVorschlaege.values.where((v) => v.offen).length;
    if (n == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Hinweis(
        key: const Key('hinweis-vorschlaege'),
        fett: n == 1 ? '1 Vorschlag eines KI-Agenten' : '$n Vorschläge von KI-Agenten',
        text: 'Löschen oder Veröffentlichen wartet auf deine Bestätigung.',
        aktion: TextButton(key: const Key('vorschlaege-ansehen'), onPressed: () => vorschlaegeZeigen(context), child: const Text('Ansehen')),
      ),
    );
  }
}
