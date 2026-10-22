// Receiving: the address as a QR code and in full, to copy.
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/config.dart';
import 'app.dart';
import 'theme.dart';
import 'widgets.dart';

class ReceiveScreen extends StatelessWidget {
  const ReceiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = AppScope.of(context);
    final wallet = state.active!;
    // The button says it's copied, whether it or the address was tapped.
    return Momentary(
      builder: (context, copied, run) => SubScreen(
        title: 'Receive',
        bottom: PrimaryButton(copied ? 'Copied' : 'Copy address', onPressed: () => run(() => copyText(wallet.address))),
        child: ListView(
          physics: scrollIfNeeded,
          padding: const EdgeInsets.symmetric(horizontal: gutter),
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
                child: QrImageView(
                  data: wallet.address,
                  size: 232,
                  padding: EdgeInsets.zero,
                  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Colors.black),
                  dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Colors.black),
                  semanticsLabel: 'QR code of your address',
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              wallet.name,
              textAlign: TextAlign.center,
              style: geist(17, weight: FontWeight.w600, color: p.fg),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => run(() => copyText(wallet.address)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: AddressText(wallet.address, size: 18, align: TextAlign.center),
              ),
            ),
            const SizedBox(height: 28),
            Notice(
              state.network == Network.devnet ? 'This is a devnet address' : 'Only Solana coins and tokens',
              body: state.network == Network.devnet
                  ? 'Zandr is set to devnet: what arrives here is test SOL and tokens, worth nothing.'
                  : 'Send only SOL and Solana tokens here. Coins on other networks (Ethereum, Bitcoin, Tron) sent to this address are lost.',
              danger: false,
            ),
          ],
        ),
      ),
    );
  }
}
