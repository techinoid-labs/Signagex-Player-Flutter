import 'dart:async';

import 'package:media_kit/media_kit.dart' as media_kit;

import 'kiosk_campaign.dart';

/// Pauses a signage video (and its sound) while a kiosk campaign covers the
/// screen, and resumes it where it was when the kiosk ends. Only a video this
/// class paused is resumed.
class KioskVideoPause {
  KioskVideoPause(this._player) {
    KioskCampaignService.instance.addListener(_apply);
  }

  final media_kit.Player Function() _player;
  bool _paused = false;

  static bool get _covering => KioskCampaignService.instance.showing;

  void _apply() {
    final player = _player();
    if (_covering) {
      if (player.state.playing) {
        _paused = true;
        unawaited(player.pause().catchError((_) {}));
      }
    } else if (_paused) {
      _paused = false;
      unawaited(player.play().catchError((_) {}));
    }
  }

  /// Call after the widget itself starts playback: a video that opens under
  /// a kiosk stays paused.
  Future<void> afterPlay() async {
    if (!_covering) return;
    _paused = true;
    try {
      await _player().pause();
    } catch (_) {}
  }

  void dispose() => KioskCampaignService.instance.removeListener(_apply);
}
