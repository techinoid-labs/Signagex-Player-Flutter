import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import 'package:digital_signage/models/play_list_model.dart';
import 'package:digital_signage/view_models/mqtt_view_model.dart';

class PlaylistScreen extends StatelessWidget {
  const PlaylistScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mqttViewModel = Provider.of<MqttViewModel>(context);
    print(
        "this is playlist media ... ${mqttViewModel.playListModel!.data.playlist.playlistSchedule.period!.date.start}");

    DateTime now = DateTime.now();
    var playlistSchedule =
        mqttViewModel.playListModel!.data.playlist.playlistSchedule;

    // Check if always_play is true
    if (playlistSchedule.alwaysPlay) {
      return Scaffold(
        body: mqttViewModel.mediaPath.isNotEmpty
            ? VideoPlaylistWidget(
                mediaPaths: mqttViewModel.playListModel!.data.playlist.media,
                playlist: mqttViewModel.playListModel!.data.playlist,
              )
            : const Center(
                child: Text("No media available"),
              ),
      );
    }

    // Call _isPlaylistDateInRange with DateTime arguments
    bool isPlaylistDateInRange = _isPlaylistDateInRange(
      playlistSchedule.period!.date.start,
      playlistSchedule.period!.date.end,
    );

    bool isPlaylistDayAllowed =
        _isCurrentDayAllowed(playlistSchedule.period!.days, now);
    bool isTimeInRange = _isTimeInRange(
      playlistSchedule.period!.time.from,
      playlistSchedule.period!.time.to,
    );

    return Scaffold(
      body: mqttViewModel.mediaPath.isNotEmpty &&
              isPlaylistDateInRange &&
              isPlaylistDayAllowed &&
              isTimeInRange
          ? VideoPlaylistWidget(
              mediaPaths: mqttViewModel.playListModel!.data.playlist.media,
              playlist: mqttViewModel.playListModel!.data.playlist,
            )
          : const Center(
              child: Text("No media available"),
            ),
    );
  }

  // Change the argument types to DateTime
  bool _isPlaylistDateInRange(DateTime startDate, DateTime endDate) {
    DateTime now = DateTime.now();
    return now.isAfter(startDate) &&
        now.isBefore(endDate.add(Duration(days: 1)));
  }

  // Check if the current day is allowed based on the schedule
  bool _isCurrentDayAllowed(dynamic days, DateTime now) {
    switch (now.weekday) {
      case 1:
        return days.monday ?? false;
      case 2:
        return days.tuesday ?? false;
      case 3:
        return days.wednesday ?? false;
      case 4:
        return days.thursday ?? false;
      case 5:
        return days.friday ?? false;
      case 6:
        return days.saturday ?? false;
      case 7:
        return days.sunday ?? false;
      default:
        return false;
    }
  }

  // Check if the current time is within the allowed time range
  bool _isTimeInRange(String timeFrom, String timeTo) {
    DateTime currentTime = DateTime.now();
    DateTime fromTime = DateTime.now().copyWith(
      hour: int.parse(timeFrom.split(':')[0]),
      minute: int.parse(timeFrom.split(':')[1]),
      second: int.parse(timeFrom.split(':')[2]),
    );

    DateTime toTime = DateTime.now().copyWith(
      hour: int.parse(timeTo.split(':')[0]),
      minute: int.parse(timeTo.split(':')[1]),
      second: int.parse(timeTo.split(':')[2]),
    );

    return currentTime.isAfter(fromTime) && currentTime.isBefore(toTime);
  }
}

class VideoPlaylistWidget extends StatefulWidget {
  final List<Media> mediaPaths;
  final Playlist playlist;

  const VideoPlaylistWidget({
    super.key,
    required this.mediaPaths,
    required this.playlist,
  });

  @override
  _VideoPlaylistWidgetState createState() => _VideoPlaylistWidgetState();
}

class _VideoPlaylistWidgetState extends State<VideoPlaylistWidget> {
  int _currentIndex = 0;
  late Timer _timer;
  double _opacity = 1.0;
  VideoPlayerController? _nextController;

  @override
  void initState() {
    super.initState();
    _initializeNextMedia();
  }

  void _onMediaEnd() {
    setState(() {
      _opacity = 0.0;
    });

    Future.delayed(const Duration(milliseconds: 500), () {
      setState(() {
        if (_currentIndex < widget.mediaPaths.length - 1) {
          _currentIndex++;
        } else {
          _currentIndex = 0;
        }
        _opacity = 1.0;
        _initializeNextMedia();
      });
    });
  }

  void _initializeNextMedia() {
    if (_currentIndex < widget.mediaPaths.length) {
      Media nextMedia = widget.mediaPaths[_currentIndex];
      print("Loading media at index $_currentIndex: ${nextMedia.mediaUrl!}");

      // Check if always_play is true
      if (nextMedia.schedule!.alwaysPlay) {
        print("Always play is true for media: ${nextMedia.mediaUrl!}");
        _loadMedia(nextMedia);
        return;
      }

      // Proceed with date, day, and time checks
      DateTime now = DateTime.now();
      print("Current date: $now");

      DateTime startDate = nextMedia.schedule!.period!.date.start;
      DateTime endDate = nextMedia.schedule!.period!.date.end;
      print("Media start date: $startDate");
      print("Media end date: $endDate");

      bool isDateInRange = now.isAfter(startDate) &&
          now.isBefore(endDate.add(Duration(days: 1)));
      print("Is current date in range: $isDateInRange");

      bool isDayAllowed =
          _isCurrentDayAllowed(nextMedia.schedule!.period!.days, now);
      print("Is current day allowed: $isDayAllowed");

      String? timeFrom = nextMedia.schedule!.period!.time.from;
      String? timeTo = nextMedia.schedule!.period!.time.to;

      if (timeFrom != null && timeTo != null) {
        DateTime currentTime = DateTime.now();
        DateTime fromTime = DateTime.now().copyWith(
          hour: int.parse(timeFrom.split(':')[0]),
          minute: int.parse(timeFrom.split(':')[1]),
          second: int.parse(timeFrom.split(':')[2]),
        );

        DateTime toTime = DateTime.now().copyWith(
          hour: int.parse(timeTo.split(':')[0]),
          minute: int.parse(timeTo.split(':')[1]),
          second: int.parse(timeTo.split(':')[2]),
        );

        bool isTimeInRange =
            currentTime.isAfter(fromTime) && currentTime.isBefore(toTime);
        print("Is current time in range: $isTimeInRange");

        if (isDateInRange && isDayAllowed && isTimeInRange) {
          String duration = nextMedia.settings!.duration;
          print("Loading duration at index $_currentIndex: $duration");
          _startMediaLoop(duration);
          _loadMedia(nextMedia);
        } else {
          print("Current date, day, or time is not allowed for this media.");
          _onMediaEnd();
        }
      } else {
        print("Time range not defined for this media.");
        _onMediaEnd();
      }
    }
  }

  void _loadMedia(Media nextMedia) {
    if (isVideoFile(nextMedia.mediaUrl!)) {
      _initializeNextVideo(nextMedia);
    } else {
      print("Current media is an image: ${nextMedia.mediaUrl!}");
    }
  }

  String _getCurrentDayString(int weekday) {
    switch (weekday) {
      case 1:
        return 'monday';
      case 2:
        return 'tuesday';
      case 3:
        return 'wednesday';
      case 4:
        return 'thursday';
      case 5:
        return 'friday';
      case 6:
        return 'saturday';
      case 7:
        return 'sunday';
      default:
        return '';
    }
  }

  // Check if current day is allowed based on the schedule
  bool _isCurrentDayAllowed(dynamic days, DateTime now) {
    switch (now.weekday) {
      case 1:
        return days.monday ?? false;
      case 2:
        return days.tuesday ?? false;
      case 3:
        return days.wednesday ?? false;
      case 4:
        return days.thursday ?? false;
      case 5:
        return days.friday ?? false;
      case 6:
        return days.saturday ?? false;
      case 7:
        return days.sunday ?? false;
      default:
        return false; // Should not reach here
    }
  }

  void _initializeNextVideo(Media nextMedia) {
    _nextController = VideoPlayerController.file(File(nextMedia.mediaUrl!))
      ..initialize().then((_) {
        setState(() {
          _nextController!.play();
          _nextController!.setLooping(false);
        });
        _nextController!.addListener(() {
          _checkVideoDuration(nextMedia);
        });
      }).catchError((error) {
        print("Error initializing video: $error");
        setState(() {});
      });
  }

  void _startMediaLoop(String duration) {
    int durationSeconds =
        int.tryParse(duration) ?? 10; 
    _timer = Timer(Duration(seconds: durationSeconds), _onMediaEnd);
  }

  void _checkVideoDuration(Media media) {
    if (_nextController != null &&
        _nextController!.value.isInitialized &&
        !_nextController!.value.isPlaying &&
        _nextController!.value.position >= _nextController!.value.duration) {
      _nextController!.seekTo(Duration.zero);
      _nextController!.play();
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    _nextController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Media currentMedia = widget.mediaPaths[_currentIndex];

    // Debugging: Display media information
    print("Displaying media: ${currentMedia.settings!.duration}");
    print("Displaying media: ${currentMedia.settings!.ratio}");
    print("Displaying media: ${currentMedia.mediaUrl!}");

    return AnimatedOpacity(
      opacity: _opacity,
      duration: const Duration(milliseconds: 500), // Fade transition duration
      child: AnimatedSwitcher(
        duration: const Duration(
            milliseconds: 500),
        child: isVideoFile(currentMedia.mediaUrl!)
            ? VideoPlayerWidget(
                filePath: currentMedia.mediaUrl!,
                onVideoEnd: _onMediaEnd,
                aspectRatio: getAspectRatio(currentMedia.settings?.ratio),
                transitionType:
                    currentMedia.settings!.transition, 
              )
            : SizedBox.expand(
                child: ImageWidget(
                  filePath: currentMedia.mediaUrl!,
                  onImageEnd: _onMediaEnd,
                  aspectRatio: getAspectRatio(currentMedia.settings?.ratio),
                  transitionType: currentMedia.settings!.transition,
                ),
              ),
      ),
    );
  }

  double getAspectRatio(String? ratio) {
    switch (ratio) {
      case 'Stretch to Fill Region':
        return 16 / 9;
      default:
        return 16 / 9;
    }
  }

  bool isVideoFile(String path) {
    final videoExtensions = ['.mp4', '.avi', '.mov', '.mkv'];
    return videoExtensions.any((ext) => path.endsWith(ext));
  }
}

class VideoPlayerWidget extends StatefulWidget {
  final String filePath;
  final VoidCallback onVideoEnd;
  final double aspectRatio;
  final String transitionType;

  const VideoPlayerWidget({
    super.key,
    required this.filePath,
    required this.onVideoEnd,
    required this.aspectRatio,
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
    _controller = VideoPlayerController.file(File(widget.filePath));

    try {
      await _controller.initialize();
      setState(() {
        _isLoading = false;
      });
      _controller.play();
      _controller.setLooping(false);
      _controller.addListener(_checkVideoEnd);
    } catch (error) {
      setState(() {
        _isLoading = false;
      });
      print("Error initializing video: $error");
    }
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
        : SizedBox.expand(
            child: AspectRatio(
              aspectRatio: widget.aspectRatio,
              child: VideoPlayer(_controller),
            ),
          );

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
  final double aspectRatio;
  final String transitionType;

  const ImageWidget({
    super.key,
    required this.filePath,
    required this.onImageEnd,
    required this.aspectRatio,
    required this.transitionType,
  });

  @override
  Widget build(BuildContext context) {
    Widget imageWidget = AspectRatio(
      aspectRatio: aspectRatio,
      child: Image.file(File(filePath), fit: BoxFit.cover),
    );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: imageWidget,
    );
  }
}
