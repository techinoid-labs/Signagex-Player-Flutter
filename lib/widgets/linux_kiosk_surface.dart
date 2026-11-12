import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_cef/webview_cef.dart' as cef;

import '../services/linux_kiosk_campaign.dart';
import '../utils/mqtt_state.dart';
import 'linux_kiosk_approval.dart';

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
          // A clashing campaign waiting for approval, over signage or the
          // kiosk (never during a customer session; the service holds it).
          if (state != MqttState.playerStopped && state != MqttState.pairedScreen)
            Positioned.fill(child: LinuxKioskApprovalOverlay(kiosk: kiosk)),
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
          // The code is a CEF net error (-105 = name not resolved, -106 =
          // offline...) or an HTTP status (404, 502...).
          widget.kiosk.onPageLoadFailed(
              'code ${url.substring('signagex-load-failed:'.length)} at ${_where(widget.url)}');
        }
      },
    ));
    widget.kiosk.reloadRequests.addListener(_reload);
    widget.kiosk.endSessionRequests.addListener(_endSession);
    widget.kiosk.backRequests.addListener(_back);
    unawaited(_initialize());
  }

  /// Host and path only: the query holds the runtime address and player code.
  static String _where(String url) {
    final u = Uri.tryParse(url);
    return u == null ? 'an invalid address' : '${u.scheme}://${u.host}${u.path}';
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize(widget.url);
    } catch (error) {
      widget.kiosk.onPageLoadFailed('browser did not start: $error');
    }
  }

  void _reload() {
    unawaited(_load(widget.url));
  }

  Future<void> _load(String url) async {
    try {
      await _controller.ready;
      if (mounted) await _controller.loadUrl(url).timeout(const Duration(seconds: 10));
    } catch (error) {
      widget.kiosk.onPageLoadFailed('reload of ${_where(url)}: $error');
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

  void _back() {
    unawaited(_runBack());
  }

  /// One screen back inside the kiosk (the page has no browser history, so
  /// the Alt+Left key remote view also sends does nothing there).
  Future<void> _runBack() async {
    try {
      await _controller.ready;
      await _controller.executeJavaScript(
          'window.__sxKioskBack && window.__sxKioskBack()');
    } catch (_) {
      // An older page without the hook: nothing to go back to.
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
    widget.kiosk.backRequests.removeListener(_back);
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
