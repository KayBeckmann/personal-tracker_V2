import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/modell/notiz.dart';
import '../../core/sitzung.dart';
import '../bausteine.dart';
import '../format.dart';
import '../thema.dart';

Future<void> notizOeffnen(BuildContext context, Notiz? notiz) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => NotizEditor(notiz: notiz)));

/// Markdown-Notiz bearbeiten. Der Text wird unverändert gespeichert;
/// die Vorschau rendert ihn nur.
class NotizEditor extends ConsumerStatefulWidget {
  const NotizEditor({super.key, this.notiz});
  final Notiz? notiz;

  @override
  ConsumerState<NotizEditor> createState() => _NotizEditorState();
}

class _NotizEditorState extends ConsumerState<NotizEditor> {
  late final _titel = TextEditingController(text: widget.notiz?.titel);
  late final _text = TextEditingController(text: widget.notiz?.text);
  late bool _vorschau = widget.notiz != null && widget.notiz!.text.isNotEmpty;
  late Notiz? _gespeichert = widget.notiz;

  bool get _geaendert =>
      _titel.text != (_gespeichert?.titel ?? '') || _text.text != (_gespeichert?.text ?? '');

  @override
  void initState() {
    super.initState();
    _titel.addListener(() => setState(() {}));
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _titel.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _speichern() async {
    if (_titel.text.trim().isEmpty && _text.text.trim().isEmpty) return;
    final s = ref.read(sitzungProvider.notifier);
    final jetzt = DateTime.now().toUtc();
    final n = (_gespeichert ?? Notiz(id: s.neueId(), titel: '', text: '', erstellt: jetzt, geaendert: jetzt))
        .kopie(titel: _titel.text, text: _text.text);
    await s.speichereNotiz(n);
    if (mounted) setState(() => _gespeichert = ref.read(bestandProvider).notizen[n.id]);
  }

  Future<void> _loeschen() async {
    final n = _gespeichert;
    if (n == null) {
      Navigator.pop(context);
      return;
    }
    if (!await bestaetigen(context, titel: 'Notiz löschen?', text: '„${n.anzeigeTitel}“ wird endgültig gelöscht.')) return;
    await ref.read(sitzungProvider.notifier).loescheNotiz(n.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    final dunkel = Theme.of(context).brightness == Brightness.dark;
    final breit = MediaQuery.sizeOf(context).width >= 980;
    final editor = TextField(
      key: const Key('notiz-text'),
      controller: _text,
      maxLines: null,
      minLines: 16,
      keyboardType: TextInputType.multiline,
      style: const TextStyle(fontFamily: 'NotoSansMono', fontSize: 14, height: 1.5),
      decoration: const InputDecoration(hintText: '# Überschrift\n\nText in Markdown …', alignLabelWithHint: true),
    );
    final vorschau = Container(
      key: const Key('notiz-vorschau'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: f.karte, borderRadius: BorderRadius.circular(12), border: Border.all(color: f.karteRand)),
      child: _text.text.trim().isEmpty
          ? const Leer('Noch kein Text.')
          : MarkdownBlock(data: _text.text, config: dunkel ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig),
    );

    return PopScope(
      canPop: !_geaendert,
      onPopInvokedWithResult: (bereits, _) async {
        if (bereits) return;
        final verwerfen = await bestaetigen(
          context,
          titel: 'Änderungen verwerfen?',
          text: 'Die Notiz hat ungespeicherte Änderungen.',
          ja: 'Verwerfen',
        );
        if (verwerfen && context.mounted) {
          _titel.text = _gespeichert?.titel ?? '';
          _text.text = _gespeichert?.text ?? '';
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: f.flaeche,
        appBar: AppBar(
          backgroundColor: f.flaeche,
          surfaceTintColor: Colors.transparent,
          title: Text(_gespeichert == null ? 'Neue Notiz' : 'Notiz'),
          actions: [
            IconButton(key: const Key('notiz-loeschen'), tooltip: 'Löschen', onPressed: _loeschen, icon: const Icon(Icons.delete_outline)),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                key: const Key('notiz-speichern'),
                onPressed: _geaendert ? _speichern : null,
                child: const Text('Speichern'),
              ),
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
                    TextField(
                      key: const Key('notiz-titel'),
                      controller: _titel,
                      style: Theme.of(context).textTheme.headlineSmall,
                      decoration: const InputDecoration(
                        hintText: 'Titel (optional)',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                    if (_gespeichert != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          'Zuletzt geändert ${datumKurz(_gespeichert!.geaendert.toLocal())}, ${uhrzeit(_gespeichert!.geaendert.toLocal())} · Markdown · nur auf diesem Gerät',
                          style: TextStyle(fontSize: 12, color: f.leise),
                        ),
                      ),
                    if (!breit)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SegmentedButton<bool>(
                          key: const Key('notiz-modus'),
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: false, label: Text('Bearbeiten')),
                            ButtonSegment(value: true, label: Text('Vorschau')),
                          ],
                          selected: {_vorschau},
                          onSelectionChanged: (s) => setState(() => _vorschau = s.first),
                        ),
                      ),
                    if (breit)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: editor),
                          const SizedBox(width: 18),
                          Expanded(child: vorschau),
                        ],
                      )
                    else
                      _vorschau ? vorschau : editor,
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
