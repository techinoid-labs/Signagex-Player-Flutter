import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
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
        if (touch != null && settings.touchFeedback) Positioned(left:touch!.dx-16,top:touch!.dy-16,
          child: IgnorePointer(child: Container(width:32,height:32,decoration:BoxDecoration(shape:BoxShape.circle,color:Colors.blue.withOpacity(.5))))),
      ]),
    ));
  }
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
