// Unlocking: Face ID at once, or the iPhone's passcode when Face ID can't; the key that opens the
// wallet comes only from them. Black with the mark in the middle, as the launch screen before it,
// so starting up and unlocking read as one; the button shows only once a prompt was dismissed.
// If the key is gone (the passcode was turned off), only the recovery phrase brings the wallet back.
import 'package:flutter/material.dart';

import '../app/store.dart';
import 'app.dart';
import 'theme.dart';
import 'widgets.dart';

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});
  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  String? _error;
  // Asking: from the start, so the first frame already shows nothing but the mark.
  bool _busy = true;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).unlock();
    } on KeyFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _gone = failure.outcome == KeyOutcome.gone;
        _error = failure.outcome == KeyOutcome.failed ? 'Couldn\'t unlock. Try again.' : null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final faceId = AppScope.of(context).faceIdAvailable;
    return Scaffold(
      body: Stack(
        children: [
          const Center(child: BrandMark()),
          Positioned(
            left: gutter,
            right: gutter,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: AnimatedOpacity(
                opacity: _busy ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: _busy,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_gone) ...[
                        const Notice(
                          'This wallet can\'t be opened',
                          body: 'The key that opens it is no longer on this iPhone, which happens when the iPhone\'s passcode is turned off. Restore the wallet from its recovery phrase.',
                        ),
                        const SizedBox(height: 20),
                        PrimaryButton('Restore from recovery phrase', onPressed: () => AppScope.read(context).startOver()),
                      ] else ...[
                        Text(
                          _error ?? (faceId ? 'Unlock with Face ID or your iPhone passcode' : 'Unlock with your iPhone passcode'),
                          textAlign: TextAlign.center,
                          style: geist(14, color: _error == null ? p.muted : p.danger, height: 1.35),
                        ),
                        const SizedBox(height: 16),
                        PrimaryButton('Unlock', onPressed: _busy ? null : _unlock),
                      ],
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
