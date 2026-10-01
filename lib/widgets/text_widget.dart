import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

class TextWidget extends StatelessWidget {
  final String html;
  final String text;
  final VoidCallback onTextEnd;
  final String transitionType;

  /// Screen pixels: the CMS value already scaled with the canvas. Not
  /// rounded -- the editor's size is the size.
  final double? fontSize;
  final String? fontFamily;
  final String? fill;
  final double? strokeWidth;
  final double? shadowBlur;

  const TextWidget({
    super.key,
    required this.html,
    required this.text,
    required this.onTextEnd,
    required this.transitionType,
    this.fontSize,
    this.fontFamily,
    this.fill,
    this.strokeWidth,
    this.shadowBlur,
  });

  /// The CMS sends a CSS font list -- "'Open Sans', sans-serif". Flutter
  /// wants bare family names: quotes stripped, and CSS generic families
  /// dropped since they name no real font. Passed through whole, the list
  /// matched no font at all and the text fell back to the system font.
  static const _genericFamilies = {
    'serif',
    'sans-serif',
    'monospace',
    'cursive',
    'fantasy',
    'system-ui',
  };

  List<String> _fontFamilies() {
    return (fontFamily ?? '')
        .split(',')
        .map((f) => f.trim().replaceAll(RegExp(r'''^["']|["']$'''), '').trim())
        .where((f) => f.isNotEmpty && !_genericFamilies.contains(f.toLowerCase()))
        .toList();
  }

  // CSS colour keywords -- what the editor's canvas means by them. The
  // editor's default fill is "black", which a hex-only parser turned into
  // the white fallback.
  static const _namedColors = <String, Color>{
    'black': Color(0xFF000000),
    'white': Color(0xFFFFFFFF),
    'red': Color(0xFFFF0000),
    'green': Color(0xFF008000),
    'blue': Color(0xFF0000FF),
    'yellow': Color(0xFFFFFF00),
    'orange': Color(0xFFFFA500),
    'purple': Color(0xFF800080),
    'grey': Color(0xFF808080),
    'gray': Color(0xFF808080),
  };

  Color _parseColor(String? value) {
    final v = value?.trim().toLowerCase() ?? '';
    final named = _namedColors[v];
    if (named != null) return named;
    final hex = v.replaceFirst('#', '');
    if (RegExp(r'^[0-9a-f]{6}$').hasMatch(hex)) {
      return Color(int.parse('FF$hex', radix: 16));
    }
    return const Color(0xFF000000);
  }

  @override
  Widget build(BuildContext context) {
    if (text.trim().isNotEmpty) return _buildCmsText();

    // No plain text to draw -- fall back to the editor's HTML.
    final families = _fontFamilies();
    return SizedBox.expand(
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: HtmlWidget(
            html,
            textStyle: TextStyle(
              color: _parseColor(fill),
              fontSize: fontSize ?? 16,
              fontFamily: families.isEmpty ? null : families.first,
              fontFamilyFallback:
                  families.length > 1 ? families.sublist(1) : null,
            ),
          ),
        ),
      ),
    );
  }

  /// The text exactly as the CMS editor draws it.
  ///
  /// The editor is a Konva Text node (Canvas/DraggableText.tsx):
  ///
  ///   <Text x y width={item.width} fontSize={item.fontSize} wrap="word"
  ///         align="center" stroke strokeWidth shadowBlur .../>
  ///
  /// so: the stored font size (scaled only with the canvas), wrapped at the
  /// object's width, centred horizontally, growing down from the top,
  /// Konva's line height of 1, no height of its own -- a line that does not
  /// fit flows onto the next one below the box. The old FittedBox shrank
  /// it instead, so text came out smaller than designed.
  Widget _buildCmsText() {
    final size = math.max(1.0, fontSize ?? 16);
    final stroke = strokeWidth ?? 0;
    final blur = shadowBlur ?? 0;
    final families = _fontFamilies();
    TextStyle style({Paint? foreground, Color? color, List<Shadow>? shadows}) =>
        TextStyle(
          color: color,
          foreground: foreground,
          fontSize: size,
          height: 1.0,
          fontFamily: families.isEmpty ? null : families.first,
          fontFamilyFallback:
              families.length > 1 ? families.sublist(1) : null,
          shadows: shadows,
        );
    Widget line(TextStyle s) => Text(
          text,
          textAlign: TextAlign.center,
          softWrap: true,
          style: s,
        );
    final filled = line(style(
      color: _parseColor(fill),
      // Konva: shadowColor black, opacity 1, offset 0.
      shadows: blur > 0 ? [Shadow(color: Colors.black, blurRadius: blur)] : null,
    ));
    return OverflowBox(
      alignment: Alignment.topCenter,
      minHeight: 0,
      maxHeight: double.infinity,
      child: stroke > 0
          // Konva draws the fill, then the stroke over it (stroke defaults
          // to black in the editor).
          ? Stack(children: [
              filled,
              line(style(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = stroke
                  ..color = Colors.black,
              )),
            ])
          : filled,
    );
  }
}

class SimpleText extends StatelessWidget {
  final String text;
  final double fontSize;
  final FontWeight fontWeight;

  const SimpleText({
    required this.text,
    this.fontSize = 13.0,
    this.fontWeight = FontWeight.normal,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      textAlign: TextAlign.center,
      text,
      style: TextStyle(
        color: Colors.white,
        fontSize: fontSize,
        fontWeight: fontWeight,
      ),
    );
  }
}
