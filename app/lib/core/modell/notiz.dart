/// Markdown-Notiz. Unabhängig von einem Obsidian-Vault (der folgt in M4).
class Notiz {
  const Notiz({
    required this.id,
    required this.titel,
    required this.text,
    required this.erstellt,
    required this.geaendert,
  });

  final String id;
  final String titel;

  /// Markdown-Quelltext, unverändert gespeichert.
  final String text;
  final DateTime erstellt;
  final DateTime geaendert;

  /// Angezeigter Titel: eigener Titel, sonst erste Textzeile.
  String get anzeigeTitel {
    if (titel.trim().isNotEmpty) return titel.trim();
    final erste = text.split('\n').map((z) => z.replaceFirst(RegExp(r'^#+\s*'), '').trim()).firstWhere(
          (z) => z.isNotEmpty,
          orElse: () => '',
        );
    return erste.isEmpty ? 'Ohne Titel' : erste;
  }

  bool passtZu(String suche) {
    final s = suche.trim().toLowerCase();
    return s.isEmpty || titel.toLowerCase().contains(s) || text.toLowerCase().contains(s);
  }

  Notiz kopie({String? titel, String? text, DateTime? geaendert}) => Notiz(
        id: id,
        titel: titel ?? this.titel,
        text: text ?? this.text,
        erstellt: erstellt,
        geaendert: geaendert ?? this.geaendert,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'titel': titel,
        'text': text,
        'erstellt': erstellt.toUtc().toIso8601String(),
        'geaendert': geaendert.toUtc().toIso8601String(),
      };

  static Notiz fromJson(Map<String, dynamic> j) => Notiz(
        id: j['id'] as String,
        titel: (j['titel'] as String?) ?? '',
        text: (j['text'] as String?) ?? '',
        erstellt: DateTime.parse(j['erstellt'] as String),
        geaendert: DateTime.parse(j['geaendert'] as String),
      );
}
