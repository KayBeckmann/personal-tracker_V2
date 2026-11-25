import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../katalog/katalog_dienst.dart';
import '../modell/agent.dart';
import '../sitzung.dart';
import '../sync/sync_dienst.dart';
import '../sync/sync_krypto.dart';
import '../sync/sync_stand.dart';
import '../vault/vault_dienst.dart';

final agentProvider = Provider<AgentDienst>(AgentDienst.new);

/// Module, für die ein Agent Rechte bekommen kann.
const agentModule = {
  'termine': 'Termine',
  'aufgaben': 'Aufgaben',
  'notizen': 'Notizen',
  'haushaltsbuch': 'Haushaltsbuch',
  'einkauf': 'Einkauf',
  'vault': 'Vault',
};

class AgentFehler implements Exception {
  AgentFehler(this.meldung);
  final String meldung;
  @override
  String toString() => meldung;
}

/// KI-Agenten einrichten, widerrufen und ihre Vorschläge ausführen. Der
/// Agent selbst läuft über die lokale Brücke `pt-agent` (siehe agent/README.md).
class AgentDienst {
  AgentDienst(this.ref);
  final Ref ref;

  static const kopplungGueltig = Duration(minutes: 10);

  SitzungNotifier get _sitzung => ref.read(sitzungProvider.notifier);

  /// Neuer Agenten-Zugang; liefert den Kopplungscode für `pt-agent koppeln`.
  Future<({Kopplungscode code, AgentZugang agent})> einrichten({required String name, required Map<String, String> rechte, int? ablaufTage}) async {
    final r = {for (final e in rechte.entries) if (agentModule.containsKey(e.key) && (e.value == 'lesen' || e.value == 'schreiben')) e.key: e.value};
    if (r.isEmpty) throw AgentFehler('Bitte mindestens ein Modul freigeben.');
    final (_, api) = await ref.read(syncProvider.notifier).werkzeug();
    final v = (await SyncStand(ref.read(ablageProvider), (ref.read(sitzungProvider) as Entsperrt).dek).verbindung())!;
    final a = AgentZugang(id: _sitzung.neueId(), name: name.trim().isEmpty ? 'KI-Agent' : name.trim(), rechte: r, erstellt: DateTime.now().toUtc(), ablaufTage: ablaufTage);
    final code = Kopplungscode.neu();
    await api.kopplungAnlegen(code.slot, code.agentPaket(v.konto, v.schluessel, {'id': a.id, 'name': a.name, 'rechte': a.rechte}), kopplungGueltig,
        agent: true, ablaufTage: ablaufTage);
    await _sitzung.speichereAgent(a);
    return (code: code, agent: a);
  }

  /// Agenten-Gerät beim Server abmelden (falls bekannt) und den Zugang
  /// samt Protokoll entfernen.
  Future<void> widerrufen(AgentZugang a) async {
    final b = ref.read(bestandProvider);
    final geraete = {for (final p in b.agentProtokoll.values) if (p.agent == a.id && p.geraet != null) p.geraet!};
    final sync = ref.read(syncProvider.notifier);
    for (final g in await sync.geraete()) {
      if (g.agent && (geraete.contains(g.id) || g.name == 'Agent: ${a.name}')) await sync.geraetEntfernen(g.id);
    }
    await _sitzung.loescheAgent(a.id);
  }

  /// Führt einen Vorschlag aus (oder lehnt ihn ab).
  Future<void> entscheiden(AgentVorschlag v, {required bool annehmen}) async {
    if (!v.offen) return;
    if (annehmen) {
      final b = ref.read(bestandProvider);
      switch ((v.art, v.bereich)) {
        case ('loeschen', 'termine'):
          await _sitzung.loescheTermin(v.zielId);
        case ('loeschen', 'aufgaben'):
          await _sitzung.loescheAufgabe(v.zielId);
        case ('loeschen', 'notizen'):
          await _sitzung.loescheNotiz(v.zielId);
        case ('loeschen', 'buchungen'):
          await _sitzung.loescheBuchung(v.zielId);
        case ('loeschen', 'vault'):
          final d = ref.read(vaultProvider).dateien.where((x) => x.id == v.zielId).firstOrNull;
          if (d != null) await ref.read(vaultProvider.notifier).loeschen(d);
        case ('veroeffentlichen', 'preise'):
          final p = b.preise[v.zielId];
          final f = p == null ? null : b.filialen[p.filialeId];
          if (p == null || f == null) throw AgentFehler('Den Preis gibt es nicht mehr.');
          await ref.read(katalogProvider).veroeffentlichen(p, f);
        default:
          throw AgentFehler('Unbekannter Vorschlag.');
      }
    }
    await _sitzung.speichereVorschlag(v.mitStatus(annehmen ? 'angenommen' : 'abgelehnt'));
  }
}
