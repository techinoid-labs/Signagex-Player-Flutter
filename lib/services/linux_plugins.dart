import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'player_attributes.dart';

/// One entry of `publish_player_plugins` (`{code}/plugins`, retained).
class PluginSpec {
  final String instanceId;
  final String url;
  final String version;
  const PluginSpec(this.instanceId, this.url, this.version);

  static List<PluginSpec> listFrom(Object? data) {
    final list = data is Map ? data['plugins'] : null;
    if (list is! List) return const [];
    final seen = <String>{};
    return [
      for (final p in list)
        if (p is Map &&
            '${p['instance_id'] ?? ''}'.isNotEmpty &&
            '${p['url'] ?? ''}'.startsWith('http') &&
            seen.add('${p['instance_id']}'))
          PluginSpec('${p['instance_id']}', '${p['url']}', '${p['version'] ?? ''}')
    ];
  }
}

/// Player plugins on Linux (backend docs/PLAYER_PLUGIN_CONTRACT.md).
///
/// Each plugin page runs in its own hidden webview. CEF here has no way to
/// inject a `SignageXPlugin` object before a page loads, so the page is loaded
/// in an iframe inside a small wrapper page. The plugin runtime posts every
/// `setAttributes` and `log` to `window.parent` as well (player-plugin.scripts
/// `post`), and the wrapper turns each message into a title change
/// `sxp:<n>:<json>`, which the player reads. Values go to [PlayerAttributes]
/// and are reported upstream as `player_attributes` (merged per instance for
/// 5 s); error logs go to `player_logs`. A plugin is reloaded when its
/// `version` changes and once every 24 h.
class LinuxPlugins extends ChangeNotifier {
  LinuxPlugins._();
  static final LinuxPlugins instance = LinuxPlugins._();

  static const reportMerge = Duration(seconds: 5);
  static const dailyReload = Duration(hours: 24);

  List<PluginSpec> plugins = const [];
  void Function(String message)? publish;
  bool Function()? connected;

  final Map<String, Map<String, Object>> _pendingReports = {};
  Timer? _reportTimer;
  Timer? _reloadTimer;
  int reloadGeneration = 0;

  void update(Object? data) {
    plugins = PluginSpec.listFrom(data);
    _reloadTimer ??= Timer.periodic(dailyReload, (_) {
      reloadGeneration++;
      notifyListeners();
    });
    notifyListeners();
  }

  /// The wrapper page: the plugin in a 1x1 iframe, messages to the title.
  static String wrapperUrl(String pluginUrl) {
    final src = const HtmlEscape(HtmlEscapeMode.attribute).convert(pluginUrl);
    final html = '<!doctype html><html><head><meta charset="utf-8"></head>'
        '<body style="margin:0;overflow:hidden">'
        '<iframe src="$src" style="border:0;width:1px;height:1px"></iframe>'
        '<script>var n=0;addEventListener("message",function(e){var d=e.data;'
        'if(!d||d.source!=="signagex-plugin")return;n++;'
        'document.title="sxp:"+n+":"+JSON.stringify({type:d.type,payload:d.payload});});'
        '</script></body></html>';
    return 'data:text/html;base64,${base64Encode(utf8.encode(html))}';
  }

  /// A title change from plugin [instanceId]'s wrapper.
  void onTitle(String instanceId, String title) {
    final msg = parseTitle(title);
    if (msg == null) return;
    final type = msg['type'];
    final payload = msg['payload'];
    if (type == 'attributes' && payload is Map) {
      final accepted = PlayerAttributes.instance.setFromPlugin(instanceId, payload);
      if (accepted.isEmpty) return;
      (_pendingReports[instanceId] ??= {}).addAll(accepted);
      _reportTimer ??= Timer(reportMerge, flushReports);
    } else if (type == 'log' && payload is Map && '${payload['level']}' == 'error') {
      if (connected?.call() == true) {
        publish?.call(jsonEncode({
          'action': 'player_logs',
          'log': 'Plugin error',
          'name': '${payload['message'] ?? ''}'.substring(0, min300('${payload['message'] ?? ''}')),
          'type': 'error',
          'date_time': DateTime.now().toIso8601String(),
        }));
      }
    }
  }

  static int min300(String s) => s.length < 300 ? s.length : 300;

  /// Sends the merged values; kept for the next connect when offline.
  void flushReports() {
    _reportTimer = null;
    if (_pendingReports.isEmpty) return;
    if (connected?.call() != true || publish == null) {
      _reportTimer = Timer(const Duration(seconds: 30), flushReports);
      return;
    }
    _pendingReports.forEach((id, attrs) {
      publish!(jsonEncode({
        'action': 'player_attributes',
        'sender': 'player',
        'instance_id': id,
        'attrs': attrs,
      }));
    });
    _pendingReports.clear();
  }

  /// `sxp:<n>:<json>` -> the message, else null.
  static Map? parseTitle(String title) {
    if (!title.startsWith('sxp:')) return null;
    final rest = title.substring(4);
    final colon = rest.indexOf(':');
    if (colon < 0) return null;
    try {
      final v = jsonDecode(rest.substring(colon + 1));
      return v is Map ? v : null;
    } catch (_) {
      return null;
    }
  }
}
