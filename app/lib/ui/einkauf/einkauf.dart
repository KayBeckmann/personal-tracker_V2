import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dienste/standort.dart';
import '../../core/einkauf/schaetzung.dart';
import '../../core/modell/datum.dart';
import '../../core/modell/einkauf.dart';
import '../../core/raeume/raum.dart';
import '../../core/sitzung.dart';
import '../bausteine.dart';
import '../format.dart';
import '../raeume/raum_auswahl.dart';
import '../thema.dart';

String mengeText(double m, Einheit e) {
  final z = m == m.roundToDouble() ? m.toInt().toString() : m.toString().replaceAll('.', ',');
  return '$z ${e.kurz}';
}

double? mengeAusText(String s) {
  final v = double.tryParse(s.trim().replaceAll(',', '.'));
  return v == null || v <= 0 ? null : v;
}

String _herkunftText(PostenWert w, Map<String, Filiale> filialen) {
  final p = w.preis;
  return switch (w.herkunft) {
    PreisHerkunft.unbekannt => 'Preis unbekannt',
    PreisHerkunft.nichtVergleichbar => 'Preis nur für ${mengeText(p!.packungsMenge, p.packungsEinheit)} – nicht umrechenbar',
    PreisHerkunft.filiale => '${euro(w.kostenCent!)} · Stand ${datumKurz(p!.datum)}',
    PreisHerkunft.region => '≈ ${euro(w.kostenCent!)} · aus ${filialen[p!.filialeId]?.name ?? 'anderer Filiale'} (Schätzung)',
    PreisHerkunft.ohneFiliale => '≈ ${euro(w.kostenCent!)} · ${filialen[p!.filialeId]?.anzeige ?? 'unbekannte Filiale'} (Schätzung)',
  };
}

/// Einkaufslisten mit geschätzten Summen, Filialen verwalten.
class EinkaufSeite extends ConsumerWidget {
  const EinkaufSeite({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(bestandProvider);
    final f = context.farben;
    final listen = b.einkaufslisten.values.toList()..sort((a, c) => a.name.toLowerCase().compareTo(c.name.toLowerCase()));
    final filialen = b.filialen.values.toList()..sort((a, c) => a.anzeige.toLowerCase().compareTo(c.anzeige.toLowerCase()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Seitenkopf(
          oberzeile: '${listen.length} ${listen.length == 1 ? 'Liste' : 'Listen'} · ${filialen.length} ${filialen.length == 1 ? 'Filiale' : 'Filialen'}',
          titel: 'Einkauf.',
          unterzeile: 'Listen mit Preisen je Filiale. Summen sind Schätzungen; ins Haushaltsbuch kommt erst, was du beim Abschließen bestätigst.',
          aktionen: [
            FilledButton.icon(key: const Key('liste-neu'), onPressed: () => listeBearbeiten(context, ref, null), icon: const Icon(Icons.add, size: 18), label: const Text('Liste')),
            OutlinedButton(key: const Key('filiale-neu'), onPressed: () => filialeBearbeiten(context, ref, null), child: const Text('Filiale')),
          ],
        ),
        const SizedBox(height: 22),
        Karte(
          titel: 'Listen',
          child: listen.isEmpty
              ? const Leer('Noch keine Einkaufsliste.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, l) in listen.indexed)
                      Builder(builder: (context) {
                        final posten = b.postenVon(l.id);
                        final s = ListenSchaetzung(posten, b.preise.values, b.filialen, l.filialeId);
                        final filiale = b.filialen[l.filialeId];
                        return Zeile(
                          key: Key('liste-${l.name}'),
                          ersteZeile: i == 0,
                          vorne: Icon(Icons.shopping_cart_outlined, size: 20, color: f.gedaempft),
                          titel: l.name,
                          unter: [
                            filiale?.anzeige ?? 'ohne Filiale',
                            '${posten.length} offen',
                            if (posten.isNotEmpty) '≈ ${euro(s.summeCent)}${s.ohnePreis > 0 ? ' + ${s.ohnePreis} ohne Preis' : ''}',
                          ].join(' · '),
                          rechtsWidget: l.raum == null ? null : RaumMarke(raumId: l.raum),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ListeSeite(listeId: l.id))),
                        );
                      }),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        Karte(
          titel: 'Filialen',
          child: filialen.isEmpty
              ? const Leer('Noch keine Filiale. Zwei Filialen derselben Kette bleiben getrennt – Preise gelten je Filiale.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, x) in filialen.indexed)
                      Zeile(
                        key: Key('filiale-${x.name}'),
                        ersteZeile: i == 0,
                        vorne: Icon(x.hatPosition ? Icons.place_outlined : Icons.storefront_outlined, size: 20, color: f.gedaempft),
                        titel: x.anzeige,
                        unter: [
                          if (x.region != null) 'Region ${x.region}',
                          '${b.preise.values.where((p) => p.filialeId == x.id).length} Preise',
                          if (x.hatPosition) 'Position gespeichert',
                        ].join(' · '),
                        rechtsWidget: x.raum == null ? null : RaumMarke(raumId: x.raum),
                        onTap: nurLesen(ref, x.raum) ? null : () => filialeBearbeiten(context, ref, x),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Eine Liste: Posten mit Preis aus der gewählten Filiale, abhaken,
/// Preise erfassen, Einkauf abschließen.
class ListeSeite extends ConsumerWidget {
  const ListeSeite({super.key, required this.listeId});
  final String listeId;

  Future<void> _naechsteFiliale(BuildContext context, WidgetRef ref, Einkaufsliste l) async {
    try {
      final pos = await ref.read(standortProvider).holen();
      final b = ref.read(bestandProvider);
      Filiale? beste;
      var abstand = double.infinity;
      for (final x in b.filialen.values) {
        if (!x.hatPosition) continue;
        final d = entfernungMeter(pos.breite, pos.laenge, x.breite!, x.laenge!);
        if (d < abstand) {
          abstand = d;
          beste = x;
        }
      }
      if (beste == null) {
        if (context.mounted) meldung(context, 'Keine Filiale mit gespeicherter Position.', fehler: true);
        return;
      }
      await ref.read(sitzungProvider.notifier).speichereListe(l.kopie(filialeId: () => beste!.id));
      if (context.mounted) meldung(context, 'Nächste Filiale: ${beste.anzeige} (${(abstand / 1000).toStringAsFixed(1).replaceAll('.', ',')} km).');
    } on StandortFehler catch (e) {
      if (context.mounted) meldung(context, e.meldung, fehler: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(bestandProvider);
    final l = b.einkaufslisten[listeId];
    final f = context.farben;
    if (l == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Diese Liste gibt es nicht mehr.')));
    }
    final gesperrt = nurLesen(ref, l.raum);
    final posten = b.postenVon(l.id);
    final s = ListenSchaetzung(posten, b.preise.values, b.filialen, l.filialeId);
    final imWagen = posten.where((p) => p.abgehakt).toList();
    final wagen = ListenSchaetzung(imWagen, b.preise.values, b.filialen, l.filialeId);
    final filiale = b.filialen[l.filialeId];

    return Scaffold(
      backgroundColor: f.flaeche,
      appBar: AppBar(
        backgroundColor: f.flaeche,
        surfaceTintColor: Colors.transparent,
        title: Text(l.name),
        actions: [
          if (!gesperrt) IconButton(key: const Key('liste-bearbeiten'), tooltip: 'Liste bearbeiten', onPressed: () => listeBearbeiten(context, ref, l), icon: const Icon(Icons.edit_outlined)),
        ],
      ),
      floatingActionButton: gesperrt
          ? null
          : FloatingActionButton.extended(
              key: const Key('posten-neu'),
              onPressed: () => postenBearbeiten(context, ref, l, null),
              icon: const Icon(Icons.add),
              label: const Text('Posten'),
            ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (gesperrt) const Padding(padding: EdgeInsets.only(bottom: 12), child: Hinweis(text: 'Mit dir nur zum Lesen geteilt.')),
                    Karte(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(filiale?.anzeige ?? 'Keine Filiale gewählt', key: const Key('liste-filiale'), style: const TextStyle(fontWeight: FontWeight.w600))),
                              if (!gesperrt)
                                TextButton.icon(
                                  key: const Key('naechste-filiale'),
                                  onPressed: () => _naechsteFiliale(context, ref, l),
                                  icon: const Icon(Icons.near_me_outlined, size: 18),
                                  label: const Text('Nächste'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            posten.isEmpty
                                ? 'Die Liste ist leer.'
                                : 'Geschätzt ${euro(s.summeCent)}'
                                    '${s.ohnePreis > 0 ? ' · ${s.ohnePreis} Posten ohne Preis (nicht mitgezählt)' : ''}'
                                    '${s.geschaetzt > 0 ? ' · ${s.geschaetzt} mit Preis aus anderer Filiale' : ''}',
                            key: const Key('liste-summe'),
                            style: TextStyle(color: f.gedaempft),
                          ),
                          if (imWagen.isNotEmpty && !gesperrt) ...[
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              key: const Key('einkauf-abschliessen'),
                              onPressed: () => einkaufAbschliessen(context, ref, l, wagen),
                              icon: const Icon(Icons.receipt_long_outlined, size: 18),
                              label: Text('Einkauf abschließen (${imWagen.length})'),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Karte(
                      child: posten.isEmpty
                          ? const Leer('Noch nichts auf der Liste.')
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final (i, p) in posten.indexed)
                                  Zeile(
                                    key: Key('posten-${p.name}'),
                                    ersteZeile: i == 0,
                                    vorne: SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: IconButton(
                                        key: Key('posten-haken-${p.name}'),
                                        padding: EdgeInsets.zero,
                                        iconSize: 20,
                                        tooltip: p.abgehakt ? 'Wieder offen' : 'In den Wagen',
                                        onPressed: gesperrt ? null : () => ref.read(sitzungProvider.notifier).speicherePosten(p.kopie(abgehakt: !p.abgehakt)),
                                        icon: Icon(p.abgehakt ? Icons.check_circle : Icons.radio_button_unchecked, color: p.abgehakt ? f.leise : f.meterFuellung),
                                      ),
                                    ),
                                    titel: '${p.name}${p.variante == null ? '' : ' (${p.variante})'}',
                                    titelStil: p.abgehakt ? TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: f.leise, decoration: TextDecoration.lineThrough) : null,
                                    unter: '${mengeText(p.menge, p.einheit)} · ${_herkunftText(s.werte[p.id]!, b.filialen)}',
                                    onTap: gesperrt ? null : () => postenBearbeiten(context, ref, l, p),
                                  ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _dialog(BuildContext context, Widget kind) => showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: kind),
      ),
    );

Future<void> listeBearbeiten(BuildContext context, WidgetRef ref, Einkaufsliste? l) => _dialog(context, _ListeFormular(liste: l));

class _ListeFormular extends ConsumerStatefulWidget {
  const _ListeFormular({this.liste});
  final Einkaufsliste? liste;
  @override
  ConsumerState<_ListeFormular> createState() => _ListeFormularState();
}

class _ListeFormularState extends ConsumerState<_ListeFormular> {
  late final _name = TextEditingController(text: widget.liste?.name);
  late String? _filiale = widget.liste?.filialeId;
  late String? _raum = widget.liste?.raum;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _speichern() async {
    if (_name.text.trim().isEmpty) return;
    final s = ref.read(sitzungProvider.notifier);
    final l = (widget.liste ?? Einkaufsliste(id: s.neueId(), name: '', geaendert: DateTime.now().toUtc()))
        .kopie(name: _name.text.trim(), filialeId: () => _filiale, raum: () => _raum);
    await s.speichereListe(l);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _loeschen() async {
    final l = widget.liste!;
    if (!await bestaetigen(context, titel: 'Liste löschen?', text: '„${l.name}“ und ihre offenen Posten werden gelöscht. Abgeschlossene Einkäufe und Buchungen bleiben.')) return;
    await ref.read(sitzungProvider.notifier).loescheListe(l.id);
    if (mounted) {
      Navigator.of(context)
        ..pop()
        ..maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final filialen = ref.watch(bestandProvider).filialen.values.toList()..sort((a, c) => a.anzeige.compareTo(c.anzeige));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.liste == null ? 'Neue Einkaufsliste' : 'Liste bearbeiten', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 18),
          TextField(key: const Key('liste-name'), controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            key: const Key('liste-filiale-wahl'),
            initialValue: filialen.any((x) => x.id == _filiale) ? _filiale : null,
            decoration: const InputDecoration(labelText: 'Filiale'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Keine')),
              for (final x in filialen) DropdownMenuItem(value: x.id, child: Text(x.anzeige)),
            ],
            onChanged: (v) => setState(() => _filiale = v),
          ),
          const SizedBox(height: 12),
          RaumAuswahl(art: RaumArt.einkauf, wert: _raum, onChanged: (v) => setState(() => _raum = v), bezeichnung: 'Teilen'),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              if (widget.liste != null) TextButton(key: const Key('liste-loeschen'), onPressed: _loeschen, child: const Text('Löschen')),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
              FilledButton(key: const Key('liste-speichern'), onPressed: _speichern, child: const Text('Speichern')),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> postenBearbeiten(BuildContext context, WidgetRef ref, Einkaufsliste l, Posten? p) => _dialog(context, _PostenFormular(liste: l, posten: p));

class _PostenFormular extends ConsumerStatefulWidget {
  const _PostenFormular({required this.liste, this.posten});
  final Einkaufsliste liste;
  final Posten? posten;
  @override
  ConsumerState<_PostenFormular> createState() => _PostenFormularState();
}

class _PostenFormularState extends ConsumerState<_PostenFormular> {
  late final _name = TextEditingController(text: widget.posten?.name);
  late final _variante = TextEditingController(text: widget.posten?.variante);
  late final _menge = TextEditingController(text: widget.posten == null ? '1' : mengeText(widget.posten!.menge, Einheit.stueck).split(' ').first);
  late Einheit _einheit = widget.posten?.einheit ?? Einheit.stueck;
  String? _fehler;

  @override
  void dispose() {
    _name.dispose();
    _variante.dispose();
    _menge.dispose();
    super.dispose();
  }

  Posten? _bauen() {
    final menge = mengeAusText(_menge.text);
    if (_name.text.trim().isEmpty || menge == null) {
      setState(() => _fehler = 'Bitte Name und eine Menge über 0 angeben.');
      return null;
    }
    final s = ref.read(sitzungProvider.notifier);
    final v = _variante.text.trim();
    return (widget.posten ?? Posten(id: s.neueId(), listeId: widget.liste.id, name: '', geaendert: DateTime.now().toUtc()))
        .kopie(name: _name.text.trim(), variante: () => v.isEmpty ? null : v, menge: menge, einheit: _einheit);
  }

  Future<void> _speichern() async {
    final p = _bauen();
    if (p == null) return;
    await ref.read(sitzungProvider.notifier).speicherePosten(p);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _preis() async {
    final p = _bauen();
    if (p == null) return;
    await ref.read(sitzungProvider.notifier).speicherePosten(p);
    if (!mounted) return;
    Navigator.pop(context);
    await preisErfassen(context, ref, widget.liste, p);
  }

  @override
  Widget build(BuildContext context) {
    final b = ref.watch(bestandProvider);
    final p = widget.posten;
    final w = p == null ? null : bewerten(p, b.preise.values, b.filialen, widget.liste.filialeId);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(p == null ? 'Neuer Posten' : 'Posten bearbeiten', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 18),
          TextField(key: const Key('posten-name'), controller: _name, autofocus: p == null, decoration: const InputDecoration(labelText: 'Was?')),
          const SizedBox(height: 12),
          TextField(key: const Key('posten-variante'), controller: _variante, decoration: const InputDecoration(labelText: 'Variante (optional, z. B. Bio, laktosefrei)')),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: TextField(key: const Key('posten-menge'), controller: _menge, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Menge'))),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<Einheit>(
                  key: const Key('posten-einheit'),
                  initialValue: _einheit,
                  decoration: const InputDecoration(labelText: 'Einheit'),
                  items: [for (final e in Einheit.values) DropdownMenuItem(value: e, child: Text(e.kurz))],
                  onChanged: (e) => setState(() => _einheit = e!),
                ),
              ),
            ],
          ),
          if (w != null) ...[
            const SizedBox(height: 12),
            Text(_herkunftText(w, b.filialen), key: const Key('posten-preis-info')),
            if (w.preis?.grundpreisCent != null) Text('Grundpreis ${euro(w.preis!.grundpreisCent!)} je ${w.preis!.packungsEinheit.grundpreisEinheit}'),
          ],
          if (_fehler != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_fehler!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (p != null)
                TextButton(
                  key: const Key('posten-loeschen'),
                  onPressed: () async {
                    await ref.read(sitzungProvider.notifier).loeschePosten(p.id);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Löschen'),
                ),
              OutlinedButton(key: const Key('posten-preis'), onPressed: _preis, child: const Text('Preis erfassen …')),
              FilledButton(key: const Key('posten-speichern'), onPressed: _speichern, child: const Text('Speichern')),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> preisErfassen(BuildContext context, WidgetRef ref, Einkaufsliste l, Posten p) => _dialog(context, _PreisFormular(liste: l, posten: p));

class _PreisFormular extends ConsumerStatefulWidget {
  const _PreisFormular({required this.liste, required this.posten});
  final Einkaufsliste liste;
  final Posten posten;
  @override
  ConsumerState<_PreisFormular> createState() => _PreisFormularState();
}

class _PreisFormularState extends ConsumerState<_PreisFormular> {
  final _preis = TextEditingController();
  final _menge = TextEditingController(text: '1');
  late Einheit _einheit = widget.posten.einheit == Einheit.packung ? Einheit.stueck : widget.posten.einheit;
  late String? _filiale = widget.liste.filialeId;
  DateTime _datum = tagVon(DateTime.now());
  String? _fehler;

  @override
  void dispose() {
    _preis.dispose();
    _menge.dispose();
    super.dispose();
  }

  Preis? get _entwurf {
    final cent = centAusText(_preis.text);
    final menge = mengeAusText(_menge.text);
    if (cent == null || cent <= 0 || menge == null || _filiale == null) return null;
    return Preis(
      id: ref.read(sitzungProvider.notifier).neueId(),
      artikel: widget.posten.name,
      variante: widget.posten.variante,
      filialeId: _filiale!,
      packungsPreisCent: cent,
      packungsMenge: menge,
      packungsEinheit: _einheit,
      datum: _datum,
      geaendert: DateTime.now().toUtc(),
      raum: widget.liste.raum,
    );
  }

  Future<void> _speichern() async {
    final p = _entwurf;
    if (p == null) {
      setState(() => _fehler = 'Bitte Filiale, Preis (z. B. 1,29) und Packungsgröße angeben.');
      return;
    }
    await ref.read(sitzungProvider.notifier).speicherePreis(p);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final b = ref.watch(bestandProvider);
    // Nur Filialen am selben Ort wie die Liste (privat bzw. derselbe Raum).
    final filialen = b.filialen.values.where((x) => x.raum == widget.liste.raum).toList()..sort((a, c) => a.anzeige.compareTo(c.anzeige));
    final e = _entwurf;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Preis für ${widget.posten.name}', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 18),
          DropdownButtonFormField<String?>(
            key: const Key('preis-filiale'),
            initialValue: filialen.any((x) => x.id == _filiale) ? _filiale : null,
            decoration: const InputDecoration(labelText: 'Filiale'),
            items: [for (final x in filialen) DropdownMenuItem(value: x.id, child: Text(x.anzeige))],
            onChanged: (v) => setState(() => _filiale = v),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('preis-betrag'),
            controller: _preis,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Preis je Packung', suffixText: '€'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('preis-menge'),
                  controller: _menge,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'Packungsgröße'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<Einheit>(
                  key: const Key('preis-einheit'),
                  initialValue: _einheit,
                  decoration: const InputDecoration(labelText: 'Einheit'),
                  items: [for (final x in Einheit.values) if (x != Einheit.packung) DropdownMenuItem(value: x, child: Text(x.kurz))],
                  onChanged: (x) => setState(() => _einheit = x!),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Text('Gesehen am ${datumKurz(_datum)}')),
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(context: context, initialDate: _datum, firstDate: DateTime(2000), lastDate: DateTime.now());
                  if (d != null) setState(() => _datum = d);
                },
                child: const Text('Ändern'),
              ),
            ],
          ),
          if (e?.grundpreisCent != null) Text('Grundpreis ${euro(e!.grundpreisCent!)} je ${e.packungsEinheit.grundpreisEinheit}', key: const Key('preis-grundpreis')),
          if (filialen.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Lege zuerst eine Filiale an.')),
          if (_fehler != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_fehler!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
              FilledButton(key: const Key('preis-speichern'), onPressed: _speichern, child: const Text('Speichern')),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> filialeBearbeiten(BuildContext context, WidgetRef ref, Filiale? f) => _dialog(context, _FilialeFormular(filiale: f));

class _FilialeFormular extends ConsumerStatefulWidget {
  const _FilialeFormular({this.filiale});
  final Filiale? filiale;
  @override
  ConsumerState<_FilialeFormular> createState() => _FilialeFormularState();
}

class _FilialeFormularState extends ConsumerState<_FilialeFormular> {
  late final _kette = TextEditingController(text: widget.filiale?.kette);
  late final _name = TextEditingController(text: widget.filiale?.name);
  late final _region = TextEditingController(text: widget.filiale?.region);
  late double? _breite = widget.filiale?.breite;
  late double? _laenge = widget.filiale?.laenge;
  bool _sucht = false;

  @override
  void dispose() {
    _kette.dispose();
    _name.dispose();
    _region.dispose();
    super.dispose();
  }

  Future<void> _position() async {
    setState(() => _sucht = true);
    try {
      final p = await ref.read(standortProvider).holen();
      setState(() {
        _breite = p.breite;
        _laenge = p.laenge;
      });
    } on StandortFehler catch (e) {
      if (mounted) meldung(context, e.meldung, fehler: true);
    } catch (e) {
      if (mounted) meldung(context, 'Position nicht verfügbar: $e', fehler: true);
    } finally {
      if (mounted) setState(() => _sucht = false);
    }
  }

  Future<void> _speichern() async {
    if (_kette.text.trim().isEmpty || _name.text.trim().isEmpty) return;
    final s = ref.read(sitzungProvider.notifier);
    final r = _region.text.trim();
    final f = (widget.filiale ?? Filiale(id: s.neueId(), kette: '', name: '', geaendert: DateTime.now().toUtc()))
        .kopie(kette: _kette.text.trim(), name: _name.text.trim(), region: () => r.isEmpty ? null : r, breite: () => _breite, laenge: () => _laenge);
    await s.speichereFiliale(f);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _loeschen() async {
    final f = widget.filiale!;
    if (!await bestaetigen(context, titel: 'Filiale löschen?', text: '„${f.anzeige}“ und ihre Preise werden gelöscht.')) return;
    await ref.read(sitzungProvider.notifier).loescheFiliale(f.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.filiale == null ? 'Neue Filiale' : 'Filiale bearbeiten', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 18),
            TextField(key: const Key('filiale-kette'), controller: _kette, autofocus: widget.filiale == null, decoration: const InputDecoration(labelText: 'Kette, z. B. Aldi Süd')),
            const SizedBox(height: 12),
            TextField(key: const Key('filiale-name'), controller: _name, decoration: const InputDecoration(labelText: 'Filiale, z. B. Hauptstraße')),
            const SizedBox(height: 12),
            TextField(key: const Key('filiale-region'), controller: _region, decoration: const InputDecoration(labelText: 'Region (optional)', helperText: 'Preise anderer Filialen derselben Region dienen als Schätzung.')),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _breite == null ? 'Keine Position gespeichert.' : 'Position: ${_breite!.toStringAsFixed(5)}, ${_laenge!.toStringAsFixed(5)}',
                    key: const Key('filiale-position'),
                  ),
                ),
                if (_breite != null) IconButton(tooltip: 'Position entfernen', onPressed: () => setState(() => _breite = _laenge = null), icon: const Icon(Icons.close, size: 18)),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('filiale-hier'),
                onPressed: _sucht ? null : _position,
                icon: const Icon(Icons.my_location, size: 18),
                label: Text(_sucht ? 'Position wird bestimmt …' : 'Ich bin gerade hier'),
              ),
            ),
            const Text('Die Position wird nur auf Knopfdruck bestimmt und verschlüsselt gespeichert – ohne Kartendienst.', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 18),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                if (widget.filiale != null) TextButton(key: const Key('filiale-loeschen'), onPressed: _loeschen, child: const Text('Löschen')),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
                FilledButton(key: const Key('filiale-speichern'), onPressed: _speichern, child: const Text('Speichern')),
              ],
            ),
          ],
        ),
      );
}

Future<void> einkaufAbschliessen(BuildContext context, WidgetRef ref, Einkaufsliste l, ListenSchaetzung wagen) =>
    _dialog(context, _AbschlussFormular(liste: l, wagen: wagen));

class _AbschlussFormular extends ConsumerStatefulWidget {
  const _AbschlussFormular({required this.liste, required this.wagen});
  final Einkaufsliste liste;
  final ListenSchaetzung wagen;
  @override
  ConsumerState<_AbschlussFormular> createState() => _AbschlussFormularState();
}

class _AbschlussFormularState extends ConsumerState<_AbschlussFormular> {
  late final _betrag = TextEditingController(text: widget.wagen.summeCent > 0 ? centAlsText(widget.wagen.summeCent) : '');
  String? _konto;
  DateTime _datum = tagVon(DateTime.now());
  String? _fehler;

  @override
  void dispose() {
    _betrag.dispose();
    super.dispose();
  }

  Future<void> _ok() async {
    final cent = centAusText(_betrag.text);
    if (cent == null || cent <= 0 || _konto == null) {
      setState(() => _fehler = 'Bitte den bezahlten Betrag und ein Konto angeben.');
      return;
    }
    await ref.read(sitzungProvider.notifier).einkaufAbschliessen(
          listeId: widget.liste.id,
          betragCent: cent,
          kontoId: _konto!,
          datum: _datum,
          geschaetztCent: widget.wagen.vollstaendig ? widget.wagen.summeCent : null,
        );
    if (mounted) {
      Navigator.pop(context);
      meldung(context, 'Gebucht: ${euro(-cent)} im Haushaltsbuch.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final konten = ref.watch(bestandProvider).kontenSortiert.where((k) => !k.archiviert).toList();
    final w = widget.wagen;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Einkauf abschließen', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            w.vollstaendig
                ? 'Geschätzt aus den Preisen: ${euro(w.summeCent)}. Trage ein, was du laut Kassenbon bezahlt hast.'
                : 'Für ${w.ohnePreis} Posten fehlt ein Preis; die Schätzung (${euro(w.summeCent)}) ist unvollständig.',
            key: const Key('abschluss-hinweis'),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('abschluss-betrag'),
            controller: _betrag,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Bezahlt', suffixText: '€'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key('abschluss-konto'),
            initialValue: _konto,
            decoration: const InputDecoration(labelText: 'Von Konto'),
            items: [for (final k in konten) DropdownMenuItem(value: k.id, child: Text('${k.name} · ${k.art.bezeichnung}'))],
            onChanged: (v) => setState(() => _konto = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Text('Am ${datumKurz(_datum)}')),
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(context: context, initialDate: _datum, firstDate: DateTime(2000), lastDate: DateTime(2100));
                  if (d != null) setState(() => _datum = d);
                },
                child: const Text('Ändern'),
              ),
            ],
          ),
          const Text('Daraus wird genau eine Buchung in deinem Haushaltsbuch. Die abgehakten Posten verschwinden von der Liste.', style: TextStyle(fontSize: 12)),
          if (_fehler != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_fehler!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
              FilledButton(key: const Key('abschluss-ok'), onPressed: _ok, child: const Text('Buchen')),
            ],
          ),
        ],
      ),
    );
  }
}
