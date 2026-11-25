import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/raeume/raum.dart';
import '../../core/sitzung.dart';
import '../bausteine.dart';

/// Raum eines Eintrags, falls er geteilt ist.
Raum? raumVon(WidgetRef ref, String? id) => id == null ? null : ref.watch(bestandProvider).raeume[id];

/// Geteilt und nur lesbar: nicht bearbeiten.
bool nurLesen(WidgetRef ref, String? raumId) => raumVon(ref, raumId)?.schreibbar == false;

/// Auswahl „Privat“ oder ein geteilter Kalender bzw. eine geteilte Liste
/// (nur solche mit Schreibrecht). Ohne passende Freigaben unsichtbar.
class RaumAuswahl extends ConsumerWidget {
  const RaumAuswahl({super.key, required this.art, required this.wert, required this.onChanged, required this.bezeichnung});

  final RaumArt art;
  final String? wert;
  final ValueChanged<String?> onChanged;
  final String bezeichnung;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final raeume = [for (final r in ref.watch(bestandProvider).raeumeDerArt(art)) if (r.schreibbar) r];
    if (raeume.isEmpty && wert == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String?>(
        key: Key('raum-auswahl-${art.name}'),
        initialValue: raeume.any((r) => r.id == wert) ? wert : null,
        decoration: InputDecoration(labelText: bezeichnung),
        items: [
          const DropdownMenuItem(value: null, child: Text('Privat')),
          for (final r in raeume) DropdownMenuItem(value: r.id, child: Text(r.eigen ? '${r.name} (geteilt)' : '${r.name} (von ${r.von})')),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// Kleines Kennzeichen „geteilt“ / „nur lesen“ an Einträgen.
class RaumMarke extends ConsumerWidget {
  const RaumMarke({super.key, required this.raumId});
  final String? raumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = raumVon(ref, raumId);
    if (r == null) return const SizedBox.shrink();
    return Marke(r.schreibbar ? r.name : '${r.name} · nur lesen');
  }
}
