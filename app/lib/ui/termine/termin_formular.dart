import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/modell/datum.dart';
import '../../core/modell/termin.dart';
import '../../core/sitzung.dart';
import '../bausteine.dart';
import '../format.dart';

const _erinnerungenMitZeit = <int?, String>{
  null: 'Keine Erinnerung',
  0: 'Zum Beginn',
  5: '5 Minuten vorher',
  15: '15 Minuten vorher',
  30: '30 Minuten vorher',
  60: '1 Stunde vorher',
  1440: '1 Tag vorher',
};

const _erinnerungenGanztag = <int?, String>{
  null: 'Keine Erinnerung',
  0: 'Am Tag um 9:00',
  1440: 'Am Vortag um 9:00',
};

/// Termin anlegen ([termin] == null) oder bearbeiten.
Future<void> terminBearbeiten(BuildContext context, WidgetRef ref, {Termin? termin, DateTime? tag}) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: _TerminFormular(termin: termin, tag: tag),
        ),
      ),
    );

class _TerminFormular extends ConsumerStatefulWidget {
  const _TerminFormular({this.termin, this.tag});
  final Termin? termin;
  final DateTime? tag;

  @override
  ConsumerState<_TerminFormular> createState() => _TerminFormularState();
}

class _TerminFormularState extends ConsumerState<_TerminFormular> {
  final _form = GlobalKey<FormState>();
  late final _titel = TextEditingController(text: widget.termin?.titel);
  late final _ort = TextEditingController(text: widget.termin?.ort);
  late final _notiz = TextEditingController(text: widget.termin?.notiz);
  late final _intervall = TextEditingController(text: '${widget.termin?.wiederholung?.intervall ?? 1}');
  late bool _ganztag = widget.termin?.ganztaegig ?? false;
  late DateTime _beginn;
  late DateTime? _ende;
  late Rhythmus? _rhythmus = widget.termin?.wiederholung?.rhythmus;
  late DateTime? _bis = widget.termin?.wiederholung?.bis;
  late int? _erinnerung = widget.termin?.erinnerungMinuten;
  String? _fehler;

  @override
  void initState() {
    super.initState();
    final t = widget.termin;
    if (t != null) {
      _beginn = t.beginn;
      _ende = t.ende;
    } else {
      final jetzt = DateTime.now();
      final tag = widget.tag ?? jetzt;
      final stunde = gleicherTag(tag, jetzt) ? (jetzt.hour + 1).clamp(0, 23) : 9;
      _beginn = DateTime(tag.year, tag.month, tag.day, stunde);
      _ende = _beginn.add(const Duration(hours: 1));
    }
  }

  @override
  void dispose() {
    _titel.dispose();
    _ort.dispose();
    _notiz.dispose();
    _intervall.dispose();
    super.dispose();
  }

  Future<DateTime?> _datum(DateTime start) => showDatePicker(
        context: context,
        initialDate: start,
        firstDate: DateTime(1970),
        lastDate: DateTime(2100),
      );

  Future<TimeOfDay?> _zeit(DateTime start) => showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(start));

  Future<void> _speichern() async {
    if (!_form.currentState!.validate()) return;
    final intervall = int.tryParse(_intervall.text.trim()) ?? 0;
    if (_rhythmus != null && intervall < 1) {
      setState(() => _fehler = 'Das Intervall muss mindestens 1 sein.');
      return;
    }
    final ende = _ende;
    if (ende != null && (_ganztag ? tagVon(ende).isBefore(tagVon(_beginn)) : ende.isBefore(_beginn))) {
      setState(() => _fehler = 'Das Ende liegt vor dem Beginn.');
      return;
    }
    final s = ref.read(sitzungProvider.notifier);
    final t = Termin(
      id: widget.termin?.id ?? s.neueId(),
      titel: _titel.text.trim(),
      beginn: _ganztag ? tagVon(_beginn) : _beginn,
      ende: ende == null ? null : (_ganztag ? (gleicherTag(ende, _beginn) ? null : tagVon(ende)) : ende),
      ganztaegig: _ganztag,
      ort: _ort.text.trim().isEmpty ? null : _ort.text.trim(),
      notiz: _notiz.text.trim().isEmpty ? null : _notiz.text.trim(),
      wiederholung: _rhythmus == null ? null : Wiederholung(_rhythmus!, intervall: intervall, bis: _bis),
      ausnahmen: widget.termin?.ausnahmen ?? const {},
      erinnerungMinuten: _erinnerung,
      geaendert: DateTime.now().toUtc(),
    );
    final ersteErinnerung = _erinnerung != null && !ref.read(bestandProvider).termine.values.any((x) => x.erinnerungMinuten != null);
    await s.speichereTermin(t);
    if (ersteErinnerung) await s.erinnerungenErlauben();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final erinnerungen = _ganztag ? _erinnerungenGanztag : _erinnerungenMitZeit;
    if (!erinnerungen.containsKey(_erinnerung)) _erinnerung = null;
    final ende = _ende;
    return Form(
      key: _form,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.termin == null ? 'Neuer Termin' : 'Termin bearbeiten', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 18),
            TextFormField(
              key: const Key('termin-titel'),
              controller: _titel,
              autofocus: widget.termin == null,
              decoration: const InputDecoration(labelText: 'Titel'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Bitte einen Titel eingeben.' : null,
            ),
            SwitchListTile(
              key: const Key('termin-ganztag'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Ganztägig'),
              value: _ganztag,
              onChanged: (v) => setState(() => _ganztag = v),
            ),
            _ZeitZeile(
              label: 'Beginn',
              wert: _beginn,
              mitZeit: !_ganztag,
              datumKey: const Key('termin-beginn-datum'),
              onDatum: () async {
                final d = await _datum(_beginn);
                if (d == null) return;
                final dauer = ende?.difference(_beginn);
                setState(() {
                  _beginn = DateTime(d.year, d.month, d.day, _beginn.hour, _beginn.minute);
                  if (dauer != null) _ende = _beginn.add(dauer);
                });
              },
              onZeit: () async {
                final z = await _zeit(_beginn);
                if (z == null) return;
                final dauer = ende?.difference(_beginn);
                setState(() {
                  _beginn = DateTime(_beginn.year, _beginn.month, _beginn.day, z.hour, z.minute);
                  if (dauer != null) _ende = _beginn.add(dauer);
                });
              },
            ),
            _ZeitZeile(
              label: _ganztag ? 'Bis (Tag)' : 'Ende',
              wert: ende ?? _beginn,
              mitZeit: !_ganztag,
              onDatum: () async {
                final d = await _datum(ende ?? _beginn);
                if (d == null) return;
                final basis = ende ?? _beginn;
                setState(() => _ende = DateTime(d.year, d.month, d.day, basis.hour, basis.minute));
              },
              onZeit: () async {
                final z = await _zeit(ende ?? _beginn);
                if (z == null) return;
                final basis = ende ?? _beginn;
                setState(() => _ende = DateTime(basis.year, basis.month, basis.day, z.hour, z.minute));
              },
            ),
            const SizedBox(height: 10),
            TextFormField(controller: _ort, decoration: const InputDecoration(labelText: 'Ort (optional)')),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notiz,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Notiz (optional)'),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<Rhythmus?>(
                    key: const Key('termin-wiederholung'),
                    initialValue: _rhythmus,
                    decoration: const InputDecoration(labelText: 'Wiederholung'),
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
                      key: const Key('termin-intervall'),
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
                    Text(_bis == null ? 'Ohne Enddatum' : 'Endet am ${datumKurz(_bis!)}'),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        final d = await _datum(_bis ?? _beginn.add(const Duration(days: 90)));
                        if (d != null) setState(() => _bis = d);
                      },
                      child: Text(_bis == null ? 'Ende festlegen' : 'Ändern'),
                    ),
                    if (_bis != null) IconButton(tooltip: 'Ohne Ende', onPressed: () => setState(() => _bis = null), icon: const Icon(Icons.close, size: 18)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int?>(
              key: ValueKey('termin-erinnerung-$_ganztag'),
              initialValue: _erinnerung,
              decoration: const InputDecoration(labelText: 'Erinnerung'),
              items: [for (final e in erinnerungen.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => setState(() => _erinnerung = v),
            ),
            if (_fehler != null)
              Padding(padding: const EdgeInsets.only(top: 12), child: Text(_fehler!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
                const SizedBox(width: 8),
                FilledButton(key: const Key('termin-speichern'), onPressed: _speichern, child: const Text('Speichern')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ZeitZeile extends StatelessWidget {
  const _ZeitZeile({
    required this.label,
    required this.wert,
    required this.mitZeit,
    required this.onDatum,
    required this.onZeit,
    this.datumKey,
  });

  final String label;
  final DateTime wert;
  final bool mitZeit;
  final VoidCallback onDatum;
  final VoidCallback onZeit;
  final Key? datumKey;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            SizedBox(width: 80, child: Text(label)),
            Expanded(
              child: OutlinedButton(key: datumKey, onPressed: onDatum, child: Text(datumMittel(wert), overflow: TextOverflow.ellipsis)),
            ),
            if (mitZeit) ...[
              const SizedBox(width: 8),
              OutlinedButton(onPressed: onZeit, child: Text(uhrzeit(wert))),
            ],
          ],
        ),
      );
}

/// Detailblatt für ein Vorkommen: bearbeiten, dieses Vorkommen oder die
/// ganze Serie löschen.
Future<void> vorkommenZeigen(BuildContext context, WidgetRef ref, Vorkommen v) async {
  final t = v.termin;
  final aktion = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.titel, style: Theme.of(ctx).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(vorkommenZeit(v)),
            if (t.ort != null) Text(t.ort!),
            if (t.wiederholung != null) Text('Wiederholt sich ${t.wiederholung!.beschreibung}'),
            if (t.erinnerungMinuten != null) Text('Erinnerung: ${(t.ganztaegig ? _erinnerungenGanztag : _erinnerungenMitZeit)[t.erinnerungMinuten] ?? '${t.erinnerungMinuten} Min. vorher'}'),
            if (t.notiz != null) ...[const SizedBox(height: 10), Text(t.notiz!)],
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('vorkommen-bearbeiten'),
                  onPressed: () => Navigator.pop(ctx, 'bearbeiten'),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(t.wiederholung == null ? 'Bearbeiten' : 'Serie bearbeiten'),
                ),
                if (t.wiederholung != null)
                  OutlinedButton(
                    key: const Key('vorkommen-loeschen-einzeln'),
                    onPressed: () => Navigator.pop(ctx, 'einzeln'),
                    child: const Text('Nur diesen Termin löschen'),
                  ),
                OutlinedButton(
                  key: const Key('vorkommen-loeschen'),
                  onPressed: () => Navigator.pop(ctx, 'alle'),
                  child: Text(t.wiederholung == null ? 'Löschen' : 'Ganze Serie löschen'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted || aktion == null) return;
  final s = ref.read(sitzungProvider.notifier);
  switch (aktion) {
    case 'bearbeiten':
      await terminBearbeiten(context, ref, termin: t);
    case 'einzeln':
      await s.loescheVorkommen(t, v.beginn);
    case 'alle':
      if (await bestaetigen(context, titel: 'Termin löschen?', text: '„${t.titel}“ wird gelöscht${t.wiederholung != null ? ' — mit allen Wiederholungen' : ''}.')) {
        await s.loescheTermin(t.id);
      }
  }
}

String vorkommenZeit(Vorkommen v) {
  final t = v.termin;
  if (t.ganztaegig) {
    return gleicherTag(v.beginn, v.ende)
        ? '${datumLang(v.beginn)} · ganztägig'
        : '${datumMittel(v.beginn)} – ${datumMittel(v.ende)} · ganztägig';
  }
  if (t.ende == null) return '${datumLang(v.beginn)} · ${uhrzeit(v.beginn)}';
  return gleicherTag(v.beginn, v.ende)
      ? '${datumLang(v.beginn)} · ${uhrzeit(v.beginn)}–${uhrzeit(v.ende)}'
      : '${datumMittel(v.beginn)} ${uhrzeit(v.beginn)} – ${datumMittel(v.ende)} ${uhrzeit(v.ende)}';
}
