import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/regionen/regionen.dart' show gtinGueltig;

/// Barcode der Packung (EAN/UPC) scannen (M10). Erkannt wird auf dem Gerät:
/// Android mit dem mitgelieferten ML-Kit-Modell, im Browser nur mit dessen
/// eingebauter Erkennung (kein Nachladen von fremden Servern). Wo das nicht
/// geht, lässt sich die Nummer unter dem Strichcode eintippen.
Future<String?> barcodeScannen(BuildContext context) =>
    Navigator.of(context).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const ScannerSeite()));

class ScannerSeite extends StatefulWidget {
  const ScannerSeite({super.key});
  @override
  State<ScannerSeite> createState() => _ScannerSeiteState();
}

class _ScannerSeiteState extends State<ScannerSeite> {
  late final MobileScannerController _kamera;
  final _eingabe = TextEditingController();
  String? _fehler;
  bool _fertig = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) MobileScannerPlatform.instance.setWebBarcodeReader(WebBarcodeReader.barcodeDetector);
    _kamera = MobileScannerController(
      formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.upcA],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  @override
  void dispose() {
    _kamera.dispose();
    _eingabe.dispose();
    super.dispose();
  }

  void _erkannt(BarcodeCapture c) {
    for (final b in c.barcodes) {
      final wert = b.rawValue?.trim();
      if (wert != null && gtinGueltig(wert)) {
        _zurueck(wert);
        return;
      }
    }
  }

  void _zurueck(String ean) {
    if (_fertig) return;
    _fertig = true;
    Navigator.pop(context, ean);
  }

  void _uebernehmen() {
    final t = _eingabe.text.replaceAll(RegExp(r'\s'), '');
    if (!gtinGueltig(t)) {
      setState(() => _fehler = 'Das ist keine gültige EAN (8, 12 oder 13 Ziffern, Prüfziffer passt nicht).');
      return;
    }
    _zurueck(t);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Barcode scannen')),
        body: Column(
          children: [
            Expanded(
              child: ClipRect(
                child: MobileScanner(
                  controller: _kamera,
                  onDetect: _erkannt,
                  errorBuilder: (context, e) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        e.errorCode == MobileScannerErrorCode.permissionDenied
                            ? 'Kein Zugriff auf die Kamera. Du kannst die Nummer unter dem Strichcode eintippen.'
                            : 'Scannen ist hier nicht möglich. Bitte die Nummer unter dem Strichcode eintippen.',
                        key: const Key('scanner-fehler'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Die Kamera erkennt den Code auf diesem Gerät; es wird nichts gesendet.', style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('scanner-eingabe'),
                            controller: _eingabe,
                            keyboardType: TextInputType.number,
                            onSubmitted: (_) => _uebernehmen(),
                            decoration: InputDecoration(labelText: 'Oder Nummer eintippen', errorText: _fehler, errorMaxLines: 2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(key: const Key('scanner-uebernehmen'), onPressed: _uebernehmen, child: const Text('Übernehmen')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}
