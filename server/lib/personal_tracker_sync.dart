/// Sync-Server des Personal Trackers V2: speichert Geheimtext, kann ihn
/// aber nicht lesen. Vertrag siehe `server/API.md`.
library;

export 'src/api.dart' show Konfiguration, apiVersion, serverVersion, syncHandler;
export 'src/speicher.dart' show Speicher, SpeicherFehler, dbSchema;
