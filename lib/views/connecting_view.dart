import 'package:flutter/material.dart';

import 'package:digital_signage/widgets/center_image_widget.dart';
import 'package:digital_signage/widgets/text_widget.dart';

class ConnectingView extends StatefulWidget {
  const ConnectingView({super.key});

  @override
  State<ConnectingView> createState() => _ConnectingViewState();
}

class _ConnectingViewState extends State<ConnectingView> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CustomImageWidget(
              imagePath: 'assets/images/Wifi.png',
            ),
            SimpleText(
              text: "Connecting...",
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
            SimpleText(
              text:
                  "Wifi is still trying to connect, but it’s taking longer than normal.\nCheck that your Wifi is on and connected.",
            )
          ],
        ),
      ),
    );
  }
}
