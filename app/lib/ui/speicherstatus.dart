import 'speicherstatus_io.dart' if (dart.library.js_interop) 'speicherstatus_web.dart' as impl;

/// Browser: bittet um dauerhaften Speicher (IndexedDB wird sonst bei
/// Platzmangel u. U. geräumt). Android: immer dauerhaft.
Future<bool> dauerhaftenSpeicherAnfragen() => impl.anfragen();

/// `null` = unbekannt.
Future<bool?> speicherDauerhaft() => impl.dauerhaft();
