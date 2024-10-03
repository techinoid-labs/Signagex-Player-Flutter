import 'dart:io';

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import 'package:digital_signage/view_models/mqtt_view_model.dart';

class PlaylistScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final mqttViewModel = Provider.of<MqttViewModel>(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('Playlist'),
      ),
      body: mqttViewModel.mediaPath.isNotEmpty
          ? LayoutBuilder(
              builder: (context, constraints) {
                // Calculate the number of sections based on available width
                int crossAxisCount = _calculateCrossAxisCount(constraints.maxWidth);
                
                return GridView.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    childAspectRatio: 1.0, // Each item is square
                  ),
                  itemCount: mqttViewModel.mediaPath.length,
                  itemBuilder: (context, index) {
                    String filePath = mqttViewModel.mediaPath[index];
                    return Container(
                      // Full screen use
                      margin: EdgeInsets.all(0), // No margins
                      child: isVideoFile(filePath)
                          ? VideoPlayerWidget(filePath: filePath)
                          : ImageWidget(filePath: filePath),
                    );
                  },
                );
              },
            )
          : Center(
              child: Text("No media available"),
            ),
    );
  }

  // Calculate the number of sections based on available width
  int _calculateCrossAxisCount(double maxWidth) {
    if (maxWidth >= 1200) {
      return 4; // Large screens
    } else if (maxWidth >= 800) {
      return 3; // Medium screens
    } else {
      return 2; // Small screens
    }
  }

  // Check if the file is a video
  bool isVideoFile(String path) {
    final videoExtensions = ['.mp4', '.avi', '.mov', '.mkv'];
    return videoExtensions.any((ext) => path.endsWith(ext));
  }
}

// Video Player Widget
class VideoPlayerWidget extends StatefulWidget {
  final String filePath;

  const VideoPlayerWidget({required this.filePath});

  @override
  _VideoPlayerWidgetState createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  late VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.filePath))
      ..initialize().then((_) {
        setState(() {}); // Ensure the first frame is shown after the video is initialized
        _controller.setLooping(true); // Set the video to loop
        _controller.play();
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _controller.value.isInitialized
        ? AspectRatio(
            aspectRatio: 1.0, // Keep it square
            child: VideoPlayer(_controller),
          )
        : Center(child: CircularProgressIndicator());
  }
}

// Image Widget
class ImageWidget extends StatelessWidget {
  final String filePath;

  const ImageWidget({required this.filePath});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.0, // Keep it square
      child: Image.file(
        File(filePath),
        fit: BoxFit.cover,
      ),
    );
  }
}
