import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

class TextWidget extends StatelessWidget {
  final String html;
  final String text;
  final VoidCallback onTextEnd;
  final String transitionType;
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

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(fill) ?? Colors.white;
    final style = TextStyle(
      color: color,
      fontSize: fontSize ?? 24,
      fontFamily: fontFamily,
      shadows: shadowBlur != null && shadowBlur! > 0
          ? [Shadow(color: Colors.black54, blurRadius: shadowBlur!)]
          : null,
    );
    final content = html.trim().isNotEmpty ? html : text;

    return SizedBox.expand(
      child: Center(
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
