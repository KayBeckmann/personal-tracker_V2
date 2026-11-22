import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/modell/notiz.dart';
import '../../core/sitzung.dart';
import '../bausteine.dart';
import '../format.dart';
import '../thema.dart';
import 'notiz_editor.dart';

class NotizenSeite extends ConsumerStatefulWidget {
  const NotizenSeite({super.key});

  @override
  ConsumerState<NotizenSeite> createState() => _NotizenSeiteState();
}

class _NotizenSeiteState extends ConsumerState<NotizenSeite> {
  final _suche = TextEditingController();

  @override
  void dispose() {
    _suche.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final alle = ref.watch(bestandProvider).notizenNeuesteZuerst;
    final treffer = alle.where((n) => n.passtZu(_suche.text)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Seitenkopf(
          oberzeile: '${alle.length} ${alle.length == 1 ? 'Notiz' : 'Notizen'} · Markdown',
          titel: 'Notizen.',
          unterzeile: 'Gedanken in offenem Format, verschlüsselt auf diesem Gerät.',
          aktionen: [
            FilledButton.icon(key: const Key('notiz-neu'), onPressed: () => notizOeffnen(context, null), icon: const Icon(Icons.add, size: 18), label: const Text('Notiz')),
          ],
        ),
        const SizedBox(height: 24),
        TextField(
          key: const Key('notiz-suche'),
          controller: _suche,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: 'In Titel und Text suchen',
            suffixIcon: _suche.text.isEmpty
                ? null
                : IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(_suche.clear)),
          ),
        ),
        const SizedBox(height: 18),
        Karte(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (alle.isEmpty)
                const Leer('Noch keine Notizen. „Notiz“ oben legt die erste an — Überschriften mit #, Listen mit -.')
              else if (treffer.isEmpty)
                const Leer('Keine Notiz passt zur Suche.'),
              for (final (i, n) in treffer.indexed) _NotizZeile(notiz: n, erste: i == 0),
            ],
          ),
        ),
      ],
    );
  }
}

class _NotizZeile extends StatelessWidget {
  const _NotizZeile({required this.notiz, required this.erste});
  final Notiz notiz;
  final bool erste;

  @override
  Widget build(BuildContext context) {
    final vorschau = notiz.text
        .split('\n')
        .map((z) => z.replaceFirst(RegExp(r'^[#>\-*\s]+'), '').trim())
        .where((z) => z.isNotEmpty && z != notiz.anzeigeTitel)
        .take(2)
        .join(' · ');
    return Zeile(
      key: Key('notiz-${notiz.id}'),
      ersteZeile: erste,
      vorne: Icon(Icons.description_outlined, size: 18, color: context.farben.leise),
      titel: notiz.anzeigeTitel,
      unter: vorschau.length > 110 ? '${vorschau.substring(0, 110)}…' : vorschau,
      rechts: datumKurz(notiz.geaendert.toLocal()),
      onTap: () => notizOeffnen(context, notiz),
    );
  }
}
