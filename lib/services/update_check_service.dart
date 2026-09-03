// Checks whether a newer Windows build has been published, and can
// download + silently run its installer -- the player-side half of the
// player-releases backend feature (D:\SignageX\signageX-backend,
// src/modules/player-releases). See UpdateBanner (main.dart) for the UI.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'package:digital_signage/data/api_repository/api_repository.dart';
import 'package:digital_signage/utils/debug_log.dart' as debug;

Future<void> _debugLog(String message) =>
    debug.debugLog('UpdateCheckService', message);

// CI passes --dart-define=APP_BUILD_ID=<v1, v2, v3...> when building the
// production Windows installer (see .github/workflows/build-windows.yml) --
// that's what gets compared against player-releases/latest's "version".
// 'dev' (the default for any build that didn't set this, including every
// local/manual run) must never be treated as "out of date": comparing it
// against a real release's SHA would always differ and nag forever.
const String appBuildId =
    String.fromEnvironment('APP_BUILD_ID', defaultValue: 'dev');

class UpdateInfo {
  final String version;
  final String downloadUrl;
  const UpdateInfo({required this.version, required this.downloadUrl});
}

class UpdateCheckService {
  Future<UpdateInfo?> checkForUpdate() async {
    if (!Platform.isWindows || appBuildId == 'dev') return null;

    try {
      final response = await ApiRepository()
          .fetchData('player-releases/latest?platform=windows');
      final latestVersion = (response?['version'] ?? '').toString();
      final downloadUrl = (response?['downloadUrl'] ?? '').toString();
      if (latestVersion.isEmpty ||
          downloadUrl.isEmpty ||
          latestVersion == appBuildId) {
        return null;
      }

      await _debugLog(
          'checkForUpdate: current=$appBuildId latest=$latestVersion -- update available');
      return UpdateInfo(version: latestVersion, downloadUrl: downloadUrl);
    } catch (e) {
      // A 404 (no release published for this platform yet) lands here too --
      // that's an expected, quiet no-op, not a failure worth surfacing.
      await _debugLog('checkForUpdate: no update / check failed -- $e');
      return null;
    }
  }

  Future<String?> downloadInstaller(
    String downloadUrl,
    void Function(double progress) onProgress,
  ) async {
    try {
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}\\SignageX-Player-Update.exe';
      await Dio().download(
        downloadUrl,
        filePath,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress(received / total);
        },
      );
      await _debugLog('downloadInstaller: SUCCESS -- $filePath');
      return filePath;
    } catch (e) {
      await _debugLog('downloadInstaller: FAILED -- $e');
      return null;
    }
  }

  Future<bool> runInstallerSilently(String installerPath) async {
    try {
      // Detached and never awaited: setup.iss's CloseApplications will
      // close THIS running process as part of installing over it, so
      // waiting on the installer's exit code here would just deadlock the
      // app waiting on a process that's about to kill it. RestartApplications
      // brings the app back up once the new files are in place.
      await Process.start(
        installerPath,
        ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'],
        mode: ProcessStartMode.detached,
      );
      await _debugLog('runInstallerSilently: launched $installerPath');
      return true;
    } catch (e) {
      await _debugLog('runInstallerSilently: FAILED -- $e');
      return false;
    }
  }
}
