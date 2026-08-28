import 'package:flutter/material.dart';

import 'package:digital_signage/utils/globle_variable.dart';

/// Player Configuration's "Show touch feedback" setting -- briefly shows a
/// blue circle where the user touched. Wraps [child] with a translucent
/// [Listener] so it only observes pointer-down events and never intercepts
/// them, leaving every screen's own tap handling (campaign zone taps,
/// interactivity regions, etc.) untouched.
class TouchFeedbackOverlay extends StatefulWidget {
  final Widget child;

  const TouchFeedbackOverlay({required this.child, super.key});

  @override
  State<TouchFeedbackOverlay> createState() => _TouchFeedbackOverlayState();
}

class _TouchFeedbackOverlayState extends State<TouchFeedbackOverlay> {
  Offset? _position;
  int _rippleId = 0;

  void _onPointerDown(PointerDownEvent event) {
    if (!touchFeedbackEnabled.value) return;
    final id = ++_rippleId;
    setState(() => _position = event.localPosition);
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted && id == _rippleId) {
        setState(() => _position = null);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      child: Stack(
        children: [
          widget.child,
          if (_position != null)
            Positioned(
              left: _position!.dx - 25,
              top: _position!.dy - 25,
              child: IgnorePointer(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 1.0, end: 0.0),
                  duration: const Duration(milliseconds: 400),
                  builder: (context, opacity, _) => Opacity(
                    opacity: opacity,
                    child: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.blue.withOpacity(0.4),
                        border: Border.all(color: Colors.blue, width: 2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
