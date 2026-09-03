import 'dart:io';

import 'package:flutter/material.dart';

// Prefixed: this package re-exports its own X509Certificate class (from
// flutter_inappwebview_platform_interface), which collides with
// dart:io's X509Certificate used in MyHttpOverrides below the moment both
// are imported unprefixed into the same file -- confirmed via a CI build
// failure ("A value of type 'bool Function(X509Certificate/*1*/ ...)
// can't be assigned to ... X509Certificate/*2*/ ...").
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    as webview;
import 'package:flutter_phoenix/flutter_phoenix.dart';
import 'package:media_kit/media_kit.dart';

import 'package:digital_signage/provider/main_provider.dart';
import 'package:digital_signage/utils/debug_log.dart' as debug;
import 'package:digital_signage/utils/globle_variable.dart';
import 'package:digital_signage/widgets/touch_feedback_overlay.dart';
import 'package:digital_signage/widgets/update_banner.dart';

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  HttpOverrides.global = MyHttpOverrides();
  runApp(Phoenix(
    child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: boundaryKey,
          child: ValueListenableBuilder<int>(
            valueListenable: screenRotationDegrees,
            builder: (context, degrees, child) {
              // Player Configuration's Screen Rotation setting -- matches the
              // working Android player's approach of rotating just its own
              // root view (frameLayout.rotation), not the OS display itself,
              // so this needs no elevated privileges and never leaves the
              // machine's actual desktop rotated.
              final quarterTurns = (degrees ~/ 90) % 4;
              return RotatedBox(quarterTurns: quarterTurns, child: child);
            },
            child: TouchFeedbackOverlay(
              child: Stack(
                children: [
                  MqttProvider(
                    child: MyHomePage(),
                  ),
                  const _WebViewPrewarmer(),
                  const UpdateBanner(),
                ],
              ),
            ),
          ),
        )),
  ));
}

// On Windows, flutter_inappwebview runs on Microsoft's WebView2 -- the
// *first* WebView2 control created in the app's lifetime has to spin up
// its whole underlying browser runtime process, which is genuinely slow
// (can be several seconds). Every WebView created after that first one
// reuses the already-running runtime and is far faster. Without this,
// that one-time cost landed on whichever web app/HTML zone happened to be
// shown first, as a visible white-screen delay -- especially bad for a
// zone that's the only item in its rotation, since there's no other
// content playing first to hide the cost behind (see
// _buildWebAppPrefetchLayer in campaign_view.dart for that same-zone
// case). This pays it once, invisibly, at app launch instead -- typically
// while the player is still on the pairing/downloading screen, well
// before any real content needs to show.
class _WebViewPrewarmer extends StatefulWidget {
  const _WebViewPrewarmer();

  @override
  State<_WebViewPrewarmer> createState() => _WebViewPrewarmerState();
}

class _WebViewPrewarmerState extends State<_WebViewPrewarmer> {
  // Timestamps logged here vs. WBViewWidget's own onWebViewCreated/
  // onLoadStop timestamps (campaign_view.dart) are what actually tell us
  // whether a still-slow web app zone is waiting on WebView2's runtime
  // (this prewarm not done yet, or not helping) or just that specific
  // page's own network/render time -- neither was logged anywhere before,
  // so there was no way to tell the two apart from a real test run.
  DateTime? _createdAt;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    // Creating the native WebView2 control synchronously in the app's very
    // first frame puts it in a race with Flutter's own Windows compositor
    // (ANGLE/D3D) setting up its swapchain on the same UI thread -- on this
    // hardware that showed up as either a permanently blank grey window (no
    // crash, no further log output at all past this widget) or an outright
    // process crash in coremessaging.dll (confirmed via Windows Event
    // Viewer), both intermittent/timing-dependent. Waiting for the first
    // real frame to be submitted before creating the WebView2 control means
    // Flutter's compositor is already up and running by the time WebView2
    // starts spinning up its own -- still well before any real content
    // needs the runtime warm, which is all this was ever trying to save.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _createdAt = DateTime.now();
        _armed = true;
      });
      debug.debugLog('WebViewPrewarmer',
          'offstage WebView2 control creation starting at $_createdAt (post first frame)');
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows || !_armed) return const SizedBox.shrink();
    // Not const: URLRequest/WebUri.uri(Uri.parse(...)) call real
    // constructors/methods at runtime, not const ones, so this whole
    // subtree can't be a const expression.
    return Offstage(
      offstage: true,
      child: SizedBox(
        width: 1,
        height: 1,
        child: webview.InAppWebView(
          initialUrlRequest: webview.URLRequest(
              url: webview.WebUri.uri(Uri.parse('about:blank'))),
          onWebViewCreated: (controller) {
            debug.debugLog('WebViewPrewarmer',
                'native WebView2 control created after ${DateTime.now().difference(_createdAt!).inMilliseconds}ms');
          },
          onLoadStop: (controller, url) {
            debug.debugLog('WebViewPrewarmer',
                'about:blank finished loading after ${DateTime.now().difference(_createdAt!).inMilliseconds}ms -- runtime is warm from here on');
          },
          onReceivedError: (controller, request, error) {
            debug.debugLog('WebViewPrewarmer',
                'FAILED: ${error.description} after ${DateTime.now().difference(_createdAt!).inMilliseconds}ms');
          },
        ),
      ),
    );
  }
}

class MyHomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MQTT App')),
      body: const Center(child: Text('Welcome to the MQTT App!')),
    );
  }
}
