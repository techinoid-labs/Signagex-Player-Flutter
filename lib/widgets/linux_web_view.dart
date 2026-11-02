import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_cef/webview_cef.dart' as cef;

import '../utils/web_page_retry.dart';

/// CEF 0.2.2 displays load failures as HTML, without a Dart error callback.
/// Inspect that specific error document; do not periodically reload live widgets.
class LinuxWebView extends StatefulWidget {
  final String url;
  const LinuxWebView({super.key, required this.url});

  @override
  State<LinuxWebView> createState() => _LinuxWebViewState();
}

class _LinuxWebViewState extends State<LinuxWebView> {
  late final cef.WebViewController _controller;
  final _retry = WebPageRetry();
  Timer? _timer;
  bool _checking = false;
  bool _failed = false;
  int _generation = 0;

  static const _pageStatus = r'''(() => {
    const text = (document.body?.innerText || '').trim();
    const failed = location.href.startsWith('chrome-error://') ||
      (text.startsWith('Failed to load URL ') &&
       /with error[\s\S]*\(-?\d+\)/.test(text));
    if (failed) return 'signagex-load-failed';
    if (document.readyState === 'complete' && location.href !== 'about:blank')
      return 'signagex-load-healthy';
    return 'signagex-load-pending';
  })()''';

  @override
  void initState() {
    super.initState();
    _controller = cef.WebviewManager().createWebView(
      loading: const Center(child: CircularProgressIndicator()),
    );
    _controller.setWebviewListener(cef.WebviewEventsListener(
      onLoadEnd: (_, __) => unawaited(_checkPage()),
    ));
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize(widget.url);
      if (!mounted) return;
      print('[WEB_RECOVERY] browser ready');
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        unawaited(_checkPage());
      });
      await _checkPage();
    } catch (error) {
      print('[WEB_RECOVERY] browser initialization failed: $error');
    }
  }

  Future<void> _checkPage() async {
    if (!mounted || !_controller.value || _checking) return;
    _checking = true;
    final generation = _generation;
    try {
      final result = await _controller.evaluateJavascript(_pageStatus)
          .timeout(const Duration(seconds: 4));
      if (!mounted || generation != _generation) return;
      final status = result.toString();
      if (status.contains('signagex-load-failed')) {
        if (!_failed) print('[WEB_RECOVERY] failed page detected');
        _failed = true;
        final now = DateTime.now();
        if (_retry.shouldRetry(now)) {
          _retry.attempted(now);
          print('[WEB_RECOVERY] retrying failed page');
          await _controller.loadUrl(widget.url)
              .timeout(const Duration(seconds: 4));
        }
      } else if (status.contains('signagex-load-healthy')) {
        if (_failed) print('[WEB_RECOVERY] page recovered');
        _failed = false;
        _retry.recovered();
      }
    } catch (error) {
      // A hung probe must not cause reloads of a potentially healthy document.
      print('[WEB_RECOVERY] page check unavailable: $error');
    } finally {
      _checking = false;
    }
  }

  @override
  void didUpdateWidget(covariant LinuxWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _generation++;
      _failed = false;
      _retry.recovered();
      unawaited(_loadUpdatedUrl());
    }
  }

  Future<void> _loadUpdatedUrl() async {
    try {
      await _controller.ready;
      if (mounted) await _controller.loadUrl(widget.url);
    } catch (error) {
      print('[WEB_RECOVERY] updated page load failed: $error');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _generation++;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: _controller,
    builder: (_, ready, __) =>
        ready ? _controller.webviewWidget : _controller.loadingWidget,
  );
}
