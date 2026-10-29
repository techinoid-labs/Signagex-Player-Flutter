import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Fits the complete pairing flow on small signage displays, including 1024x600.
/// Scrolling remains available for unusually small screens or large text sizes.
class PlayerPairingScreen extends StatelessWidget {
  const PlayerPairingScreen({super.key, required this.code});

  final String code;
  static const _background = Color(0xFF000000);
  static const _muted = Color(0xFF9CA3AF);
  static const _accent = Color(0xFF9F78F8);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          final landscape = constraints.maxWidth >= 760 &&
              constraints.maxWidth > constraints.maxHeight;
          final compact = constraints.maxHeight < 700;
          final padding = constraints.maxWidth < 480 ? 20.0 : 32.0;
          final qrSize = landscape
              ? (constraints.maxHeight < 520 ? 160.0 : 220.0)
              : (compact ? 156.0 : 240.0);
          final introduction = _introduction(compact: compact);
          final pairing = _pairingCard(qrSize: qrSize, compact: compact);

          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: EdgeInsets.all(padding),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: landscape
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(child: introduction),
                              const SizedBox(width: 40),
                              SizedBox(width: qrSize + 72, child: pairing),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              introduction,
                              SizedBox(height: compact ? 20 : 32),
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 360),
                                child: pairing,
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _introduction({required bool compact}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Image.asset(
          'assets/images/Logo.png',
          width: 160,
          height: 48,
          alignment: Alignment.centerLeft,
          color: Colors.white,
          fit: BoxFit.contain,
          semanticLabel: 'SignageX',
        ),
        SizedBox(height: compact ? 20 : 36),
        const Text(
          'Let’s connect\nyour screen.',
          style: TextStyle(
            color: Colors.white,
            fontSize: 34,
            height: 1.15,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.8,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Pair this player with your SignageX account.',
          style: TextStyle(color: _muted, fontSize: 17, height: 1.45),
        ),
        SizedBox(height: compact ? 20 : 32),
        _step('1', 'Open your SignageX dashboard.'),
        const SizedBox(height: 12),
        _step('2', 'Add a player and enter this code,\nor scan the QR code.'),
      ],
    );
  }

  Widget _step(String number, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1625),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(number,
              style: const TextStyle(
                  color: _accent, fontSize: 15, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text,
              style: const TextStyle(
                  color: Colors.white, fontSize: 16, height: 1.5)),
        ),
      ],
    );
  }

  Widget _pairingCard({required double qrSize, required bool compact}) {
    final ready = code.isNotEmpty;
    return Container(
      padding: EdgeInsets.all(compact ? 20 : 24),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF374151)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            ready ? 'SCAN TO PAIR' : 'PREPARING YOUR CODE',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: _muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5),
          ),
          const SizedBox(height: 16),
          if (ready)
            Semantics(
              label: 'QR code for pairing code $code',
              image: true,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: code,
                  version: QrVersions.auto,
                  size: qrSize,
                  padding: EdgeInsets.zero,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square, color: Colors.black),
                  dataModuleStyle: const QrDataModuleStyle(
                      color: Colors.black,
                      dataModuleShape: QrDataModuleShape.square),
                ),
              ),
            )
          else
            SizedBox(
              height: qrSize + 24,
              width: qrSize + 24,
              child: const Center(
                  child: CircularProgressIndicator(color: _accent)),
            ),
          const SizedBox(height: 16),
          const Text('Or enter this pairing code',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, fontSize: 14)),
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                ready ? code : '------',
                key: const ValueKey('pairing-code'),
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontSize: 36,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            ready ? 'Waiting for pairing…' : 'Connecting to SignageX…',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _accent, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
