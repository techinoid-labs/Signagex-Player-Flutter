import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/linux_setup_hotspot.dart';

/// Shown while the setup hotspot runs: join it, then open the setup page.
class SetupHotspotView extends StatelessWidget {
  const SetupHotspotView({required this.hotspot, super.key});

  final LinuxSetupHotspot hotspot;

  static const _muted = Color(0xFF9CA3AF);
  static const _accent = Color(0xFF9F78F8);

  @override
  Widget build(BuildContext context) {
    final info = hotspot.info;
    if (info == null) return const Scaffold(backgroundColor: Colors.black);
    final closes = TimeOfDay.fromDateTime(info.expires).format(context);
    final failed = hotspot.phase == 'failed';
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          final qrSize = (constraints.maxHeight * 0.32).clamp(140.0, 260.0);
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Connect this screen to Wi-Fi',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  const Text('No network found. Use a phone to set up Wi-Fi.',
                      textAlign: TextAlign.center, style: TextStyle(color: _muted, fontSize: 17)),
                  const SizedBox(height: 28),
                  Wrap(
                    spacing: 32,
                    runSpacing: 24,
                    alignment: WrapAlignment.center,
                    children: [
                      _card('1', 'Scan to join the setup Wi-Fi', info.joinCode, qrSize,
                          [_line('Network', info.ssid), _line('Password', info.password)],
                          'QR code to join Wi-Fi network ${info.ssid}'),
                      _card('2', 'Scan to open the setup page', info.url, qrSize, [_line('Or open', info.url)],
                          'QR code for the setup page ${info.url}'),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (hotspot.detail.isNotEmpty)
                    Text(failed ? '${hotspot.detail} Try again from the setup page.' : hotspot.detail,
                        key: const ValueKey('setup-hotspot-status'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: failed ? const Color(0xFFF87171) : _accent, fontSize: 17)),
                  const SizedBox(height: 8),
                  Text('This setup network closes at $closes.',
                      textAlign: TextAlign.center, style: const TextStyle(color: _muted, fontSize: 14)),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _card(String number, String title, String data, double qrSize, List<Widget> lines, String label) {
    return Container(
      width: qrSize + 80,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF374151)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$number. $title',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          Semantics(
            label: label,
            image: true,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: QrImageView(
                data: data,
                version: QrVersions.auto,
                size: qrSize,
                padding: EdgeInsets.zero,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 14),
          ...lines,
        ],
      ),
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: '$label  ', style: const TextStyle(color: _muted, fontSize: 14)),
          TextSpan(
              text: value,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontFamily: 'monospace', fontWeight: FontWeight.w600)),
        ]),
        textAlign: TextAlign.center,
      ),
    );
  }
}
