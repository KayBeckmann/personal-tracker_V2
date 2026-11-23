import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/krypto/kdf.dart';
import '../../core/sitzung.dart';
import '../../core/speicher/backup.dart';
import '../../version.dart';
import '../bausteine.dart';
import '../dateien.dart';
import '../format.dart';
import '../navigation.dart';
import '../speicherstatus.dart';
import '../thema.dart';
import '../zugang/rahmen.dart';
import '../zugang/wiederherstellen.dart';

class EinstellungenSeite extends ConsumerStatefulWidget {
  const EinstellungenSeite({super.key});

  @override
  ConsumerState<EinstellungenSeite> createState() => _EinstellungenSeiteState();
}

class _EinstellungenSeiteState extends ConsumerState<EinstellungenSeite> {
  bool? _dauerhaft;
  bool _sichert = false;

  @override
  void initState() {
    super.initState();
    speicherDauerhaft().then((v) {
      if (mounted) setState(() => _dauerhaft = v);
    });
  }

  Future<void> _sichern() async {
    setState(() => _sichert = true);
    try {
      final s = ref.read(sitzungProvider.notifier);
      final bytes = s.sicherungErstellen();
      final ok = await ref.read(dateienProvider).speichern(Backup.dateiname(DateTime.now()), bytes);
      if (!ok) return;
      await s.sicherungVermerken();
      if (mounted) {
        meldung(context, kIsWeb
            ? 'Sicherung heruntergeladen. Bitte zusätzlich an einem zweiten Ort aufbewahren.'
            : 'Sicherung gespeichert. Bitte zusätzlich an einem zweiten Ort aufbewahren.');
      }
    } catch (e) {
      if (mounted) meldung(context, 'Sicherung fehlgeschlagen: $e', fehler: true);
    } finally {
      if (mounted) setState(() => _sichert = false);
    }
  }

  Future<void> _einlesen() => Navigator.of(context).push(MaterialPageRoute(
        builder: (ctx) => Scaffold(
          backgroundColor: ctx.farben.flaeche,
          appBar: AppBar(backgroundColor: ctx.farben.flaeche, surfaceTintColor: Colors.transparent),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: WiederherstellenAblauf(
                  neu: false,
                  vorherSichern: _sichern,
                  onAbbrechen: () => Navigator.pop(ctx),
                  onFertig: () {
                    Navigator.pop(ctx);
                    meldung(context, 'Sicherung übernommen.');
                  },
                ),
              ),
            ),
          ),
        ),
      ));

  Future<void> _passwortAendern() async {
    final form = GlobalKey<FormState>();
    String? fehler;
    var arbeitet = false;
    final geaendert = await eingabeDialog<bool>(
      context,
      start: const ['', '', ''],
      builder: (ctx, felder) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Passwort ändern'),
          content: SizedBox(
            width: 400,
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PasswortFeld(key: const Key('pw-alt'), controller: felder[0], label: 'Aktuelles Passwort'),
                  const SizedBox(height: 12),
                  PasswortFeld(key: const Key('pw-neu1'), controller: felder[1], label: 'Neues Passwort', validator: passwortRegel),
                  const SizedBox(height: 12),
                  PasswortFeld(
                    key: const Key('pw-neu2'),
                    controller: felder[2],
                    label: 'Neues Passwort wiederholen',
                    validator: (v) => v != felder[1].text ? 'Die Passwörter sind verschieden.' : null,
                  ),
                  if (fehler != null) Fehlertext(fehler!),
                  if (arbeitet) const Laedt('Wird gespeichert …'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
            FilledButton(
              key: const Key('pw-aendern-ok'),
              onPressed: arbeitet
                  ? null
                  : () async {
                      if (!form.currentState!.validate()) return;
                      setState(() => arbeitet = true);
                      final ok = await ref.read(sitzungProvider.notifier).passwortAendern(felder[0].text, felder[1].text);
                      if (!ctx.mounted) return;
                      if (ok) {
                        Navigator.pop(ctx, true);
                      } else {
                        setState(() {
                          arbeitet = false;
                          fehler = 'Das aktuelle Passwort stimmt nicht.';
                        });
                      }
                    },
              child: const Text('Ändern'),
            ),
          ],
        ),
      ),
    );
    if (geaendert == true && mounted) meldung(context, 'Passwort geändert.');
  }

  Future<void> _biometrie(bool an) async {
    try {
      await ref.read(sitzungProvider.notifier).biometrieSetzen(an);
      if (mounted) meldung(context, an ? 'Fingerabdruck eingerichtet.' : 'Fingerabdruck ausgeschaltet.');
    } catch (e) {
      if (mounted) {
        meldung(context, 'Fingerabdruck ließ sich nicht einrichten. Ist auf dem Gerät ein Fingerabdruck hinterlegt? ($e)', fehler: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sitzungProvider);
    if (s is! Entsperrt) return const SizedBox();
    final b = s.bestand;
    final f = context.farben;
    final letzte = b.einstellungen.letzteSicherung;
    final biometrie = ref.read(biometrieProvider);
    final erinnerung = s.erinnerung;
    final kdf = s.bund.kdf.verfahren == KdfParameter.verfahrenArgon2id ? 'Argon2id' : 'PBKDF2-SHA256 (WebCrypto)';
    final klein = TextStyle(fontSize: 13, color: f.gedaempft);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Seitenkopf(
          oberzeile: 'Speicherort · dieses Gerät',
          titel: 'Du entscheidest, wo deine Daten liegen.',
          unterzeile: 'Standalone bleibt immer möglich. Sync gibt es erst nach deiner ausdrücklichen Wahl.',
        ),
        const SizedBox(height: 24),
        Raster(
          verhaeltnis: 1,
          kinder: [
            Karte(
              titel: 'Datensicherung',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Verschlüsselte Datei mit allen Terminen, Aufgaben, Notizen und Buchungen. Zum Einlesen braucht es den '
                    'Recovery-Schlüssel. Bitte an einem zweiten Ort aufbewahren — es gibt keinen automatischen Upload.',
                    style: klein,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    letzte == null ? 'Noch keine Sicherung erstellt.' : 'Letzte Sicherung: ${datumKurz(letzte.toLocal())}, ${uhrzeit(letzte.toLocal())} Uhr',
                    key: const Key('letzte-sicherung'),
                    style: TextStyle(fontWeight: FontWeight.w600, color: letzte == null ? f.warnText : f.text),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const Key('sicherung-erstellen'),
                        onPressed: _sichert ? null : _sichern,
                        icon: const Icon(Icons.save_alt, size: 18),
                        label: const Text('Sicherung erstellen'),
                      ),
                      OutlinedButton(key: const Key('sicherung-einlesen'), onPressed: _einlesen, child: const Text('Sicherung einlesen …')),
                    ],
                  ),
                ],
              ),
            ),
            Karte(
              titel: 'Sicherheit',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Die App sperrt sich nach 5 Minuten im Hintergrund.', style: klein),
                  const SizedBox(height: 8),
                  if (biometrie.unterstuetzt)
                    SwitchListTile(
                      key: const Key('biometrie-schalter'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Mit Fingerabdruck entsperren'),
                      subtitle: const Text('Schlüssel im Android-Keystore, nur per Fingerabdruck lesbar'),
                      value: s.bund.biometrie,
                      onChanged: _biometrie,
                    )
                  else
                    Text('Fingerabdruck gibt es in der Android-App.', style: klein),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(key: const Key('passwort-aendern'), onPressed: _passwortAendern, child: const Text('Passwort ändern')),
                      OutlinedButton.icon(
                        onPressed: () => ref.read(sitzungProvider.notifier).sperren(),
                        icon: const Icon(Icons.lock_outline, size: 18),
                        label: const Text('Jetzt sperren'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Karte(
              titel: 'Erinnerungen',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    kIsWeb
                        ? 'Im Browser kommen Erinnerungen nur, solange die App geöffnet und entsperrt ist.'
                        : 'Geplant für die nächsten 30 Tage; bei jedem Öffnen erneuert.',
                    style: klein,
                  ),
                  if (erinnerung?.hinweis != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(erinnerung!.hinweis!, style: TextStyle(fontSize: 13, color: erinnerung.erlaubt && erinnerung.exakt ? f.gedaempft : f.warnText)),
                    ),
                  if (erinnerung != null && !kIsWeb)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('${erinnerung.geplant} Erinnerungen geplant.', style: klein),
                    ),
                  SwitchListTile(
                    key: const Key('erinnerung-titel'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Termintitel in Benachrichtigungen'),
                    subtitle: const Text('Aus: nur „Termin · Heute um 14:00“ — der Titel steht dann weder im Sperrbildschirm noch im Systemspeicher.'),
                    value: b.einstellungen.erinnerungMitTitel,
                    onChanged: (v) => ref.read(sitzungProvider.notifier).speichereEinstellungen(b.einstellungen.kopie(erinnerungMitTitel: v)),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      key: const Key('erinnerungen-erlauben'),
                      onPressed: () => ref.read(sitzungProvider.notifier).erinnerungenErlauben(),
                      child: const Text('Benachrichtigungen erlauben'),
                    ),
                  ),
                ],
              ),
            ),
            Karte(
              titel: 'Darstellung',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<ThemeMode>(
                    key: const Key('farbschema'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: ThemeMode.system, label: Text('System')),
                      ButtonSegment(value: ThemeMode.light, label: Text('Hell')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dunkel')),
                    ],
                    selected: {ref.watch(farbschemaProvider)},
                    onSelectionChanged: (m) => ref.read(farbschemaProvider.notifier).setzen(m.first),
                  ),
                ],
              ),
            ),
            Karte(
              titel: 'Lokal auf diesem Gerät',
              marke: 'aktiv',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Ohne Konto und dauerhaft offline. ${b.anzahlDatensaetze} Datensätze, einzeln verschlüsselt.', style: klein),
                  if (kIsWeb) ...[
                    const SizedBox(height: 8),
                    Text(
                      _dauerhaft == true
                          ? 'Der Browser hat dauerhaften Speicher zugesagt.'
                          : 'Der Browser hat keinen dauerhaften Speicher zugesagt — er darf die Daten bei Platzmangel löschen. '
                              'Regelmäßig sichern oder die App installieren.',
                      key: const Key('speicher-dauerhaft'),
                      style: TextStyle(fontSize: 13, color: _dauerhaft == true ? f.gedaempft : f.warnText),
                    ),
                  ],
                ],
              ),
            ),
            Karte(
              titel: 'Optional synchronisieren',
              marke: 'später',
              child: Text(
                'Kommt mit Meilenstein M3: Kays kostenpflichtig gehostetes Backend oder deine eigene Serveradresse. '
                'Eine Voreinstellung verbindet sich nie automatisch und lädt nichts hoch.',
                style: klein,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Personal Tracker $appVersion · AES-256-GCM je Datensatz · Passwort über $kdf · Recovery-Schlüssel 160 Bit',
          style: TextStyle(fontSize: 11, color: f.leise),
        ),
      ],
    );
  }
}
