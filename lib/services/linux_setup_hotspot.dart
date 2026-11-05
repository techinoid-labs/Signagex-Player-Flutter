import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'linux_network.dart';

/// The running setup hotspot, as the root network helper started it. The
/// password lives only here and on the screen; it is never logged.
class SetupHotspotInfo {
  SetupHotspotInfo({
    required this.ssid,
    required this.password,
    required this.address,
    required this.port,
    required this.expires,
    required this.networks,
  });

  factory SetupHotspotInfo.fromJson(Map json) => SetupHotspotInfo(
        ssid: json['ssid'].toString(),
        password: json['password'].toString(),
        address: json['address']?.toString() ?? '10.42.0.1',
        port: json['port'] is int ? json['port'] as int : 8080,
        expires: DateTime.fromMillisecondsSinceEpoch(((json['expires'] as num?) ?? 0).toInt() * 1000),
        networks: [for (final entry in json['networks'] as List? ?? []) Map<String, dynamic>.from(entry as Map)],
      );

  final String ssid;
  final String password;
  final String address;
  final int port;
  final DateTime expires;
  final List<Map<String, dynamic>> networks;

  String get url => 'http://$address:$port/';

  /// The standard Wi-Fi QR payload phones join from the camera app.
  String get joinCode => 'WIFI:T:WPA;S:${_escape(ssid)};P:${_escape(password)};;';

  static String _escape(String value) => value.replaceAllMapped(RegExp(r'[\\;,:"]'), (match) => '\\${match[0]}');
}

/// Setup hotspot for Linux players with no network (no cable, no known Wi-Fi).
///
/// After [offlineDelay] without a default route or the SignageX API, an
/// unpaired player (or one with no saved Wi-Fi) asks the root network helper
/// for a temporary WPA2 access point and serves a small setup page on the
/// hotspot address only. The page takes a Wi-Fi name and password and applies
/// them through the helper's normal "connect now" path, which rolls back to the
/// hotspot when they do not work. While the player is online this costs one read
/// of /proc/net/route per management tick.
class LinuxSetupHotspot extends ChangeNotifier {
  LinuxSetupHotspot({
    LinuxNetwork? network,
    Future<ProcessResult> Function(String request)? runHelper,
    bool Function()? hasDefaultRoute,
    Future<bool> Function()? apiReachable,
    DateTime Function()? clock,
    this.applyDelay = const Duration(seconds: 2),
  })  : _network = network ?? LinuxNetwork.instance,
        _runHelper = runHelper ?? LinuxNetwork.pkexecHelper,
        _hasDefaultRoute = hasDefaultRoute ?? _procDefaultRoute,
        _apiReachable = apiReachable ?? _probeApi,
        _clock = clock ?? DateTime.now;

  static final LinuxSetupHotspot instance = LinuxSetupHotspot();
  static const offlineDelay = Duration(minutes: 3);
  static const maxAttempts = 10;

  final LinuxNetwork _network;
  final Future<ProcessResult> Function(String request) _runHelper;
  final bool Function() _hasDefaultRoute;
  final Future<bool> Function() _apiReachable;
  final DateTime Function() _clock;
  final Duration applyDelay;

  Future<void> Function(String message, String type)? event;

  SetupHotspotInfo? info;

  /// waiting | connecting | failed | connected, with a line for the screen and page.
  String phase = 'waiting';

  /// The Wi-Fi join started from the phone page, while it runs (tests await it).
  @visibleForTesting
  Future<void>? pendingConnect;
  String detail = '';

  DateTime? _offlineSince;
  DateTime? _probedAt;
  bool _probeOk = false;
  bool _busy = false;
  int _attempts = 0;
  HttpServer? _server;
  Timer? _watch;
  final Map<String, List<DateTime>> _requests = {};

  /// Called on every Linux management tick (30 s).
  Future<void> tick({required bool connected, required bool paired, required String code}) async {
    if (_busy || info != null) return;
    _busy = true;
    try {
      if (await _online(connected)) {
        _offlineSince = null;
        return;
      }
      final now = _clock();
      _offlineSince ??= now;
      if (now.difference(_offlineSince!) < offlineDelay || _network.busy) return;
      final status = await _network.status(force: true);
      if (status['supported'] != true || status['wifi_hardware'] != true) return;
      // A paired screen with saved Wi-Fi waits for that network to come back.
      if (paired && (status['saved'] as List? ?? []).isNotEmpty) return;
      await start(suffix(code, status));
    } catch (error) {
      await event?.call('Setup hotspot: $error', 'warning');
    } finally {
      _busy = false;
    }
  }

  Future<bool> _online(bool connected) async {
    if (!_hasDefaultRoute()) return false;
    if (connected) return true;
    // A route but no MQTT: ask the API itself, at most once a minute.
    final now = _clock();
    if (_probedAt == null || now.difference(_probedAt!) >= const Duration(minutes: 1)) {
      _probedAt = now;
      _probeOk = await _apiReachable();
    }
    return _probeOk;
  }

  /// Last 4 letters/digits of the player code, else of the Wi-Fi MAC.
  static String suffix(String code, Map<String, dynamic> status) {
    String tail(String value) {
      final clean = value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      return clean.length >= 4 ? clean.substring(clean.length - 4) : '';
    }

    final fromCode = tail(code);
    if (fromCode.isNotEmpty) return fromCode;
    for (final entry in status['interfaces'] as List? ?? []) {
      if (entry['type'] == 'wifi' && tail(entry['mac']?.toString() ?? '').isNotEmpty) return tail(entry['mac'].toString());
    }
    return '0000';
  }

  Future<Map> _helper(Map<String, dynamic> request) async {
    final result = await _runHelper(jsonEncode({'job': 'hotspot-${_clock().millisecondsSinceEpoch}', ...request}))
        .timeout(const Duration(minutes: 2));
    final lines = const LineSplitter().convert(result.stdout.toString()).where((line) => line.startsWith('{'));
    if (result.exitCode != 0 || lines.isEmpty) {
      final error = result.stderr.toString().trim();
      return {'phase': 'failed', 'detail': error.isNotEmpty ? error : 'The network helper did not answer'};
    }
    return jsonDecode(lines.last) as Map;
  }

  Future<void> start(String suffix) async {
    final answer = await _helper({'op': 'hotspot_start', 'suffix': suffix});
    if (answer['phase'] != 'applied' || answer['hotspot'] is! Map) {
      _offlineSince = _clock(); // Try again after another offline period.
      await event?.call('Setup hotspot not started: ${answer['detail']}', 'warning');
      return;
    }
    final hotspot = SetupHotspotInfo.fromJson(answer['hotspot'] as Map);
    try {
      _server = await HttpServer.bind(InternetAddress(hotspot.address), hotspot.port);
    } catch (error) {
      await _helper({'op': 'hotspot_stop'});
      _offlineSince = _clock();
      await event?.call('Setup hotspot stopped: setup page unavailable ($error)', 'error');
      return;
    }
    _server!.idleTimeout = const Duration(seconds: 15);
    _server!.listen((request) => unawaited(_handle(request)), onError: (_) {});
    info = hotspot;
    phase = 'waiting';
    detail = '';
    _attempts = 0;
    _requests.clear();
    _watch = Timer.periodic(const Duration(seconds: 10), (_) => unawaited(_check()));
    await event?.call('Setup hotspot ${hotspot.ssid} started (no network)', 'info');
    notifyListeners();
  }

  Future<void> _check() async {
    if (info == null || phase == 'connecting') return;
    if (_hasDefaultRoute()) return stop('a network connected');
    if (!_clock().isBefore(info!.expires)) return stop('15 minutes passed');
  }

  /// Stop the hotspot; if the player is still offline it starts again after another [offlineDelay].
  Future<void> stop(String reason) async {
    if (info == null) return;
    final name = info!.ssid;
    await _close();
    await _helper({'op': 'hotspot_stop'});
    await event?.call('Setup hotspot $name stopped: $reason', 'info');
  }

  Future<void> _close() async {
    _watch?.cancel();
    _watch = null;
    await _server?.close(force: true);
    _server = null;
    info = null;
    _offlineSince = _clock();
    notifyListeners();
  }

  Future<void> _connect(String ssid, String password, bool hidden) async {
    phase = 'connecting';
    detail = 'Connecting to "$ssid"…';
    notifyListeners();
    // Let the phone receive its answer before the radio leaves access-point mode.
    await Future.delayed(applyDelay);
    final id = 'setup-${_clock().millisecondsSinceEpoch}';
    await _network.run({
      'job': id,
      'op': 'wifi_add',
      'ssid': ssid,
      'password': password,
      'hidden': hidden,
      'connect': true,
    }, source: 'the setup hotspot');
    final job = _network.job?['job'] == id ? _network.job : {'phase': 'failed', 'detail': 'Another network change is running'};
    if (job?['phase'] == 'applied') {
      phase = 'connected';
      detail = job?['detail']?.toString() ?? 'Connected';
      await _close(); // The helper already removed the hotspot.
    } else {
      // The helper brought the hotspot back so the installer can try again.
      phase = 'failed';
      detail = job?['detail']?.toString() ?? 'Could not connect';
      notifyListeners();
    }
  }

  static bool validSsid(Object? ssid) =>
      ssid is String && ssid.isNotEmpty && utf8.encode(ssid).length <= 32 && !ssid.runes.any((c) => c < 32 || c == 127);

  static bool validPassword(Object? password) {
    if (password is! String) return false;
    if (password.isEmpty) return true;
    if (password.length == 64) return RegExp(r'^[0-9A-Fa-f]{64}$').hasMatch(password);
    return password.length >= 8 && password.length <= 63 && password.runes.every((c) => c >= 32 && c < 127);
  }

  /// 60 requests a minute per phone is plenty for the page and its status polling.
  bool _allowed(String client) {
    final now = _clock();
    if (_requests.length > 64) _requests.clear();
    final recent = (_requests[client] ?? []).where((at) => now.difference(at) < const Duration(minutes: 1)).toList();
    if (recent.length >= 60) return false;
    _requests[client] = recent..add(now);
    return true;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final hotspot = info;
    try {
      response.headers
        ..set('Cache-Control', 'no-store')
        ..set('X-Content-Type-Options', 'nosniff')
        ..set('X-Frame-Options', 'DENY')
        ..set('Referrer-Policy', 'no-referrer')
        ..set('Content-Security-Policy',
            "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'");
      if (hotspot == null) return _reply(response, HttpStatus.serviceUnavailable, {'phase': 'closed'});
      if (!_allowed(request.connectionInfo?.remoteAddress.address ?? '')) {
        return _reply(response, HttpStatus.tooManyRequests, {'phase': phase, 'detail': 'Too many requests, wait a minute'});
      }
      // Only the hotspot address: a name pointing here (DNS rebinding) gets nothing.
      if (request.headers.host != hotspot.address) return _reply(response, HttpStatus.misdirectedRequest, {});
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/') {
        response.headers.contentType = ContentType.html;
        response.write(page(hotspot));
        return;
      }
      if (request.method == 'GET' && path == '/status') return _reply(response, HttpStatus.ok, {'phase': phase, 'detail': detail});
      if (request.method == 'POST' && path == '/connect') return await _connectRequest(request, hotspot);
      return _reply(response, HttpStatus.notFound, {});
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badRequest;
      } catch (_) {}
    } finally {
      await response.close().catchError((_) {});
    }
  }

  Future<void> _connectRequest(HttpRequest request, SetupHotspotInfo hotspot) async {
    final response = request.response;
    final origin = request.headers.value('origin');
    final sameOrigin = origin == null || origin == 'http://${hotspot.address}:${hotspot.port}';
    // JSON only: a cross-site form cannot send it without a preflight this server never answers.
    if (!sameOrigin || request.headers.contentType?.mimeType != 'application/json') {
      return _reply(response, HttpStatus.forbidden, {});
    }
    if ((request.contentLength) > 2048) return _reply(response, HttpStatus.requestEntityTooLarge, {});
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 10))) {
      bytes.addAll(chunk);
      if (bytes.length > 2048) return _reply(response, HttpStatus.requestEntityTooLarge, {});
    }
    if (phase == 'connecting') return _reply(response, HttpStatus.conflict, {'phase': phase, 'detail': detail});
    if (++_attempts > maxAttempts) {
      return _reply(response, HttpStatus.tooManyRequests, {'phase': phase, 'detail': 'Too many attempts. Restart the player to try again.'});
    }
    final body = jsonDecode(utf8.decode(bytes));
    final ssid = body is Map ? body['ssid'] : null;
    final password = body is Map ? (body['password'] ?? '') : null;
    if (!validSsid(ssid)) return _reply(response, HttpStatus.badRequest, {'phase': phase, 'detail': 'Enter a Wi-Fi name (up to 32 bytes)'});
    if (!validPassword(password)) {
      return _reply(response, HttpStatus.badRequest, {'phase': phase, 'detail': 'The password must be 8-63 characters (or empty for an open network)'});
    }
    _reply(response, HttpStatus.accepted, {'phase': 'connecting', 'detail': 'Connecting to "$ssid"…'});
    final join = _connect(ssid as String, password as String, body['hidden'] == true);
    pendingConnect = join;
    unawaited(join.whenComplete(() {
      if (identical(pendingConnect, join)) pendingConnect = null;
    }));
  }

  static void _reply(HttpResponse response, int status, Map body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
  }

  /// The setup page: one small self-contained document, no external resources.
  static String page(SetupHotspotInfo hotspot) {
    const escape = HtmlEscape();
    final options = hotspot.networks
        .where((network) => network['security'] != 'enterprise')
        .map((network) => '<option value="${escape.convert(network['ssid'].toString())}">'
            '${escape.convert(network['ssid'].toString())}${network['security'] == 'open' ? ' (open)' : ''}</option>')
        .join();
    final name = escape.convert(hotspot.ssid);
    return '''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>SignageX Wi-Fi setup</title>
<style>body{font:16px system-ui,sans-serif;margin:0;padding:24px 16px;background:#0b0b10;color:#f3f4f6}
main{max-width:420px;margin:auto}h1{font-size:22px}label{display:block;margin:16px 0 6px;color:#9ca3af}
select,input{width:100%;box-sizing:border-box;padding:12px;font-size:16px;border-radius:10px;border:1px solid #374151;background:#111827;color:#fff}
.row{display:flex;gap:8px;align-items:center;margin-top:12px}.row input{width:auto}
button{margin-top:20px;width:100%;padding:14px;font-size:17px;border:0;border-radius:10px;background:#9f78f8;color:#fff}
button:disabled{opacity:.5}#message{margin-top:18px;min-height:3em;line-height:1.5}</style></head>
<body><main><h1>Connect this screen to Wi-Fi</h1>
<form id="form"><label for="network">Wi-Fi network</label>
<select id="network">$options<option value="">Other network…</option></select>
<div id="other" hidden><label for="ssid">Network name</label><input id="ssid" maxlength="32" autocomplete="off"></div>
<label for="password">Password</label><input id="password" type="password" maxlength="64" autocomplete="off">
<div class="row"><input id="show" type="checkbox"><label for="show" style="margin:0">Show password</label></div>
<div class="row"><input id="hidden" type="checkbox"><label for="hidden" style="margin:0">Hidden network</label></div>
<button id="go">Connect</button></form><p id="message" role="status"></p></main>
<script>
const \$=id=>document.getElementById(id),msg=t=>\$('message').textContent=t;
function other(){\$('other').hidden=\$('network').value!=='';}
\$('network').onchange=other;other();
\$('show').onchange=()=>\$('password').type=\$('show').checked?'text':'password';
async function poll(){try{const s=await(await fetch('/status',{cache:'no-store'})).json();
if(s.phase==='failed'){msg(s.detail+' Check the password and try again.');\$('go').disabled=false;return;}
if(s.phase==='connected'){msg(s.detail);return;}}catch(e){}setTimeout(poll,3000);}
\$('form').onsubmit=async e=>{e.preventDefault();const ssid=\$('network').value||\$('ssid').value;
if(!ssid){msg('Enter the Wi-Fi name.');return;}\$('go').disabled=true;msg('Sending…');
try{const r=await fetch('/connect',{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify({ssid,password:\$('password').value,hidden:\$('hidden').checked})});const s=await r.json();
if(r.status!==202){msg(s.detail||'Not accepted.');\$('go').disabled=false;return;}
msg('Connecting to "'+ssid+'". This setup network now closes. If the screen does not come online within a minute, join $name again and reload this page.');
setTimeout(poll,5000);}catch(e){msg('No answer. Join $name again and reload this page.');\$('go').disabled=false;}};
</script></body></html>''';
  }

  static bool _procDefaultRoute() {
    try {
      // Destination and mask 00000000: a default route (the hotspot itself never adds one).
      return File('/proc/net/route').readAsLinesSync().skip(1).any((line) {
        final columns = line.split(RegExp(r'\s+'));
        return columns.length > 7 && columns[1] == '00000000' && columns[7] == '00000000';
      });
    } catch (_) {
      return true; // Unknown: never start a hotspot on a guess.
    }
  }

  static Future<bool> _probeApi() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.headUrl(Uri.parse('https://api.signagex.ai/')).timeout(const Duration(seconds: 10));
      await (await request.close().timeout(const Duration(seconds: 10))).drain<void>();
      return true; // Any HTTPS answer counts.
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
