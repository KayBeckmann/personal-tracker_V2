import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../modell/einkauf.dart';
import '../sitzung.dart';
import '../sync/sync_api.dart';
import '../sync/sync_dienst.dart';

final katalogProvider = Provider<KatalogDienst>(KatalogDienst.new);

class KatalogFehler implements Exception {
  KatalogFehler(this.meldung);
  final String meldung;
  @override
  String toString() => meldung;
}

/// Ein Preis aus dem öffentlichen Katalog.
class KatalogPreis {
  KatalogPreis(this.j);
  final Map<String, dynamic> j;

  String get instanz => j['instanz'] as String;
  String get id => j['id'] as String;
  String get artikel => j['artikel'] as String;
  String? get variante => j['variante'] as String?;
  String get kette => j['kette'] as String;
  String get filiale => j['filiale'] as String;
  String get region => j['region'] as String;
  int get preisCent => j['preisCent'] as int;
  double get packungsMenge => (j['packungsMenge'] as num).toDouble();
  Einheit get einheit => Einheit.values.byName(j['packungsEinheit'] as String);
  DateTime get tag => DateTime.parse(j['tag'] as String);
  bool get bestaetigt => j['bestaetigt'] == true;
  int get bestaetigungen => j['bestaetigungen'] as int;
  bool get eigen => j['eigen'] == true;
  bool get vonMir => j['vonMir'] == true;
  bool get veraltet => j['veraltet'] == true;

  /// Passt zu einer eigenen Filiale (Kette, Name und Region gleich)?
  bool passtZu(Filiale f) => _n(f.kette) == _n(kette) && _n(f.name) == _n(filiale) && _n(f.region ?? '') == _n(region);
  static String _n(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}

/// Zugriff auf den öffentlichen, föderierten Preiskatalog über den eigenen
/// Sync-Server. Was veröffentlicht wird, ist **nicht** verschlüsselt: Artikel,
/// Packung, Kette, Filialname, Region, Preis und Tag, unter einem Pseudonym.
/// Nie Position, Listen, Kaufverlauf oder Name.
class KatalogDienst {
  KatalogDienst(this.ref);
  final Ref ref;

  Future<SyncApi> _api() async {
    final (_, api) = await ref.read(syncProvider.notifier).werkzeug();
    return api;
  }

  /// Genau das, was öffentlich würde.
  static Map<String, dynamic> beitragFuer(Preis p, Filiale f) {
    final region = f.region?.trim();
    if (region == null || region.isEmpty) {
      throw KatalogFehler('Für den Katalog braucht die Filiale eine Region (z. B. den Ort), damit andere sie zuordnen können.');
    }
    if (p.packungsEinheit == Einheit.packung) throw KatalogFehler('Für den Katalog bitte eine Packungsgröße in Stück, g, kg, ml oder l angeben.');
    return {
      'typ': 'preis',
      'artikel': p.artikel,
      'variante': ?p.variante,
      'packungsMenge': p.packungsMenge == p.packungsMenge.roundToDouble() ? p.packungsMenge.toInt() : p.packungsMenge,
      'packungsEinheit': p.packungsEinheit.name,
      'kette': f.kette,
      'filiale': f.name,
      'region': region,
      'preisCent': p.packungsPreisCent,
      'waehrung': 'EUR',
      'tag': '${p.datum.year.toString().padLeft(4, '0')}-${p.datum.month.toString().padLeft(2, '0')}-${p.datum.day.toString().padLeft(2, '0')}',
    };
  }

  void _pruefeBeitragen() {
    if (!ref.read(bestandProvider).einstellungen.katalogBeitragen) throw KatalogFehler('Beitragen zum Katalog ist ausgeschaltet.');
  }

  Future<void> veroeffentlichen(Preis p, Filiale f) async {
    _pruefeBeitragen();
    final b = beitragFuer(p, f);
    await (await _api()).katalogBeitrag(b);
  }

  Future<void> bestaetigen(KatalogPreis k) async {
    _pruefeBeitragen();
    await (await _api()).katalogBeitrag({'typ': 'bestaetigung', 'ziel': {'instanz': k.instanz, 'id': k.id}});
  }

  Future<void> zurueckziehen(String instanz, String id) async {
    await (await _api()).katalogBeitrag({'typ': 'rueckzug', 'ziel': {'instanz': instanz, 'id': id}});
  }

  Future<List<KatalogPreis>> suchen(String artikel, {Filiale? filiale}) async {
    if (!ref.read(bestandProvider).einstellungen.katalogLesen) throw KatalogFehler('Lesen aus dem Katalog ist ausgeschaltet.');
    final r = await (await _api()).katalogPreise(artikel: artikel, kette: filiale?.kette, region: filiale?.region);
    return [for (final j in r) KatalogPreis(j)];
  }

  Future<List<Map<String, dynamic>>> meine() async => (await _api()).katalogMeine();

  /// Einen bestätigten Katalogpreis als eigenen Preis übernehmen (dann
  /// zählt er in der Schätzung). Ohne passende eigene Filiale wird sie
  /// angelegt (ohne Position).
  Future<Preis> uebernehmen(KatalogPreis k, {String? raum}) async {
    if (!k.bestaetigt) throw KatalogFehler('Nur bestätigte Preise lassen sich übernehmen.');
    final s = ref.read(sitzungProvider.notifier);
    final b = ref.read(bestandProvider);
    var f = b.filialen.values.where((x) => x.raum == raum && k.passtZu(x)).firstOrNull;
    if (f == null) {
      f = Filiale(id: s.neueId(), kette: k.kette, name: k.filiale, region: k.region, geaendert: DateTime.now().toUtc(), raum: raum);
      await s.speichereFiliale(f);
    }
    final p = Preis(
      id: s.neueId(),
      artikel: k.artikel,
      variante: k.variante,
      filialeId: f.id,
      packungsPreisCent: k.preisCent,
      packungsMenge: k.packungsMenge,
      packungsEinheit: k.einheit,
      datum: k.tag,
      quelle: 'katalog',
      geaendert: DateTime.now().toUtc(),
      raum: raum,
    );
    await s.speicherePreis(p);
    return p;
  }

  /// Pseudonym und Instanz dieses Kontos im Katalog.
  Future<({String pseudonym, String instanz, bool foederiert})> ich() async {
    final j = await (await _api()).katalogIch();
    return (pseudonym: j['pseudonym'] as String, instanz: j['instanz'] as String, foederiert: j['foederiert'] == true);
  }
}

