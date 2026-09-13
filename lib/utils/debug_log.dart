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

// This log had NO size limit. Measured on the test machine, it reached
// 1.35 MB in about two hours of normal playback -- roughly 16 MB/day, and
// a signage player is expected to run unattended for months or years. That
// is unbounded disk growth on a box nobody logs into, and a full disk on a
// kiosk is an outage, not a cosmetic problem. (The diagnostic logging added
// while chasing the scheduling and connectivity bugs made it chattier,
// which makes bounding it more urgent, not less.)
//
// Matches what the watchdog already does for its own log
// (windows/runner/watchdog_main.cpp's Log(): rotate past a cap, keep one
// ".previous"), just with a larger cap since this one is far more verbose.
// Worst case on disk is _kMaxLogBytes * 2. Keeping the previous file is
// what preserves the run leading UP TO a crash, usually the interesting
// part.
const int _kMaxLogBytes = 8 * 1024 * 1024;

// Tracked in memory so the common path costs nothing: the file is stat'd
// once per process, not on every write.
int? _currentLogBytes;

Future<void> _rotateIfOversized(File file) async {
  try {
    _currentLogBytes ??= (await file.exists()) ? await file.length() : 0;
    if (_currentLogBytes! < _kMaxLogBytes) return;
    // rename() replaces an existing destination, so the older ".previous"
    // is discarded rather than accumulating a third copy.
    await file.rename(file.path + '.previous');
    _currentLogBytes = 0;
  } catch (e) {
    // A failed rotation must not stop logging -- losing rotation is far
    // less bad than losing the diagnostics. Reset so it is retried on the
    // next write rather than re-failing on every write forever.
    _currentLogBytes = 0;
    stderr.writeln('debugLog rotation failed: $e');
  }
}

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
      await _rotateIfOversized(file);
      await file.writeAsString(
        '${DateTime.now().toIso8601String()} [$tag] $message\n',
        mode: FileMode.append,
        flush: true,
      );
      // Approximate (ASCII assumed, ~40 chars of ISO-8601 timestamp and
      // punctuation). Deliberately not exact: this only decides WHEN to
      // rotate, and the alternative -- stat'ing the file on every single
      // write -- costs a syscall per log line to enforce a soft cap.
      _currentLogBytes = (_currentLogBytes ?? 0) + message.length + tag.length + 40;
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
