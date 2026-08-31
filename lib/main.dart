import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_phoenix/flutter_phoenix.dart';
import 'package:media_kit/media_kit.dart';

import 'package:digital_signage/provider/main_provider.dart';
import 'package:digital_signage/utils/globle_variable.dart';
import 'package:digital_signage/widgets/touch_feedback_overlay.dart';

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
class _WebViewPrewarmer extends StatelessWidget {
  const _WebViewPrewarmer();

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    return const Offstage(
      offstage: true,
      child: SizedBox(
        width: 1,
        height: 1,
        child: InAppWebView(
          initialUrlRequest:
              URLRequest(url: WebUri.uri(Uri.parse('about:blank'))),
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
