import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:digital_signage/view_models/mqtt_view_model.dart';
import 'package:digital_signage/widgets/center_image_widget.dart';
import 'package:digital_signage/widgets/text_widget.dart';

class DownloadingView extends StatefulWidget {
  const DownloadingView({super.key});

  @override
  State<DownloadingView> createState() => _DownloadingViewState();
}

class _DownloadingViewState extends State<DownloadingView> {
  @override
  Widget build(BuildContext context) {
    final downloadViewModel = Provider.of<MqttViewModel>(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CustomImageWidget(
              imagePath: 'assets/images/Cloud.png',
            ),
            const SimpleText(
              text: "Downloading...",
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
            const SimpleText(
              text:
                  "Your content is being downloaded. Thank you for your patience.",
            ),
            const SizedBox(height: 20),
            if (downloadViewModel.state == MqttState.downloading)
              Column(
                children: [
                  SizedBox(
                    width: 280,
                    child: LinearProgressIndicator(
                      value: downloadViewModel.overallProgress.clamp(0.0, 1.0),
                      backgroundColor: Colors.grey[700],
                      color: Colors.blue,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '${(downloadViewModel.overallProgress * 100).clamp(0.0, 100.0).toStringAsFixed(0)}%',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
