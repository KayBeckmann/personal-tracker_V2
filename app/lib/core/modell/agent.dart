/// Agenten-Zugänge (M8): ein externer KI-Agent erhält über die lokale
/// Brücke `pt-agent` je Modul Lese- oder Schreibrecht. Die Rechte stehen im
/// Kopplungspaket; dieser Datensatz hält fest, was eingerichtet wurde.
class AgentZugang {
  const AgentZugang({required this.id, required this.name, required this.rechte, required this.erstellt, this.ablaufTage});

  final String id;
  final String name;

  /// Modul (`termine`, `aufgaben`, `notizen`, `haushaltsbuch`, `einkauf`,
  /// `vault`) → `lesen` oder `schreiben`.
  final Map<String, String> rechte;
  final DateTime erstellt;

  /// `null` = bis zum Widerruf.
  final int? ablaufTage;

  DateTime? get ablauf => ablaufTage == null ? null : erstellt.add(Duration(days: ablaufTage!));

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'rechte': rechte,
        'erstellt': erstellt.toUtc().toIso8601String(),
        if (ablaufTage != null) 'ablaufTage': ablaufTage,
      };

  static AgentZugang fromJson(Map<String, dynamic> j) => AgentZugang(
        id: j['id'] as String,
        name: j['name'] as String,
        rechte: ((j['rechte'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')),
        erstellt: DateTime.parse(j['erstellt'] as String),
        ablaufTage: j['ablaufTage'] as int?,
      );
}

/// Ein Aufruf des Agenten, ohne Inhalte (nur Werkzeug, Modul, Anzahl).
class AgentProtokoll {
  const AgentProtokoll({required this.id, required this.agent, this.geraet, required this.zeit, required this.werkzeug, required this.modul, required this.art, required this.anzahl});

  final String id;
  final String agent;
  final String? geraet;
  final DateTime zeit;
  final String werkzeug;
  final String modul;

  /// `lesen`, `schreiben` oder `vorschlag`.
  final String art;
  final int anzahl;

  Map<String, dynamic> toJson() => {
        'id': id,
        'agent': agent,
        if (geraet != null) 'geraet': geraet,
        'zeit': zeit.toUtc().toIso8601String(),
        'werkzeug': werkzeug,
        'modul': modul,
        'art': art,
        'anzahl': anzahl,
      };

  static AgentProtokoll fromJson(Map<String, dynamic> j) => AgentProtokoll(
        id: j['id'] as String,
        agent: j['agent'] as String,
        geraet: j['geraet'] as String?,
        zeit: DateTime.parse(j['zeit'] as String),
        werkzeug: j['werkzeug'] as String,
        modul: j['modul'] as String,
        art: j['art'] as String,
        anzahl: (j['anzahl'] as num?)?.toInt() ?? 0,
      );
}

/// Was der Agent nicht selbst darf, schlägt er vor: Löschen und
/// Veröffentlichen. Erst die Person führt es aus.
class AgentVorschlag {
  const AgentVorschlag({
    required this.id,
    required this.agent,
    required this.agentName,
    required this.zeit,
    required this.art,
    required this.bereich,
    required this.zielId,
    required this.beschreibung,
    required this.status,
  });

  final String id;
  final String agent;
  final String agentName;
  final DateTime zeit;

  /// `loeschen` oder `veroeffentlichen`.
  final String art;
  final String bereich;
  final String zielId;
  final String beschreibung;

  /// `offen`, `angenommen`, `abgelehnt`.
  final String status;

  bool get offen => status == 'offen';

  AgentVorschlag mitStatus(String s) => AgentVorschlag(
        id: id,
        agent: agent,
        agentName: agentName,
        zeit: zeit,
        art: art,
        bereich: bereich,
        zielId: zielId,
        beschreibung: beschreibung,
        status: s,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'agent': agent,
        'agentName': agentName,
        'zeit': zeit.toUtc().toIso8601String(),
        'art': art,
        'bereich': bereich,
        'zielId': zielId,
        'beschreibung': beschreibung,
        'status': status,
      };

  static AgentVorschlag fromJson(Map<String, dynamic> j) => AgentVorschlag(
        id: j['id'] as String,
        agent: j['agent'] as String,
        agentName: (j['agentName'] as String?) ?? 'Agent',
        zeit: DateTime.parse(j['zeit'] as String),
        art: j['art'] as String,
        bereich: j['bereich'] as String,
        zielId: j['zielId'] as String,
        beschreibung: j['beschreibung'] as String,
        status: j['status'] as String,
      );
}
