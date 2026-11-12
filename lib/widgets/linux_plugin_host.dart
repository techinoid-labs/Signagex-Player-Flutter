import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_cef/webview_cef.dart' as cef;

import '../services/linux_plugins.dart';

/// Keeps one hidden 1x1 webview per player plugin, above everything else and
/// invisible, so plugins keep running while content plays or changes.
class LinuxPluginHost extends StatelessWidget {
  final Widget child;
  const LinuxPluginHost({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final plugins = LinuxPlugins.instance;
    return AnimatedBuilder(
      animation: plugins,
      builder: (_, __) => Stack(fit: StackFit.expand, children: [
        child,
        for (final p in plugins.plugins)
          Positioned(
            left: 0,
            top: 0,
            width: 1,
            height: 1,
            child: IgnorePointer(
              child: Opacity(
                opacity: 0,
                child: _PluginView(
                  key: ValueKey('plugin-${p.instanceId}'),
                  spec: p,
                  generation: plugins.reloadGeneration,
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class _PluginView extends StatefulWidget {
  final PluginSpec spec;
  final int generation;
  const _PluginView({super.key, required this.spec, required this.generation});

  @override
  State<_PluginView> createState() => _PluginViewState();
}

class _PluginViewState extends State<_PluginView> {
  late final cef.WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = cef.WebviewManager().createWebView(loading: const SizedBox.shrink());
    _controller.setWebviewListener(cef.WebviewEventsListener(
      onTitleChanged: (title) => LinuxPlugins.instance.onTitle(widget.spec.instanceId, title),
    ));
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await _controller.initialize(LinuxPlugins.wrapperUrl(widget.spec.url));
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant _PluginView old) {
    super.didUpdateWidget(old);
    // New version (its url changes too) or the daily reload.
    if (old.spec.version != widget.spec.version ||
        old.spec.url != widget.spec.url ||
        old.generation != widget.generation) {
      unawaited(_reload());
    }
  }

  Future<void> _reload() async {
    try {
      await _controller.ready;
      await _controller.loadUrl(LinuxPlugins.wrapperUrl(widget.spec.url));
    } catch (_) {}
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: _controller,
        builder: (_, ready, __) =>
            ready ? _controller.webviewWidget : const SizedBox.shrink(),
      );
}
