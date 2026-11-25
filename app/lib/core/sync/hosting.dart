import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Gehostete Instanz, die beim Verbinden als erste Wahl erscheint (M9).
/// Sie wird beim Bauen gesetzt, z. B.
/// `--dart-define=PT_HOSTED_URL=https://sync.example.org`; ohne Adresse gibt
/// es nur „Eigener Server“. Gewählt wird immer bewusst – nichts lädt hoch,
/// bevor die Person auf „Verbinden“ tippt.
typedef Hosting = ({String url, String name, String hinweis});

const _url = String.fromEnvironment('PT_HOSTED_URL');
const _name = String.fromEnvironment('PT_HOSTED_NAME', defaultValue: 'Personal-Tracker-Hosting');
const _hinweis = String.fromEnvironment('PT_HOSTED_HINWEIS', defaultValue: 'kostenpflichtig, Preise und Bedingungen beim Anbieter');

final hostingProvider = Provider<Hosting?>((ref) => _url.isEmpty ? null : (url: _url, name: _name, hinweis: _hinweis));
