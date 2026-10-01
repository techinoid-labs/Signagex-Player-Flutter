import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

class TextWidget extends StatelessWidget {
  final String html;
  final String text;
  final VoidCallback onTextEnd;
  final String transitionType;
  final int? fontSize;
  final String? fontFamily;
  final String? fill;
  final int? strokeWidth;
  final int? shadowBlur;

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

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(fill) ?? Colors.white;
    final families = _fontFamilies();
    final style = TextStyle(
      color: color,
      fontSize: (fontSize ?? 24).toDouble(),
      fontFamily: families.isEmpty ? null : families.first,
      fontFamilyFallback: families.length > 1 ? families.sublist(1) : null,
      shadows: shadowBlur != null && shadowBlur! > 0
          ? [Shadow(color: Colors.black54, blurRadius: shadowBlur!.toDouble())]
          : null,
    );
    final content = html.trim().isNotEmpty ? html : text;

    return SizedBox.expand(
      child: Center(
        child: FittedBox(
          // Never let a computed fontSize (however it was scaled upstream)
          // overflow/clip its zone box -- shrink to fit, never enlarge.
          fit: BoxFit.scaleDown,
          child: html.trim().isNotEmpty
              ? HtmlWidget(
                  content,
                  textStyle: style,
                )
              : Text(
                  content,
                  textAlign: TextAlign.center,
                  style: style,
                ),
        ),
      ),
    );
  }

  Color? _parseColor(String? value) {
    final hex = value?.trim().replaceFirst('#', '');
    if (hex == null || !RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
      return null;
    }
    return Color(int.parse('FF$hex', radix: 16));
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
