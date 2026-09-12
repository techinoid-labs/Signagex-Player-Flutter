import 'dart:async';
import 'dart:io';

// Root cause of "connected via Ethernet, player still says no network"
// (reported repeatedly against this same symptom, while the working
// Android player on the same office network works fine over Ethernet):
// _monitorConnectivity() previously used InternetConnectionChecker() with
// no custom configuration, which probes a hardcoded list of well-known
// third-party addresses (public DNS resolver IPs on port 53) to decide
// whether "the internet" is reachable at all. Many office/corporate
// networks route Ethernet through a firewall that allows normal outbound
// HTTPS to real destinations (including this app's own backend) but blocks
// arbitrary raw TCP to unrelated external IPs on port 53 -- so the check
// itself was reachability testing the wrong thing and failing on exactly
// the kind of network this player is meant to run on, unrelated to
// wifi/ethernet as such.
//
// This checks reachability the way it should be checked for THIS app:
// can it open a live TCP connection to its own backend host:port -- the
// exact same host:port the MQTT client (mqttBroker:mqttPort from
// mqtt_client_service.dart) and every API call already depend on. If that
// succeeds, the app's actual required connectivity is confirmed; if it
// doesn't, no unrelated third party's reachability is relevant anyway.

/// Whether a live TCP connection to [host]:[port] can be established within
/// [timeout].
Future<bool> canReachHost(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Polls [canReachHost] on [interval] and emits only when reachability
/// actually flips, mirroring the shape of
/// InternetConnectionChecker().onStatusChange (a status stream a listener
/// can just .listen() to) without depending on that package's fixed,
/// third-party check targets.
Stream<bool> hostReachabilityStream(
  String host,
  int port, {
  Duration interval = const Duration(seconds: 5),
  Duration timeout = const Duration(seconds: 5),
}) {
  late StreamController<bool> controller;
  Timer? timer;
  bool? lastState;
  var checking = false;

  Future<void> check() async {
    if (checking) return;
    checking = true;
    try {
      final reachable = await canReachHost(host, port, timeout: timeout);
      if (reachable != lastState) {
        lastState = reachable;
        controller.add(reachable);
      }
    } finally {
      checking = false;
    }
  }

  controller = StreamController<bool>(
    onListen: () {
      check();
      timer = Timer.periodic(interval, (_) => check());
    },
    onCancel: () {
      timer?.cancel();
      timer = null;
    },
  );

  return controller.stream;
}
