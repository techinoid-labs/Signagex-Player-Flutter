import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/linux_configuration.dart';
import '../services/linux_interactivity.dart';

class LinuxConfiguredSurface extends StatefulWidget {
  final Widget child;
  final bool applySchedule;
  const LinuxConfiguredSurface({super.key, required this.child, this.applySchedule = true});
  @override
  State<LinuxConfiguredSurface> createState() => _LinuxConfiguredSurfaceState();
}
class _LinuxConfiguredSurfaceState extends State<LinuxConfiguredSurface> {
  Offset? touch;
  Timer? timer;
  @override
  void dispose() { timer?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    if (!Platform.isLinux) return widget.child;
    final settings = LinuxConfiguration.instance;
    return AnimatedBuilder(animation: settings, builder: (_, __) => Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        final size = context.size;
        if (size != null) LinuxInteractivity.instance.touch(event.localPosition.dx,event.localPosition.dy,size.width,size.height);
        if (!settings.touchFeedback) return;
        timer?.cancel();
        setState(() => touch = event.localPosition);
        timer = Timer(const Duration(milliseconds: 250), () { if (mounted) setState(() => touch = null); });
      },
      child: Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: Colors.black),
        Offstage(offstage: widget.applySchedule && !settings.working, child: widget.child),
        if (widget.applySchedule && !settings.working) const Positioned.fill(child: LinuxOffHoursView()),
        if (touch != null && settings.touchFeedback) Positioned(left:touch!.dx-16,top:touch!.dy-16,
          child: IgnorePointer(child: Container(width:32,height:32,decoration:BoxDecoration(shape:BoxShape.circle,color:Colors.blue.withOpacity(.5))))),
      ]),
    ));
  }
}

/// What shows outside the working schedule (CMS "Outside working hours"):
/// a message with the logo and the next opening time, a picture or video, or
/// black (also for "display off", where the screen itself is powered down).
class LinuxOffHoursView extends StatelessWidget {
  const LinuxOffHoursView({super.key});

  static String opensText(DateTime opens, DateTime now) {
    final time = '${opens.hour.toString().padLeft(2, '0')}:${opens.minute.toString().padLeft(2, '0')}';
    final today = DateTime(now.year, now.month, now.day);
    final days = DateTime(opens.year, opens.month, opens.day).difference(today).inDays;
    if (days == 0) return 'Opens today at $time';
    if (days == 1) return 'Opens tomorrow at $time';
    const names = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return 'Opens on ${names[opens.weekday - 1]} at $time';
  }

  @override
  Widget build(BuildContext context) {
    final config = LinuxConfiguration.instance;
    switch (config.offHoursMode) {
      case 'message':
        final opens = config.opensAt;
        return ColoredBox(
          color: Colors.black,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const ConfiguredPlayerLogo(fallback: SizedBox.shrink()),
                const SizedBox(height: 32),
                Text(config.offHoursMessage ?? '',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w600)),
                if (opens != null) ...[
                  const SizedBox(height: 16),
                  Text(opensText(opens, DateTime.now()),
                      style: const TextStyle(color: Colors.white70, fontSize: 24)),
                ],
              ]),
            ),
          ),
        );
      case 'content':
        final path = config.offHoursMediaPath;
        if (path == null) return const ColoredBox(color: Colors.black);
        return ColoredBox(
          color: Colors.black,
          child: config.offHoursVideo
              ? _OffHoursVideo(key: ValueKey(path), path: path)
              : Image.file(File(path), key: ValueKey(path), fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink()),
        );
      default:
        return const ColoredBox(color: Colors.black);
    }
  }
}

class _OffHoursVideo extends StatefulWidget {
  final String path;
  const _OffHoursVideo({super.key, required this.path});
  @override
  State<_OffHoursVideo> createState() => _OffHoursVideoState();
}

class _OffHoursVideoState extends State<_OffHoursVideo> {
  late final VideoPlayerController _controller = VideoPlayerController.file(File(widget.path));

  @override
  void initState() {
    super.initState();
    // Muted: the player mutes audio outside working hours anyway.
    _controller.initialize().then((_) async {
      await _controller.setLooping(true);
      await _controller.setVolume(0);
      await _controller.play();
      if (mounted) setState(() {});
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _controller.value.isInitialized
      ? Center(child: AspectRatio(aspectRatio: _controller.value.aspectRatio, child: VideoPlayer(_controller)))
      : const SizedBox.shrink();
}

class ConfiguredEmptyState extends StatelessWidget {
  final Widget child;
  const ConfiguredEmptyState({super.key, required this.child});
  @override
  Widget build(BuildContext context) => !Platform.isLinux ? child : AnimatedBuilder(
    animation: LinuxConfiguration.instance,
    builder: (_,__) => LinuxConfiguration.instance.hideMessages ? const ColoredBox(color:Colors.black) : child,
  );
}

class ConfiguredPlayerLogo extends StatelessWidget {
  final Widget fallback;
  const ConfiguredPlayerLogo({super.key, required this.fallback});
  @override
  Widget build(BuildContext context) => !Platform.isLinux ? fallback : AnimatedBuilder(
    animation: LinuxConfiguration.instance,
    builder: (_,__) {
      final config = LinuxConfiguration.instance;
      if (config.removeLogo) return const SizedBox.shrink();
      final path = config.logoPath;
      return path == null ? fallback : Image.file(File(path),key:ValueKey(config.revision),width:160,height:48,fit:BoxFit.contain,errorBuilder:(_,__,___)=>fallback);
    },
  );
}
