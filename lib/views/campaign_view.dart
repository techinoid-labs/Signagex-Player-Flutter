import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:video_player/video_player.dart';

import 'package:digital_signage/models/ad_proof_of_play_model.dart';
import 'package:digital_signage/models/compaign_model.dart';
import 'package:digital_signage/utils/agent_debug_log.dart';
import 'package:digital_signage/utils/log_format.dart';

import '../view_models/mqtt_view_model.dart';
import '../views/no_content_view.dart';
import '../widgets/center_image_widget.dart';
import '../widgets/text_widget.dart';

String? _normalizeLocalMediaPath(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('file://')) {
    s = Uri.parse(s).toFilePath(windows: Platform.isWindows);
  }
  if (Platform.isWindows && s.contains('/')) {
    if (RegExp(r'^[A-Za-z]:[/\\]').hasMatch(s)) {
      final drive = s.substring(0, 2);
      s = drive + s.substring(2).replaceAll('/', Platform.pathSeparator);
    }
  }
  return s;
}

bool _svgNeedsHtmlRaster(String svg) {
  return svg.contains('<pattern') ||
      svg.contains('xlink:href') ||
      svg.contains('href="data:') ||
      svg.length > 8000;
}

/// SignageX stickers often wrap a PNG inside SVG (`<image xlink:href="data:image/png;base64,...">`).
Uint8List? _extractRasterBytesFromSvg(String svg) {
  final match = RegExp(
    r'''(?:xlink:href|href)\s*=\s*["']?(data:image/(?:png|jpeg|jpg|webp|gif);base64,([A-Za-z0-9+/=\s]+))''',
    caseSensitive: false,
  ).firstMatch(svg);
  if (match == null) return null;
  try {
    final payload = match.group(2)!.replaceAll(RegExp(r'\s+'), '');
    return base64Decode(payload);
  } catch (_) {
    return null;
  }
}

Widget _stickerRasterImage(Uint8List bytes, {Key? key}) {
  return SizedBox.expand(
    key: key,
    child: Image.memory(
      bytes,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.grey),
      ),
    ),
  );
}

Widget _buildStickerSvgContent(
  String svg, {
  required String transition,
  required VoidCallback onEnd,
  Key? key,
  String? zoneId,
  String? mediaId,
}) {
  final raster = _extractRasterBytesFromSvg(svg);
  if (raster != null) {
    // #region agent log
    agentDebugLog(
      location: 'campaign_view.dart:_buildStickerSvgContent',
      message: 'sticker_raster_extract',
      hypothesisId: 'H8',
      runId: 'post-fix',
      data: {
        'zoneId': zoneId,
        'mediaId': mediaId,
        'rasterBytes': raster.length,
        'svgLen': svg.length,
      },
    );
    // #endregion
    return _stickerRasterImage(raster, key: key);
  }

  if (!_svgNeedsHtmlRaster(svg)) {
    return SizedBox.expand(
      key: key,
      child: SvgWidget(
        svgContent: _normalizeSvgForParser(svg),
        onSvgEnd: onEnd,
        transitionType: transition,
      ),
    );
  }

  // Last resort for complex inline SVG without extractable raster.
  final encoded = Uri.encodeComponent(svg);
  if (encoded.length > 120000) {
    agentDebugLog(
      location: 'campaign_view.dart:_buildStickerSvgContent',
      message: 'sticker_svg_too_large_for_html',
      hypothesisId: 'H8',
      runId: 'post-fix',
      data: {'zoneId': zoneId, 'mediaId': mediaId, 'encodedLen': encoded.length},
    );
    return const Center(
      child: Icon(Icons.broken_image_outlined, color: Colors.grey),
    );
  }

  return SizedBox.expand(
    key: key,
    child: Html(
      data:
          '<div style="width:100%;height:100%;display:flex;align-items:center;'
          'justify-content:center;overflow:hidden;">'
          '<img src="data:image/svg+xml;charset=utf-8,$encoded" '
          'style="max-width:100%;max-height:100%;object-fit:contain;" alt="" />'
          '</div>',
      style: _stickerHtmlStyles,
    ),
  );
}

String _normalizeSvgForParser(String svg) {
  String s = svg.replaceAll('\\"', '"');

  s = s.replaceAllMapped(
      RegExp(r'points=\s*([0-9,\s\.\-]+)'), (m) => 'points="${m[1]!.trim()}"');

  s = s.replaceAllMapped(
      RegExp(r'\bd=\s*([^"\x27\s>][^>]*)'), (m) => 'd="${m[1]!.trim()}"');

  s = s.replaceAllMapped(RegExp(r'viewBox=\s*([^"\x27\s][^>]*)'),
      (m) => 'viewBox="${m[1]!.trim()}"');

  s = s.replaceAllMapped(RegExp('fill=\s*([^"\x27\\s][^>\\s/]*)'),
      (m) => 'fill="${m[1]!.trim()}"');
  s = s.replaceAllMapped(RegExp('stroke=\s*([^"\x27\\s][^>\\s/]*)'),
      (m) => 'stroke="${m[1]!.trim()}"');

  s = s.replaceAllMapped(RegExp(r'stroke-width=\s*([0-9.]+)'),
      (m) => 'stroke-width="${m[1]!.trim()}"');

  s = s.replaceAllMapped(
      RegExp(
          r'([a-zA-Z_][a-zA-Z0-9_.:-]*)=\s*([^"\x27\s][^>]*?)(?=\s+[a-zA-Z_][a-zA-Z0-9_.:-]*=|\s*\/?>)'),
      (m) => '${m[1]}="${m[2]!.trim()}"');

  return s;
}

String _stripDataUrlImagesFromSvg(String svg) {
  String s = svg;

  s = s.replaceAllMapped(RegExp(r'<image[^>]*\/?>', caseSensitive: false), (m) {
    return (m[0]!.contains('data:image')) ? '' : m[0]!;
  });

  s = s.replaceAllMapped(
      RegExp(r'<image[^>]*>[\s\S]*?<\/image>', caseSensitive: false), (m) {
    return (m[0]!.contains('data:image')) ? '' : m[0]!;
  });
  return s;
}

String _stripUnsupportedSvgBlocks(String svg) {
  String s = svg;
  s = s.replaceAll(
      RegExp(r'<style[^>]*>[\s\S]*?<\/style>', caseSensitive: false), '');
  s = s.replaceAll(
      RegExp(r'<script[^>]*>[\s\S]*?<\/script>', caseSensitive: false), '');
  return s;
}

class CampaignView extends StatefulWidget {
  const CampaignView({super.key});

  @override
  State<CampaignView> createState() => _CampaignViewState();
}

class _CampaignViewState extends State<CampaignView> {
  late FocusNode _focusNode;
  Timer? _restrictionCheckTimer;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final mqttViewModel = Provider.of<MqttViewModel>(context, listen: false);
      mqttViewModel.startPlaylistTimerForCampaign();
    });

    _restrictionCheckTimer =
        Timer.periodic(const Duration(seconds: 8), (timer) {
      if (mounted) {
        setState(() {});
      } else {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _restrictionCheckTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mqttViewModel = Provider.of<MqttViewModel>(context);
    final campaignModel = mqttViewModel.campaignModel;

    final campaigns = campaignModel?.data?.playerCampaigns;
    if (campaigns == null || campaigns.isEmpty) {
      return const NoContentView();
    }

    final campaignIndex =
        mqttViewModel.currentIndexOfCapmaign.clamp(0, campaigns.length - 1);
    final campaign = campaigns[campaignIndex];

    // #region agent log
    agentDebugLog(
      location: 'campaign_view.dart:build',
      message: 'active_campaign',
      hypothesisId: 'H1',
      data: {
        'index': campaignIndex,
        'campaignId': campaign.campaignId,
        'campaignName': campaign.campaignName,
        'isCompositionLayout': campaign.isCompositionLayout,
        'zoneCount': campaign.zones?.length ?? 0,
        'totalCampaigns': campaigns.length,
      },
    );
    // #endregion

    final campaignSchedule = campaign.campaignSchedule;

    const String reset = '\x1B[0m';
    const String red = '\x1B[31m';
    const String green = '\x1B[32m';
    const String yellow = '\x1B[33m';
    const String blue = '\x1B[34m';
    const String cyan = '\x1B[36m';

    print(
        '$cyan═══════════════════════════════════════════════════════════$reset');
    print('$cyan🎬 CAMPAIGN RESTRICTION CHECK$reset');
    print(
        '$cyan═══════════════════════════════════════════════════════════$reset');
    print('$blue📋 Campaign: ${campaign.campaignName ?? "N/A"}$reset');

    bool campaignCanPlay = false;

    if (campaignSchedule?.alwaysPlay ?? false) {
      campaignCanPlay = true;
      print('$green✅ CAMPAIGN: alwaysPlay = true → Campaign can play$reset');
    } else {
      final restrictions = campaignSchedule?.restrictions;
      if (restrictions != null && restrictions.isNotEmpty) {
        print(
            '$yellow🔍 CAMPAIGN: Checking ${restrictions.length} restriction(s)...$reset');
        campaignCanPlay = mqttViewModel.checkRestrictions(restrictions);
        if (campaignCanPlay) {
          print(
              '$green✅ CAMPAIGN: Restrictions PASSED → Campaign can play$reset');
        } else {
          print(
              '$red❌ CAMPAIGN: Restrictions FAILED → Campaign cannot play$reset');
        }
      } else {
        print('$yellow⚠️  CAMPAIGN: No restrictions configured$reset');
        campaignCanPlay = false;
      }
    }

    print(
        '$cyan═══════════════════════════════════════════════════════════$reset');

    if (campaignCanPlay) {
      return _buildZones(campaign, campaigns, campaignCanPlay);
    } else {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Stack(
          children: [
            Image.asset(
              "assets/images/background.png",
              fit: BoxFit.cover,
              height: MediaQuery.of(context).size.height,
              width: MediaQuery.of(context).size.width,
            ),
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CustomImageWidget(
                    imagePath: 'assets/images/Browser.png',
                  ),
                  SimpleText(
                    text: "Campaign Not Scheduled",
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  SimpleText(
                    text: "Campaign is not scheduled to play at this time.",
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildZones(
    PlayerCampaign campaign,
    List<Campaign> playerCampaigns,
    bool campaignCanPlay,
  ) {
    final screenSize = MediaQuery.of(context).size;
    final deviceWidth = screenSize.width;
    final deviceHeight = screenSize.height;

    final campaignWidth = campaign.resolution?.width?.toDouble() ?? deviceWidth;
    final campaignHeight =
        campaign.resolution?.height?.toDouble() ?? deviceHeight;

    final scaleX = deviceWidth / campaignWidth;
    final scaleY = deviceHeight / campaignHeight;

    print("Campaign resolution: ${campaignWidth}x${campaignHeight}");
    print("Device resolution: ${deviceWidth}x${deviceHeight}");
    print("Scale factors: X=$scaleX, Y=$scaleY");

    // #region agent log
    agentDebugLog(
      location: 'campaign_view.dart:_buildZones',
      message: 'zones_layout',
      hypothesisId: 'H1',
      data: {
        'campaignId': campaign.campaignId,
        'zoneCount': campaign.zones?.length ?? 0,
        'playerCampaignsCount': playerCampaigns.length,
        'resolution': '${campaignWidth}x$campaignHeight',
      },
    );
    // #endregion

    return Scaffold(
      backgroundColor: Colors.white,
      body: GestureDetector(
        onTapDown: (details) {
          final mqttViewModel =
              Provider.of<MqttViewModel>(context, listen: false);
          mqttViewModel.setTapPosition(
              details.localPosition.dx, details.localPosition.dy);
          print(
              "Tapped at: x=${details.localPosition.dx}, y=${details.localPosition.dy}");
        },
        child: Stack(
          children: (campaign.zones ?? []).map((zone) {
            final scaledX = (zone.x ?? 0) * scaleX;
            final scaledY = (zone.y ?? 0) * scaleY;
            final scaledWidth = (zone.width ?? 0) * scaleX;
            final scaledHeight = (zone.height ?? 0) * scaleY;

            // #region agent log
            final zoneMediaTypes = (zone.mediaItems ?? [])
                .map((m) => m.mediaType ?? 'unknown')
                .toList();
            final hasComposition = zoneMediaTypes.any(
              (t) => t.toLowerCase() == 'composition');
            agentDebugLog(
              location: 'campaign_view.dart:_buildZones:zone',
              message: 'zone_render',
              hypothesisId: 'H5',
              data: {
                'campaignId': campaign.campaignId,
                'zoneId': zone.id,
                'position': '${scaledX.toStringAsFixed(0)},${scaledY.toStringAsFixed(0)}',
                'size': '${scaledWidth.toStringAsFixed(0)}x${scaledHeight.toStringAsFixed(0)}',
                'mediaTypes': zoneMediaTypes,
                'hasComposition': hasComposition,
              },
            );
            // #endregion

            return Positioned(
              left: scaledX,
              top: scaledY,
              width: scaledWidth,
              height: scaledHeight,
              child: VideoPlaylistWidget(
                zoneId: (zone.id ?? 0).toString(),
                mediaItems: zone.mediaItems ?? [],
                campaignId: campaign.campaignId,
                playerCampaigns: playerCampaigns,
                campaignCanPlay: campaignCanPlay,
                campaignSchedule: campaign.campaignSchedule,
                coordinateBaseWidth: campaignWidth,
                coordinateBaseHeight: campaignHeight,
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class VideoPlaylistWidget extends StatefulWidget {
  final String zoneId;
  final List<MediaItem> mediaItems;
  final String? campaignId;
  final List<Campaign> playerCampaigns;
  final bool campaignCanPlay;
  final CampaignSchedule? campaignSchedule;

  final double coordinateBaseWidth;
  final double coordinateBaseHeight;

  const VideoPlaylistWidget({
    super.key,
    required this.zoneId,
    required this.mediaItems,
    this.campaignId,
    this.playerCampaigns = const [],
    required this.campaignCanPlay,
    required this.campaignSchedule,
    required this.coordinateBaseWidth,
    required this.coordinateBaseHeight,
  });

  @override
  _VideoPlaylistWidgetState createState() => _VideoPlaylistWidgetState();
}

class _VideoPlaylistWidgetState extends State<VideoPlaylistWidget> {
  int _currentMediaIndex = 0;
  Timer? _timer;
  Timer? _restrictionCheckTimer;
  double _opacity = 1.0;
  VideoPlayerController? _videoController;
  DateTime? _videoStartTime;
  int? _targetDuration;

  final Map<String, Widget Function()> _webViewWidgetBuilders = {};
  bool _adProofReported = false;
  String? _adPlaybackSessionKey;

  @override
  void initState() {
    super.initState();
    _timer = Timer(Duration.zero, () {});
    _startRestrictionCheckTimer();
    _initializeNextMedia();
  }

  void _startRestrictionCheckTimer() {
    _restrictionCheckTimer?.cancel();
    _restrictionCheckTimer =
        Timer.periodic(const Duration(seconds: 8), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _checkCampaignRestrictions();
    });
  }

  void _checkCampaignRestrictions() {
    if (widget.campaignSchedule == null) return;

    final mqttViewModel = Provider.of<MqttViewModel>(context, listen: false);
    const String reset = '\x1B[0m';
    const String red = '\x1B[31m';
    const String yellow = '\x1B[33m';
    const String cyan = '\x1B[36m';

    bool canPlay = false;

    if (widget.campaignSchedule?.alwaysPlay ?? false) {
      canPlay = true;
    } else {
      final restrictions = widget.campaignSchedule?.restrictions;
      if (restrictions != null && restrictions.isNotEmpty) {
        canPlay = mqttViewModel.checkRestrictions(restrictions);
      } else {
        canPlay = false;
      }
    }

    if (!canPlay && widget.campaignCanPlay) {
      print(
          '$red🛑 PERIODIC CHECK: Campaign restrictions FAILED → Stopping media$reset');
      print(
          '$yellow⏸️  Media was playing but campaign restrictions no longer allow it$reset');
      _stopMedia();
    } else if (canPlay && !widget.campaignCanPlay) {
      print(
          '$cyan✅ PERIODIC CHECK: Campaign restrictions now PASS → Can resume media$reset');
    }
  }

  void _stopMedia() {
    _timer?.cancel();
    _videoController?.pause();
    _videoController?.removeListener(_checkVideoPlaybackDuration);
    setState(() {
      _opacity = 0.0;
    });
  }

  @override
  void didUpdateWidget(covariant VideoPlaylistWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaItems != widget.mediaItems ||
        oldWidget.zoneId != widget.zoneId ||
        oldWidget.campaignCanPlay != widget.campaignCanPlay) {
      if (!widget.campaignCanPlay && oldWidget.campaignCanPlay) {}
      _resetState();
      return;
    }
    final oldUrl = _mediaUrlAt(_currentMediaIndex, oldWidget.mediaItems);
    final newUrl = _mediaUrlAt(_currentMediaIndex, widget.mediaItems);
    if (oldUrl != newUrl && newUrl.isNotEmpty) {
      print('[AdPoP] Ad creative URL became available, restarting slot session');
      _adProofReported = false;
      _adPlaybackSessionKey = null;
      _initializeNextMedia();
    }
  }

  String _mediaUrlAt(int index, List<MediaItem> items) {
    if (index < 0 || index >= items.length) return '';
    return items[index].adCreativeUrl;
  }

  void _resetState() {
    _currentMediaIndex = 0;
    _timer?.cancel();
    _adPlaybackSessionKey = null;
    _adProofReported = false;
    _videoController?.removeListener(_checkVideoPlaybackDuration);
    _videoController?.dispose();
    _videoController = null;
    _videoStartTime = null;
    _targetDuration = null;
    setState(() {
      _opacity = 1.0;
    });
    _initializeNextMedia();
  }

  bool _isNestedCampaign(MediaItem media) {
    final type = (media.mediaType ?? '').toLowerCase();
    final hasZones = media.zones != null && media.zones!.isNotEmpty;
    return hasZones || type == 'campaign' || type == 'composition';
  }

  MediaItem _resolvedMediaAt(int index) {
    if (index < 0 || index >= widget.mediaItems.length) {
      return widget.mediaItems.isNotEmpty
          ? widget.mediaItems.first
          : MediaItem();
    }
    return resolveCompositionMediaItem(
      widget.mediaItems[index],
      widget.playerCampaigns,
    );
  }

  Widget _buildNestedZones(MediaItem media) {
    final zones = media.zones ?? const <CampaignZone>[];
    if (zones.isEmpty) {
      final linked = findLinkedCompositionCampaign(media, widget.playerCampaigns);
      print(
          '[Composition] Zone ${widget.zoneId}: no layers on media "${media.id}"; '
          'linked campaign=${linked?.campaignId ?? "none"}, '
          'playerCampaigns=${widget.playerCampaigns.length}');
      return Center(
        child: Text(
          'Composition "${media.id ?? ''}"\nNo layers (publish composition campaign in playerCampaigns)',
          textAlign: TextAlign.center,
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final linked =
            findLinkedCompositionCampaign(media, widget.playerCampaigns);
        double maxX = 0;
        double maxY = 0;
        for (final zone in zones) {
          final zoneRight = (zone.x ?? 0) + (zone.width ?? 0);
          final zoneBottom = (zone.y ?? 0) + (zone.height ?? 0);
          if (zoneRight > maxX) maxX = zoneRight.toDouble();
          if (zoneBottom > maxY) maxY = zoneBottom.toDouble();
        }

        final resW = linked?.resolution?.width?.toDouble();
        final resH = linked?.resolution?.height?.toDouble();
        final nestedCoordinateBaseWidth = (resW != null && resW > 0)
            ? resW
            : (maxX > 0 ? maxX : constraints.maxWidth);
        final nestedCoordinateBaseHeight = (resH != null && resH > 0)
            ? resH
            : (maxY > 0 ? maxY : constraints.maxHeight);

        final scaleX = constraints.maxWidth / nestedCoordinateBaseWidth;
        final scaleY = constraints.maxHeight / nestedCoordinateBaseHeight;

        print("═══════════════════════════════════════════════════════════");
        print("Nested zones in zone ${widget.zoneId}:");
        print(
            "  Parent zone size: ${constraints.maxWidth}x${constraints.maxHeight}");
        print(
            "  Nested coordinate base: ${nestedCoordinateBaseWidth}x$nestedCoordinateBaseHeight");
        print("  Scale factors: X=$scaleX, Y=$scaleY");
        print("  Number of nested zones: ${zones.length}");

        // #region agent log
        agentDebugLog(
          location: 'campaign_view.dart:_buildNestedZones',
          message: 'nested_composition_layout',
          hypothesisId: 'H4',
          data: {
            'zoneId': widget.zoneId,
            'mediaId': media.id,
            'parentConstraints': '${constraints.maxWidth}x${constraints.maxHeight}',
            'nestedBase': '${nestedCoordinateBaseWidth}x$nestedCoordinateBaseHeight',
            'scaleX': scaleX,
            'scaleY': scaleY,
            'zoneCount': zones.length,
            'linkedCampaignId': linked?.campaignId,
          },
        );
        // #endregion

        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: zones.map((z) {
              final left = (z.x ?? 0) * scaleX;
              final top = (z.y ?? 0) * scaleY;
              final width = (z.width ?? 0) * scaleX;
              final height = (z.height ?? 0) * scaleY;
              final zoneMedia = (z.mediaItems ?? const <MediaItem>[])
                  .map(
                    (m) => resolveCompositionMediaItem(
                      m,
                      widget.playerCampaigns,
                    ),
                  )
                  .toList();

              print(
                  "  Zone ${z.id}: design=(${z.x}, ${z.y}) size=(${z.width}x${z.height}) -> screen=(${left.toStringAsFixed(1)}, ${top.toStringAsFixed(1)}) size=(${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)})");

              // #region agent log
              agentDebugLog(
                location: 'campaign_view.dart:_buildNestedZones:zone',
                message: 'nested_zone_media',
                hypothesisId: 'H6',
                data: {
                  'parentZoneId': widget.zoneId,
                  'nestedZoneId': z.id,
                  'size': '${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)}',
                  'media': zoneMedia
                      .map((m) => {
                            'id': m.id,
                            'type': m.mediaType,
                            'zones': m.zones?.length ?? 0,
                            'urlLen': (m.mediaUrl ?? '').length,
                            'isShape':
                                (m.mediaType ?? '').toLowerCase() == 'shape',
                            'hasRemoteSrc':
                                (m.settings?.remoteSrc ?? '').isNotEmpty,
                            'hasHtml': (m.settings?.html ?? '').isNotEmpty,
                            'compId': m.settings?.compositionCampaignId,
                          })
                      .toList(),
                },
              );
              // #endregion

              return Positioned(
                left: left,
                top: top,
                width: width,
                height: height,
                child: VideoPlaylistWidget(
                  zoneId: '${widget.zoneId}.${z.id ?? 0}',
                  mediaItems: zoneMedia,
                  campaignId: widget.campaignId,
                  playerCampaigns: widget.playerCampaigns,
                  campaignCanPlay: widget.campaignCanPlay,
                  campaignSchedule: widget.campaignSchedule,
                  coordinateBaseWidth: nestedCoordinateBaseWidth,
                  coordinateBaseHeight: nestedCoordinateBaseHeight,
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  void _initializeNextMedia() {
    if (widget.mediaItems.isEmpty) {
      print("Zone ${widget.zoneId}: No media items available.");
      return;
    }

    // Ensure _currentMediaIndex is within bounds
    if (_currentMediaIndex < 0 ||
        _currentMediaIndex >= widget.mediaItems.length) {
      print(
          "Zone ${widget.zoneId}: Media index $_currentMediaIndex is out of bounds (0-${widget.mediaItems.length - 1}), resetting to 0");
      _currentMediaIndex = 0;
    }

    const String reset = '\x1B[0m';
    const String red = '\x1B[31m';
    const String green = '\x1B[32m';
    const String yellow = '\x1B[33m';
    const String blue = '\x1B[34m';
    const String magenta = '\x1B[35m';
    const String cyan = '\x1B[36m';

    MediaItem currentMedia = _resolvedMediaAt(_currentMediaIndex);
    final adSessionKey = currentMedia.isAd
        ? '${currentMedia.id}|${currentMedia.adCreativeUrl}'
        : '';
    if (adSessionKey.isEmpty || adSessionKey != _adPlaybackSessionKey) {
      _adProofReported = false;
    }

    if (currentMedia.isAd) {
      print(
          '$cyan📢 AD: ${currentMedia.adCreativeName} (${currentMedia.adCreativeMediaType})$reset');
    }

    print(
        '$magenta═══════════════════════════════════════════════════════════$reset');
    print('$magenta🎥 MEDIA RESTRICTION CHECK$reset');
    print(
        '$magenta═══════════════════════════════════════════════════════════$reset');
    print('$blue📍 Zone: ${widget.zoneId}$reset');
    print('$blue🎬 Media ID: ${currentMedia.id ?? "N/A"}$reset');
    print(
        '$blue📁 Media URL: ${formatForLog(currentMedia.mediaUrl ?? "N/A")}$reset');
    print(
        '$cyan📊 Campaign can play: ${widget.campaignCanPlay ? "YES ✅" : "NO ❌"}$reset');

    if (!widget.campaignCanPlay) {
      print(
          '$red❌ MEDIA: Campaign restrictions FAILED → Media cannot play$reset');
      print('$red⏭️  MEDIA: Skipping media (campaign not allowed)$reset');
      print(
          '$magenta═══════════════════════════════════════════════════════════$reset');
      _sendAdProofOfPlay(
        currentMedia,
        status: 'failed',
        errorMessage: 'campaign_not_allowed',
      );
      _onMediaEnd();
      return;
    }

    bool shouldPlay = false;
    final mqttViewModel = Provider.of<MqttViewModel>(context, listen: false);

    // Missing schedule = play (SignageX layers often omit schedule on stickers/compositions).
    if (currentMedia.schedule == null ||
        (currentMedia.schedule?.alwaysPlay ?? false)) {
      shouldPlay = true;
      print('$green✅ MEDIA: alwaysPlay = true → Media can play$reset');
    } else {
      final restrictions = currentMedia.schedule?.restrictions;
      if (restrictions != null && restrictions.isNotEmpty) {
        print(
            '$yellow🔍 MEDIA: Checking ${restrictions.length} restriction(s)...$reset');
        shouldPlay = mqttViewModel.checkRestrictions(restrictions);
        if (shouldPlay) {
          print('$green✅ MEDIA: Restrictions PASSED → Media can play$reset');
        } else {
          print('$red❌ MEDIA: Restrictions FAILED → Media cannot play$reset');
        }
      } else {
        print(
            '$yellow⚠️  MEDIA: No restrictions configured and alwaysPlay = false$reset');
        print('$red⏭️  MEDIA: Skipping media (no schedule configured)$reset');
        // #region agent log
        agentDebugLog(
          location: 'campaign_view.dart:_initializeNextMedia',
          message: 'media_skipped_no_schedule',
          hypothesisId: 'H7',
          data: {
            'zoneId': widget.zoneId,
            'mediaId': currentMedia.id,
            'mediaType': currentMedia.mediaType,
            'alwaysPlay': currentMedia.schedule?.alwaysPlay,
          },
        );
        // #endregion
        print(
            '$magenta═══════════════════════════════════════════════════════════$reset');
        _sendAdProofOfPlay(
          currentMedia,
          status: 'failed',
          errorMessage: 'no_schedule_configured',
        );
        _onMediaEnd();
        return;
      }
    }

    print(
        '$magenta═══════════════════════════════════════════════════════════$reset');

    if (shouldPlay) {
      int? durationInt = currentMedia.settings?.duration;
      String duration = (durationInt ?? 0).toString();
      print(
          '$green▶️  MEDIA: Loading and playing media (duration: $duration seconds)$reset');
      if (!currentMedia.isAd) {
        _startMediaLoop(duration, currentMedia);
      }

      if (_isNestedCampaign(currentMedia)) {
        setState(() {});
        return;
      }
      _loadMedia(currentMedia);
    } else {
      print('$red⏭️  MEDIA: Skipping media (restrictions did not pass)$reset');
      _sendAdProofOfPlay(
        currentMedia,
        status: 'failed',
        errorMessage: 'restrictions_failed',
      );
      _onMediaEnd();
    }
  }

  int _parseZoneId() {
    final parts = widget.zoneId.split('.');
    return int.tryParse(parts.last) ?? int.tryParse(widget.zoneId) ?? 0;
  }

  Future<void> _sendAdProofOfPlay(
    MediaItem adMedia, {
    required String status,
    int? completionPercent,
    String? errorMessage,
  }) async {
    if (!adMedia.isAd) return;

    if (status == 'completed') {
      if (_adProofReported) return;
      _adProofReported = true;
    }

    final mqttViewModel = Provider.of<MqttViewModel>(context, listen: false);
    final settings = adMedia.settings;
    final zoneId = _parseZoneId();

    final request = adMedia.toProofOfPlayRequest(
      playerCode: mqttViewModel.playerCode,
      campaignId: widget.campaignId ?? '',
      zoneId: zoneId,
      status: status,
      completionPercent: completionPercent,
      errorMessage: errorMessage,
    );

    print(
        '[AdPoP] Scheduling proof-of-play (status=$status) → zone=$zoneId, '
        'ad_campaign_id=${settings?.adCampaignId ?? "(missing)"}');
    await mqttViewModel.reportAdProofOfPlay(request);
  }

  void _ensureAdSlotProofOfPlaySession(MediaItem adMedia) {
    if (!adMedia.isAd) return;

    final creativeUrl = adMedia.adCreativeUrl;
    if (creativeUrl.isEmpty) {
      print('[AdPoP] Waiting for creative URL (${adMedia.id})');
      return;
    }

    final slotId = adMedia.id ?? '';
    final sessionKey = '$slotId|$creativeUrl';
    final sameSession = _adPlaybackSessionKey == sessionKey;
    if (sameSession && (_timer?.isActive ?? false)) return;

    if (!sameSession) {
      _adProofReported = false;
    }
    _adPlaybackSessionKey = sessionKey;

    var durationSeconds = adMedia.settings?.duration ?? 0;
    if (durationSeconds <= 0) {
      durationSeconds = 15;
      print('[AdPoP] Ad slot duration missing, defaulting to ${durationSeconds}s');
    }

    print(
        '[AdPoP] Ad slot session started: id=${adMedia.id}, '
        'zone=${widget.zoneId}, duration=${durationSeconds}s '
        '(proof-of-play on completion only)');
    _startMediaLoop(durationSeconds.toString(), adMedia);
  }

  void _startMediaLoop(String duration, MediaItem sourceMedia) {
    print("Starting media loop for duration: $duration");
    int durationSeconds = int.tryParse(duration) ?? 10;
    if (durationSeconds <= 0) {
      durationSeconds = 15;
    }

    _timer?.cancel();

    _timer = Timer(Duration(seconds: durationSeconds), () {
      print(
          "[LOG] Media duration timer expired after $durationSeconds seconds");
      if (sourceMedia.isAd) {
        _sendAdProofOfPlay(
          sourceMedia,
          status: 'completed',
          completionPercent: 100,
        );
      }
      _onMediaEnd();
    });
  }

  void _loadMedia(MediaItem nextMedia) {
    final mediaType = (nextMedia.mediaType ?? '').toLowerCase();
    final mediaUrl = nextMedia.mediaUrl ?? '';

    print(
        '[LOG] Loading media - Type: $mediaType, URL: ${formatForLog(mediaUrl)}');

    if (mediaType == 'composition') {
      if (_isNestedCampaign(nextMedia)) {
        print(
            '[LOG] Composition with ${nextMedia.zones?.length ?? 0} layer(s) – '
            'rendering nested layout');
        setState(() {});
        return;
      }
      print(
          '[LOG] Composition has no nested zones/layers in campaign data '
          '(${nextMedia.id})');
      setState(() {});
      return;
    }

    if (nextMedia.isAd) {
      final creative = nextMedia.playbackMedia;
      final creativeUrl = creative.mediaUrl ?? '';
      print(
          "[LOG] Resolved ad/ad_slot creative for playback: "
          '${nextMedia.mediaType} → ${creative.mediaType} (${creative.id})');
      if (creativeUrl.isEmpty) {
        print("[LOG] Ad slot has no creative URL yet (${nextMedia.id})");
        _onMediaEnd();
        return;
      }
      _ensureAdSlotProofOfPlaySession(nextMedia);
      _loadMedia(creative);
      return;
    }

    if (mediaType == 'web_app_instance') {
      print(
          "[LOG] Current media is web_app_instance, loading remote web app in WebView");
      setState(() {});
      return;
    }

    if (mediaType == 'text/html') {
      print("[LOG] Current media is text/html, loading HTML file in WebView");
      setState(() {});
      return;
    }

    if (mediaType == 'text') {
      print("[LOG] Current media is text, using HTML from settings");
      setState(() {});
      return;
    }

    if (mediaType == 'shape') {
      print(
          '[LOG] Current media is shape, svgLen=${(nextMedia.mediaUrl ?? '').length}');
      setState(() {});
      return;
    }

    if (mediaType == 'sticker' || MediaItem.looksLikeSticker(nextMedia)) {
      print(
          '[LOG] Current media is sticker - remoteSrc: ${formatForLog(nextMedia.settings?.remoteSrc)}, '
          'mediaUrl: ${formatForLog(mediaUrl)}');
      setState(() {});
      return;
    }

    // Handle image types (image/jpeg, image/png, image, etc.)
    if (mediaType.startsWith('image')) {
      print("[LOG] Current media is image type: $mediaType");
      setState(() {});
      return;
    }

    if (mediaType.startsWith('video')) {
      print("[LOG] Current media is video type: $mediaType");
      _initializeNextVideo(nextMedia);
      return;
    }

    if (mediaType == 'content') {
      final kind = nextMedia.settings?.kind ?? '';
      print("[LOG] Current media is content, kind: $kind");

      if (mediaItemIsWebAppIframe(nextMedia)) {
        final iframeUrl = mediaItemWebAppIframeUrl(nextMedia);
        print('[LOG] Content is web-app iframe → $iframeUrl');
        setState(() {});
        return;
      }

      if (kind.toLowerCase().contains('video') || isVideoFile(mediaUrl)) {
        _initializeNextVideo(nextMedia);
        return;
      } else if (kind.toLowerCase().contains('image') ||
          isImageFile(mediaUrl)) {
        print("[LOG] Content is image");
        setState(() {});
        return;
      } else {
        print("[LOG] Content type not recognized, treating as image");
        setState(() {});
        return;
      }
    }

    if (mediaUrl.isEmpty) {
      print("[LOG] Media URL is empty, checking if text type");
      if (mediaType == 'text') {
        setState(() {});
        return;
      }
      final slotMedia = widget.mediaItems[_currentMediaIndex];
      if (slotMedia.isAd) {
        _sendAdProofOfPlay(
          slotMedia,
          status: 'failed',
          errorMessage: 'no_creative_url',
        );
      }
      print("[LOG] Media URL is empty and not text, skipping");
      _onMediaEnd();
      return;
    }

    if (isVideoFile(mediaUrl)) {
      _initializeNextVideo(nextMedia);
    } else if (isWebFile(mediaUrl)) {
      if (_currentMediaIndex > 0 &&
          (widget.mediaItems[_currentMediaIndex - 1].mediaUrl ?? '') ==
              mediaUrl) {
        print("[LOG] Skipping recreation of the same WebView");
        return;
      }

      setState(() {});
    } else if (isSvgContent(mediaUrl)) {
      print("[LOG] Current media is SVG: ${nextMedia.mediaUrl}");

      setState(() {});
    } else {
      print("[LOG] Current media is an image: ${nextMedia.mediaUrl}");

      setState(() {});
    }
  }

  bool isImageFile(String path) {
    final imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'];
    return imageExtensions.any((ext) => path.toLowerCase().endsWith(ext));
  }

  void _initializeNextVideo(MediaItem nextMedia) {
    final mediaUrl = nextMedia.mediaUrl ?? '';
    if (mediaUrl.isEmpty) {
      print("[LOG] Video URL is empty, skipping");
      _onMediaEnd();
      return;
    }
    print("[LOG] Initializing video: $mediaUrl");

    final volume = (nextMedia.settings?.volume ?? 100) / 100.0;
    print(
        "[LOG] Setting video volume to: $volume (${nextMedia.settings?.volume}%)");

    _videoController = VideoPlayerController.file(File(mediaUrl))
      ..initialize().then((_) {
        if (_videoController!.value.isInitialized) {
          int targetDuration = nextMedia.settings?.duration ??
              _videoController!.value.duration.inSeconds;
          int videoLength = _videoController!.value.duration.inSeconds;

          _targetDuration = targetDuration;
          _videoStartTime = DateTime.now();

          print("Target play duration: $targetDuration seconds");
          print("Video length: $videoLength seconds");

          setState(() {
            _videoController!.setVolume(volume.clamp(0.0, 1.0));
            _videoController!.play();

            if (targetDuration > 0 &&
                videoLength > 0 &&
                videoLength < targetDuration) {
              _videoController!.setLooping(true);
              print(
                  "[LOG] Video ($videoLength sec) is shorter than target duration ($targetDuration sec), will loop");
            } else {
              _videoController!.setLooping(false);
            }
          });

          if (targetDuration > 0) {
            _videoController!.addListener(_checkVideoPlaybackDuration);
          } else {
            _videoController!.addListener(() {
              if (_videoController!.value.position >=
                      _videoController!.value.duration &&
                  _videoController!.value.position.inMilliseconds > 0) {
                print("[LOG] Video ended naturally, transitioning");
                _videoController!.removeListener(() {});
                _onMediaEnd();
              }
            });
          }
        }
      }).catchError((error) {
        print("[LOG] Error initializing video: $error");
        print("[LOG] Video URL: ${nextMedia.mediaUrl}");
        setState(() {});
      });
  }

  void _checkVideoPlaybackDuration() {
    if (_videoController == null ||
        _videoStartTime == null ||
        _targetDuration == null) {
      return;
    }

    if (_timer?.isActive ?? false) {
      final elapsed = DateTime.now().difference(_videoStartTime!).inSeconds;

      if (elapsed >= _targetDuration! &&
          _videoController!.value.position >=
              _videoController!.value.duration) {
        print("[LOG] Video ended naturally before timer, transitioning early");
        _videoController!.removeListener(_checkVideoPlaybackDuration);
        _timer?.cancel();
        _videoController!.pause();
        _onMediaEnd();
      }
    }
  }

  bool _isDisposed = false;

  void _onMediaEnd() {
    _timer?.cancel();

    if (_videoController != null) {
      _videoController!.removeListener(_checkVideoPlaybackDuration);
    }

    if (!_isDisposed && mounted) {
      _videoController?.pause();
      _videoController?.dispose();
      _videoController = null;
      _videoStartTime = null;
      _targetDuration = null;

      final currentIndex = _currentMediaIndex;
      final totalMedia = widget.mediaItems.length;
      print("[LOG] Media ended at index $currentIndex of $totalMedia");

      setState(() {
        _opacity = 0.0;
      });

      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted || _isDisposed) return;

        if (widget.mediaItems.isEmpty) {
          print("[LOG] No media items available, cannot transition");
          return;
        }

        setState(() {
          if (_currentMediaIndex < widget.mediaItems.length - 1) {
            _currentMediaIndex++;
          } else {
            _currentMediaIndex = 0;
          }
          print(
              "[LOG] Transitioning to media index $_currentMediaIndex of ${widget.mediaItems.length}");

          if (_currentMediaIndex < widget.mediaItems.length) {
            print(
                "[LOG] Next media ID: ${widget.mediaItems[_currentMediaIndex].id ?? 'N/A'}");
            print(
                "[LOG] Next media URL: ${widget.mediaItems[_currentMediaIndex].mediaUrl ?? 'N/A'}");
          }

          _opacity = 1.0;
          _initializeNextMedia();
        });
      });
    }
  }

  bool isWebFile(String path) {
    final webExtensions = ['.html'];
    return webExtensions.any((ext) => path.endsWith(ext));
  }

  bool isSvgContent(String content) {
    final trimmed = content.trim();
    return trimmed.startsWith('<svg') ||
        (trimmed.contains('<svg') && trimmed.contains('</svg>'));
  }

  String _decodeSvgContent(String content) {
    try {
      print("[LOG] _decodeSvgContent - Input length: ${content.length}");
      print(
          "[LOG] _decodeSvgContent - Input preview: ${content.substring(0, content.length > 200 ? 200 : content.length)}...");

      String cleaned = _normalizeSvgForParser(content);

      print(
          "[LOG] _decodeSvgContent - After unescape, length: ${cleaned.length}");
      print(
          "[LOG] _decodeSvgContent - After unescape preview: ${cleaned.substring(0, cleaned.length > 200 ? 200 : cleaned.length)}...");

      if (cleaned.contains('points="') || cleaned.contains('fill="')) {
        print("[LOG] _decodeSvgContent - Quotes preserved correctly");
      } else {
        print(
            "[LOG] _decodeSvgContent - No quotes found in attributes (may be using single quotes or no quotes)");
      }

      if (cleaned.contains('%')) {
        final decoded = Uri.decodeComponent(cleaned);

        if (decoded != cleaned && isSvgContent(decoded)) {
          print("[LOG] SVG decoded from URL encoding");
          return decoded;
        }
      }

      print("[LOG] SVG content ready, length: ${cleaned.length}");
      return cleaned;
    } catch (e) {
      print("[ERROR] SVG decode error: $e");
      return content;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _restrictionCheckTimer?.cancel();
    _isDisposed = true;
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mediaItems.isEmpty) {
      return Center(child: Text("Zone ${widget.zoneId}: No media items."));
    }

    if (_currentMediaIndex < 0 ||
        _currentMediaIndex >= widget.mediaItems.length) {
      _currentMediaIndex = 0;
    }

    MediaItem currentMedia = _resolvedMediaAt(_currentMediaIndex);
    final playbackMedia =
        currentMedia.isAd ? currentMedia.playbackMedia : currentMedia;
    final mediaType = (playbackMedia.mediaType ?? '').toLowerCase();

    if (mediaType == 'composition') {
      final linked = findLinkedCompositionCampaign(currentMedia, widget.playerCampaigns);
      // #region agent log
      agentDebugLog(
        location: 'campaign_view.dart:build:composition',
        message: 'composition_resolved',
        hypothesisId: 'H3',
        data: {
          'zoneId': widget.zoneId,
          'mediaId': currentMedia.id,
          'zoneCount': playbackMedia.zones?.length ?? 0,
          'linkedCampaignId': linked?.campaignId,
          'linkedCampaignZones': linked?.zones?.length ?? 0,
          'settingsCompId': currentMedia.settings?.compositionCampaignId,
          'playerCampaignsCount': widget.playerCampaigns.length,
          'compositionCampaigns': widget.playerCampaigns
              .where((c) => c.isCompositionLayout)
              .map((c) => {'id': c.campaignId, 'name': c.campaignName, 'zones': c.zones?.length ?? 0})
              .toList(),
        },
      );
      // #endregion
    }

    final isWebViewWidget = mediaType == 'text' ||
        mediaType == 'text/html' ||
        mediaType == 'sticker' ||
        mediaType == 'shape' ||
        mediaType == 'web_app_instance' ||
        (mediaType == 'content' && mediaItemIsWebAppIframe(playbackMedia));

    final mediaWidget = _buildMediaWidget(playbackMedia, sourceMedia: currentMedia);

    if (isWebViewWidget) {
      return AnimatedOpacity(
        opacity: _opacity,
        duration: const Duration(milliseconds: 500),
        child: mediaWidget,
      );
    }

    return AnimatedOpacity(
      opacity: _opacity,
      duration: const Duration(milliseconds: 500),
      child: AnimatedSwitcher(
        key: ValueKey(currentMedia.id),
        duration: const Duration(milliseconds: 500),
        transitionBuilder: (child, animation) {
          print(
              "this is transition${currentMedia.settings?.transition ?? 'none'}");

          switch (currentMedia.settings?.transition ?? 'none') {
            case "fadeIn":
              return FadeTransition(opacity: animation, child: child);
            case "slideOverLeftToRight":
              return SlideTransition(
                position: animation.drive(
                  Tween(
                    begin: const Offset(-1, 0),
                    end: Offset.zero,
                  ).chain(CurveTween(curve: Curves.easeInOut)),
                ),
                child: child,
              );
            case "slideOverRightToLeft":
              return SlideTransition(
                position: animation.drive(
                  Tween(
                    begin: const Offset(1, 0),
                    end: Offset.zero,
                  ).chain(CurveTween(curve: Curves.easeInOut)),
                ),
                child: child,
              );
            case "slideOverTopToBottom":
              return SlideTransition(
                position: animation.drive(
                  Tween(
                    begin: const Offset(0, -1), // From top
                    end: Offset.zero,
                  ).chain(CurveTween(curve: Curves.easeInOut)),
                ),
                child: child,
              );
            case "slideOverBottomToTop":
              return SlideTransition(
                position: animation.drive(
                  Tween(
                    begin: const Offset(0, 1), // From bottom
                    end: Offset.zero,
                  ).chain(CurveTween(curve: Curves.easeInOut)),
                ),
                child: child,
              );
            case "slideInOutLeftToRight":
              return Stack(
                children: [
                  SlideTransition(
                    position: animation.drive(
                      Tween(
                        begin: const Offset(-1, 0),
                        end: Offset.zero,
                      ).chain(CurveTween(curve: Curves.easeInOut)),
                    ),
                    child: child,
                  ),
                  SlideTransition(
                    position: animation.drive(
                      Tween(
                        begin: Offset.zero,
                        end: const Offset(1, 0),
                      ).chain(CurveTween(curve: Curves.easeInOut)),
                    ),
                    child: child,
                  ),
                ],
              );
            case "slideInOutRightToLeft":
              return Stack(
                children: [
                  SlideTransition(
                    position: animation.drive(
                      Tween(
                        begin: const Offset(1, 0),
                        end: Offset.zero,
                      ).chain(CurveTween(curve: Curves.easeInOut)),
                    ),
                    child: child,
                  ),
                  SlideTransition(
                    position: animation.drive(
                      Tween(
                        begin: Offset.zero,
                        end: const Offset(-1, 0),
                      ).chain(CurveTween(curve: Curves.easeInOut)),
                    ),
                    child: child,
                  ),
                ],
              );
            case "slideInOutTopToBottom":
              return Stack(
                children: [
                  SlideTransition(
                    position: animation.drive(
                      Tween(
                        begin: const Offset(0, -1),
                        end: Offset.zero,
                      ).chain(CurveTween(curve: Curves.easeInOut)),
                    ),
                    child: child,
                  ),
                  SlideTransition(
                    position: animation.drive(
                      Tween(
                        begin: Offset.zero,
                        end: const Offset(0, 1),
                      ).chain(CurveTween(curve: Curves.easeInOut)),
                    ),
                    child: child,
                  ),
                ],
              );
            case "slideInOutBottomToTop":
              return Stack(
                children: [
                  SlideTransition(
                    position: animation.drive(
                      Tween(
                        begin: const Offset(0, 1),
                        end: Offset.zero,
                      ).chain(CurveTween(curve: Curves.easeInOut)),
                    ),
                    child: child,
                  ),
                  SlideTransition(
                    position: animation.drive(
                      Tween(
                        begin: Offset.zero,
                        end: const Offset(0, -1),
                      ).chain(CurveTween(curve: Curves.easeInOut)),
                    ),
                    child: child,
                  ),
                ],
              );
            default:
              return child;
          }
        },
        child: mediaWidget,
      ),
    );
  }

  bool isVideoFile(String path) {
    final videoExtensions = ['.mp4', '.avi', '.mov', '.mkv'];
    return videoExtensions.any((ext) => path.toLowerCase().endsWith(ext));
  }

  Widget _buildStickerWidget(MediaItem media) {
    final remoteSrc = media.settings?.remoteSrc?.trim() ?? '';
    final stickerHtml = media.settings?.html?.trim() ?? '';
    final mediaUrl = media.mediaUrl ?? '';
    final effectiveStickerUrl = remoteSrc.isNotEmpty ? remoteSrc : mediaUrl;
    print(
        '[LOG] _buildMediaWidget - Sticker zone=${widget.zoneId} '
        'remoteSrc=${formatForLog(remoteSrc)} '
        'mediaUrl=${formatForLog(mediaUrl)} '
        'hasHtml=${stickerHtml.isNotEmpty}');
    // #region agent log
    agentDebugLog(
      location: 'campaign_view.dart:_buildStickerWidget',
      message: 'sticker_render',
      hypothesisId: 'H8',
      data: {
        'zoneId': widget.zoneId,
        'mediaId': media.id,
        'mediaType': media.mediaType,
        'urlLen': effectiveStickerUrl.length,
        'hasHtml': stickerHtml.isNotEmpty,
        'durationSec': media.settings?.duration,
        'effectiveStickerUrlKind': effectiveStickerUrl.isEmpty
            ? 'empty'
            : (effectiveStickerUrl.startsWith('data:image')
                ? 'data:image'
                : (effectiveStickerUrl.startsWith('http://') ||
                        effectiveStickerUrl.startsWith('https://'))
                    ? 'http'
                    : (effectiveStickerUrl.startsWith('file://')
                        ? 'file'
                        : 'path')),
        'effectiveStickerUrlPreview': effectiveStickerUrl.isEmpty
            ? ''
            : (effectiveStickerUrl.length > 60
                ? effectiveStickerUrl.substring(0, 60)
                : effectiveStickerUrl),
        'remoteSrcLen': remoteSrc.length,
        'remoteSrcPreview': remoteSrc.isEmpty
            ? ''
            : (remoteSrc.length > 60 ? remoteSrc.substring(0, 60) : remoteSrc),
        'mediaUrlLen': mediaUrl.length,
        'mediaUrlPreview': mediaUrl.isEmpty
            ? ''
            : (mediaUrl.length > 60
                ? mediaUrl.substring(0, 60)
                : mediaUrl),
      },
    );
    // #endregion

    final transition = media.settings?.transition ?? 'none';

    if (stickerHtml.isNotEmpty) {
      return SizedBox.expand(
        child: StickerHtmlWidget(
          key: ValueKey('${widget.zoneId}_sticker_html_${media.id}'),
          svgUrl: '',
          htmlContent: stickerHtml,
          onSvgEnd: _onMediaEnd,
          transitionType: transition,
        ),
      );
    }

    if (isSvgContent(effectiveStickerUrl)) {
      return _buildStickerSvgContent(
        _decodeSvgContent(effectiveStickerUrl),
        transition: transition,
        onEnd: _onMediaEnd,
        key: ValueKey('${widget.zoneId}_sticker_inline_${media.id}'),
        zoneId: widget.zoneId,
        mediaId: media.id,
      );
    }

    final localPath = _normalizeLocalMediaPath(effectiveStickerUrl);
    if (localPath != null) {
      final file = File(localPath);
      final exists = file.existsSync();
      // #region agent log
      agentDebugLog(
        location: 'campaign_view.dart:_buildStickerWidget:file',
        message: 'sticker_file_check',
        hypothesisId: 'H8',
        runId: 'post-fix',
        data: {
          'zoneId': widget.zoneId,
          'mediaId': media.id,
          'path': localPath,
          'exists': exists,
          'ext': localPath.contains('.') ? localPath.split('.').last : '',
        },
      );
      // #endregion
      if (exists) {
        if (localPath.toLowerCase().endsWith('.svg')) {
          try {
            final svg = file.readAsStringSync();
            // #region agent log
            agentDebugLog(
              location: 'campaign_view.dart:_buildStickerWidget:file',
              message: 'sticker_svg_loaded',
              hypothesisId: 'H8',
              runId: 'post-fix',
              data: {
                'zoneId': widget.zoneId,
                'mediaId': media.id,
                'svgLen': svg.length,
                'useHtmlRaster': _svgNeedsHtmlRaster(svg),
              },
            );
            // #endregion
            return _buildStickerSvgContent(
              svg,
              transition: transition,
              onEnd: _onMediaEnd,
              key: ValueKey('${widget.zoneId}_sticker_file_${media.id}'),
              zoneId: widget.zoneId,
              mediaId: media.id,
            );
          } catch (e) {
            agentDebugLog(
              location: 'campaign_view.dart:_buildStickerWidget:file',
              message: 'sticker_svg_read_error',
              hypothesisId: 'H8',
              runId: 'post-fix',
              data: {
                'zoneId': widget.zoneId,
                'mediaId': media.id,
                'error': e.toString(),
              },
            );
          }
        }
        if (isImageFile(localPath)) {
          return ImageWidget(
            key: ValueKey('${widget.zoneId}_sticker_img_${media.id}'),
            filePath: localPath,
            onImageEnd: _onMediaEnd,
            transitionType: transition,
          );
        }
      }
    }

    return SizedBox.expand(
      child: StickerHtmlWidget(
        key: ValueKey('${widget.zoneId}_sticker_remote_${media.id}'),
        svgUrl: effectiveStickerUrl,
        htmlContent: null,
        onSvgEnd: _onMediaEnd,
        transitionType: transition,
      ),
    );
  }

  Widget _buildMediaWidget(MediaItem media, {MediaItem? sourceMedia}) {
    final mediaType = (media.mediaType ?? '').toLowerCase();
    final mediaUrl = media.mediaUrl ?? '';
    final adSource = sourceMedia ?? media;

    print(
        '[LOG] _buildMediaWidget - Media ID: ${adSource.id}, '
        "Type: '$mediaType', URL: ${formatForLog(mediaUrl)}");
    if (isAdMediaType(adSource.mediaType)) {
      print(
          '[LOG] _buildMediaWidget - Ad slot '
          '(ad_campaign_id=${adSource.settings?.adCampaignId ?? "missing"})');
    }
    print(
        '[LOG] _buildMediaWidget - Settings HTML: '
        '${formatForLog(media.settings?.html, maxLen: 60)}');

    if (_isNestedCampaign(media)) {
      final source = sourceMedia ?? media;
      var nestedMedia = resolveCompositionMediaItem(
        source,
        widget.playerCampaigns,
      );
      if ((nestedMedia.zones == null || nestedMedia.zones!.isEmpty)) {
        final linked = findLinkedCompositionCampaign(
          source,
          widget.playerCampaigns,
        );
        if (linked?.zones != null && linked!.zones!.isNotEmpty) {
          nestedMedia = MediaItem(
            id: source.id,
            settings: source.settings,
            schedule: source.schedule,
            mediaType: source.mediaType,
            mediaUrl: source.mediaUrl,
            zones: linked.zones,
          );
        }
      }
      final zoneCount = nestedMedia.zones?.length ?? 0;
      print(
          "[LOG] _buildMediaWidget - Building nested layout "
          '(${nestedMedia.mediaType}, $zoneCount zone(s))');
      if (zoneCount == 0) {
        return Center(
          child: Text(
            'Composition "${source.id ?? ''}" has no layers',
            textAlign: TextAlign.center,
          ),
        );
      }
      return _buildNestedZones(nestedMedia);
    }

    if (mediaType == 'text/html') {
      print("[LOG] _buildMediaWidget - Building WBViewWidget for text/html");
      final cacheKey = '${widget.zoneId}_html_${media.id ?? ''}';
      if (!_webViewWidgetBuilders.containsKey(cacheKey)) {
        _webViewWidgetBuilders[cacheKey] = () => RepaintBoundary(
              key: ValueKey(cacheKey),
              child: SizedBox.expand(
                child: WBViewWidget(
                  key: ValueKey(cacheKey),
                  media: mediaUrl,
                  onMediaEnd: _onMediaEnd,
                ),
              ),
            );
      }
      return _webViewWidgetBuilders[cacheKey]!();
    }

    if (mediaType == 'web_app_instance') {
      print(
          "[LOG] _buildMediaWidget - Building WBViewWidget for web_app_instance");
      final cacheKey = '${widget.zoneId}_webapp_${media.id ?? ''}';
      if (!_webViewWidgetBuilders.containsKey(cacheKey)) {
        _webViewWidgetBuilders[cacheKey] = () => RepaintBoundary(
              key: ValueKey(cacheKey),
              child: SizedBox.expand(
                child: WBViewWidget(
                  key: ValueKey(cacheKey),
                  media: mediaUrl,
                  onMediaEnd: _onMediaEnd,
                ),
              ),
            );
      }
      return _webViewWidgetBuilders[cacheKey]!();
    }

    if (mediaType == 'text') {
      print("[LOG] _buildMediaWidget - Building TextWidget");
      final cacheKey = '${widget.zoneId}_text_${media.id ?? ''}';
      if (!_webViewWidgetBuilders.containsKey(cacheKey)) {
        _webViewWidgetBuilders[cacheKey] = () => RepaintBoundary(
              key: ValueKey(cacheKey),
              child: SizedBox.expand(
                child: TextWidget(
                  key: ValueKey(cacheKey),
                  html: media.settings?.html ?? '',
                  text: media.settings?.text ?? '',
                  onTextEnd: _onMediaEnd,
                  transitionType: media.settings?.transition ?? 'none',
                  fontSize: media.settings?.fontSize,
                  fontFamily: media.settings?.fontFamily,
                  fill: media.settings?.fill,
                  strokeWidth: media.settings?.strokeWidth,
                  shadowBlur: media.settings?.shadowBlur,
                ),
              ),
            );
      }
      return _webViewWidgetBuilders[cacheKey]!();
    }

    if (mediaType == 'shape') {
      var svgContent = mediaUrl.isNotEmpty ? _decodeSvgContent(mediaUrl) : '';
      if (!isSvgContent(svgContent)) {
        final built = MediaItem.svgFromShapeProperties({
          if (media.settings?.fill != null) 'fill': media.settings!.fill,
          if (media.settings?.strokeWidth != null)
            'strokeWidth': media.settings!.strokeWidth,
          if (media.settings?.kind != null) 'shapeType': media.settings!.kind,
        });
        if (built != null) svgContent = built;
      }
      print(
          '[LOG] _buildMediaWidget - Shape zone=${widget.zoneId} svgLen=${svgContent.length}');
      // #region agent log
      agentDebugLog(
        location: 'campaign_view.dart:_buildMediaWidget:shape',
        message: 'shape_render',
        hypothesisId: 'H9',
        data: {
          'zoneId': widget.zoneId,
          'mediaId': media.id,
          'svgLen': svgContent.length,
          'fill': media.settings?.fill,
          'shapeKind': media.settings?.kind,
        },
      );
      // #endregion
      final cacheKey = '${widget.zoneId}_shape_${media.id ?? ''}';
      if (!_webViewWidgetBuilders.containsKey(cacheKey)) {
        _webViewWidgetBuilders[cacheKey] = () => RepaintBoundary(
              key: ValueKey(cacheKey),
              child: SizedBox.expand(
                child: SvgWidget(
                  key: ValueKey(cacheKey),
                  svgContent: svgContent,
                  onSvgEnd: _onMediaEnd,
                  transitionType: media.settings?.transition ?? 'none',
                ),
              ),
            );
      }
      return _webViewWidgetBuilders[cacheKey]!();
    }

    if (mediaType == 'sticker') {
      return _buildStickerWidget(media);
    }

    if (mediaType.startsWith('image')) {
      print(
          "[LOG] _buildMediaWidget - Building ImageWidget for image type: $mediaType");
      return ImageWidget(
        key: ValueKey(media.id ?? ''),
        filePath: mediaUrl,
        onImageEnd: () {
          _onMediaEnd();
        },
        transitionType: media.settings?.transition ?? 'none',
      );
    }

    if (mediaType.startsWith('video')) {
      print(
          "[LOG] _buildMediaWidget - Building VideoPlayerWidget for video type: $mediaType");
      return VideoPlayerWidget(
        key: ValueKey('${media.id ?? ''}_${_currentMediaIndex}'),
        filePath: mediaUrl,
        onVideoEnd: () {
          if (!(_timer?.isActive ?? false)) {
            _onMediaEnd();
          }
        },
        transitionType: media.settings?.transition ?? 'none',
        volume: (media.settings?.volume ?? 100) / 100.0,
      );
    }

    if (mediaType == 'content' && mediaItemIsWebAppIframe(media)) {
      final iframeUrl = mediaItemWebAppIframeUrl(media);
      print(
          '[LOG] _buildMediaWidget - Building WBViewWidget for web-app iframe: '
          '$iframeUrl');
      final cacheKey = '${widget.zoneId}_iframe_${media.id ?? ''}';
      if (!_webViewWidgetBuilders.containsKey(cacheKey)) {
        _webViewWidgetBuilders[cacheKey] = () => RepaintBoundary(
              key: ValueKey(cacheKey),
              child: SizedBox.expand(
                child: WBViewWidget(
                  key: ValueKey(cacheKey),
                  media: iframeUrl,
                  onMediaEnd: _onMediaEnd,
                ),
              ),
            );
      }
      return _webViewWidgetBuilders[cacheKey]!();
    }

    if (mediaType == 'content') {
      final kind = (media.settings?.kind ?? '').toLowerCase();
      if (kind.contains('video') || isVideoFile(mediaUrl)) {
        return VideoPlayerWidget(
          key: ValueKey('${media.id ?? ''}_${_currentMediaIndex}'),
          filePath: mediaUrl,
          onVideoEnd: () {
            if (!(_timer?.isActive ?? false)) {
              _onMediaEnd();
            }
          },
          transitionType: media.settings?.transition ?? 'none',
          volume: (media.settings?.volume ?? 100) / 100.0,
        );
      } else {
        // Treat as image
        return ImageWidget(
          key: ValueKey(media.id ?? ''),
          filePath: mediaUrl,
          onImageEnd: _onMediaEnd,
          transitionType: media.settings?.transition ?? 'none',
        );
      }
    }

    if (isVideoFile(mediaUrl)) {
      return VideoPlayerWidget(
        key: ValueKey('${media.id ?? ''}_${_currentMediaIndex}'),
        filePath: mediaUrl,
        onVideoEnd: () {
          if (!(_timer?.isActive ?? false)) {
            _onMediaEnd();
          }
        },
        transitionType: media.settings?.transition ?? 'none',
        volume: (media.settings?.volume ?? 100) / 100.0,
      );
    } else if (isWebFile(mediaUrl)) {
      return WBViewWidget(
        key: ValueKey(media.id ?? ''),
        media: mediaUrl,
        onMediaEnd: _onMediaEnd,
      );
    } else if (isSvgContent(mediaUrl)) {
      return SvgWidget(
        key: ValueKey(media.id ?? ''),
        svgContent: _decodeSvgContent(mediaUrl),
        onSvgEnd: _onMediaEnd,
        transitionType: media.settings?.transition ?? 'none',
      );
    } else {
      return ImageWidget(
        key: ValueKey(media.id ?? ''),
        filePath: mediaUrl,
        onImageEnd: _onMediaEnd,
        transitionType: media.settings?.transition ?? 'none',
      );
    }
  }
}

class VideoPlayerWidget extends StatefulWidget {
  final String filePath;
  final VoidCallback onVideoEnd;
  final String transitionType;
  final double volume;

  const VideoPlayerWidget({
    super.key,
    required this.filePath,
    required this.onVideoEnd,
    required this.transitionType,
    this.volume = 1.0,
  });

  @override
  _VideoPlayerWidgetState createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _controller;
  bool _isLoading = true;
  bool _isVideoEnded = false;
  int _initAttempts = 0;
  static const int _maxInitAttempts = 5;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  bool get _isNetworkUrl =>
      widget.filePath.startsWith('http://') ||
      widget.filePath.startsWith('https://');

  void _initializeVideo() async {
    print("[LOG] VideoPlayerWidget: Initializing video: ${widget.filePath}");

    if (!_isNetworkUrl) {
      final file = File(widget.filePath);
      if (!await file.exists()) {
        _initAttempts++;
        print(
            "[LOG] VideoPlayerWidget: File does not exist (attempt $_initAttempts/$_maxInitAttempts): ${widget.filePath}");
        if (_initAttempts <= _maxInitAttempts) {
          await Future.delayed(const Duration(seconds: 1));
          if (!mounted) return;
          _initializeVideo();
          return;
        } else {
          print(
              "[LOG] VideoPlayerWidget: Giving up after $_maxInitAttempts attempts – video will show as not initialized.");
          setState(() {
            _isLoading = false;
          });
          return;
        }
      }
    }

    print(
        "[LOG] VideoPlayerWidget: ${_isNetworkUrl ? "Network URL" : "File exists"}, creating controller...");

    // Dispose any previous controller before re-initializing
    if (_controller != null) {
      try {
        _controller!.dispose();
      } catch (_) {}
      _controller = null;
    }

    final VideoPlayerController controller = _isNetworkUrl
        ? VideoPlayerController.network(widget.filePath)
        : VideoPlayerController.file(File(widget.filePath));
    _controller = controller
      ..initialize().then(
        (_) {
          if (!mounted || _controller == null) return;

          print("[LOG] VideoPlayerWidget: Video initialized successfully");
          print(
              "[LOG] VideoPlayerWidget: Duration: ${_controller!.value.duration}");
          print("[LOG] VideoPlayerWidget: Size: ${_controller!.value.size}");
          print(
              "[LOG] VideoPlayerWidget: IsInitialized: ${_controller!.value.isInitialized}");

          if (!_controller!.value.isInitialized ||
              _controller!.value.hasError) {
            _initAttempts++;
            print(
                "[LOG] VideoPlayerWidget: ERROR after initialize() (attempt $_initAttempts/$_maxInitAttempts) "
                "- hasError=${_controller!.value.hasError}, desc=${_controller!.value.errorDescription}");
            if (_initAttempts <= _maxInitAttempts) {
              Future.delayed(const Duration(seconds: 1), () {
                if (!mounted) return;
                _initializeVideo();
              });
              return;
            } else {
              setState(() {
                _isLoading = false;
              });
              return;
            }
          }

          setState(
            () {
              _isLoading = false;
              _controller!.setVolume(widget.volume.clamp(0.0, 1.0));
              // Keep videos playing continuously (repeat forever).
              _controller!.setLooping(true);
              _controller!.play();
              print("[LOG] VideoPlayerWidget: Video play() called");
            },
          );

          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted && _controller != null) {
              print(
                  "[LOG] VideoPlayerWidget: After 500ms - IsPlaying: ${_controller!.value.isPlaying}, "
                  "HasError: ${_controller!.value.hasError}, "
                  "Position: ${_controller!.value.position}");
              if (_controller!.value.hasError) {
                print(
                    "[LOG] VideoPlayerWidget: ERROR after play() - ${_controller!.value.errorDescription}");
              }
              if (!_controller!.value.isPlaying &&
                  _controller!.value.isInitialized) {
                print(
                    "[LOG] VideoPlayerWidget: WARNING - Video not playing after play() call, trying again...");
                _controller!.play();
              }
            }
          });

          _controller!.addListener(
            () {
              if (_controller == null) return;

              if (!_controller!.value.isLooping &&
                  _controller!.value.position >= _controller!.value.duration &&
                  !_isVideoEnded) {
                _isVideoEnded = true;
                widget.onVideoEnd();
              }

              if (_controller!.value.position.inSeconds % 5 == 0 &&
                  _controller!.value.position.inMilliseconds > 0) {
                print(
                    "[LOG] VideoPlayerWidget: Playing - Position: ${_controller!.value.position}, "
                    "IsPlaying: ${_controller!.value.isPlaying}, "
                    "HasError: ${_controller!.value.hasError}");
                if (_controller!.value.hasError) {
                  print(
                      "[LOG] VideoPlayerWidget: ERROR - ${_controller!.value.errorDescription}");
                }
              }
            },
          );
        },
      ).catchError(
        (error, stackTrace) async {
          _initAttempts++;
          print(
              "[LOG] VideoPlayerWidget: ERROR initializing video (attempt $_initAttempts/$_maxInitAttempts): $error");
          print("[LOG] VideoPlayerWidget: Stack trace: $stackTrace");
          print("[LOG] VideoPlayerWidget: File path: ${widget.filePath}");

          if (_initAttempts <= _maxInitAttempts) {
            await Future.delayed(const Duration(seconds: 1));
            if (!mounted) return;
            _initializeVideo();
          } else {
            setState(
              () {
                _isLoading = false;
              },
            );
          }
        },
      );
  }

  void _checkVideoEnd() {
    if (_controller != null &&
        _controller!.value.isInitialized &&
        !_controller!.value.isPlaying &&
        _controller!.value.position >= _controller!.value.duration &&
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
      if (_controller != null) {
        _controller!.removeListener(_checkVideoEnd);
        _controller!.dispose();
        _controller = null;
      }
      _initializeVideo();
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget videoWidget;

    if (_isLoading) {
      print("[LOG] VideoPlayerWidget: Building - Still loading...");
      videoWidget = const Center(child: CircularProgressIndicator());
    } else if (_controller == null || !_controller!.value.isInitialized) {
      print("[LOG] VideoPlayerWidget: Building - Controller not initialized!");
      videoWidget = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            const Text("Video not initialized", style: TextStyle(fontSize: 16)),
            Text("File: ${widget.filePath}",
                style: const TextStyle(fontSize: 12)),
            if (_controller != null && _controller!.value.hasError)
              Text("Error: ${_controller!.value.errorDescription}",
                  style: const TextStyle(fontSize: 12, color: Colors.red)),
          ],
        ),
      );
    } else {
      print("[LOG] VideoPlayerWidget: Building - Displaying video player");
      print(
          "[LOG] VideoPlayerWidget: IsPlaying: ${_controller!.value.isPlaying}");
      print(
          "[LOG] VideoPlayerWidget: HasError: ${_controller!.value.hasError}");
      if (_controller!.value.hasError) {
        print(
            "[LOG] VideoPlayerWidget: ERROR - ${_controller!.value.errorDescription}");
      }

      videoWidget = SizedBox.expand(
        child: VideoPlayer(_controller!),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: videoWidget,
    );
  }

  @override
  void dispose() {
    if (_controller != null) {
      _controller!.removeListener(_checkVideoEnd);
      _controller!.dispose();
    }
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

  bool get _isNetworkUrl =>
      filePath.startsWith('http://') || filePath.startsWith('https://');

  bool get _isDataUri => filePath.startsWith('data:image');

  Uint8List? _decodeBase64Image(String source) {
    try {
      var payload = source.trim();
      if (payload.startsWith('data:image')) {
        final comma = payload.indexOf(',');
        if (comma < 0) return null;
        payload = payload.substring(comma + 1);
      }
      return base64Decode(payload.replaceAll(RegExp(r'\s+'), ''));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final normalized = MediaItem.normalizeImageMediaUrl(
      filePath,
      kind: filePath.contains('jpeg') ? 'image/jpeg' : 'image/png',
    );
    final bytes = (_isDataUri || MediaItem.isRawBase64ImagePayload(normalized))
        ? _decodeBase64Image(normalized ?? filePath)
        : null;

    final Widget imageChild;
    if (bytes != null) {
      imageChild = Image.memory(
        bytes,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Center(
          child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
        ),
      );
    } else if (_isNetworkUrl) {
      imageChild = Image.network(
        filePath,
        fit: BoxFit.cover,
        height: MediaQuery.sizeOf(context).height,
        width: MediaQuery.sizeOf(context).width,
        errorBuilder: (_, __, ___) => const Center(
          child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
        ),
      );
    } else {
      imageChild = Image.file(
        File(filePath),
        fit: BoxFit.cover,
        height: MediaQuery.sizeOf(context).height,
        width: MediaQuery.sizeOf(context).width,
        errorBuilder: (_, __, ___) => const Center(
          child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
        ),
      );
    }

    Widget imageWidget = SizedBox.expand(child: imageChild);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: imageWidget,
    );
  }
}

class SvgWidget extends StatefulWidget {
  final String svgContent;
  final VoidCallback onSvgEnd;
  final String transitionType;

  const SvgWidget({
    super.key,
    required this.svgContent,
    required this.onSvgEnd,
    required this.transitionType,
  });

  @override
  _SvgWidgetState createState() => _SvgWidgetState();
}

class _SvgWidgetState extends State<SvgWidget> {
  @override
  Widget build(BuildContext context) {
    print(
        "[LOG] SvgWidget: Rendering SVG content: ${widget.svgContent.substring(0, widget.svgContent.length > 100 ? 100 : widget.svgContent.length)}...");

    try {
      return SizedBox.expand(
        child: SvgPicture.string(
          widget.svgContent,
          fit: BoxFit.contain,
          placeholderBuilder: (BuildContext context) => const Center(
            child: CircularProgressIndicator(),
          ),
        ),
      );
    } catch (e) {
      print("[ERROR] SvgWidget: Error rendering SVG: $e");
      return const Center(
        child: Text('Error loading SVG'),
      );
    }
  }
}

class TextWidget extends StatefulWidget {
  final String html;
  final String text;
  final VoidCallback onTextEnd;
  final String transitionType;
  final int? fontSize;
  final String? fontFamily;
  final String? fill;
  final int? strokeWidth;
  final int? shadowBlur;

  const TextWidget({
    super.key,
    required this.html,
    required this.text,
    required this.onTextEnd,
    required this.transitionType,
    this.fontSize,
    this.fontFamily,
    this.fill,
    this.strokeWidth,
    this.shadowBlur,
  });

  @override
  _TextWidgetState createState() => _TextWidgetState();
}

class _TextWidgetState extends State<TextWidget> {
  String _normalizeHtmlCss(String html) {
    return html
        .replaceAll('fontSize:', 'font-size:')
        .replaceAll('fontFamily:', 'font-family:')
        .replaceAll('textAlign:', 'text-align:')
        .replaceAll('textShadow:', 'text-shadow:');
  }

  String _getBodyInner() {
    if (widget.html.isNotEmpty) {
      return _normalizeHtmlCss(widget.html);
    }
    final fontSize = widget.fontSize ?? 16;
    final fontFamily = widget.fontFamily ?? 'Arial, sans-serif';
    final color = widget.fill ?? 'black';
    final strokeWidth = widget.strokeWidth ?? 0;
    final shadowBlur = widget.shadowBlur ?? 0;
    final styles = <String>[
      'font-size: ${fontSize}px',
      'font-family: $fontFamily',
      'color: $color',
      if (strokeWidth > 0) '-webkit-text-stroke-width: ${strokeWidth}px',
      if (strokeWidth > 0) 'text-stroke-width: ${strokeWidth}px',
      if (shadowBlur > 0) 'text-shadow: 0 0 ${shadowBlur}px rgba(0,0,0,0.5)',
      'width: 100%',
      'height: 100%',
      'display: flex',
      'align-items: center',
      'justify-content: center',
      'text-align: center',
    ];
    return '<p style="${styles.join('; ')}">${widget.text.isNotEmpty ? widget.text : ''}</p>';
  }

  @override
  Widget build(BuildContext context) {
    final data = _getBodyInner();
    return SizedBox.expand(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w =
              constraints.maxWidth.isFinite ? constraints.maxWidth : 400.0;
          final h =
              constraints.maxHeight.isFinite ? constraints.maxHeight : 100.0;
          return SizedBox(
            width: w,
            height: h,
            child: Html(
              data:
                  '<div style="width:100%;height:100%;display:flex;align-items:center;justify-content:center;text-align:center;">$data</div>',
              style: {
                'div': Style(
                  margin: Margins.zero,
                  padding: HtmlPaddings.zero,
                ),
                'p': Style(
                  margin: Margins.zero,
                  padding: HtmlPaddings.zero,
                ),
              },
            ),
          );
        },
      ),
    );
  }
}

final _stickerHtmlStyles = {
  'div': Style(
    margin: Margins.zero,
    padding: HtmlPaddings.zero,
  ),
  'img': Style(
    margin: Margins.zero,
    padding: HtmlPaddings.zero,
  ),
};

/// Renders sticker SVG via [Html] (settings.html or fetched SVG as data-URI img).
class StickerHtmlWidget extends StatefulWidget {
  final String svgUrl;
  final String? htmlContent;
  final VoidCallback onSvgEnd;
  final String transitionType;

  const StickerHtmlWidget({
    super.key,
    required this.svgUrl,
    this.htmlContent,
    required this.onSvgEnd,
    required this.transitionType,
  });

  @override
  State<StickerHtmlWidget> createState() => _StickerHtmlWidgetState();
}

class _StickerHtmlWidgetState extends State<StickerHtmlWidget> {
  Future<String>? _loadFuture;

  @override
  void initState() {
    super.initState();
    _loadFuture = _createLoadFuture();
  }

  @override
  void didUpdateWidget(covariant StickerHtmlWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.svgUrl != widget.svgUrl ||
        oldWidget.htmlContent != widget.htmlContent) {
      _loadFuture = _createLoadFuture();
    }
  }

  ({String? url, String? path}) _resolveSource() {
    if (widget.svgUrl.startsWith('http://') ||
        widget.svgUrl.startsWith('https://')) {
      return (url: widget.svgUrl, path: null);
    }
    if ((widget.svgUrl.startsWith('/_next') ||
            widget.svgUrl.startsWith('/static')) &&
        !widget.svgUrl.startsWith('http')) {
      return (url: 'https://signagexai.com${widget.svgUrl}', path: null);
    }
    String path = widget.svgUrl;
    if (widget.svgUrl.startsWith('file://')) {
      path = Uri.parse(widget.svgUrl).path;
    }
    return (url: null, path: path);
  }

  Future<String>? _createLoadFuture() {
    final html = widget.htmlContent?.trim();
    if (html != null && html.isNotEmpty) return null;
    final src = _resolveSource();
    // #region agent log
    agentDebugLog(
      location: 'campaign_view.dart:StickerHtmlWidget:_createLoadFuture',
      message: 'sticker_load_start',
      hypothesisId: 'H8_load',
      data: {
        'svgUrlKind': widget.svgUrl.isEmpty
            ? 'empty'
            : (widget.svgUrl.startsWith('data:image')
                ? 'data:image'
                : (widget.svgUrl.startsWith('http://') ||
                        widget.svgUrl.startsWith('https://'))
                    ? 'http'
                    : (widget.svgUrl.startsWith('file://')
                        ? 'file'
                        : 'path')),
        'svgUrlLen': widget.svgUrl.length,
        'srcUrl': src.url,
        'srcUrlLen': src.url?.length ?? 0,
        'srcPath': src.path,
        'srcPathLen': src.path?.length ?? 0,
      },
    );
    // #endregion
    if (src.url != null) {
      print('[LOG] StickerHtmlWidget: Loading SVG from URL: ${src.url}');
      return http.read(Uri.parse(src.url!));
    }
    if (src.path != null && src.path!.isNotEmpty) {
      print('[LOG] StickerHtmlWidget: Loading SVG from file: ${src.path}');
      return File(src.path!).readAsString();
    }
    return Future.value('');
  }

  String _wrapHtml(String inner) {
    return '<div style="width:100%;height:100%;display:flex;align-items:center;justify-content:center;overflow:hidden;">$inner</div>';
  }

  String _svgToHtmlImg(String svg) {
    final encoded = Uri.encodeComponent(svg);
    return _wrapHtml(
      '<img src="data:image/svg+xml;charset=utf-8,$encoded" '
      'style="max-width:100%;max-height:100%;object-fit:contain;" alt="" />',
    );
  }

  @override
  Widget build(BuildContext context) {
    final presetHtml = widget.htmlContent?.trim();
    if (presetHtml != null && presetHtml.isNotEmpty) {
      return SizedBox.expand(
        child: Html(
          data: _wrapHtml(presetHtml),
          style: _stickerHtmlStyles,
        ),
      );
    }

    return SizedBox.expand(
      child: FutureBuilder<String>(
        key: ValueKey(widget.svgUrl),
        future: _loadFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            final errStr = snapshot.error?.toString() ?? '';
            final errPreview =
                errStr.length > 160 ? errStr.substring(0, 160) : errStr;
            agentDebugLog(
              location: 'campaign_view.dart:StickerHtmlWidget:build',
              message: 'sticker_load_error',
              hypothesisId: 'H8_load',
              data: {
                'svgUrl': widget.svgUrl,
                'hasError': snapshot.hasError,
                'errorPreview': errPreview,
              },
            );
            print(
                '[ERROR] StickerHtmlWidget: Failed to load ${widget.svgUrl}: '
                '${snapshot.error}');
            return const Center(
              child: Icon(Icons.broken_image_outlined, color: Colors.grey),
            );
          }
          final raw = snapshot.data!.trim();
          if (raw.isEmpty) {
            agentDebugLog(
              location: 'campaign_view.dart:StickerHtmlWidget:build',
              message: 'sticker_load_empty',
              hypothesisId: 'H8_load',
              data: {
                'svgUrlLen': widget.svgUrl.length,
              },
            );
            return const Center(
              child: Icon(Icons.broken_image_outlined, color: Colors.grey),
            );
          }
          if (raw.contains('<html') || raw.contains('<body')) {
            return Html(data: raw, style: _stickerHtmlStyles);
          }
          if (raw.contains('<svg')) {
            return _buildStickerSvgContent(
              _normalizeSvgForParser(raw),
              transition: widget.transitionType,
              onEnd: widget.onSvgEnd,
              key: ValueKey('sticker_html_${widget.svgUrl}'),
            );
          }
          return Html(data: _svgToHtmlImg(raw), style: _stickerHtmlStyles);
        },
      ),
    );
  }
}

class SvgFileWidget extends StatefulWidget {
  final String svgUrl;
  final VoidCallback onSvgEnd;
  final String transitionType;

  const SvgFileWidget({
    super.key,
    required this.svgUrl,
    required this.onSvgEnd,
    required this.transitionType,
  });

  @override
  _SvgFileWidgetState createState() => _SvgFileWidgetState();
}

class _SvgFileWidgetState extends State<SvgFileWidget> {
  Future<String>? _loadFuture;

  @override
  void initState() {
    super.initState();
    _loadFuture = _createLoadFuture();
  }

  @override
  void didUpdateWidget(covariant SvgFileWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.svgUrl != widget.svgUrl) {
      _loadFuture = _createLoadFuture();
    }
  }

  ({String? url, String? path}) _resolveSource() {
    if (widget.svgUrl.startsWith('http://') ||
        widget.svgUrl.startsWith('https://')) {
      return (url: widget.svgUrl, path: null);
    }
    if ((widget.svgUrl.startsWith('/_next') ||
            widget.svgUrl.startsWith('/static')) &&
        !widget.svgUrl.startsWith('http')) {
      return (url: 'https://signagexai.com${widget.svgUrl}', path: null);
    }
    String path = widget.svgUrl;
    if (widget.svgUrl.startsWith('file://')) {
      path = Uri.parse(widget.svgUrl).path;
    }
    return (url: null, path: path);
  }

  Future<String> _createLoadFuture() {
    final src = _resolveSource();
    if (src.url != null) {
      print("[LOG] SvgFileWidget: Loading from URL: ${src.url}");
      return http.read(Uri.parse(src.url!));
    }
    print("[LOG] SvgFileWidget: Loading from file path: ${src.path}");
    return File(src.path!).readAsString();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Center(
        child: FutureBuilder<String>(
          key: ValueKey(widget.svgUrl),
          future: _loadFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError || !snapshot.hasData) {
              print(
                  "[ERROR] SvgFileWidget: Failed to load ${widget.svgUrl}: ${snapshot.error}");
              return const Center(
                  child: Icon(Icons.broken_image_outlined, color: Colors.grey));
            }

            final raw = snapshot.data!;
            final noDataImages = _stripDataUrlImagesFromSvg(raw);
            final noUnsupported = _stripUnsupportedSvgBlocks(noDataImages);
            final normalized = _normalizeSvgForParser(noUnsupported);
            try {
              final pic = SvgPicture.string(
                normalized,
                fit: BoxFit.contain,
                placeholderBuilder: (context) => const SizedBox(
                  width: 24,
                  height: 24,
                  child:
                      Center(child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              );
              return pic;
            } catch (e) {
              print("[ERROR] SvgFileWidget: Invalid SVG data: $e");
              return const Center(
                  child: Icon(Icons.broken_image_outlined, color: Colors.grey));
            }
          },
        ),
      ),
    );
  }
}

class WBViewWidget extends StatefulWidget {
  final String media;
  final VoidCallback onMediaEnd;

  const WBViewWidget({
    Key? key,
    required this.media,
    required this.onMediaEnd,
  }) : super(key: key);

  @override
  State<WBViewWidget> createState() => _WBViewWidgetState();
}

class _WBViewWidgetState extends State<WBViewWidget> {
  InAppWebViewController? _webViewController;
  double progress = 0;

  @override
  void dispose() {
    _webViewController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isMacOS) {
      return const SizedBox.shrink();
    }

    final String targetUrl;
    if (widget.media.startsWith('http://') ||
        widget.media.startsWith('https://')) {
      targetUrl = widget.media;
    } else {
      targetUrl = 'file://${widget.media}';
    }

    return SizedBox.expand(
      child: Column(
        key: ValueKey(widget.media),
        children: [
          if (progress < 1.0) LinearProgressIndicator(value: progress),
          Expanded(
            child: InAppWebView(
              key: ValueKey('wbview_${widget.media}'),
              initialUrlRequest:
                  URLRequest(url: WebUri.uri(Uri.parse(targetUrl))),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
              ),
              onWebViewCreated: (InAppWebViewController controller) {
                _webViewController = controller;
              },
              onProgressChanged: (controller, newProgress) {
                if (!mounted) return;
                setState(() {
                  progress = newProgress / 100.0;
                });
              },
              onLoadStop: (controller, url) {
                if (!mounted) return;
                setState(() {
                  progress = 1.0;
                });
              },
              onReceivedError: (controller, request, error) {
                print(
                    "[LOG] WBViewWidget load error: ${error.description}");
              },
              onReceivedHttpError: (controller, request, errorResponse) {
                print(
                    "[LOG] WBViewWidget HTTP error: ${errorResponse.statusCode}");
              },
            ),
          ),
        ],
      ),
    );
  }
}
