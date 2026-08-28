import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_phoenix/flutter_phoenix.dart';

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
              child: MqttProvider(
                child: MyHomePage(),
              ),
            ),
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
