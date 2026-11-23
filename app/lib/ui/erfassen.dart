import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/sitzung.dart';
import 'aufgaben/aufgabe_formular.dart';
import 'bausteine.dart';
import 'finanzen/formulare.dart';
import 'notizen/notiz_editor.dart';
import 'termine/termin_formular.dart';
import 'thema.dart';

/// Zentrale Schnellerfassung („＋ Erfassen“): klar unterscheidbare
/// Aktionen statt eines Kategorienzwangs.
Future<void> erfassen(BuildContext context, WidgetRef ref) async {
  final wahl = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    // Fünf Einträge: auf kleinen Handys scrollbar statt abgeschnitten.
    isScrollControlled: true,
    builder: (ctx) {
      Widget eintrag(String id, IconData icon, String titel, String text) => ListTile(
            key: Key('erfassen-$id'),
            leading: CircleAvatar(
              backgroundColor: ctx.farben.tagHg,
              child: Icon(icon, color: ctx.farben.tagText, size: 20),
            ),
            title: Text(titel, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(text),
            onTap: () => Navigator.pop(ctx, id),
          );
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              eintrag('termin', Icons.calendar_today_outlined, 'Termin', 'Mit Uhrzeit oder ganztägig, auch wiederkehrend'),
              eintrag('aufgabe', Icons.task_alt, 'Aufgabe', 'Mit Fälligkeit und Wichtigkeit, auf Wunsch wiederkehrend'),
              eintrag('notiz', Icons.notes_outlined, 'Notiz', 'Markdown, nur auf diesem Gerät'),
              eintrag('ausgabe', Icons.remove_circle_outline, 'Ausgabe oder Einnahme', 'Gebucht oder geplant'),
              eintrag('umbuchung', Icons.swap_horiz, 'Umbuchung', 'Zwischen zwei eigenen Konten'),
            ],
          ),
        ),
      );
    },
  );
  if (wahl == null || !context.mounted) return;
  switch (wahl) {
    case 'termin':
      await terminBearbeiten(context, ref);
    case 'aufgabe':
      await aufgabeBearbeiten(context, ref);
    case 'notiz':
      await notizOeffnen(context, null);
    case 'ausgabe':
      if (_kontenDa(context, ref)) await buchungBearbeiten(context, ref);
    case 'umbuchung':
      if (ref.read(bestandProvider).konten.values.where((k) => !k.archiviert).length < 2) {
        meldung(context, 'Für eine Umbuchung braucht es zwei Konten — zuerst im Haushaltsbuch anlegen.');
      } else {
        await umbuchungBearbeiten(context, ref);
      }
  }
}

bool _kontenDa(BuildContext context, WidgetRef ref) {
  if (ref.read(bestandProvider).konten.values.any((k) => !k.archiviert)) return true;
  meldung(context, 'Zuerst im Haushaltsbuch ein Konto anlegen (z. B. Girokonto oder Bargeld).');
  return false;
}
