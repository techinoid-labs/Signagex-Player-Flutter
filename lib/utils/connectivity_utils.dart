import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

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
  return results.any((r) => r != ConnectivityResult.none);
}

/// Whether the OS currently reports any connected network -- WiFi, Ethernet,
/// mobile, or VPN all count equally, exactly matching how the Android
/// reference implementation treats this (no transport is special-cased).
Future<bool> isOsNetworkConnected() async {
  final results = await Connectivity().checkConnectivity();
  return _isConnected(results);
}

/// Emits the OS-level connectivity state (see [isOsNetworkConnected]) once
/// immediately and again on every change connectivity_plus reports.
Stream<bool> osNetworkConnectivityStream() async* {
  yield await isOsNetworkConnected();
  yield* Connectivity().onConnectivityChanged.map(_isConnected);
}
