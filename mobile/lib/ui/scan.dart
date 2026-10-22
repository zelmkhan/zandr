// Scanning a QR code for an address to send to: a plain address, or a Solana Pay transfer request
// (solana:<address>?amount=…&spl-token=…), whose amount and token come along.
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/base58.dart';
import 'theme.dart';
import 'widgets.dart';

class Scanned {
  final String address;
  final String? amount, mint;
  const Scanned(this.address, {this.amount, this.mint});
}

final _amount = RegExp(r'^\d+(\.\d+)?$');

Scanned? parseScanned(String raw) {
  final text = raw.trim();
  if (isAddress(text)) return Scanned(text);
  if (!text.toLowerCase().startsWith('solana:')) return null;
  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  final address = Uri.decodeComponent(uri.path);
  if (!isAddress(address)) return null;
  final amount = uri.queryParameters['amount'];
  final mint = uri.queryParameters['spl-token'];
  return Scanned(address, amount: amount != null && _amount.hasMatch(amount) ? amount : null, mint: mint != null && isAddress(mint) ? mint : null);
}

Future<Scanned?> scan(BuildContext context) => Navigator.of(context).push<Scanned>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _ScanScreen()));

class _ScanScreen extends StatefulWidget {
  const _ScanScreen();
  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  String? _problem;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _found(BarcodeCapture capture) {
    if (_done) return;
    for (final code in capture.barcodes) {
      final value = code.rawValue;
      if (value == null) continue;
      final scanned = parseScanned(value);
      if (scanned != null) {
        _done = true;
        Navigator.of(context).pop(scanned);
        return;
      }
      setState(() => _problem = 'That QR code isn\'t a Solana address.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SubScreen(
      title: 'Scan a QR code',
      child: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(gutter),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: MobileScanner(
                  controller: _controller,
                  onDetect: _found,
                  errorBuilder: (context, error) => Container(
                    color: p.fill,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      error.errorCode == MobileScannerErrorCode.permissionDenied ? 'Zandr may not use the camera. Allow it in Settings → Zandr → Camera.' : 'The camera couldn\'t start.',
                      textAlign: TextAlign.center,
                      style: geist(15, color: p.muted, height: 1.4),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 56,
            child: _problem == null ? null : Text(_problem!, style: geist(15, color: p.danger)),
          ),
        ],
      ),
    );
  }
}
