import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
// Prefixed: the package re-exports names (X509Certificate...) that clash
// with dart:io elsewhere in the app.
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as web;

import '../services/kiosk_campaign.dart';
import '../view_models/mqtt_view_model.dart' show MqttState;
import 'kiosk_approval.dart';

/// Puts the running kiosk campaign over scheduled signage.
///
/// Signage stays mounted underneath, offstage, so it resumes exactly where it
/// was when the kiosk is cleared or falls back after repeated failures.
class KioskSurface extends StatelessWidget {
  final MqttState state;
  final Widget child;
  const KioskSurface({super.key, required this.state, required this.child});

  /// A stopped (licence/account) or never-paired player shows its own
  /// screen, never a kiosk or an approval prompt.
  static bool allowedIn(MqttState state) =>
      state != MqttState.playerStopped && state != MqttState.pairedScreen;

  @override
  Widget build(BuildContext context) {
    final kiosk = KioskCampaignService.instance;
    return AnimatedBuilder(
      animation: kiosk,
      builder: (_, __) {
        final show = kiosk.showing && allowedIn(state);
        final active = kiosk.active;
        return Stack(fit: StackFit.expand, children: [
          Offstage(offstage: show, child: child),
          if (show && active != null)
            MouseRegion(
              cursor: SystemMouseCursors.none,
              child: KioskView(
                key: const ValueKey('kiosk-view'),
                url: active.playerUrl,
                kiosk: kiosk,
              ),
            ),
          // A clashing campaign waiting for approval, over signage or the
          // kiosk (never during a customer session; the service holds it).
          if (allowedIn(state))
            Positioned.fill(child: KioskApprovalOverlay(kiosk: kiosk)),
        ]);
      },
    );
  }
}

/// Defines the page's `SignageXKiosk` channel before the page runs, and
/// hands its messages to the player. The page also puts its state in the
/// title (`sxk:<state>`), which covers a message sent before the bridge was
/// ready.
const String kioskChannelShim = '''
(function () {
  if (window.SignageXKiosk) return;
  window.SignageXKiosk = {
    postMessage: function (message) {
      try {
        if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
          window.flutter_inappwebview.callHandler('SignageXKiosk', String(message));
        }
      } catch (e) {}
    }
  };
})();
''';

/// WebView2 running /kiosk-play. Reports the page's state to the service and
/// reloads, ends the session or goes back when the service asks.
class KioskView extends StatefulWidget {
  final String url;
  final KioskCampaignService kiosk;
  const KioskView({super.key, required this.url, required this.kiosk});

  @override
  State<KioskView> createState() => _KioskViewState();
}

class _KioskViewState extends State<KioskView> {
  final Completer<web.InAppWebViewController> _ready = Completer();

  @override
  void initState() {
    super.initState();
    widget.kiosk.reloadRequests.addListener(_reload);
    widget.kiosk.endSessionRequests.addListener(_endSession);
    widget.kiosk.backRequests.addListener(_back);
  }

  /// Host and path only: the query holds the runtime address and player code.
  static String _where(String url) {
    final u = Uri.tryParse(url);
    return u == null ? 'an invalid address' : '${u.scheme}://${u.host}${u.path}';
  }

  /// Whether [url] is the kiosk page itself (not a frame or a resource).
  bool _isPage(web.WebResourceRequest request) {
    if (request.isForMainFrame == false) return false;
    final page = Uri.tryParse(widget.url);
    final asked = request.url;
    return page == null || (asked.host == page.host && asked.path == page.path);
  }

  void _reload() => unawaited(_load(widget.url));

  Future<void> _load(String url) async {
    try {
      final controller = await _ready.future.timeout(const Duration(seconds: 30));
      if (!mounted) return;
      await controller
          .loadUrl(urlRequest: web.URLRequest(url: web.WebUri(url)))
          .timeout(const Duration(seconds: 10));
    } catch (error) {
      widget.kiosk.onPageLoadFailed('reload of ${_where(url)}: $error');
    }
  }

  void _endSession() => unawaited(
      _run('window.__sxKioskEndSession && window.__sxKioskEndSession()'));

  /// One screen back inside the kiosk (the page has no browser history).
  void _back() => unawaited(_run('window.__sxKioskBack && window.__sxKioskBack()'));

  Future<void> _run(String script) async {
    try {
      final controller = await _ready.future.timeout(const Duration(seconds: 10));
      await controller.evaluateJavascript(source: script);
    } catch (_) {
      // An older page without the hook, or a swap the service applies anyway
      // after its grace period.
    }
  }

  @override
  void didUpdateWidget(covariant KioskView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) unawaited(_load(widget.url));
  }

  @override
  void dispose() {
    widget.kiosk.reloadRequests.removeListener(_reload);
    widget.kiosk.endSessionRequests.removeListener(_endSession);
    widget.kiosk.backRequests.removeListener(_back);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: web.InAppWebView(
        initialUrlRequest: web.URLRequest(url: web.WebUri(widget.url)),
        initialSettings: web.InAppWebViewSettings(
          javaScriptEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          disableContextMenu: true,
          supportZoom: false,
          isInspectable: kDebugMode,
        ),
        initialUserScripts: UnmodifiableListView([
          web.UserScript(
            source: kioskChannelShim,
            injectionTime: web.UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
        ]),
        onWebViewCreated: (controller) {
          controller.addJavaScriptHandler(
            handlerName: 'SignageXKiosk',
            callback: (args) {
              if (mounted && args.isNotEmpty) widget.kiosk.onPageMessage(args.first);
              return null;
            },
          );
          if (!_ready.isCompleted) _ready.complete(controller);
        },
        onTitleChanged: (_, title) {
          if (mounted && title != null) widget.kiosk.onPageTitle(title);
        },
        onReceivedError: (_, request, error) {
          // A navigation replaced by the next one isn't a failure.
          if (!mounted || !_isPage(request) || error.type == web.WebResourceErrorType.CANCELLED) {
            return;
          }
          widget.kiosk.onPageLoadFailed(
              '${error.type} ${error.description} at ${_where(widget.url)}');
        },
        onReceivedHttpError: (_, request, response) {
          final status = response.statusCode ?? 0;
          if (!mounted || !_isPage(request) || status < 400) return;
          widget.kiosk.onPageLoadFailed('HTTP $status at ${_where(widget.url)}');
        },
      ),
    );
  }
}
