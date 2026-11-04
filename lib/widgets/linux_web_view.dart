import 'dart:async';
import '../services/linux_configuration.dart';

import 'package:flutter/material.dart';
import 'package:webview_cef/webview_cef.dart' as cef;

import '../utils/web_page_retry.dart';

/// Linux native overrides report main-frame load failures through onLoadEnd.
/// Retry only confirmed failures; healthy live widgets are never polled/reloaded.
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
  @override
  void initState() {
    super.initState();
    _controller = cef.WebviewManager().createWebView(
      loading: const Center(child: CircularProgressIndicator()),
    );
    _controller.setWebviewListener(cef.WebviewEventsListener(
      onLoadEnd: (_, url) => _onLoadEnd(url),
    ));
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize(widget.url);
      if (!mounted) return;
      print('[WEB_RECOVERY] browser ready');
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        unawaited(_retryFailedPage());
      });
      await _retryFailedPage();
    } catch (error) {
      print('[WEB_RECOVERY] browser initialization failed: $error');
    }
  }

  void _onLoadEnd(String url) {
    if (!mounted) return;
    if (url.startsWith('signagex-load-failed:')) {
      if (!_failed) {
        print('[WEB_RECOVERY] failed page detected');
        unawaited(LinuxConfiguration.instance.event?.call('Web page connection failed; automatic retry active', 'warning') ?? Future.value());
      }
      setState(() => _failed = true);
      unawaited(_retryFailedPage());
    } else {
      if (_failed) {
        print('[WEB_RECOVERY] page recovered');
        unawaited(LinuxConfiguration.instance.event?.call('Web page recovered', 'info') ?? Future.value());
      }
      if (_failed) setState(() => _failed = false);
      _retry.recovered();
    }
  }

  Future<void> _retryFailedPage() async {
    if (!mounted || !_controller.value || _checking || !_failed) return;
    final now = DateTime.now();
    if (!_retry.shouldRetry(now)) return;
    _retry.attempted(now);
    _checking = true;
    try {
      print('[WEB_RECOVERY] retrying failed page');
      await _controller.loadUrl(widget.url)
          .timeout(const Duration(seconds: 4));
    } catch (error) {
      print('[WEB_RECOVERY] retry unavailable: $error');
    } finally {
      _checking = false;
    }
  }

  @override
  void didUpdateWidget(covariant LinuxWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
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
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: _controller,
    builder: (_, ready, __) => ColoredBox(
      color: Colors.black,
      child: Stack(fit: StackFit.expand, children: [
        ready ? _controller.webviewWidget : _controller.loadingWidget,
        if (_failed)
          const Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Material(
                color: Colors.black87,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Web content unavailable · retrying',
                    style: TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ),
            ),
          ),
      ]),
    ),
  );
}
