import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

// Diagnostic-only file logger for release-mode Windows builds -- print()/
// debugPrint() output goes nowhere visible (GUI-subsystem exe, no console
// attached regardless of how it's launched).
//
// This used to be four separate copies of the same function (one each in
// MqttViewModel, MqttClientService, DeviceSettingsViewModel, CampaignView),
// each independently opening/appending/closing the file with no shared
// synchronization. Concurrent bursts of calls from different files raced
// against each other and silently corrupted or dropped lines -- confirmed
// in practice: a composition with ~10 zones logging in a tight loop lost
// every single one of its entries while simpler campaigns' entries survived.
// Every call now funnels through one shared Future chain so writes to the
// underlying file happen strictly one at a time, regardless of which file
// or how many callers fire concurrently.
Future<void> _writeChain = Future.value();

Future<void> debugLog(String tag, String message) {
  final next = _writeChain.then((_) async {
    try {
      final dir = await getApplicationSupportDirectory();
      // Confirmed real-world failure mode: this directory does not always
      // already exist when this is first called -- a fresh install, or a
      // reinstall over an uninstall (which deliberately deletes this exact
      // folder, see setup.iss's [UninstallDelete]), starts with nothing here
      // until something creates it. File.writeAsString does NOT create
      // missing parent directories on Windows; it throws
      // PathNotFoundException instead, which the catch below used to
      // swallow with zero trace -- "the log file is never created at all"
      // looked identical to every other silent failure this could have.
      await Directory(dir.path).create(recursive: true);
      final file = File('${dir.path}\\signagex_debug.log');
      await file.writeAsString(
        '${DateTime.now().toIso8601String()} [$tag] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      // Still must never let a logging failure become the app's OWN crash
      // or block startup -- but silently doing nothing made every possible
      // cause (missing directory, permissions, disk full, antivirus
      // interference) indistinguishable from every other. stderr costs
      // nothing and is free if anyone ever does run this from a console/
      // debug build; there is deliberately no second file-based fallback
      // here, since a logger that itself needs a working log to debug its
      // own failures is not a fallback.
      stderr.writeln('[$tag] debugLog failed: $e');
    }
  });
  _writeChain = next;
  return next;
}
