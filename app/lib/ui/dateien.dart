import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Datei speichern/öffnen; in Tests ersetzbar.
abstract class Dateien {
  /// `true`, wenn gespeichert (Web: Download gestartet).
  Future<bool> speichern(String name, Uint8List bytes);

  /// `null` bei Abbruch.
  Future<({String name, Uint8List bytes})?> oeffnen();
}

class SystemDateien implements Dateien {
  const SystemDateien();

  @override
  Future<bool> speichern(String name, Uint8List bytes) async {
    final uri = await FilePicker.saveFile(
      fileName: name,
      bytes: bytes,
      mimeType: 'application/octet-stream',
      dialogTitle: 'Sicherung speichern',
    );
    // Im Browser startet ein Download ohne Rückmeldung.
    return kIsWeb || uri != null;
  }

  @override
  Future<({String name, Uint8List bytes})?> oeffnen() async {
    final dateien = await FilePicker.pickFiles(dialogTitle: 'Sicherung öffnen');
    if (dateien.isEmpty) return null;
    final d = dateien.first;
    return (name: d.name, bytes: await d.readAsBytes());
  }
}

final dateienProvider = Provider<Dateien>((ref) => const SystemDateien());
