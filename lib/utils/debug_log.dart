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
      final file = File('${dir.path}\\signagex_debug.log');
      await file.writeAsString(
        '${DateTime.now().toIso8601String()} [$tag] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  });
  _writeChain = next;
  return next;
}
