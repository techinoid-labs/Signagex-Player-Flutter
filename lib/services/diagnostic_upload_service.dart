import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'package:digital_signage/utils/constants.dart';
import 'package:digital_signage/utils/debug_log.dart' as debug;

Future<void> _debugLog(String message) =>
    debug.debugLog('DiagnosticUpload', message);

// Sends the player's own debug log to the backend so nobody has to retrieve
// it from the machine by hand.
//
// Diagnosing a field player previously meant asking whoever is near the
// screen to find
//   %AppData%\SignageX\SignageX Player\signagex_debug.log
// and send it over. That round trip costs hours, and in practice it
// repeatedly produced the wrong file -- a stale build's log, or one already
// rotated away -- so several investigations were spent just establishing
// which binary had produced the evidence.
//
// Uploads land at POST /v1/player-diagnostics/upload and are filed against
// the device by player_code, appearing in the CMS log view the backend
// already renders.

/// Name of the marker the watchdog writes next to the exe after it restarts
/// a player that exited abnormally. Its presence at startup means the
/// PREVIOUS run crashed, and its contents are that run's exit code.
const String kCrashMarkerFileName = 'crash-marker.txt';

class DiagnosticUploadService {
  DiagnosticUploadService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<File?> _logFile({required bool previous}) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final name =
          previous ? 'signagex_debug.log.previous' : 'signagex_debug.log';
      final file = File('${dir.path}\\$name');
      return await file.exists() ? file : null;
    } catch (error) {
      await _debugLog('could not locate log file: $error');
      return null;
    }
  }

  /// Uploads the current (or [previous]) debug log for [playerCode].
  ///
  /// Returns the stored URL, or null when there was nothing to send or the
  /// upload failed. Never throws: a diagnostics feature must not be able to
  /// take down the player it exists to diagnose.
  Future<String?> upload({
    required String playerCode,
    required String macAddress,
    required String reason,
    bool previous = false,
  }) async {
    if (playerCode.trim().isEmpty) {
      await _debugLog('skipped: no player code yet');
      return null;
    }
    // The backend requires this as a second factor: player_code on its own is
    // six hex characters shown on screen during pairing, so it cannot gate an
    // unauthenticated endpoint by itself.
    if (macAddress.trim().isEmpty) {
      await _debugLog('skipped: no MAC address known yet');
      return null;
    }

    final file = await _logFile(previous: previous);
    if (file == null) {
      await _debugLog('skipped: no ${previous ? "previous " : ""}log file');
      return null;
    }

    try {
      final bytes = await file.length();
      final form = FormData.fromMap({
        'player_code': playerCode,
        'mac_address': macAddress,
        'reason': reason,
        'file': await MultipartFile.fromFile(
          file.path,
          filename: previous
              ? 'signagex_debug.log.previous'
              : 'signagex_debug.log',
        ),
      });

      final response = await _dio.post(
        '${baseurl}player-diagnostics/upload',
        data: form,
        options: Options(
          // A player on a poor connection must not hang here forever; the
          // upload is best-effort and the next trigger will try again.
          sendTimeout: const Duration(minutes: 2),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );

      final url = (response.data is Map) ? response.data['url'] as String? : null;
      await _debugLog(
          'uploaded $bytes bytes (reason=$reason previous=$previous) -> $url');
      return url;
    } catch (error) {
      await _debugLog('upload FAILED (reason=$reason): $error');
      return null;
    }
  }

  /// If the watchdog recorded that the previous run exited abnormally,
  /// uploads that run's log and clears the marker.
  ///
  /// This is the valuable case: it arrives without anyone noticing there was
  /// a crash, and it carries the log of the run that actually died.
  Future<void> uploadPreviousRunIfItCrashed(
      String playerCode, String macAddress) async {
    File? marker;
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      marker = File('${exeDir.path}\\$kCrashMarkerFileName');
      if (!await marker.exists()) return;
    } catch (error) {
      await _debugLog('crash-marker check failed: $error');
      return;
    }

    String exitCode = 'unknown';
    try {
      exitCode = (await marker.readAsString()).trim();
    } catch (_) {}
    await _debugLog('previous run exited abnormally (exit=$exitCode) '
        '-- uploading its log');

    // Uploads the CURRENT log, not the ".previous" one. The debug log is a
    // single continuous file appended across runs -- it is only rotated when
    // it passes 8 MB -- so after a crash the live file still contains the
    // dead run's lines, and the replacement process simply appends below
    // them. ".previous" would usually be older history, or absent entirely.
    await upload(
      playerCode: playerCode,
      macAddress: macAddress,
      reason: 'crash',
    );

    // Cleared even when the upload failed, so a device that cannot reach the
    // backend does not retry the same crash on every launch forever.
    try {
      await marker.delete();
    } catch (error) {
      await _debugLog('could not clear crash marker: $error');
    }
  }
}
