import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/modell/datum.dart';
import '../../core/modell/finanzen.dart';
import '../../core/sitzung.dart';
import '../bausteine.dart';
import '../format.dart';

Future<void> _formular(BuildContext context, Widget kind) => showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 500), child: kind),
      ),
    );

String? _betragPruefen(String? v, {bool nullErlaubt = false, bool negativErlaubt = false}) {
  final c = centAusText(v ?? '');
  if (c == null) return 'Betrag wie 12,50 eingeben.';
  if (!negativErlaubt && c < 0) return 'Ohne Minus — die Art legt Ausgabe oder Einnahme fest.';
  if (!nullErlaubt && c == 0) return 'Der Betrag darf nicht 0 sein.';
  return null;
}

class _Rahmen extends StatelessWidget {
  const _Rahmen({required this.titel, required this.formKey, required this.kinder, required this.onSpeichern, this.onLoeschen});

  final String titel;
  final GlobalKey<FormState> formKey;
  final List<Widget> kinder;
  final VoidCallback onSpeichern;
  final VoidCallback? onLoeschen;

  @override
  Widget build(BuildContext context) => Form(
        key: formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(titel, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 18),
              for (final k in kinder) Padding(padding: const EdgeInsets.only(bottom: 12), child: k),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (onLoeschen != null)
                    TextButton(
                      key: const Key('formular-loeschen'),
                      onPressed: onLoeschen,
                      style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                      child: const Text('Löschen'),
                    ),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
                  const SizedBox(width: 8),
                  FilledButton(key: const Key('formular-speichern'), onPressed: onSpeichern, child: const Text('Speichern')),
                ],
              ),
            ],
          ),
        ),
      );
}

class _DatumFeld extends StatelessWidget {
  const _DatumFeld({required this.label, required this.wert, required this.onWahl});
  final String label;
  final DateTime wert;
  final ValueChanged<DateTime> onWahl;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          SizedBox(width: 90, child: Text(label)),
          Expanded(
            child: OutlinedButton(
              onPressed: () async {
                final d = await showDatePicker(context: context, initialDate: wert, firstDate: DateTime(1990), lastDate: DateTime(2100));
                if (d != null) onWahl(d);
              },
              child: Text(datumMittel(wert)),
            ),
          ),
        ],
      );
}

Widget _kontoAuswahl(WidgetRef ref, {required Key key, required String label, required String? wert, required ValueChanged<String?> onChanged}) {
  final konten = ref.read(bestandProvider).kontenSortiert.where((k) => !k.archiviert || k.id == wert);
  return DropdownButtonFormField<String>(
    key: key,
    initialValue: wert,
    decoration: InputDecoration(labelText: label),
    items: [for (final k in konten) DropdownMenuItem(value: k.id, child: Text('${k.name} · ${k.art.bezeichnung}'))],
    onChanged: onChanged,
    validator: (v) => v == null ? 'Bitte ein Konto wählen.' : null,
  );
}

Widget _statusWahl(BuchungsStatus wert, ValueChanged<BuchungsStatus> onChanged) =>
    SegmentedButton<BuchungsStatus>(
      key: const Key('buchung-status'),
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: BuchungsStatus.gebucht, label: Text('Gebucht')),
        ButtonSegment(value: BuchungsStatus.geplant, label: Text('Geplant')),
      ],
      selected: {wert},
      onSelectionChanged: (s) => onChanged(s.first),
    );

// ---------------------------------------------------------------------------
// Buchung

Future<void> buchungBearbeiten(BuildContext context, WidgetRef ref, {Buchung? buchung, BuchungsStatus? status, DateTime? datum}) =>
    _formular(context, _BuchungFormular(buchung: buchung, status: status, datum: datum));

class _BuchungFormular extends ConsumerStatefulWidget {
  const _BuchungFormular({this.buchung, this.status, this.datum});
  final Buchung? buchung;
  final BuchungsStatus? status;
  final DateTime? datum;

  @override
  ConsumerState<_BuchungFormular> createState() => _BuchungFormularState();
}

class _BuchungFormularState extends ConsumerState<_BuchungFormular> {
  final _form = GlobalKey<FormState>();
  late final b = widget.buchung;
  late bool _einnahme = (b?.betragCent ?? -1) > 0;
  late final _betrag = TextEditingController(text: b == null ? '' : centAlsText(b!.betragCent.abs()));
  late final _empfaenger = TextEditingController(text: b?.empfaenger);
  late final _bemerkung = TextEditingController(text: b?.bemerkung);
  late String? _konto = b?.kontoId ?? ref.read(bestandProvider).kontenSortiert.where((k) => !k.archiviert).firstOrNull?.id;
  late DateTime _datum = b?.datum ?? tagVon(widget.datum ?? DateTime.now());
  late BuchungsStatus _status = b?.status ?? widget.status ?? BuchungsStatus.gebucht;

  @override
  void dispose() {
    _betrag.dispose();
    _empfaenger.dispose();
    _bemerkung.dispose();
    super.dispose();
  }

  Future<void> _speichern() async {
    if (!_form.currentState!.validate()) return;
    final s = ref.read(sitzungProvider.notifier);
    final betrag = centAusText(_betrag.text)!.abs() * (_einnahme ? 1 : -1);
    final bemerkung = _bemerkung.text.trim().isEmpty ? null : _bemerkung.text.trim();
    final alt = b;
    await s.speichereBuchung(alt == null
        ? Buchung(
            id: s.neueId(),
            kontoId: _konto!,
            datum: _datum,
            empfaenger: _empfaenger.text.trim(),
            betragCent: betrag,
            status: _status,
            bemerkung: bemerkung,
            geaendert: DateTime.now().toUtc(),
          )
        : alt.kopie(
            kontoId: _konto,
            datum: _datum,
            empfaenger: _empfaenger.text.trim(),
            betragCent: betrag,
            status: _status,
            bemerkung: () => bemerkung,
            // Geplant erfasst und jetzt gebucht: nicht als variable Ausgabe zählen.
            ausPlanung: alt.ausPlanung || (alt.status == BuchungsStatus.geplant && _status == BuchungsStatus.gebucht),
          ));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _loeschen() async {
    if (!await bestaetigen(context, titel: 'Buchung löschen?', text: '${b!.empfaenger} · ${euro(b!.betragCent)}')) return;
    await ref.read(sitzungProvider.notifier).loescheBuchung(b!.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => _Rahmen(
        titel: b == null ? 'Neue Buchung' : 'Buchung bearbeiten',
        formKey: _form,
        onSpeichern: _speichern,
        onLoeschen: b == null ? null : _loeschen,
        kinder: [
          SegmentedButton<bool>(
            key: const Key('buchung-art'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Ausgabe')),
              ButtonSegment(value: true, label: Text('Einnahme')),
            ],
            selected: {_einnahme},
            onSelectionChanged: (s) => setState(() => _einnahme = s.first),
          ),
          TextFormField(
            key: const Key('buchung-betrag'),
            controller: _betrag,
            autofocus: b == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Betrag', suffixText: '€'),
            validator: _betragPruefen,
          ),
          TextFormField(
            key: const Key('buchung-empfaenger'),
            controller: _empfaenger,
            decoration: InputDecoration(labelText: _einnahme ? 'Von wem' : 'Empfänger'),
          ),
          _kontoAuswahl(ref, key: const Key('buchung-konto'), label: 'Konto', wert: _konto, onChanged: (v) => setState(() => _konto = v)),
          _DatumFeld(label: 'Datum', wert: _datum, onWahl: (d) => setState(() => _datum = d)),
          _statusWahl(_status, (v) => setState(() => _status = v)),
          TextFormField(controller: _bemerkung, decoration: const InputDecoration(labelText: 'Bemerkung (optional)')),
        ],
      );
}

// ---------------------------------------------------------------------------
// Umbuchung

Future<void> umbuchungBearbeiten(BuildContext context, WidgetRef ref, {String? umbuchungId}) =>
    _formular(context, _UmbuchungFormular(umbuchungId: umbuchungId));

class _UmbuchungFormular extends ConsumerStatefulWidget {
  const _UmbuchungFormular({this.umbuchungId});
  final String? umbuchungId;

  @override
  ConsumerState<_UmbuchungFormular> createState() => _UmbuchungFormularState();
}

class _UmbuchungFormularState extends ConsumerState<_UmbuchungFormular> {
  final _form = GlobalKey<FormState>();
  late final _teile = ref.read(bestandProvider).buchungen.values.where((b) => b.umbuchungId != null && b.umbuchungId == widget.umbuchungId).toList();
  late final _abgang = _teile.where((b) => b.betragCent < 0).firstOrNull;
  late final _zugang = _teile.where((b) => b.betragCent >= 0).firstOrNull;
  late final _betrag = TextEditingController(text: _abgang == null ? '' : centAlsText(_abgang.betragCent.abs()));
  late final _bemerkung = TextEditingController(text: _abgang?.bemerkung);
  late String? _von = _abgang?.kontoId;
  late String? _nach = _zugang?.kontoId;
  late DateTime _datum = _abgang?.datum ?? tagVon(DateTime.now());
  late BuchungsStatus _status = _abgang?.status ?? BuchungsStatus.gebucht;

  @override
  void dispose() {
    _betrag.dispose();
    _bemerkung.dispose();
    super.dispose();
  }

  Future<void> _speichern() async {
    if (!_form.currentState!.validate()) return;
    await ref.read(sitzungProvider.notifier).umbuchen(
          umbuchungId: widget.umbuchungId,
          vonKonto: _von!,
          nachKonto: _nach!,
          betragCent: centAusText(_betrag.text)!.abs(),
          datum: _datum,
          status: _status,
          bemerkung: _bemerkung.text.trim().isEmpty ? null : _bemerkung.text.trim(),
        );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _loeschen() async {
    if (!await bestaetigen(context, titel: 'Umbuchung löschen?', text: 'Beide Buchungen werden entfernt.')) return;
    await ref.read(sitzungProvider.notifier).loescheBuchung(_abgang!.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => _Rahmen(
        titel: widget.umbuchungId == null ? 'Neue Umbuchung' : 'Umbuchung bearbeiten',
        formKey: _form,
        onSpeichern: _speichern,
        onLoeschen: _abgang == null ? null : _loeschen,
        kinder: [
          const Text('Geld zwischen eigenen Konten — zählt weder als Einnahme noch als Ausgabe.'),
          _kontoAuswahl(ref, key: const Key('umbuchung-von'), label: 'Von Konto', wert: _von, onChanged: (v) => setState(() => _von = v)),
          DropdownButtonFormField<String>(
            key: const Key('umbuchung-nach'),
            initialValue: _nach,
            decoration: const InputDecoration(labelText: 'Auf Konto'),
            items: [
              for (final k in ref.read(bestandProvider).kontenSortiert.where((k) => !k.archiviert || k.id == _nach))
                DropdownMenuItem(value: k.id, child: Text('${k.name} · ${k.art.bezeichnung}')),
            ],
            onChanged: (v) => setState(() => _nach = v),
            validator: (v) => v == null
                ? 'Bitte ein Konto wählen.'
                : v == _von
                    ? 'Zwei verschiedene Konten wählen.'
                    : null,
          ),
          TextFormField(
            key: const Key('umbuchung-betrag'),
            controller: _betrag,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Betrag', suffixText: '€'),
            validator: _betragPruefen,
          ),
          _DatumFeld(label: 'Datum', wert: _datum, onWahl: (d) => setState(() => _datum = d)),
          _statusWahl(_status, (v) => setState(() => _status = v)),
          TextFormField(controller: _bemerkung, decoration: const InputDecoration(labelText: 'Bemerkung (optional)')),
        ],
      );
}

// ---------------------------------------------------------------------------
// Konto

Future<void> kontoBearbeiten(BuildContext context, WidgetRef ref, {Konto? konto}) =>
    _formular(context, _KontoFormular(konto: konto));

class _KontoFormular extends ConsumerStatefulWidget {
  const _KontoFormular({this.konto});
  final Konto? konto;

  @override
  ConsumerState<_KontoFormular> createState() => _KontoFormularState();
}

class _KontoFormularState extends ConsumerState<_KontoFormular> {
  final _form = GlobalKey<FormState>();
  late final k = widget.konto;
  late final _name = TextEditingController(text: k?.name);
  late final _anfang = TextEditingController(text: k == null ? '0,00' : centAlsText(k!.anfangssaldoCent));
  late KontoArt _art = k?.art ?? KontoArt.bank;
  late bool _archiviert = k?.archiviert ?? false;

  @override
  void dispose() {
    _name.dispose();
    _anfang.dispose();
    super.dispose();
  }

  Future<void> _speichern() async {
    if (!_form.currentState!.validate()) return;
    final s = ref.read(sitzungProvider.notifier);
    final anfang = centAusText(_anfang.text)!;
    await s.speichereKonto(k == null
        ? Konto(id: s.neueId(), name: _name.text.trim(), art: _art, anfangssaldoCent: anfang, geaendert: DateTime.now().toUtc())
        : k!.kopie(name: _name.text.trim(), art: _art, anfangssaldoCent: anfang, archiviert: _archiviert));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _loeschen() async {
    if (!await bestaetigen(context, titel: 'Konto löschen?', text: '„${k!.name}“ wird gelöscht.')) return;
    await ref.read(sitzungProvider.notifier).loescheKonto(k!.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final loeschbar = k != null && ref.read(sitzungProvider.notifier).kontoLoeschbar(k!.id);
    return _Rahmen(
      titel: k == null ? 'Neues Konto' : 'Konto bearbeiten',
      formKey: _form,
      onSpeichern: _speichern,
      onLoeschen: loeschbar ? _loeschen : null,
      kinder: [
        TextFormField(
          key: const Key('konto-name'),
          controller: _name,
          autofocus: k == null,
          decoration: const InputDecoration(labelText: 'Name', hintText: 'z. B. Girokonto, Portemonnaie'),
          validator: (v) => (v ?? '').trim().isEmpty ? 'Bitte einen Namen eingeben.' : null,
        ),
        DropdownButtonFormField<KontoArt>(
          key: const Key('konto-art'),
          initialValue: _art,
          decoration: const InputDecoration(labelText: 'Kategorie'),
          items: [for (final a in KontoArt.values) DropdownMenuItem(value: a, child: Text(a.bezeichnung))],
          onChanged: (v) => setState(() => _art = v!),
        ),
        TextFormField(
          key: const Key('konto-anfang'),
          controller: _anfang,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: const InputDecoration(labelText: 'Anfangsstand', suffixText: '€', helperText: 'Stand vor der ersten Buchung (darf negativ sein)'),
          validator: (v) => _betragPruefen(v, nullErlaubt: true, negativErlaubt: true),
        ),
        if (_art == KontoArt.depot)
          const Text('Ein Depot führt hier nur Buchungen — Kurswerte werden nicht abgebildet.'),
        if (k != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Archiviert'),
            subtitle: Text(loeschbar ? 'Ausgeblendet bei neuen Buchungen' : 'Konten mit Buchungen werden archiviert statt gelöscht'),
            value: _archiviert,
            onChanged: (v) => setState(() => _archiviert = v),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Wiederkehrender Posten

Future<void> planBearbeiten(BuildContext context, WidgetRef ref, {Plan? plan}) => _formular(context, _PlanFormular(plan: plan));

class _PlanFormular extends ConsumerStatefulWidget {
  const _PlanFormular({this.plan});
  final Plan? plan;

  @override
  ConsumerState<_PlanFormular> createState() => _PlanFormularState();
}

class _PlanFormularState extends ConsumerState<_PlanFormular> {
  final _form = GlobalKey<FormState>();
  late final p = widget.plan;
  late bool _einnahme = (p?.betragCent ?? -1) > 0;
  late final _empfaenger = TextEditingController(text: p?.empfaenger);
  late final _betrag = TextEditingController(text: p == null ? '' : centAlsText(p!.betragCent.abs()));
  late final _tag = TextEditingController(text: '${p?.tag ?? DateTime.now().day}');
  late final _bemerkung = TextEditingController(text: p?.bemerkung);
  late String? _konto = p?.kontoId ?? ref.read(bestandProvider).kontenSortiert.where((k) => !k.archiviert).firstOrNull?.id;
  late Monat _ab = p?.ab ?? monatVon(DateTime.now());
  late Monat? _bis = p?.bis;

  @override
  void dispose() {
    _empfaenger.dispose();
    _betrag.dispose();
    _tag.dispose();
    _bemerkung.dispose();
    super.dispose();
  }

  Future<void> _speichern() async {
    if (!_form.currentState!.validate()) return;
    final s = ref.read(sitzungProvider.notifier);
    final betrag = centAusText(_betrag.text)!.abs() * (_einnahme ? 1 : -1);
    final bem = _bemerkung.text.trim().isEmpty ? null : _bemerkung.text.trim();
    final tag = int.parse(_tag.text.trim());
    await s.speicherePlan(p == null
        ? Plan(
            id: s.neueId(),
            kontoId: _konto!,
            empfaenger: _empfaenger.text.trim(),
            betragCent: betrag,
            tag: tag,
            ab: _ab,
            bis: _bis,
            bemerkung: bem,
            geaendert: DateTime.now().toUtc(),
          )
        : p!.kopie(kontoId: _konto, empfaenger: _empfaenger.text.trim(), betragCent: betrag, tag: tag, ab: _ab, bis: () => _bis, bemerkung: () => bem));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _loeschen() async {
    if (!await bestaetigen(context, titel: 'Wiederkehrenden Posten löschen?', text: 'Bereits gebuchte Monate bleiben im Haushaltsbuch.')) return;
    await ref.read(sitzungProvider.notifier).loeschePlan(p!.id);
    if (mounted) Navigator.pop(context);
  }

  Future<Monat?> _monatWaehlen(Monat start) async {
    final d = await showDatePicker(
      context: context,
      initialDate: monatsErster(start),
      firstDate: DateTime(1990),
      lastDate: DateTime(2100),
      helpText: 'Einen Tag im gewünschten Monat wählen',
    );
    return d == null ? null : monatVon(d);
  }

  @override
  Widget build(BuildContext context) => _Rahmen(
        titel: p == null ? 'Wiederkehrender Posten' : 'Wiederkehrenden Posten bearbeiten',
        formKey: _form,
        onSpeichern: _speichern,
        onLoeschen: p == null ? null : _loeschen,
        kinder: [
          const Text('Monatlich geplant, z. B. Miete oder Gehalt. Zählt als „geplant“, bis du den Monat buchst.'),
          SegmentedButton<bool>(
            key: const Key('plan-art'),
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: false, label: Text('Ausgabe')), ButtonSegment(value: true, label: Text('Einnahme'))],
            selected: {_einnahme},
            onSelectionChanged: (s) => setState(() => _einnahme = s.first),
          ),
          TextFormField(
            key: const Key('plan-empfaenger'),
            controller: _empfaenger,
            decoration: const InputDecoration(labelText: 'Bezeichnung', hintText: 'z. B. Miete'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Bitte eine Bezeichnung eingeben.' : null,
          ),
          TextFormField(
            key: const Key('plan-betrag'),
            controller: _betrag,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Betrag', suffixText: '€'),
            validator: _betragPruefen,
          ),
          _kontoAuswahl(ref, key: const Key('plan-konto'), label: 'Konto', wert: _konto, onChanged: (v) => setState(() => _konto = v)),
          TextFormField(
            key: const Key('plan-tag'),
            controller: _tag,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Tag im Monat', helperText: 'In kürzeren Monaten der letzte Tag'),
            validator: (v) {
              final t = int.tryParse((v ?? '').trim());
              return t == null || t < 1 || t > 31 ? 'Tag 1–31' : null;
            },
          ),
          Row(
            children: [
              Expanded(child: Text('Ab ${monatName(_ab)}')),
              TextButton(
                onPressed: () async {
                  final m = await _monatWaehlen(_ab);
                  if (m != null) setState(() => _ab = m);
                },
                child: const Text('Ändern'),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(child: Text(_bis == null ? 'Ohne Ende' : 'Bis ${monatName(_bis!)}')),
              TextButton(
                onPressed: () async {
                  final m = await _monatWaehlen(_bis ?? _ab);
                  if (m != null) setState(() => _bis = m < _ab ? _ab : m);
                },
                child: Text(_bis == null ? 'Ende festlegen' : 'Ändern'),
              ),
              if (_bis != null) IconButton(onPressed: () => setState(() => _bis = null), icon: const Icon(Icons.close, size: 18)),
            ],
          ),
          TextFormField(controller: _bemerkung, decoration: const InputDecoration(labelText: 'Bemerkung (optional)')),
        ],
      );
}

/// Ein Vorkommen eines Plans buchen — Betrag und Datum anpassbar.
Future<void> planBuchenDialog(BuildContext context, WidgetRef ref, Plan plan, Monat monat) async {
  var datum = plan.faelligIm(monat);
  final form = GlobalKey<FormState>();
  final cent = await eingabeDialog<int>(
    context,
    start: [centAlsText(plan.betragCent.abs())],
    builder: (ctx, felder) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('${plan.empfaenger} buchen'),
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('plan-buchen-betrag'),
                controller: felder[0],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: plan.betragCent < 0 ? 'Betrag (Ausgabe)' : 'Betrag (Einnahme)', suffixText: '€'),
                validator: _betragPruefen,
              ),
              const SizedBox(height: 12),
              _DatumFeld(label: 'Datum', wert: datum, onWahl: (d) => setState(() => datum = d)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
            key: const Key('plan-buchen-ok'),
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(ctx, centAusText(felder[0].text)!.abs() * (plan.betragCent < 0 ? -1 : 1));
              }
            },
            child: const Text('Buchen'),
          ),
        ],
      ),
    ),
  );
  if (cent != null) await ref.read(sitzungProvider.notifier).planBuchen(plan, monat, betragCent: cent, datum: datum);
}

/// Optionaler monatlicher Ausgabenrahmen — getrennt von der Prognose.
Future<void> rahmenSetzen(BuildContext context, WidgetRef ref) async {
  final e = ref.read(bestandProvider).einstellungen;
  final form = GlobalKey<FormState>();
  final ergebnis = await eingabeDialog<(int?,)>(
    context,
    start: [e.ausgabenrahmenCent == null ? '' : centAlsText(e.ausgabenrahmenCent!)],
    builder: (ctx, felder) => AlertDialog(
      title: const Text('Monatlicher Ausgabenrahmen'),
      content: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Dein selbst gesetzter Rahmen für Ausgaben pro Monat. Er wird neben der Schätzung gezeigt, '
                'nicht mit ihr verrechnet. Leer lassen = kein Rahmen.'),
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('rahmen-betrag'),
              controller: felder[0],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Rahmen', suffixText: '€'),
              validator: (v) => (v ?? '').trim().isEmpty ? null : _betragPruefen(v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
        FilledButton(
          key: const Key('rahmen-ok'),
          onPressed: () {
            if (!form.currentState!.validate()) return;
            final t = felder[0].text.trim();
            Navigator.pop(ctx, (t.isEmpty ? null : centAusText(t)!.abs(),));
          },
          child: const Text('Übernehmen'),
        ),
      ],
    ),
  );
  if (ergebnis != null) {
    await ref.read(sitzungProvider.notifier).speichereEinstellungen(e.kopie(ausgabenrahmenCent: () => ergebnis.$1));
  }
}
