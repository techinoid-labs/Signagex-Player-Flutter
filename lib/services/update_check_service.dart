// Checks whether a newer Windows build has been published, and can
// download + silently run its installer -- the player-side half of the
// player-releases backend feature (D:\SignageX\signageX-backend,
// src/modules/player-releases). See UpdateBanner (main.dart) for the UI.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'package:shared_preferences/shared_preferences.dart';

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

/// True only when [latest] is a *strictly newer* build than [current].
///
/// Build ids are the CI run number formatted as "vN" (see [appBuildId]). Only a
/// strictly greater N is an update: equal or older never updates -- this avoids
/// silently downgrading, and avoids an update/restart loop if the feed's version
/// string ever fails to match the installed binary's baked id. Anything that
/// doesn't parse as an integer build number (empty, "dev", "vX", "13beta") is
/// treated as "not newer" -- logged by the caller, never nags. If the versioning
/// scheme ever becomes semver, replace the integer compare with a semver one.
bool isNewerBuild(String current, String latest) {
  final c = _parseBuildNumber(current);
  final l = _parseBuildNumber(latest);
  if (c == null || l == null) return false;
  return l > c;
}

int? _parseBuildNumber(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final body = (trimmed[0] == 'v' || trimmed[0] == 'V')
      ? trimmed.substring(1)
      : trimmed;
  return int.tryParse(body);
}

// --- Post-update identity / retry protection -------------------------------
// Strict version ordering (isNewerBuild) stops downgrades and formatting-based
// false updates, but cannot stop a loop by itself: if an installed build keeps
// identifying as OLDER than the target it was updated to, `latest > current`
// stays true forever and the player re-installs the same target every cycle. So
// bind attempts to a specific target (counted at install-launch, NOT per check,
// so an un-actioned banner never inflates them), verify what actually installed
// on the next check, and give up on a target after a few failed attempts --
// re-arming only when a strictly higher build appears.
const String _kAttemptTarget = 'update_attempt_target';
const String _kAttemptCount = 'update_attempt_count';
const String _kAbandonedTarget = 'update_abandoned_target';

class UpdateGate {
  final bool offer;
  final String? attemptTarget;
  final int attemptCount;
  final String? abandonedTarget;
  const UpdateGate({
    required this.offer,
    this.attemptTarget,
    this.attemptCount = 0,
    this.abandonedTarget,
  });
}

/// Records that an install of [target] is being launched: bump the counter for
/// the same target, else start fresh. Counted at install time, not per check.
({String attemptTarget, int attemptCount}) recordAttempt(
    String target, String? lastTarget, int lastCount) {
  if (target == lastTarget) {
    return (attemptTarget: target, attemptCount: lastCount + 1);
  }
  return (attemptTarget: target, attemptCount: 1);
}

/// At check time, reconcile the last recorded install attempt against the build
/// that is actually running, retire an exhausted target, re-arm on a higher
/// build, and decide whether to offer [latest].
UpdateGate reconcileAndGate({
  required String current,
  required String latest,
  String? attemptTarget,
  int attemptCount = 0,
  String? abandonedTarget,
  int maxAttempts = 3,
}) {
  if (attemptTarget != null) {
    if (current == attemptTarget) {
      attemptTarget = null; // the attempted build is now running -> success
      attemptCount = 0;
    } else if (attemptCount >= maxAttempts) {
      abandonedTarget = attemptTarget; // installed repeatedly, still older
      attemptTarget = null;
      attemptCount = 0;
    }
  }
  if (abandonedTarget != null && isNewerBuild(abandonedTarget, latest)) {
    abandonedTarget = null; // a strictly higher build supersedes the abandon
  }
  final offer = isNewerBuild(current, latest) && latest != abandonedTarget;
  return UpdateGate(
    offer: offer,
    attemptTarget: attemptTarget,
    attemptCount: attemptCount,
    abandonedTarget: abandonedTarget,
  );
}

Future<void> _saveUpdateGate(SharedPreferences prefs, UpdateGate gate) async {
  if (gate.attemptTarget == null) {
    await prefs.remove(_kAttemptTarget);
    await prefs.remove(_kAttemptCount);
  } else {
    await prefs.setString(_kAttemptTarget, gate.attemptTarget!);
    await prefs.setInt(_kAttemptCount, gate.attemptCount);
  }
  if (gate.abandonedTarget == null) {
    await prefs.remove(_kAbandonedTarget);
  } else {
    await prefs.setString(_kAbandonedTarget, gate.abandonedTarget!);
  }
}

class UpdateCheckService {
  Future<UpdateInfo?> checkForUpdate() async {
    if (!Platform.isWindows || appBuildId == 'dev') return null;

    try {
      final response = await ApiRepository()
          .fetchData('player-releases/latest?platform=windows');
      final latestVersion = (response?['version'] ?? '').toString();
      final downloadUrl = (response?['downloadUrl'] ?? '').toString();
      if (latestVersion.isEmpty || downloadUrl.isEmpty) {
        return null;
      }
      // Decide whether to offer this build: strict ordering (no downgrade, no
      // formatting-based false updates) PLUS reconcile-and-bound, so a target
      // that keeps installing yet stays older can't loop forever.
      final prefs = await SharedPreferences.getInstance();
      final gate = reconcileAndGate(
        current: appBuildId,
        latest: latestVersion,
        attemptTarget: prefs.getString(_kAttemptTarget),
        attemptCount: prefs.getInt(_kAttemptCount) ?? 0,
        abandonedTarget: prefs.getString(_kAbandonedTarget),
      );
      await _saveUpdateGate(prefs, gate);
      if (!gate.offer) {
        await _debugLog(
            'checkForUpdate: current=$appBuildId latest=$latestVersion -- not offering '
            '(newer=${isNewerBuild(appBuildId, latestVersion)} abandoned=${gate.abandonedTarget} attempts=${gate.attemptCount})');
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

  Future<bool> runInstallerSilently(
      String installerPath, String targetVersion) async {
    try {
      // Record the install attempt for THIS target before launching -- the
      // installer is about to close this process, so it's our only chance.
      // reconcileAndGate() checks on the next launch whether the running build
      // actually became [targetVersion], and bounds repeats if it did not.
      final prefs = await SharedPreferences.getInstance();
      final rec = recordAttempt(
        targetVersion,
        prefs.getString(_kAttemptTarget),
        prefs.getInt(_kAttemptCount) ?? 0,
      );
      await prefs.setString(_kAttemptTarget, rec.attemptTarget);
      await prefs.setInt(_kAttemptCount, rec.attemptCount);
      // Detached and never awaited: setup.iss's CloseApplications will
      // close THIS running process as part of installing over it, so
      // waiting on the installer's exit code here would just deadlock the
      // app waiting on a process that's about to close it. RestartApplications
      // is disabled; /RESTARTPLAYER=1 launches the supervised player after setup.
      await Process.start(
        installerPath,
        ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/RESTARTPLAYER=1'],
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
