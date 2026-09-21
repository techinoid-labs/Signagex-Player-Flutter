import 'dart:io';
// Prefixed: dart:ui re-declares several names (Color, Offset, Size, Rect,
// TextDirection...) that flutter/material.dart also exports with its own
// versions -- only PlatformDispatcher is actually needed from here.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import 'package:flutter_phoenix/flutter_phoenix.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:webview_cef/webview_cef.dart' as cef;

import 'package:digital_signage/provider/main_provider.dart';
import 'package:digital_signage/utils/debug_log.dart' as debug;
import 'package:digital_signage/utils/globle_variable.dart';

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Installed before anything else starts, so a failure during fvp or CEF
  // startup is captured too.
  //
  // Framework build/layout/paint errors go only to
  // FlutterError.dumpErrorToConsole by default, and a release player has
  // nowhere to print: launched from a desktop entry its stdout is
  // discarded, run as a systemd unit it is buried in the journal. A widget
  // silently erroring and being torn down was indistinguishable from
  // "nothing happened". Routing both handlers through the same file log
  // everything else uses makes them visible in signagex_debug.log.
  FlutterError.onError = (FlutterErrorDetails details) {
    debug.debugLog(
        'FlutterError', '${details.exceptionAsString()}\n${details.stack}');
    FlutterError.presentError(details);
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    debug.debugLog('PlatformDispatcher', 'uncaught: $error\n$stack');
    // Returns TRUE ("handled") deliberately. Returning false tells the
    // engine the error is unhandled and lets it tear the process down -- a
    // stray async error, such as a connection attempt that timed out on a
    // background future nobody awaited, is then enough to kill the player
    // outright. A signage screen must never go dark over a background
    // error it could have survived. The error is written to the debug log
    // above, so nothing is hidden; it just no longer doubles as a
    // process-suicide switch.
    return true;
  };

  if (Platform.isLinux) {
    fvp.registerWith(options: {'platforms': ['linux']});
    await cef.WebviewManager().initialize();
  }

  // Certificate validation is bypassed ONLY in debug builds (e.g. a local
  // dev server with a self-signed cert). Release builds -- production AND
  // staging -- must validate certificates; accepting every certificate in a
  // shipped player is a man-in-the-middle hole. If a staging server uses a
  // self-signed cert, give it a real one instead of re-enabling this
  // globally.
  if (kDebugMode) {
    HttpOverrides.global = MyHttpOverrides();
  }
  runApp(Phoenix(
    child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: boundaryKey,
          child: MqttProvider(
            child: MyHomePage(),
          ),
        )),
  ));
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
