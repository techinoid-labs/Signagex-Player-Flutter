import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_cef/webview_cef.dart' as cef;

import '../services/linux_kiosk_campaign.dart';
import '../utils/mqtt_state.dart';

/// Puts the running kiosk campaign over scheduled signage (Linux only).
///
/// Signage stays mounted underneath, offstage, so it resumes exactly where it
/// was when the kiosk is cleared or falls back after repeated failures.
class LinuxKioskSurface extends StatelessWidget {
  final MqttState state;
  final Widget child;
  const LinuxKioskSurface({super.key, required this.state, required this.child});

  @override
  Widget build(BuildContext context) {
    final kiosk = KioskCampaignService.instance;
    return AnimatedBuilder(
      animation: kiosk,
      builder: (_, __) {
        // A stopped (licence/account) or never-paired player shows its own
        // screen, never a kiosk.
        final show = kiosk.showing &&
            state != MqttState.playerStopped &&
            state != MqttState.pairedScreen;
        final active = kiosk.active;
        return Stack(fit: StackFit.expand, children: [
          Offstage(offstage: show, child: child),
          if (show && active != null)
            MouseRegion(
              cursor: SystemMouseCursors.none,
              child: LinuxKioskView(
                key: const ValueKey('linux-kiosk-view'),
                url: active.playerUrl,
                kiosk: kiosk,
              ),
            ),
        ]);
      },
    );
  }
}

/// The CEF browser running /kiosk-play. Reports the page's title-based state
/// to the service and reloads or ends the session when the service asks.
class LinuxKioskView extends StatefulWidget {
  final String url;
  final KioskCampaignService kiosk;
  const LinuxKioskView({super.key, required this.url, required this.kiosk});

  @override
  State<LinuxKioskView> createState() => _LinuxKioskViewState();
}

class _LinuxKioskViewState extends State<LinuxKioskView> {
  late final cef.WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = cef.WebviewManager().createWebView(
      loading: const ColoredBox(color: Colors.black),
    );
    _controller.setWebviewListener(cef.WebviewEventsListener(
      onTitleChanged: (title) => widget.kiosk.onPageTitle(title),
      onLoadEnd: (_, url) {
        // The Linux safety override reports a failed main frame this way
        // (see LinuxWebView).
        if (url.startsWith('signagex-load-failed:')) {
          widget.kiosk.onPageLoadFailed();
        }
      },
    ));
    widget.kiosk.reloadRequests.addListener(_reload);
    widget.kiosk.endSessionRequests.addListener(_endSession);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize(widget.url);
    } catch (_) {
      widget.kiosk.onPageLoadFailed();
    }
  }

  void _reload() {
    unawaited(_load(widget.url));
  }

  Future<void> _load(String url) async {
    try {
      await _controller.ready;
      if (mounted) await _controller.loadUrl(url).timeout(const Duration(seconds: 10));
    } catch (_) {
      widget.kiosk.onPageLoadFailed();
    }
  }

  void _endSession() {
    unawaited(_runEndSession());
  }

  Future<void> _runEndSession() async {
    try {
      await _controller.ready;
      await _controller.executeJavaScript(
          'window.__sxKioskEndSession && window.__sxKioskEndSession()');
    } catch (_) {
      // The service applies the swap anyway after its grace period.
    }
  }

  @override
  void didUpdateWidget(covariant LinuxKioskView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) unawaited(_load(widget.url));
  }

  @override
  void dispose() {
    widget.kiosk.reloadRequests.removeListener(_reload);
    widget.kiosk.endSessionRequests.removeListener(_endSession);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: _controller,
        builder: (_, ready, __) => ColoredBox(
          color: Colors.black,
          child: ready ? _controller.webviewWidget : _controller.loadingWidget,
        ),
      );
}
