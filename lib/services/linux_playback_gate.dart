import 'dart:async';
import 'dart:io';
import 'package:video_player/video_player.dart';
import 'linux_configuration.dart';
import 'linux_interactivity.dart';

class LinuxPlaybackGate {
  static final instance = LinuxPlaybackGate._();
  LinuxPlaybackGate._() {
    LinuxConfiguration.instance.addListener(update);
    LinuxInteractivity.instance.addListener(update);
  }
  final Map<VideoPlayerController, bool> _players = {};
  final Set<VideoPlayerController> _paused = {};
  final Set<VideoPlayerController> _busy = {};
  final Map<VideoPlayerController, void Function()> _listeners = {};
  void register(VideoPlayerController controller, {bool triggered = false}) {
    if (!Platform.isLinux || _players.containsKey(controller)) return;
    _players[controller] = triggered;
    void listener() {
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
    _paused.remove(controller);
    _busy.remove(controller);
  }

  void update() {
    for (final controller in _players.keys.toList()) {
      unawaited(_apply(controller));
    }
  }

  Future<void> _apply(VideoPlayerController controller) async {
    if (_busy.contains(controller) ||
        !_players.containsKey(controller) ||
        !controller.value.isInitialized) return;
    final triggers = LinuxInteractivity.instance;
    final allowed = LinuxConfiguration.instance.working &&
        (_players[controller] == true
            ? triggers.active != null
            : triggers.active == null || triggers.overlay);
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
