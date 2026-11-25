import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/raeume/raum.dart';
import '../../core/raeume/raum_dienst.dart';
import '../../core/sitzung.dart';
import '../../core/sync/sync_api.dart';
import '../../core/sync/sync_dienst.dart';
import '../bausteine.dart';
import '../format.dart';
import '../thema.dart';

String _rechtText(String r) => switch (r) {
      'schreiben' => 'lesen und schreiben',
      'lesen' => 'nur lesen',
      _ => 'Eigentümer',
    };

/// Freigaben: geteilte Kalender, Aufgabenlisten und Vault-Ordner. Alles ist
/// privat, bis es bewusst geteilt wird; geteilt wird per Einladungscode an
/// bestimmte Personen mit Lese- oder Schreibrecht.
class FreigabenSeite extends ConsumerStatefulWidget {
  const FreigabenSeite({super.key});

  @override
  ConsumerState<FreigabenSeite> createState() => _FreigabenSeiteState();
}

class _FreigabenSeiteState extends ConsumerState<FreigabenSeite> {
  bool _laeuft = false;

  Future<void> _ausfuehren(Future<void> Function() aktion, {String? erfolg}) async {
    setState(() => _laeuft = true);
    try {
      await aktion();
      if (erfolg != null && mounted) meldung(context, erfolg);
    } on RaumFehler catch (e) {
      if (mounted) meldung(context, e.meldung, fehler: true);
    } on SyncFehler catch (e) {
      if (mounted) meldung(context, e.meldung, fehler: true);
    } finally {
      if (mounted) setState(() => _laeuft = false);
    }
  }

  Future<void> _name() async {
    final e = ref.read(bestandProvider).einstellungen;
    final neu = await eingabeDialog<String>(
      context,
      start: [e.anzeigeName ?? ''],
      builder: (ctx, f) => AlertDialog(
        title: const Text('Dein Name für Freigaben'),
        content: TextField(
          key: const Key('freigabe-name-feld'),
          controller: f[0],
          autofocus: true,
          decoration: const InputDecoration(helperText: 'Das sehen die Personen, mit denen du teilst.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(key: const Key('freigabe-name-ok'), onPressed: () => Navigator.pop(ctx, f[0].text.trim()), child: const Text('Speichern')),
        ],
      ),
    );
    if (neu != null && neu.isNotEmpty) await ref.read(sitzungProvider.notifier).speichereEinstellungen(e.kopie(anzeigeName: neu));
  }

  Future<void> _neu() async {
    var art = RaumArt.kalender;
    final ergebnis = await eingabeDialog<({RaumArt art, String name, String ordner})>(
      context,
      start: const ['', ''],
      builder: (ctx, f) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Neue Freigabe'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<RaumArt>(
                  key: const Key('freigabe-art'),
                  initialValue: art,
                  decoration: const InputDecoration(labelText: 'Was teilen?'),
                  items: [for (final a in RaumArt.values) DropdownMenuItem(value: a, child: Text(a.titel))],
                  onChanged: (a) => setState(() => art = a!),
                ),
                const SizedBox(height: 12),
                TextField(key: const Key('freigabe-titel'), controller: f[0], decoration: const InputDecoration(labelText: 'Name, z. B. Familie')),
                if (art == RaumArt.vault) ...[
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('freigabe-ordner'),
                    controller: f[1],
                    decoration: const InputDecoration(
                      labelText: 'Ordner im Vault',
                      helperText: 'Alles darin wird geteilt, auch Unterordner. Private Dateien gehören in einen anderen Ordner.',
                      helperMaxLines: 3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
            FilledButton(
              key: const Key('freigabe-anlegen'),
              onPressed: () => Navigator.pop(ctx, (art: art, name: f[0].text, ordner: f[1].text)),
              child: const Text('Anlegen'),
            ),
          ],
        ),
      ),
    );
    if (ergebnis == null) return;
    await _ausfuehren(
      () => ref.read(raumDienstProvider).anlegen(art: ergebnis.art, name: ergebnis.name, ordner: ergebnis.ordner),
      erfolg: 'Freigabe angelegt. Jetzt Personen einladen.',
    );
  }

  Future<void> _annehmen() async {
    final ergebnis = await eingabeDialog<({String code, String ordner})>(
      context,
      start: const ['', ''],
      builder: (ctx, f) => AlertDialog(
        title: const Text('Einladung annehmen'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('einladung-code'),
                controller: f[0],
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Einladungscode', hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('einladung-ordner'),
                controller: f[1],
                decoration: const InputDecoration(
                  labelText: 'Ordner im Vault (nur bei Vault-Ordnern)',
                  helperText: 'Leer lassen für „Geteilt/<Name>“.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(key: const Key('einladung-ok'), onPressed: () => Navigator.pop(ctx, (code: f[0].text, ordner: f[1].text)), child: const Text('Annehmen')),
        ],
      ),
    );
    if (ergebnis == null) return;
    await _ausfuehren(() async {
      final r = await ref.read(raumDienstProvider).annehmen(ergebnis.code, ordner: ergebnis.ordner);
      if (mounted) meldung(context, '„${r.name}“ von ${r.von} ist jetzt da (${_rechtText(r.recht)}).');
    });
  }

  Future<void> _einladen(Raum r) async {
    final recht = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Person zu „${r.name}“ einladen'),
        children: [
          SimpleDialogOption(key: const Key('einladen-lesen'), onPressed: () => Navigator.pop(ctx, 'lesen'), child: const Text('Darf nur lesen')),
          SimpleDialogOption(key: const Key('einladen-schreiben'), onPressed: () => Navigator.pop(ctx, 'schreiben'), child: const Text('Darf lesen und schreiben')),
        ],
      ),
    );
    if (recht == null) return;
    await _ausfuehren(() async {
      final (:code, :bis) = await ref.read(raumDienstProvider).einladen(r, recht);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Einladungscode'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // SelectableText erscheint sonst nicht für Screenreader.
                Semantics(
                  label: 'Einladungscode ${code.anzeigen()}',
                  container: true,
                  child: ExcludeSemantics(
                    child: SelectableText(
                      code.anzeigen(),
                      key: const Key('einladung-anzeige'),
                      style: const TextStyle(fontFamily: 'NotoSansMono', fontSize: 20, letterSpacing: 1),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Gib den Code persönlich weiter – am besten mündlich oder über einen Messenger mit Ende-zu-Ende-Verschlüsselung, '
                  'nicht per E-Mail. Gültig bis ${datumKurz(bis)} und nur einmal. Wer ihn zuerst eingibt, bekommt Zugriff '
                  '(${_rechtText(recht)}). Danach siehst du den Namen hier und kannst die Person jederzeit wieder entfernen.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: code.anzeigen())), child: const Text('Kopieren')),
            FilledButton(key: const Key('einladung-fertig'), onPressed: () => Navigator.pop(ctx), child: const Text('Fertig')),
          ],
        ),
      );
    });
  }

  Future<void> _entfernen(Raum r, Mitglied m) async {
    if (!await bestaetigen(
      context,
      titel: '${m.name} entfernen?',
      text: '${m.name} bekommt ab sofort nichts Neues mehr aus „${r.name}“, und ein neuer Schlüssel gilt für alles Weitere. '
          'Was schon auf den Geräten von ${m.name} ist, lässt sich nicht zurückholen.',
      ja: 'Entfernen',
    )) {
      return;
    }
    await _ausfuehren(() => ref.read(raumDienstProvider).entfernen(r, m), erfolg: '${m.name} entfernt.');
  }

  Future<void> _verlassen(Raum r) async {
    final ok = await bestaetigen(
      context,
      titel: r.eigen ? 'Freigabe „${r.name}“ beenden?' : 'Aus „${r.name}“ austreten?',
      text: r.eigen
          ? 'Alle Mitglieder verlieren den Zugriff. Deine Einträge bleiben, aber nur noch privat.'
          : 'Die geteilten Einträge verschwinden von deinen Geräten. Zurück kommst du nur mit einer neuen Einladung.',
      ja: r.eigen ? 'Beenden' : 'Austreten',
    );
    if (ok) await _ausfuehren(() => ref.read(raumDienstProvider).verlassen(r));
  }

  @override
  Widget build(BuildContext context) {
    final b = ref.watch(bestandProvider);
    final sync = ref.watch(syncProvider);
    final f = context.farben;
    final eigene = b.raeume.values.where((r) => r.eigen).toList()..sort((a, c) => a.name.compareTo(c.name));
    final fremde = b.raeume.values.where((r) => !r.eigen).toList()..sort((a, c) => a.name.compareTo(c.name));
    final name = b.einstellungen.anzeigeName;
    final klein = TextStyle(fontSize: 13, color: f.gedaempft);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Seitenkopf(
          oberzeile: '${b.raeume.length} ${b.raeume.length == 1 ? 'Freigabe' : 'Freigaben'} · Ende-zu-Ende-verschlüsselt',
          titel: 'Freigaben.',
          unterzeile: 'Alles ist privat, bis du es teilst: Kalender, Aufgabenlisten oder Vault-Ordner, gezielt an bestimmte Personen.',
          aktionen: [
            FilledButton.icon(key: const Key('freigabe-neu'), onPressed: _laeuft || !sync.verbunden ? null : _neu, icon: const Icon(Icons.add, size: 18), label: const Text('Teilen')),
            OutlinedButton(key: const Key('einladung-annehmen'), onPressed: _laeuft || !sync.verbunden ? null : _annehmen, child: const Text('Einladung annehmen')),
          ],
        ),
        const SizedBox(height: 20),
        if (!sync.verbunden)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Hinweis(icon: Icons.cloud_off_outlined, text: 'Freigaben brauchen eine Sync-Verbindung (Speicher & Sicherheit).'),
          ),
        Karte(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name == null || name.isEmpty ? 'Lege fest, unter welchem Namen dich andere sehen.' : 'Andere sehen dich als „$name“.',
                  key: const Key('freigabe-name'),
                ),
              ),
              TextButton(key: const Key('freigabe-name-aendern'), onPressed: _name, child: const Text('Ändern')),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (b.raeume.isEmpty) const Karte(child: Leer('Noch nichts geteilt.')),
        for (final r in eigene)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Karte(
              key: Key('raum-${r.name}'),
              titel: r.name,
              marke: r.art.titel,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (r.ordner != null) Text('Ordner: ${r.ordner}', style: klein),
                  if (r.mitglieder.isEmpty) Text('Noch niemand dabei.', style: klein),
                  for (final m in r.mitglieder)
                    Zeile(
                      key: Key('mitglied-${m.name}'),
                      titel: m.name,
                      unter: _rechtText(m.recht),
                      rechtsWidget: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PopupMenuButton<String>(
                            key: Key('mitglied-recht-${m.name}'),
                            tooltip: 'Recht ändern',
                            onSelected: (x) => _ausfuehren(() => ref.read(raumDienstProvider).rechtAendern(r, m, x)),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'lesen', child: Text('Nur lesen')),
                              PopupMenuItem(value: 'schreiben', child: Text('Lesen und schreiben')),
                            ],
                            child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.tune, size: 18)),
                          ),
                          IconButton(
                            key: Key('mitglied-entfernen-${m.name}'),
                            tooltip: 'Entfernen',
                            onPressed: _laeuft ? null : () => _entfernen(r, m),
                            icon: const Icon(Icons.person_remove_outlined, size: 18),
                          ),
                        ],
                      ),
                    ),
                  if (r.einladungen.isNotEmpty) Text('${r.einladungen.length} offene Einladung(en).', style: klein),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonal(key: Key('einladen-${r.name}'), onPressed: _laeuft ? null : () => _einladen(r), child: const Text('Person einladen')),
                      TextButton(key: Key('beenden-${r.name}'), onPressed: _laeuft ? null : () => _verlassen(r), child: const Text('Freigabe beenden')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (fremde.isNotEmpty) ...[
          Padding(padding: const EdgeInsets.only(top: 6, bottom: 10), child: Text('Mit dir geteilt', style: Theme.of(context).textTheme.titleMedium)),
          for (final r in fremde)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Karte(
                key: Key('raum-${r.name}'),
                titel: r.name,
                marke: r.schreibbar ? r.art.titel : '${r.art.titel} · nur lesen',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Von ${r.von}', style: klein),
                    if (r.ordner != null) Text('In deinem Vault unter ${r.ordner}', style: klein),
                    if (r.mitgliederNamen.isNotEmpty)
                      Text('Dabei: ${r.mitgliederNamen.map((m) => m.name).join(', ')}', style: klein),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(key: Key('austreten-${r.name}'), onPressed: _laeuft ? null : () => _verlassen(r), child: const Text('Austreten')),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}
