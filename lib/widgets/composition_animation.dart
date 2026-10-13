import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Plays the animation the CMS composition editor stores on an object:
/// `{type, showAfter, showFor}` (signageX-frontend Canvas/Animation.tsx).
///
/// The editor only records the choice -- nothing in the CMS plays it -- so
/// the timing here is the player's reading of its two fields:
///
///   * entry types (fade-in, slide-*, rotate): hidden for `showAfter`
///     seconds, then animate in over `showFor` seconds and stay.
///   * fade-out: shown, then after `showAfter` seconds fade out over
///     `showFor` seconds and stay hidden.
///   * continuous types (wiggle-horizontal, pulse-scale, pulse-fade,
///     spin-continuous): start after `showAfter` seconds and repeat, one
///     cycle every `showFor` seconds.
///
/// Slides enter from the named side, by the object's own size, so the
/// motion is the same at any screen resolution.
class CompositionAnimation extends StatefulWidget {
  final Map<String, dynamic>? spec;
  final Widget child;

  const CompositionAnimation({
    super.key,
    required this.spec,
    required this.child,
  });

  @override
  State<CompositionAnimation> createState() => _CompositionAnimationState();
}

class _CompositionAnimationState extends State<CompositionAnimation>
    with SingleTickerProviderStateMixin {
  static const _continuous = {
    'wiggle-horizontal',
    'pulse-scale',
    'pulse-fade',
    'spin-continuous',
  };

  AnimationController? _controller;
  Timer? _delay;
  String _type = '';

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant CompositionAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_specKey(oldWidget.spec) != _specKey(widget.spec)) {
      _stop();
      _start();
    }
  }

  String _specKey(Map<String, dynamic>? spec) =>
      spec == null ? '' : '${spec['type']}|${spec['showAfter']}|${spec['showFor']}';

  static double _seconds(dynamic value, double fallback) {
    final v = value is num ? value.toDouble() : double.tryParse('$value');
    return v == null || v.isNaN || v < 0 ? fallback : v;
  }

  void _start() {
    final spec = widget.spec;
    _type = spec?['type']?.toString() ?? '';
    if (spec == null || _type.isEmpty || _type == 'none') return;

    final after = _seconds(spec['showAfter'], 0);
    final duration = math.max(0.1, _seconds(spec['showFor'], 1));
    final controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (duration * 1000).round()),
    );
    _controller = controller;
    _delay = Timer(Duration(milliseconds: (after * 1000).round()), () {
      if (!mounted) return;
      if (_continuous.contains(_type)) {
        controller.repeat();
      } else {
        controller.forward();
      }
    });
  }

  void _stop() {
    _delay?.cancel();
    _delay = null;
    _controller?.dispose();
    _controller = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return widget.child;
    return AnimatedBuilder(
      animation: controller,
      child: widget.child,
      builder: (context, child) => _apply(controller.value, child!),
    );
  }

  Widget _apply(double t, Widget child) {
    final e = Curves.easeOut.transform(t);
    switch (_type) {
      case 'fade-in':
        return Opacity(opacity: e, child: child);
      case 'fade-out':
        return Opacity(opacity: 1 - e, child: child);
      case 'slide-left':
        return _slide(Offset(-(1 - e), 0), e, child);
      case 'slide-right':
        return _slide(Offset(1 - e, 0), e, child);
      case 'slide-top':
        return _slide(Offset(0, -(1 - e)), e, child);
      case 'slide-bottom':
        return _slide(Offset(0, 1 - e), e, child);
      case 'rotate':
        return Opacity(
          opacity: e,
          child: Transform.rotate(angle: -(1 - e) * math.pi, child: child),
        );
      case 'wiggle-horizontal':
        return FractionalTranslation(
          translation: Offset(0.03 * math.sin(2 * math.pi * t), 0),
          child: child,
        );
      case 'pulse-scale':
        return Transform.scale(
          scale: 1 + 0.1 * math.sin(math.pi * t),
          child: child,
        );
      case 'pulse-fade':
        return Opacity(
          opacity: 1 - 0.6 * math.sin(math.pi * t),
          child: child,
        );
      case 'spin-continuous':
        return Transform.rotate(angle: 2 * math.pi * t, child: child);
      default:
        return child;
    }
  }

  Widget _slide(Offset translation, double opacity, Widget child) {
    return Opacity(
      opacity: opacity,
      child: FractionalTranslation(translation: translation, child: child),
    );
  }
}
