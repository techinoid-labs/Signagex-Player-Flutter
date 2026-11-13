import 'dart:async';
import 'dart:io';
import 'package:video_player/video_player.dart';
import 'linux_configuration.dart';
import 'linux_interactivity.dart';
import 'linux_playback_health.dart';
import 'linux_diagnostics.dart';

class LinuxPlaybackGate {
  static final instance = LinuxPlaybackGate._();
  LinuxPlaybackGate._() {
    LinuxConfiguration.instance.addListener(update);
    LinuxInteractivity.instance.addListener(update);
  }
  final Stopwatch _clock = Stopwatch()..start();
  final Map<VideoPlayerController, LinuxPlaybackHealth> _health = {};
  Timer? _monitor;
  final Map<VideoPlayerController, bool> _players = {};
  final Set<VideoPlayerController> _paused = {};
  final Set<VideoPlayerController> _busy = {};
  final Map<VideoPlayerController, void Function()> _listeners = {};
  void register(VideoPlayerController controller, {bool triggered = false}) {
    if (!Platform.isLinux || _players.containsKey(controller)) return;
    _players[controller] = triggered;
    _health[controller] = LinuxPlaybackHealth();
    _monitor ??= Timer.periodic(const Duration(seconds: 5), (_) {
      for (final player in _players.keys.toList()) {
        _checkProgress(player);
      }
    });
    void listener() {
      _checkProgress(controller);
      unawaited(_apply(controller));
    }

    _listeners[controller] = listener;
    controller.addListener(listener);
    listener();
  }

  void remove(VideoPlayerController? controller) {
    if (controller == null) return;
    final listener = _listeners.remove(controller);
    if (listener != null) controller.removeListener(listener);
    _players.remove(controller);
    _health.remove(controller);
    if (_players.isEmpty) { _monitor?.cancel(); _monitor = null; }
    _paused.remove(controller);
    _busy.remove(controller);
  }

  void update() {
    for (final controller in _players.keys.toList()) {
      unawaited(_apply(controller));
    }
  }

  bool _allowed(VideoPlayerController controller) {
    final triggers = LinuxInteractivity.instance;
    return LinuxConfiguration.instance.working &&
        (_players[controller] == true ? triggers.active != null
            : triggers.active == null || triggers.overlay);
  }

  void _checkProgress(VideoPlayerController controller) {
    final health = _health[controller];
    if (health == null || _busy.contains(controller)) return;
    final value = controller.value;
    final ended = !value.isLooping && value.duration > Duration.zero &&
        value.position >= value.duration;
    if (!health.sample(now: _clock.elapsedMilliseconds, position: value.position,
        expectedToPlay: value.isInitialized && value.isPlaying &&
            !ended && _allowed(controller), buffering: value.isBuffering)) return;
    unawaited(_recover(controller));
  }

  Future<void> _recover(VideoPlayerController controller) async {
    if (!_busy.add(controller)) return;
    try {
      await LinuxDiagnostics.instance.record(
          'Video position stopped progressing; attempting decoder recovery',
          'error', incident: 'playback_stall');
      final position = controller.value.position;
      await (() async {
        await controller.pause();
        await controller.seekTo(position);
        if (_players.containsKey(controller) && _allowed(controller)) {
          await controller.play();
        }
      })().timeout(const Duration(seconds: 10));
    } catch (_) {
      // A hung decoder must not leave the gate permanently busy. The next
      // monitor deadline retries; an event-loop heartbeat alone is no longer
      // our only playback evidence.
    } finally { _busy.remove(controller); }
  }

  Future<void> _apply(VideoPlayerController controller) async {
    if (_busy.contains(controller) ||
        !_players.containsKey(controller) ||
        !controller.value.isInitialized) return;
    final allowed = _allowed(controller);
    _busy.add(controller);
    try {
      if (!allowed && controller.value.isPlaying) {
        _paused.add(controller);
        await controller.pause();
      }
      if (allowed && _paused.remove(controller)) await controller.play();
    } catch (_) {
      remove(controller);
    } finally {
      _busy.remove(controller);
    }
  }
}
