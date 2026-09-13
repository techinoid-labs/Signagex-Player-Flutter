import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:digital_signage/utils/debug_log.dart' as debug;

// First attempt at this bug replaced InternetConnectionChecker's probe of
// third-party DNS-resolver IPs with a raw TCP connect to this app's own
// backend host:port instead -- reasoning that the specific *target* being
// probed was the problem. That did NOT fix the report on real hardware: the
// device still showed "no network" over Ethernet. That ruled out "wrong
// probe target" as the actual root cause, and pointed at something more
// fundamental about probing *any* specific external destination at all from
// this app on this platform (DNS resolution behavior, IPv6/IPv4 preference,
// or a network-stack quirk specific to raw Socket.connect on Windows --
// unconfirmed which, and it doesn't matter which, given the fix below).
//
// Checked how signagex-player-android (the reference implementation that
// works correctly over Ethernet on the same networks) actually decides this,
// expecting it to reveal the real divergence -- and it does: it NEVER probes
// any external host. Utils.kt's isInternetAvailable() and NetworkReceiver.kt
// both ask the OS directly (ConnectivityManager/NetworkCapabilities.
// NET_CAPABILITY_INTERNET on the active network, or the legacy
// NetworkInfo.isConnected), with no transport restriction at all -- WiFi,
// Ethernet, and cellular all satisfy it identically, because the OS itself
// already validated that network. No raw socket to any specific host is
// probed anywhere in that codebase for this decision.
//
// This mirrors that exactly instead of probing anything: connectivity_plus
// (already a listed dependency, previously unused) asks Windows the
// equivalent OS-level question. A result other than "none" means the OS
// considers some network connected, regardless of which transport it is.

bool _isConnected(List<ConnectivityResult> results) {
  // An EMPTY list is deliberately treated as connected, not disconnected.
  // `results.any(...)` on an empty list is false, which would report "no
  // network" -- and connectivity_plus on Windows returning an empty/unknown
  // result for an adapter configuration it doesn't recognise is a very
  // different thing from the OS actually saying "nothing is connected"
  // (which comes through explicitly as [ConnectivityResult.none]). Failing
  // OPEN here matters: a false "disconnected" strands the player on the
  // no-internet screen with nothing to recover it, whereas a false
  // "connected" just means the next real network call reports the real
  // error, which is both recoverable and far easier to diagnose.
  if (results.isEmpty) return true;
  return results.any((r) => r != ConnectivityResult.none);
}

/// Whether the OS currently reports any connected network -- WiFi, Ethernet,
/// mobile, or VPN all count equally, exactly matching how the Android
/// reference implementation treats this (no transport is special-cased).
Future<bool> isOsNetworkConnected() async {
  final results = await Connectivity().checkConnectivity();
  final connected = _isConnected(results);
  // Logs the RAW transport list, not just the boolean -- "stuck on
  // Connecting over Ethernet but fine on Wi-Fi" is impossible to diagnose
  // without knowing whether Windows reported [ethernet], [none], [other],
  // or nothing at all for that adapter.
  debug.debugLog('Connectivity', 'checkConnectivity -> $results (connected=$connected)');
  return connected;
}

/// Emits the OS-level connectivity state (see [isOsNetworkConnected]) once
/// immediately and again on every change connectivity_plus reports.
Stream<bool> osNetworkConnectivityStream() async* {
  yield await isOsNetworkConnected();
  yield* Connectivity().onConnectivityChanged.map((results) {
    final connected = _isConnected(results);
    debug.debugLog(
        'Connectivity', 'onConnectivityChanged -> $results (connected=$connected)');
    return connected;
  });
}
