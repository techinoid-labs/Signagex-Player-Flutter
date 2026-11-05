import 'dart:async';
import 'dart:ui' show ImageFilter, TileMode;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/linux_setup_hotspot.dart';

/// Shown while the setup hotspot runs: join it, then open the setup page.
///
/// Screens are often in public, and the join QR carries the hotspot password.
/// So the details start hidden behind a blur with a prompt on top; a tap,
/// click or key press shows them for [revealFor], and they hide again after
/// that long without input. While hidden, the blurred layer is drawn from
/// placeholder data, so nothing secret is on screen to be recovered.
class SetupHotspotView extends StatefulWidget {
  const SetupHotspotView({required this.hotspot, this.revealFor = const Duration(minutes: 1), super.key});

  final LinuxSetupHotspot hotspot;
  final Duration revealFor;

  @override
  State<SetupHotspotView> createState() => _SetupHotspotViewState();
}

class _SetupHotspotViewState extends State<SetupHotspotView> {
  static const _muted = Color(0xFF9CA3AF);
  static const _accent = Color(0xFF9F78F8);

  bool _revealed = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    // Global and non-consuming: works whatever has focus, and key triggers
    // elsewhere still see the event.
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _hide?.cancel();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) _reveal();
    return false;
  }

  void _reveal() {
    if (!mounted) return;
    _hide?.cancel();
    _hide = Timer(widget.revealFor, () {
      if (mounted) setState(() => _revealed = false);
    });
    if (!_revealed) setState(() => _revealed = true);
  }

  @override
  Widget build(BuildContext context) {
    final hotspot = widget.hotspot;
    final real = hotspot.info;
    if (real == null) return const Scaffold(backgroundColor: Colors.black);
    final info = _revealed ? real : _placeholder(real);
    final closes = TimeOfDay.fromDateTime(real.expires).format(context);
    final failed = hotspot.phase == 'failed';
    final details = _details(context, hotspot, info, closes, failed);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
        // A pointer-down listener, not a tap gesture: it fires even when
        // another recognizer would win the gesture arena.
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _reveal(),
        child: _revealed
            ? Stack(fit: StackFit.expand, children: [
                details,
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 12,
                  child: Text('Details hide again after ${_duration(widget.revealFor)} without a touch or key press.',
                      key: const ValueKey('setup-hotspot-hide-note'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: _muted, fontSize: 13)),
                ),
              ])
            : Stack(fit: StackFit.expand, children: [
                ExcludeSemantics(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18, tileMode: TileMode.decal),
                    child: details,
                  ),
                ),
                const ColoredBox(color: Color(0x99000000)),
                Center(child: _prompt()),
              ]),
      ),
    );
  }

  /// Same shape as the real details, so the blurred layer looks right, but
  /// with nothing that would let someone join the hotspot.
  static SetupHotspotInfo _placeholder(SetupHotspotInfo real) => SetupHotspotInfo(
        ssid: 'SignageX-Setup',
        password: '\u2022' * 12,
        address: '0.0.0.0',
        port: 80,
        expires: real.expires,
        networks: const [],
      );

  static String _duration(Duration d) =>
      d.inSeconds % 60 == 0 ? (d.inMinutes == 1 ? '1 minute' : '${d.inMinutes} minutes') : '${d.inSeconds} seconds';

  Widget _prompt() {
    return Container(
      key: const ValueKey('setup-hotspot-prompt'),
      constraints: const BoxConstraints(maxWidth: 640),
      margin: const EdgeInsets.all(32),
      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 32),
      decoration: BoxDecoration(
        color: const Color(0xEE111827),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF374151)),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_off_rounded, color: _accent, size: 48),
          SizedBox(height: 16),
          Text('This screen needs Wi-Fi setup',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700)),
          SizedBox(height: 10),
          Text('Tap the screen or press any key to show the setup details.',
              textAlign: TextAlign.center, style: TextStyle(color: _muted, fontSize: 18)),
        ],
      ),
    );
  }

  Widget _details(BuildContext context, LinuxSetupHotspot hotspot, SetupHotspotInfo info, String closes, bool failed) {
    return SafeArea(
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
