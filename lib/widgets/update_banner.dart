// Small, unobtrusive "update available" notification -- the VS Code/Cursor
// style the CMS team asked for: check quietly in the background, surface a
// corner banner when something newer exists, let a human tap it to install.
// Never auto-installs on its own; see UpdateCheckService for the actual
// check/download/install mechanics.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:digital_signage/services/update_check_service.dart';

class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

enum _BannerPhase { hidden, available, downloading, installing, failed }

class _UpdateBannerState extends State<UpdateBanner> {
  final _service = UpdateCheckService();
  Timer? _pollTimer;
  UpdateInfo? _available;
  _BannerPhase _phase = _BannerPhase.hidden;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    if (!Platform.isWindows) return;
    // Give the app time to get through pairing/downloading its own content
    // before this competes for bandwidth with an update check.
    Timer(const Duration(seconds: 30), _check);
    _pollTimer = Timer.periodic(const Duration(hours: 6), (_) => _check());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_phase != _BannerPhase.hidden) return; // already showing something
    final info = await _service.checkForUpdate();
    if (mounted && info != null) {
      setState(() {
        _available = info;
        _phase = _BannerPhase.available;
      });
    }
  }

  Future<void> _install() async {
    final info = _available;
    if (info == null || _phase != _BannerPhase.available) return;

    setState(() {
      _phase = _BannerPhase.downloading;
      _progress = 0;
    });

    final path = await _service.downloadInstaller(info.downloadUrl, (p) {
      if (mounted) setState(() => _progress = p);
    });

    if (path == null) {
      if (mounted) setState(() => _phase = _BannerPhase.failed);
      return;
    }

    if (mounted) setState(() => _phase = _BannerPhase.installing);
    final launched = await _service.runInstallerSilently(path);
    // On success the installer is about to close this process (setup.iss's
    // CloseApplications) and relaunch it (RestartApplications) -- nothing
    // left to do here. Only handle the failure case; there's no "installed"
    // state to show since the app won't be around to show it.
    if (!launched && mounted) {
      setState(() => _phase = _BannerPhase.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows || _phase == _BannerPhase.hidden) {
      return const SizedBox.shrink();
    }

    final (icon, label, tappable) = switch (_phase) {
      _BannerPhase.available => (
          Icons.system_update,
          'Update available — tap to install',
          true,
        ),
      _BannerPhase.downloading => (
          Icons.downloading,
          'Downloading update… ${(_progress * 100).round()}%',
          false,
        ),
      _BannerPhase.installing => (
          Icons.settings,
          'Installing update…',
          false,
        ),
      _BannerPhase.failed => (
          Icons.error_outline,
          'Update failed — tap to retry',
          true,
        ),
      _BannerPhase.hidden => (Icons.system_update, '', false),
    };

    return Positioned(
      right: 16,
      bottom: 16,
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: tappable
              ? () {
                  if (_phase == _BannerPhase.failed) {
                    setState(() => _phase = _BannerPhase.available);
                  }
                  _install();
                }
              : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xE6202020),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
