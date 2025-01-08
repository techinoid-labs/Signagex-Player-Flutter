
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:digital_signage/view_models/mqtt_view_model.dart';
import 'package:digital_signage/widgets/center_image_widget.dart';
import 'package:digital_signage/widgets/text_widget.dart';

class NoContentView extends StatefulWidget {
  const NoContentView({super.key});

  @override
  State<NoContentView> createState() => _NoContentViewState();
}

class _NoContentViewState extends State<NoContentView> {
  Offset? _touchPosition;
  @override
  Widget build(BuildContext context) {
   final urlLauncherViewModel = Provider.of<MqttViewModel>(context,listen: false);

    return Scaffold(
      body: GestureDetector(
          onPanUpdate: (details) {
             _touchPosition = details.localPosition;
          // This will print the touch position whenever the user touches or drags on the screen.
          print(" Position: ${_touchPosition}");
        },
        child: Stack(
          children: [
          
            Image.asset(
              "assets/images/background.png",
              fit: BoxFit.cover, 
              height: MediaQuery.of(context).size.height,
              width: MediaQuery.of(context).size.width,
            ),
          
             Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  
                 const CustomImageWidget(
                    imagePath: 'assets/images/Browser.png',
                  ),
                  const SimpleText(
                    text: "No Content Available for Playback",
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  GestureDetector(
                      onTap: () => urlLauncherViewModel.launchUrl('https://norwinsol.com/'),
                    child: const SimpleText(
                      text:
                        "Go to https://norwinsol.com/ to publish one or remove restriction.",
                    ),
                  )
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
