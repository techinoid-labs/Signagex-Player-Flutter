import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import 'package:digital_signage/models/compaign_model.dart';
import 'package:digital_signage/view_models/mqtt_view_model.dart';

class CampaignView extends StatelessWidget {
  const CampaignView({super.key});

  @override
  Widget build(BuildContext context) {
    final mqttViewModel = Provider.of<MqttViewModel>(context);
    var zones = mqttViewModel.campaignModel!.data.zones;
    print(zones[0].mediaItems[0].mediaUrl);
    print(zones[1].mediaItems[0].mediaUrl);
    print(zones[2].mediaItems[0].mediaUrl);
    print("this h:::${MediaQuery.sizeOf(context).height}");
    print("this w:::${MediaQuery.sizeOf(context).width}");

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: zones.map((zone) {
          print(
              "Rendering Zone ID: ${zone.id} with Media Items: ${zone.mediaItems.map((item) => item.mediaUrl).toList()}");
          return Positioned(
            left: zone.x.toDouble(),
            top: zone.y.toDouble(),
            width: zone.width.toDouble(),
            height: zone.height.toDouble(),
            child: VideoPlaylistWidget(
              zoneId: zone.id.toString(),
              mediaItems: zone.mediaItems,
            ),
          );
        }).toList(),
      ),
    );
  }
}

class VideoPlaylistWidget extends StatefulWidget {
  final String zoneId;
  final List<MediaItem> mediaItems;

  const VideoPlaylistWidget({
    super.key,
    required this.zoneId,
    required this.mediaItems,
  });

  @override
  _VideoPlaylistWidgetState createState() => _VideoPlaylistWidgetState();
}

class _VideoPlaylistWidgetState extends State<VideoPlaylistWidget> {
  int _currentMediaIndex = 0;
  Timer? _timer;
  double _opacity = 1.0;
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    _initializeNextMedia();
  }

  @override
  void didUpdateWidget(covariant VideoPlaylistWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaItems != widget.mediaItems ||
        oldWidget.zoneId != widget.zoneId) {
      _resetState();
    }
  }

  void _resetState() {
    _currentMediaIndex = 0;
    _timer?.cancel();
    _videoController?.dispose();
    _videoController = null;
    setState(() {
      _opacity = 1.0;
    });
    _initializeNextMedia();
  }

  void _initializeNextMedia() {
    if (widget.mediaItems.isEmpty) {
      print("Zone ${widget.zoneId}: No media items available.");
      return;
    }

    MediaItem currentMedia = widget.mediaItems[_currentMediaIndex];
    print("Zone ${widget.zoneId}: Initializing media item ${currentMedia.id}");

    if (currentMedia.schedule.alwaysPlay || _isMediaAllowed(currentMedia)) {
      String duration = currentMedia.settings.duration.toString();

      _startMediaLoop(duration);
      _loadMedia(currentMedia);
    } else {
      String duration = currentMedia.settings.duration.toString();
      _startMediaLoop(duration);
      _onMediaEnd();
    }
  }

  void _startMediaLoop(String duration) {
    print("this is duration......$duration");
    int durationSeconds = int.tryParse(duration) ?? 10;
    print("this is duration......$durationSeconds");
    _timer = Timer(Duration(seconds: durationSeconds), _onMediaEnd);
  }

  bool _isMediaAllowed(MediaItem media) {
    DateTime now = DateTime.now();
    DateTime startDate =
        DateFormat('M/d/yyyy').parse(media.schedule.period!.date.start);
    DateTime endDate =
        DateFormat('M/d/yyyy').parse(media.schedule.period!.date.end);

    bool isDateInRange = now.isAfter(startDate) &&
        now.isBefore(endDate.add(const Duration(days: 1)));
    bool isDayAllowed = _isCurrentDayAllowed(media.schedule.period!.days, now);
    bool isTimeInRange = _isTimeInRange(
      media.schedule.period!.time.from,
      media.schedule.period!.time.to,
    );

    return isDateInRange && isDayAllowed && isTimeInRange;
  }

  void _loadMedia(MediaItem media) {
    if (isVideoFile(media.mediaUrl)) {
      _initializeVideo(media);
    } else {
      _showImage(media);
    }
  }

  void _initializeVideo(MediaItem media) {
    _videoController?.dispose();
    _videoController = VideoPlayerController.file(File(media.mediaUrl))
      ..initialize().then((_) {
        setState(() {});
        _videoController?.play();
        _videoController?.addListener(() {
          if (_videoController!.value.isInitialized &&
              !_videoController!.value.isPlaying &&
              _videoController!.value.position >=
                  _videoController!.value.duration) {
            _onMediaEnd();
          }
        });
      }).catchError((e) {
        print("Zone ${widget.zoneId}: Video initialization error: $e");
        _onMediaEnd();
      });
  }

  void _showImage(MediaItem media) {
    int durationSeconds = int.tryParse(media.settings.duration.toString()) ?? 5;
    _timer?.cancel();
    _timer = Timer(Duration(seconds: durationSeconds), _onMediaEnd);
  }

  void _onMediaEnd() {
    setState(() {
      _opacity = 0.0;
    });

    Future.delayed(const Duration(milliseconds: 500), () {
      setState(() {
        if (_currentMediaIndex < widget.mediaItems.length - 1) {
          _currentMediaIndex++;
        } else {
          _currentMediaIndex = 0;
        }
        _opacity = 1.0;
        _initializeNextMedia();
      });
    });
  }

  bool _isCurrentDayAllowed(dynamic days, DateTime now) {
    switch (now.weekday) {
      case DateTime.monday:
        return days.monday ?? false;
      case DateTime.tuesday:
        return days.tuesday ?? false;
      case DateTime.wednesday:
        return days.wednesday ?? false;
      case DateTime.thursday:
        return days.thursday ?? false;
      case DateTime.friday:
        return days.friday ?? false;
      case DateTime.saturday:
        return days.saturday ?? false;
      case DateTime.sunday:
        return days.sunday ?? false;
      default:
        return false;
    }
  }

  bool _isTimeInRange(String timeFrom, String timeTo) {
    DateTime currentTime = DateTime.now();
    DateTime fromTime = DateTime.now().copyWith(
      hour: int.parse(timeFrom.split(':')[0]),
      minute: int.parse(timeFrom.split(':')[1]),
    );
    DateTime toTime = DateTime.now().copyWith(
      hour: int.parse(timeTo.split(':')[0]),
      minute: int.parse(timeTo.split(':')[1]),
    );

    return currentTime.isAfter(fromTime) && currentTime.isBefore(toTime);
  }

 @override
void dispose() {
  _timer?.cancel();
  _videoController?.dispose();
  super.dispose();
}


  @override
  Widget build(BuildContext context) {
    if (widget.mediaItems.isEmpty) {
      return Center(child: Text("Zone ${widget.zoneId}: No media items."));
    }

    MediaItem currentMedia = widget.mediaItems[_currentMediaIndex];
    return AnimatedOpacity(
      opacity: _opacity,
      duration: const Duration(milliseconds: 500),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        child: isVideoFile(currentMedia.mediaUrl)
            ? VideoPlayerWidget(
                key: ValueKey(currentMedia.id), // Unique key
                filePath: currentMedia.mediaUrl,
                onVideoEnd: _onMediaEnd,
                transitionType: currentMedia.settings.transition,
              )
            : ImageWidget(
                key: ValueKey(currentMedia.id), // Unique key
                filePath: currentMedia.mediaUrl,
                onImageEnd: _onMediaEnd,
                transitionType: currentMedia.settings.transition,
              ),
      ),
    );
  }

  bool isVideoFile(String path) {
    final videoExtensions = ['.mp4', '.avi', '.mov', '.mkv'];
    return videoExtensions.any((ext) => path.endsWith(ext));
  }
}

class VideoPlayerWidget extends StatefulWidget {
  final String filePath;
  final VoidCallback onVideoEnd;
  final String transitionType;

  const VideoPlayerWidget({
    super.key,
    required this.filePath,
    required this.onVideoEnd,
    required this.transitionType,
  });

  @override
  _VideoPlayerWidgetState createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget>
    with SingleTickerProviderStateMixin {
  late VideoPlayerController _controller;
  bool _isLoading = true;
  bool _isVideoEnded = false;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  void _initializeVideo() async {
    _controller = VideoPlayerController.file(File(widget.filePath))
      ..initialize().then(
        (_) {
          setState(
            () {
              _isLoading = false;

              _controller.setLooping(false);
              _controller.play();
            },
          );

          _controller.addListener(
            () {
              if (_controller.value.position >= _controller.value.duration &&
                  !_isVideoEnded) {
                _isVideoEnded = true;
                widget.onVideoEnd();
              }
            },
          );
        },
      ).catchError(
        (error) {
          print("Error initializing video: $error");
          setState(
            () {
              _isLoading = false;
            },
          );
        },
      );
  }

  void _checkVideoEnd() {
    if (_controller.value.isInitialized &&
        !_controller.value.isPlaying &&
        _controller.value.position >= _controller.value.duration &&
        !_isVideoEnded) {
      setState(() {
        _isVideoEnded = true;
      });
      widget.onVideoEnd();
    }
  }

  @override
  void didUpdateWidget(covariant VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _controller.removeListener(_checkVideoEnd);
      _controller.dispose();
      _initializeVideo();
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget videoWidget = _isLoading
        ? const Center(child: CircularProgressIndicator())
        : VideoPlayer(_controller);

    if (!_isLoading && !_controller.value.isInitialized) {
      videoWidget = const Center(child: CircularProgressIndicator());
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: videoWidget,
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_checkVideoEnd);
    _controller.dispose();
    super.dispose();
  }
}

class ImageWidget extends StatelessWidget {
  final String filePath;
  final VoidCallback onImageEnd;

  final String transitionType;

  const ImageWidget({
    super.key,
    required this.filePath,
    required this.onImageEnd,
    required this.transitionType,
  });

  @override
  Widget build(BuildContext context) {
    Widget imageWidget =
        SizedBox.expand(child: Image.file(File(filePath), fit: BoxFit.cover));

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: imageWidget,
    );
  }
}
