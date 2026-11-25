import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/regionen/regionen.dart';

/// Region aus der festen Liste wählen (M10): Landkreis oder kreisfreie
/// Stadt, suchbar nach Name, Kfz-Kennzeichen, Postleitzahl und Ort.
Future<Kreis?> regionWaehlen(BuildContext context, Regionen r, {String start = ''}) => showDialog<Kreis>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600), child: _RegionSuche(regionen: r, start: start)),
      ),
    );

class _RegionSuche extends StatefulWidget {
  const _RegionSuche({required this.regionen, required this.start});
  final Regionen regionen;
  final String start;
  @override
  State<_RegionSuche> createState() => _RegionSucheState();
}

class _RegionSucheState extends State<_RegionSuche> {
  late final _suche = TextEditingController(text: widget.start);

  @override
  void dispose() {
    _suche.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _suche.text;
    final treffer = widget.regionen.suchen(text);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Region wählen', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          const Text('Landkreis oder kreisfreie Stadt. So meinen alle dieselbe Region.', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 14),
          TextField(
            key: const Key('region-suche'),
            controller: _suche,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Name, Kfz-Kennzeichen, PLZ oder Ort', prefixIcon: Icon(Icons.search)),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: text.trim().isEmpty
                ? const Padding(padding: EdgeInsets.all(12), child: Text('Zum Beispiel „NWM“, „Wismar“ oder „23966“.'))
                : treffer.isEmpty
                    ? const Padding(padding: EdgeInsets.all(12), child: Text('Nichts gefunden.'))
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final k in treffer)
                            ListTile(
                              key: Key('region-${k.schluessel}'),
                              title: Text(k.name),
                              subtitle: Text([
                                '${k.art} · ${k.land}',
                                'Kfz ${k.kfz.join(', ')}',
                                if (widget.regionen.orteIn(k.schluessel, text).isNotEmpty) 'mit ${widget.regionen.orteIn(k.schluessel, text).join(', ')}',
                              ].join(' · ')),
                              onTap: () => Navigator.pop(context, k),
                            ),
                        ],
                      ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Kreise und Orte: © Statistisches Bundesamt (Destatis), dl-de/by-2-0 · Postleitzahlen: GeoNames, CC BY 4.0 · Kfz-Kennzeichen: Wikipedia',
            key: Key('region-quellen'),
            style: TextStyle(fontSize: 11),
          ),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen'))),
        ],
      ),
    );
  }
}

/// Kette mit Vorschlägen aus der festen Liste. Ein anderer Name bleibt
/// möglich (z. B. der Dorfladen), wird aber nicht veröffentlicht.
class KettenFeld extends ConsumerStatefulWidget {
  const KettenFeld({super.key, required this.controller, required this.onGewaehlt, this.autofocus = false});
  final TextEditingController controller;
  final ValueChanged<Kette> onGewaehlt;
  final bool autofocus;
  @override
  ConsumerState<KettenFeld> createState() => _KettenFeldState();
}

class _KettenFeldState extends ConsumerState<KettenFeld> {
  final _fokus = FocusNode();

  @override
  void dispose() {
    _fokus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = ref.watch(regionenProvider).value;
    return RawAutocomplete<Kette>(
      textEditingController: widget.controller,
      focusNode: _fokus,
      optionsBuilder: (v) => r == null || v.text.trim().isEmpty ? const <Kette>[] : r.kettenSuchen(v.text),
      displayStringForOption: (k) => k.name,
      onSelected: widget.onGewaehlt,
      fieldViewBuilder: (context, c, fokus, absenden) => TextField(
        key: const Key('filiale-kette'),
        controller: c,
        focusNode: fokus,
        autofocus: widget.autofocus,
        onSubmitted: (_) => absenden(),
        decoration: const InputDecoration(labelText: 'Kette, z. B. Aldi Süd', helperText: 'Aus der Liste wählen; andere Läden bleiben privat.'),
      ),
      optionsViewBuilder: (context, waehlen, optionen) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240, maxWidth: 420),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [for (final k in optionen) ListTile(key: Key('kette-${k.schluessel}'), dense: true, title: Text(k.name), onTap: () => waehlen(k))],
            ),
          ),
        ),
      ),
    );
  }
}
