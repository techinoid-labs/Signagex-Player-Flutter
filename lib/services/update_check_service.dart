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

// Decimal digits only. Dart's int.tryParse (with no explicit radix)
// auto-detects a "0x"/"0X" prefix and parses it as hexadecimal -- without
// this check, "v0x10" parsed as the integer 16, silently accepting a
// build-id format the CI workflow never actually produces (it always
// writes "v${{ github.run_number }}", a plain decimal). Validating the
// grammar explicitly, then parsing with an explicit radix: 10 (which does
// *not* auto-detect "0x", unlike an unspecified radix), closes that gap.
final RegExp _kDecimalBuildNumber = RegExp(r'^[0-9]+$');

int? _parseBuildNumber(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final body = (trimmed[0] == 'v' || trimmed[0] == 'V')
      ? trimmed.substring(1)
      : trimmed;
  if (!_kDecimalBuildNumber.hasMatch(body)) return null;
  return int.tryParse(body, radix: 10);
}

// W18: the installer signing certificate's subject name a valid signature
// must chain to. This is a placeholder -- authenticity validation is not
// a real control until this is replaced with the actual certificate
// subject the CI pipeline signs releases with (a backend/ops dependency:
// obtain a code-signing certificate, wire CI to sign every installer with
// it, then put that certificate's subject name here). Deliberately left
// obviously unset rather than a guessed real-looking value, so
// verifyInstallerAuthenticity fails closed (see below) until this is done
// for real, instead of silently no-op'ing.
const String kTrustedInstallerPublisherSubject =
    'UNSET -- see kTrustedInstallerPublisherSubject in update_check_service.dart';

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

// W19: isNewerBuild already compares build ids by their normalized numeric
// identity (parsing "v13"/"V13"/" v13 " down to 13), but recordAttempt and
// reconcileAndGate below originally compared the raw strings directly.
// Reproduced: with target "v13" abandoned/in-progress, a feed response of
// "13" (same build, different formatting) fails a raw `==`/`!=` check
// against "v13" -- recordAttempt would wrongly treat it as a brand new
// target (resetting the attempt count instead of continuing to count
// toward abandonment), and reconcileAndGate would fail to recognize "13" as
// the already-abandoned "v13" and offer it again. Comparing by parsed
// identity instead of raw string fixes both.
bool _sameBuildIdentity(String? a, String? b) {
  if (a == null || b == null) return a == b;
  final na = _parseBuildNumber(a);
  final nb = _parseBuildNumber(b);
  if (na == null || nb == null) return a == b;
  return na == nb;
}

// W20: the same maxAttempts budget reconcileAndGate uses by default, shared
// with the launch-time gate in runInstallerSilently below so the two can
// never drift apart.
const int kMaxInstallAttempts = 3;

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
  if (_sameBuildIdentity(target, lastTarget)) {
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
  int maxAttempts = kMaxInstallAttempts,
}) {
  if (attemptTarget != null) {
    if (_sameBuildIdentity(current, attemptTarget)) {
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
  final offer =
      isNewerBuild(current, latest) && !_sameBuildIdentity(latest, abandonedTarget);
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
      // W18: HTTPS-only. A checksum/signature check below still catches
      // tampering, but refusing a non-HTTPS URL up front is a cheap,
      // independent layer against a downgrade to an interceptable channel.
      if (!downloadUrl.startsWith('https://')) {
        await _debugLog(
            'checkForUpdate: refusing non-HTTPS downloadUrl: $downloadUrl');
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
      // W10: same reasoning as the player asset downloads (mqtt_view_model.dart)
      // -- connect/receive timeouts plus an outer overall deadline, so a
      // stalled installer download can't hang indefinitely.
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ));
      await dio.download(
        downloadUrl,
        filePath,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress(received / total);
        },
      ).timeout(const Duration(minutes: 10)); // installers are larger than typical media assets
      await _debugLog('downloadInstaller: SUCCESS -- $filePath');
      return filePath;
    } catch (e) {
      await _debugLog('downloadInstaller: FAILED -- $e');
      return null;
    }
  }

  // W18: validates the downloaded installer's Authenticode signature
  // before it's ever allowed to run. A checksum alone (which this doesn't
  // even have today) only detects corruption, not a malicious substitution
  // -- this is what actually distinguishes "the real signed release" from
  // "any executable that happened to land at the download URL". Fails
  // closed: any missing/invalid signature, or the publisher placeholder
  // above not yet being replaced with the real signing certificate's
  // subject, refuses the install rather than proceeding anyway.
  Future<bool> verifyInstallerAuthenticity(String installerPath) async {
    if (kTrustedInstallerPublisherSubject.startsWith('UNSET')) {
      await _debugLog(
          'verifyInstallerAuthenticity: kTrustedInstallerPublisherSubject is '
          'not configured -- refusing to install until CI signs releases '
          'and this is set to that certificate\'s subject name.');
      return false;
    }
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '\$sig = Get-AuthenticodeSignature -LiteralPath \$args[0]; '
            'if (\$sig.Status -ne "Valid") { Write-Output "INVALID:\$(\$sig.Status)"; exit 1 }; '
            'Write-Output "VALID:\$(\$sig.SignerCertificate.Subject)"',
        installerPath,
      ]);
      final output = result.stdout.toString().trim();
      await _debugLog(
          'verifyInstallerAuthenticity: exitCode=${result.exitCode} output=$output stderr=${result.stderr}');
      if (result.exitCode != 0 || !output.startsWith('VALID:')) {
        return false;
      }
      final subject = output.substring('VALID:'.length);
      // Subject match, not just "a valid signature from someone" -- a
      // validly signed installer from an unrelated publisher must not
      // pass.
      if (!subject.contains(kTrustedInstallerPublisherSubject)) {
        await _debugLog(
            'verifyInstallerAuthenticity: signer subject "$subject" does not match trusted publisher');
        return false;
      }
      return true;
    } catch (e) {
      await _debugLog('verifyInstallerAuthenticity: FAILED -- $e');
      return false;
    }
  }

  Future<bool> runInstallerSilently(
      String installerPath, String targetVersion) async {
    // W18: authenticity gate -- see verifyInstallerAuthenticity. Nothing
    // below this point may run for an installer that doesn't pass it,
    // including the retry-bounding bookkeeping below: an installer that
    // fails this check is never actually launched, so it must not count
    // against targetVersion's attempt budget either.
    if (!await verifyInstallerAuthenticity(installerPath)) {
      await _debugLog(
          'runInstallerSilently: refusing to launch $installerPath -- failed authenticity check');
      return false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      // W20: enforce the retry budget HERE, immediately before launching --
      // recordAttempt only counted attempts; nothing previously stopped this
      // method itself from launching an already-exhausted target again.
      // reconcileAndGate() (where the budget was actually enforced) only
      // runs from checkForUpdate()'s scheduled poll -- a user tapping the
      // failed-banner's Retry button calls straight into this method without
      // ever going through that check again, so a target could be relaunched
      // an unbounded number of times in one session as long as the user kept
      // tapping Retry.
      final storedTarget = prefs.getString(_kAttemptTarget);
      final storedCount = prefs.getInt(_kAttemptCount) ?? 0;
      if (_sameBuildIdentity(targetVersion, storedTarget) &&
          storedCount >= kMaxInstallAttempts) {
        await _debugLog(
            'runInstallerSilently: refusing to launch $installerPath -- '
            'target $targetVersion already exhausted its retry budget '
            '($storedCount attempts)');
        return false;
      }
      // Record the install attempt for THIS target before launching -- the
      // installer is about to close this process, so it's our only chance.
      // reconcileAndGate() checks on the next scheduled check whether the
      // running build actually became [targetVersion], and bounds repeats
      // if it did not.
      final rec = recordAttempt(targetVersion, storedTarget, storedCount);
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
