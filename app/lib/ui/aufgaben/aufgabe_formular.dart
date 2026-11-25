import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/modell/aufgabe.dart';
import '../../core/modell/datum.dart';
import '../../core/modell/termin.dart';
import '../../core/raeume/raum.dart';
import '../../core/sitzung.dart';
import '../bausteine.dart';
import '../format.dart';
import '../raeume/raum_auswahl.dart';
import '../thema.dart';

/// Aufgabe anlegen ([aufgabe] == null) oder bearbeiten.
Future<void> aufgabeBearbeiten(BuildContext context, WidgetRef ref, {Aufgabe? aufgabe, DateTime? faellig}) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: _AufgabeFormular(aufgabe: aufgabe, faellig: faellig),
        ),
      ),
    );

class _AufgabeFormular extends ConsumerStatefulWidget {
  const _AufgabeFormular({this.aufgabe, this.faellig});
  final Aufgabe? aufgabe;
  final DateTime? faellig;

  @override
  ConsumerState<_AufgabeFormular> createState() => _AufgabeFormularState();
}

class _AufgabeFormularState extends ConsumerState<_AufgabeFormular> {
  final _form = GlobalKey<FormState>();
  late final _titel = TextEditingController(text: widget.aufgabe?.titel);
  late final _notiz = TextEditingController(text: widget.aufgabe?.notiz);
  late final _intervall = TextEditingController(text: '${widget.aufgabe?.wiederholung?.intervall ?? 1}');
  late DateTime? _faellig = widget.aufgabe?.faellig ?? widget.faellig;
  late Prioritaet _prioritaet = widget.aufgabe?.prioritaet ?? Prioritaet.normal;
  late Rhythmus? _rhythmus = widget.aufgabe?.wiederholung?.rhythmus;
  late DateTime? _bis = widget.aufgabe?.wiederholung?.bis;
  late int? _erinnerungUm = widget.aufgabe?.erinnerungUm;
  late String? _raum = widget.aufgabe?.raum;
  String? _fehler;

  @override
  void dispose() {
    _titel.dispose();
    _notiz.dispose();
    _intervall.dispose();
    super.dispose();
  }

  DateTime get _heute => tagVon(DateTime.now());

  Future<DateTime?> _datum(DateTime start) => showDatePicker(
        context: context,
        initialDate: start,
        firstDate: DateTime(1970),
        lastDate: DateTime(2100),
      );

  Future<void> _speichern() async {
    if (!_form.currentState!.validate()) return;
    final faellig = _faellig;
    final intervall = int.tryParse(_intervall.text.trim()) ?? 0;
    final rhythmus = faellig == null ? null : _rhythmus;
    if (rhythmus != null && intervall < 1) {
      setState(() => _fehler = 'Das Intervall muss mindestens 1 sein.');
      return;
    }
    if (rhythmus != null && _bis != null && tagVon(_bis!).isBefore(faellig!)) {
      setState(() => _fehler = 'Das Serienende liegt vor der Fälligkeit.');
      return;
    }
    final s = ref.read(sitzungProvider.notifier);
    final alt = widget.aufgabe;
    final wiederholung = rhythmus == null ? null : Wiederholung(rhythmus, intervall: intervall, bis: _bis);
    // Neue Fälligkeit oder neuer Rhythmus: die Serie beginnt neu.
    final serieGleich = alt != null &&
        alt.faellig == faellig &&
        alt.wiederholung?.rhythmus == wiederholung?.rhythmus &&
        alt.wiederholung?.intervall == wiederholung?.intervall;
    final erinnerungUm = faellig == null ? null : _erinnerungUm;
    final a = Aufgabe(
      id: alt?.id ?? s.neueId(),
      titel: _titel.text.trim(),
      notiz: _notiz.text.trim().isEmpty ? null : _notiz.text.trim(),
      faellig: faellig,
      erinnerungUm: erinnerungUm,
      prioritaet: _prioritaet,
      wiederholung: wiederholung,
      serienStart: serieGleich ? alt.serienStart : null,
      erledigt: alt?.erledigt,
      verlauf: alt?.verlauf ?? const [],
      geaendert: DateTime.now().toUtc(),
      raum: _raum,
    );
    final b = ref.read(bestandProvider);
    final ersteErinnerung = erinnerungUm != null &&
        !b.termine.values.any((x) => x.erinnerungMinuten != null) &&
        !b.aufgaben.values.any((x) => x.erinnerungUm != null);
    await s.speichereAufgabe(a);
    if (ersteErinnerung) await s.erinnerungenErlauben();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _loeschen() async {
    final a = widget.aufgabe!;
    if (!await bestaetigen(context, titel: 'Aufgabe löschen?', text: '„${a.titel}“ wird gelöscht${a.verlauf.isEmpty ? '' : ' — mit dem Verlauf'}.')) return;
    await ref.read(sitzungProvider.notifier).loescheAufgabe(a.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    final faellig = _faellig;
    final heute = _heute;
    final morgen = heute.add(const Duration(days: 1));
    final verlauf = widget.aufgabe?.verlauf ?? const <Runde>[];
    return Form(
      key: _form,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.aufgabe == null ? 'Neue Aufgabe' : 'Aufgabe bearbeiten', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 18),
            TextFormField(
              key: const Key('aufgabe-titel'),
              controller: _titel,
              autofocus: widget.aufgabe == null,
              decoration: const InputDecoration(labelText: 'Was steht an?'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Bitte einen Titel eingeben.' : null,
            ),
            const SizedBox(height: 16),
            Text('Fällig', style: TextStyle(fontSize: 13, color: f.gedaempft)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ChoiceChip(
                  key: const Key('faellig-ohne'),
                  label: const Text('Ohne Datum'),
                  selected: faellig == null,
                  onSelected: (_) => setState(() => _faellig = null),
                ),
                ChoiceChip(
                  key: const Key('faellig-heute'),
                  label: const Text('Heute'),
                  selected: faellig != null && gleicherTag(faellig, heute),
                  onSelected: (_) => setState(() => _faellig = heute),
                ),
                ChoiceChip(
                  key: const Key('faellig-morgen'),
                  label: const Text('Morgen'),
                  selected: faellig != null && gleicherTag(faellig, morgen),
                  onSelected: (_) => setState(() => _faellig = morgen),
                ),
                OutlinedButton.icon(
                  key: const Key('faellig-datum'),
                  onPressed: () async {
                    final d = await _datum(faellig ?? heute);
                    if (d != null) setState(() => _faellig = tagVon(d));
                  },
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text(faellig == null || gleicherTag(faellig, heute) || gleicherTag(faellig, morgen) ? 'Datum …' : datumMittel(faellig)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Wichtigkeit', style: TextStyle(fontSize: 13, color: f.gedaempft)),
            const SizedBox(height: 6),
            SegmentedButton<Prioritaet>(
              key: const Key('aufgabe-prioritaet'),
              showSelectedIcon: false,
              segments: [
                for (final p in Prioritaet.values)
                  ButtonSegment(value: p, label: Text(p.bezeichnung, key: Key('prioritaet-${p.name}'))),
              ],
              selected: {_prioritaet},
              onSelectionChanged: (s) => setState(() => _prioritaet = s.single),
            ),
            if (faellig != null) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<Rhythmus?>(
                      key: const Key('aufgabe-wiederholung'),
                      isExpanded: true,
                      initialValue: _rhythmus,
                      decoration: const InputDecoration(labelText: 'Wiederholung', helperText: 'Nächste Runde nach dem Abhaken'),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('Keine')),
                        for (final r in Rhythmus.values) DropdownMenuItem(value: r, child: Text(r.bezeichnung)),
                      ],
                      onChanged: (v) => setState(() => _rhythmus = v),
                    ),
                  ),
                  if (_rhythmus != null) ...[
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 120,
                      child: TextFormField(
                        key: const Key('aufgabe-intervall'),
                        controller: _intervall,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: 'alle … ${_rhythmus!.einheiten}'),
                      ),
                    ),
                  ],
                ],
              ),
              if (_rhythmus != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Expanded(child: Text(_bis == null ? 'Ohne Enddatum' : 'Endet am ${datumKurz(_bis!)}')),
                      TextButton(
                        onPressed: () async {
                          final d = await _datum(_bis ?? faellig.add(const Duration(days: 90)));
                          if (d != null) setState(() => _bis = d);
                        },
                        child: Text(_bis == null ? 'Ende festlegen' : 'Ändern'),
                      ),
                      if (_bis != null) IconButton(tooltip: 'Ohne Ende', onPressed: () => setState(() => _bis = null), icon: const Icon(Icons.close, size: 18)),
                    ],
                  ),
                ),
              SwitchListTile(
                key: const Key('aufgabe-erinnern'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Erinnern'),
                subtitle: Text(_erinnerungUm == null ? 'Ohne Erinnerung' : 'Am Fälligkeitstag um ${uhrzeitMinuten(_erinnerungUm!)}'),
                value: _erinnerungUm != null,
                onChanged: (an) => setState(() => _erinnerungUm = an ? 9 * 60 : null),
              ),
              if (_erinnerungUm != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('aufgabe-erinnerung-zeit'),
                    onPressed: () async {
                      final z = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay(hour: _erinnerungUm! ~/ 60, minute: _erinnerungUm! % 60),
                      );
                      if (z != null) setState(() => _erinnerungUm = z.hour * 60 + z.minute);
                    },
                    icon: const Icon(Icons.schedule, size: 18),
                    label: Text(uhrzeitMinuten(_erinnerungUm!)),
                  ),
                ),
            ],
            const SizedBox(height: 14),
            RaumAuswahl(art: RaumArt.aufgaben, wert: _raum, onChanged: (v) => setState(() => _raum = v), bezeichnung: 'Liste'),
            TextFormField(
              controller: _notiz,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Notiz (optional)'),
            ),
            if (verlauf.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                'Zuletzt erledigt: ${verlauf.take(5).map((r) => datumKurz(r.erledigt.toLocal())).join(', ')}'
                '${verlauf.length > 5 ? ' (insgesamt ${verlauf.length})' : ''}',
                style: TextStyle(fontSize: 12, color: f.leise),
              ),
            ],
            if (_fehler != null)
              Padding(padding: const EdgeInsets.only(top: 12), child: Text(_fehler!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            if (nurLesen(ref, widget.aufgabe?.raum))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Hinweis(text: 'Aus einer geteilten Liste mit Leserecht. Ändern kann sie nur, wer Schreibrecht hat.'),
              ),
            const SizedBox(height: 22),
            if (!nurLesen(ref, widget.aufgabe?.raum))
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (widget.aufgabe != null)
                  TextButton(
                    key: const Key('aufgabe-loeschen'),
                    onPressed: _loeschen,
                    style: TextButton.styleFrom(foregroundColor: f.fehler),
                    child: const Text('Löschen'),
                  ),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
                FilledButton(key: const Key('aufgabe-speichern'), onPressed: _speichern, child: const Text('Speichern')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
