import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String globleTopic="";
const platformMacOS = MethodChannel('com.example/deviceControl');
const platform = MethodChannel('com.example/network');
final GlobalKey boundaryKey = GlobalKey();

// Set by the currently-mounted _LinuxWebViewWidget (campaign_view.dart) so
// remote-view capture on Linux can rasterize just the CEF texture via
// Flutter's own RepaintBoundary.toImage() and patch it onto the scrot
// screenshot — scrot's X11-level capture reads back black for the CEF
// texture region even though it's genuinely visible on the real screen.
GlobalKey? linuxWebviewBoundaryKey;